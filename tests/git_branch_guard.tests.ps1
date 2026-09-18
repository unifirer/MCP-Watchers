# tests/git_branch_guard.tests.ps1
# Pester 3.4.0 (pinned). mcpw-sr4.
#
# Slash-named branches are silently discarded on the J: volume: `git branch a/b`
# exits 0, prints nothing, writes the reflog, and never creates the ref. The
# defect is intermittent - probes at 22:05 and 23:55 on this box created
# slash-named refs without incident - so these tests do NOT depend on the volume
# misbehaving. They pin the DETECTION instead, which must answer correctly in
# both states, and they run against a scratch repo on C: so the fixture itself
# cannot be swallowed by the defect.
if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$guardScript = Join-Path $repoRoot 'dev_tools\New-VerifiedGitBranch.ps1'

# Dot-source: defines the functions and does nothing else.
. $guardScript

function New-ScratchRepo {
    # Deliberately on the OS temp volume (C:), not J:, so a slash-named ref
    # created by the fixture cannot itself be discarded.
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('sr4-guard-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & git -C $dir init -q 2>&1 | Out-Null
    & git -C $dir config user.email 'guard@example.invalid' 2>&1 | Out-Null
    & git -C $dir config user.name 'mcpw-sr4 guard' 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'a.txt') -Value 'seed' -Encoding ASCII
    & git -C $dir add a.txt 2>&1 | Out-Null
    & git -C $dir commit -qm seed 2>&1 | Out-Null
    return $dir
}

Describe 'mcpw-sr4: slash-named branch guard' {

    It 'dot-sources with no side effects and defines the guard functions' {
        (Test-Path -LiteralPath $guardScript) | Should Be $true
        { . $guardScript } | Should Not Throw
        (Get-Command Test-GitBranchRefExists -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command Assert-GitBranchRef -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command New-VerifiedGitBranch -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }

    It 'reports an existing branch and rejects a name that was never created' {
        $dir = New-ScratchRepo
        try {
            New-VerifiedGitBranch -Name 'flat-ok' -Repo $dir | Should Be $true
            (Test-GitBranchRefExists -Repo $dir -Name 'flat-ok') | Should Be $true
            # The state the J: defect produces: exit 0, no ref.
            (Test-GitBranchRefExists -Repo $dir -Name 'ghost/branch') | Should Be $false
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails loudly with the flat-name guidance when the ref is missing' {
        $dir = New-ScratchRepo
        try {
            $err = $null
            try { Assert-GitBranchRef -Repo $dir -Name 'ghost/branch' } catch { $err = $_.Exception.Message }
            $err | Should Not BeNullOrEmpty
            $err | Should Match 'FLAT'
            $err | Should Match 'mcpw-sr4|refs/heads/ghost/branch'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'names the volume defect when a reflog exists but the ref does not' {
        $dir = New-ScratchRepo
        try {
            # Reproduce the exact fingerprint: reflog written, ref file absent.
            $phantom = Join-Path $dir '.git\logs\refs\heads\phantom\branch'
            New-Item -ItemType File -Path $phantom -Force | Out-Null
            $err = $null
            try { Assert-GitBranchRef -Repo $dir -Name 'phantom/branch' } catch { $err = $_.Exception.Message }
            $err | Should Match 'mcpw-sr4'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'an empty operand never reaches git (mcpw-9lf)' {
        (Test-GitBranchRefExists -Repo '' -Name 'x') | Should Be $false
        (Test-GitBranchRefExists -Repo (Get-Location).Path -Name '') | Should Be $false
        # Caught explicitly: PowerShell 7 raises ParameterBindingValidationException
        # for the empty mandatory -Name, and Pester 3 does not report that as a
        # `Should Throw` on every host. Either way git is never invoked.
        $threw = $false
        try { New-VerifiedGitBranch -Name '' | Out-Null } catch { $threw = $true }
        $threw | Should Be $true
    }
}
