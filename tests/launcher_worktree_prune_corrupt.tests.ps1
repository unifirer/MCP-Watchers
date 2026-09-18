# tests/launcher_worktree_prune_corrupt.tests.ps1
# Pester 3.4.0 (pinned). Regression for bead mcpw-759.
#
# The launcher auto-creates a git worktree for grepai indexing. A worktree left
# HALF-CONSTRUCTED by an interrupted run is DEGRADED: measured with the real
# git, `git -C <wt> rev-parse HEAD` prints nothing and exits 128. The old Layer
# 1 guard was
#     if ($wtHead -and $wtHead -eq $mainHead) { ...remove... }
# so $wtHead being empty made the guard FALSE and the degraded worktree was
# SKIPPED IN SILENCE on every run. `git worktree remove --force` refuses such a
# path too ("fatal: validation failed, cannot remove working tree"), so nothing
# ever cleaned it up and grepai re-used the dead directory and failed to index.
#
# These tests build a REAL throwaway git repository (no mocks), corrupt a real
# linked worktree, and assert the production prune function removes it.
#
# Run (single pass, reliable exit code):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
#     "if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }; Invoke-Pester -Path 'tests\launcher_worktree_prune_corrupt.tests.ps1' -EnableExit"
if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }

$repo     = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

function Get-LauncherFunctionText {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "launcher parse error: $($errors[0].Message)" }
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
    if ($fn.Count -ne 1) { throw "expected exactly 1 definition of $Name, found $($fn.Count)" }
    return $fn[0].Extent.Text
}

# Define the REAL production functions in this scope so every It block exercises
# launcher code, never a copy.
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Test-GitWorktreeUsable')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Invoke-GrepaiWorktreePrune')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Invoke-GrepaiWorktreeValidate')))

function New-ThrowawayRepo {
    param([string]$Base)
    $main = Join-Path $Base 'main'
    $wt   = Join-Path $Base 'wt-linked'
    New-Item -ItemType Directory -Path $main -Force | Out-Null
    & git -C "$main" init -q 2>$null
    & git -C "$main" config user.email 'mcpw759@example.invalid' 2>$null
    & git -C "$main" config user.name 'mcpw759' 2>$null
    & git -C "$main" config core.autocrlf false 2>$null
    Set-Content -LiteralPath (Join-Path $main 'a.txt') -Value 'hello' -Encoding ASCII
    & git -C "$main" add -A 2>$null
    & git -C "$main" commit -qm init 2>$null
    & git -C "$main" worktree add -b feat "$wt" 2>$null
    return [pscustomobject]@{ Main = $main; Worktree = $wt }
}

function Get-NormPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
}

# `git worktree list --porcelain` prints forward slashes on Windows. Compare in
# that form.
function Get-ListPath {
    param([string]$Path)
    return ((Get-NormPath -Path $Path) -replace '\\', '/')
}

Describe 'mcpw-759: Layer 1 prunes a corrupted grepai worktree' {

    It 'removes a worktree whose .git gitfile was deleted (--is-inside-work-tree fails)' {
        $base = Join-Path $repo ("temp\mcpw759-pester-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $savedCeiling = $env:GIT_CEILING_DIRECTORIES
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            # Stop git ascending out of the throwaway repo into this repository.
            $env:GIT_CEILING_DIRECTORIES = $repo
            $f = New-ThrowawayRepo -Base $base

            # Precondition: the fresh worktree IS usable.
            (Test-GitWorktreeUsable -Path $f.Worktree) | Should Be $true

            # Corrupt it the realistic way: a linked worktree's .git is a FILE
            # pointing at the parent repo. Deleting it is what an interrupted
            # teardown / antivirus sweep leaves behind.
            Remove-Item -LiteralPath (Join-Path $f.Worktree '.git') -Force

            # --- evidence: the degraded state git actually reports ---
            $inside = & git -C "$($f.Worktree)" rev-parse --is-inside-work-tree 2>$null
            $insideExit = $LASTEXITCODE
            $wtHead = & git -C "$($f.Worktree)" rev-parse HEAD 2>$null
            $mainHead = & git -C "$($f.Main)" rev-parse HEAD 2>$null
            $listed = @(& git -C "$($f.Main)" worktree list --porcelain 2>$null |
                Where-Object { $_ -match '^worktree ' })

            $insideExit | Should Be 128
            $wtHead | Should BeNullOrEmpty
            # This is the old guard. It is FALSE, which is why the old code
            # silently skipped the one case that matters.
            ($wtHead -and $wtHead -eq $mainHead) | Should Be $false
            # git still advertises the dead path.
            ($listed -join '|') | Should Match ([regex]::Escape((Get-ListPath $f.Worktree)))
            (Test-GitWorktreeUsable -Path $f.Worktree) | Should Be $false

            # --- the fix ---
            $removed = @(Invoke-GrepaiWorktreePrune -RepoRoot $f.Main -ExpectedWorktreePath $f.Worktree -ProtectedPath $f.Main)
            $removed.Count | Should Be 1
            (Get-NormPath $removed[0]) | Should Be (Get-NormPath $f.Worktree)
            (Test-Path -LiteralPath $f.Worktree) | Should Be $false
            # The main repository itself survived.
            (Test-Path -LiteralPath $f.Main) | Should Be $true
            $after = @(& git -C "$($f.Main)" worktree list --porcelain 2>$null |
                Where-Object { $_ -match '^worktree ' })
            ($after -join '|') | Should Not Match ([regex]::Escape((Get-ListPath $f.Worktree)))
        } finally {
            $env:GIT_CEILING_DIRECTORIES = $savedCeiling
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'removes a worktree whose .git gitfile was truncated to empty' {
        $base = Join-Path $repo ("temp\mcpw759-pester-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $savedCeiling = $env:GIT_CEILING_DIRECTORIES
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $env:GIT_CEILING_DIRECTORIES = $repo
            $f = New-ThrowawayRepo -Base $base
            # Truncate the gitfile: git reports "invalid gitfile format".
            Set-Content -LiteralPath (Join-Path $f.Worktree '.git') -Value '' -Encoding ASCII

            (& git -C "$($f.Worktree)" rev-parse --is-inside-work-tree 2>$null) | Should BeNullOrEmpty
            (Test-GitWorktreeUsable -Path $f.Worktree) | Should Be $false

            # git's own removal refuses this shape, so the directory can only be
            # cleared by the fallback. Prove git refused, then prove we removed.
            & git -C "$($f.Main)" worktree remove "$($f.Worktree)" --force 2>$null
            $gitRefused = ($LASTEXITCODE -ne 0)
            $gitRefused | Should Be $true
            (Test-Path -LiteralPath $f.Worktree) | Should Be $true

            $removed = @(Invoke-GrepaiWorktreePrune -RepoRoot $f.Main -ExpectedWorktreePath $f.Worktree -ProtectedPath $f.Main)
            $removed.Count | Should Be 1
            (Test-Path -LiteralPath $f.Worktree) | Should Be $false
        } finally {
            $env:GIT_CEILING_DIRECTORIES = $savedCeiling
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'still detects a degraded worktree NESTED inside an outer repository' {
        # Without a ceiling, `git -C <corrupt wt> rev-parse --is-inside-work-tree`
        # walks UP and answers "true" for the OUTER repo. Toplevel identity is
        # what stops that false positive from hiding the defect.
        $base = Join-Path $repo ("temp\mcpw759-pester-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $savedCeiling = $env:GIT_CEILING_DIRECTORIES
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $env:GIT_CEILING_DIRECTORIES = ''
            $f = New-ThrowawayRepo -Base $base
            Remove-Item -LiteralPath (Join-Path $f.Worktree '.git') -Force

            $top = & git -C "$($f.Worktree)" rev-parse --show-toplevel 2>$null
            # The outer repository answers for the dead path.
            (Get-NormPath $top) | Should Not Be (Get-NormPath $f.Worktree)
            (Test-GitWorktreeUsable -Path $f.Worktree) | Should Be $false

            $removed = @(Invoke-GrepaiWorktreePrune -RepoRoot $f.Main -ExpectedWorktreePath $f.Worktree -ProtectedPath $f.Main)
            $removed.Count | Should Be 1
            (Test-Path -LiteralPath $f.Worktree) | Should Be $false
        } finally {
            $env:GIT_CEILING_DIRECTORIES = $savedCeiling
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'preserves the guard: a clean fully-merged worktree is pruned, a dirty one is not' {
        $base = Join-Path $repo ("temp\mcpw759-pester-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $savedCeiling = $env:GIT_CEILING_DIRECTORIES
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $env:GIT_CEILING_DIRECTORIES = $repo
            $f = New-ThrowawayRepo -Base $base

            # Clean + HEAD == main: the pre-existing prune rule still applies.
            $removed = @(Invoke-GrepaiWorktreePrune -RepoRoot $f.Main -ExpectedWorktreePath $f.Worktree -ProtectedPath $f.Main)
            $removed.Count | Should Be 1
            (Test-Path -LiteralPath $f.Worktree) | Should Be $false

            # Now a healthy worktree carrying uncommitted work must survive.
            $f2 = New-ThrowawayRepo -Base (Join-Path $base 'dirty')
            Set-Content -LiteralPath (Join-Path $f2.Worktree 'uncommitted.txt') -Value 'wip' -Encoding ASCII
            $dirty = @(& git -C "$($f2.Worktree)" status --porcelain 2>$null)
            $dirty.Count | Should Be 1
            $removed2 = @(Invoke-GrepaiWorktreePrune -RepoRoot $f2.Main -ExpectedWorktreePath $f2.Worktree -ProtectedPath $f2.Main)
            $removed2.Count | Should Be 0
            (Test-Path -LiteralPath $f2.Worktree) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $f2.Worktree 'uncommitted.txt')) | Should Be $true
        } finally {
            $env:GIT_CEILING_DIRECTORIES = $savedCeiling
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'never removes the main worktree even when it is handed in as a candidate' {
        $base = Join-Path $repo ("temp\mcpw759-pester-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $savedCeiling = $env:GIT_CEILING_DIRECTORIES
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $env:GIT_CEILING_DIRECTORIES = $repo
            $f = New-ThrowawayRepo -Base $base
            # The linked worktree is clean and fully merged, so it IS pruned -
            # that is the pre-existing rule and it stays. The assertion is that
            # the MAIN worktree, handed in explicitly, is never among them.
            $removed = @(Invoke-GrepaiWorktreePrune -RepoRoot $f.Main -ExpectedWorktreePath $f.Main -ProtectedPath $f.Main)
            (@($removed | Where-Object { (Get-NormPath $_) -ieq (Get-NormPath $f.Main) }).Count) | Should Be 0
            (Test-Path -LiteralPath $f.Main) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $f.Main '.git')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $f.Main 'a.txt')) | Should Be $true
        } finally {
            $env:GIT_CEILING_DIRECTORIES = $savedCeiling
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'keeps Layer 2 (stale index.gob removal) working on a surviving worktree' {
        $base = Join-Path $repo ("temp\mcpw759-pester-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $savedCeiling = $env:GIT_CEILING_DIRECTORIES
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $env:GIT_CEILING_DIRECTORIES = $repo
            $f = New-ThrowawayRepo -Base $base
            # Dirty it so Layer 1 leaves it alone; Layer 2 must still clean the
            # orphaned index (a gob with no config.yaml is the stale shape).
            $wtGrepai = Join-Path $f.Worktree '.grepai'
            New-Item -ItemType Directory -Path $wtGrepai -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $wtGrepai 'index.gob') -Value 'stale' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $f.Worktree 'uncommitted.txt') -Value 'wip' -Encoding ASCII

            @(Invoke-GrepaiWorktreePrune -RepoRoot $f.Main -ExpectedWorktreePath $f.Worktree -ProtectedPath $f.Main).Count | Should Be 0
            Invoke-GrepaiWorktreeValidate -RepoRoot $f.Main
            (Test-Path -LiteralPath (Join-Path $wtGrepai 'index.gob')) | Should Be $false
            (Test-Path -LiteralPath $f.Worktree) | Should Be $true
        } finally {
            $env:GIT_CEILING_DIRECTORIES = $savedCeiling
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'orders Layer 1 (prune) before Layer 2 (validate) in the launcher' {
        $src = Get-Content -LiteralPath $launcher -Raw
        $i1 = $src.IndexOf('# Layer 1: Prune fully-merged stale worktrees')
        $i2 = $src.IndexOf('# Layer 2: Validate .grepai/ state in linked worktrees')
        $i1 | Should BeGreaterThan -1
        $i2 | Should BeGreaterThan -1
        ($i1 -lt $i2) | Should Be $true
    }
}
