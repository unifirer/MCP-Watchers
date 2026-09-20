Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_grepai_clean_fixture.tests.ps1 (mcpw-zh7)
# Pester 3.4.0 (pinned). Guards the CLEAN .grepai fixture builder used by the
# T10b / T10d "a clean index must NOT be deleted" assertions in
# tests/launcher_tests.ps1.
#
# Failure mode this pins: launcher_tests.ps1 ran an UNGUARDED
#   Copy-Item -LiteralPath (Join-Path $repoRoot '.grepai') -Destination ...
# at T10b (~line 1164) and T10d (~line 1208). .grepai is gitignored tool state
# (.gitignore), so on a fresh clone or an extracted archive it does NOT exist.
# The harness runs with $ErrorActionPreference='Stop', so the Copy-Item threw
# ItemNotFoundException and aborted the whole suite: T10c-T10e and T18/T19 never
# ran. On a box that happens to have .grepai the bug stayed latent.
#
# The fix is a marker-wrapped helper, New-CleanGrepaiFixture, in
# launcher_tests.ps1. It copies the repo's real .grepai when present (that
# authentic whole-dir copy is what makes grepai report clean) and otherwise
# synthesizes a minimal config-only fixture so the no-false-delete path still
# runs.
#
# The helper SOURCE IS EXTRACTED from launcher_tests.ps1 between its begin/end
# markers and executed, so these assertions run against the shipped code rather
# than a hand-copied replica that could drift.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcherTests = Join-Path $repo 'tests\launcher_tests.ps1'

$MARK_BEGIN = '# === grepai clean fixture (begin) ==='
$MARK_END   = '# === grepai clean fixture (end) ==='

$suiteSrc = Get-Content -LiteralPath $launcherTests -Raw
$bIdx = $suiteSrc.IndexOf($MARK_BEGIN)
$eIdx = $suiteSrc.IndexOf($MARK_END)
if ($bIdx -lt 0 -or $eIdx -le $bIdx) {
    throw 'mcpw-zh7: grepai clean fixture begin/end markers not found in launcher_tests.ps1'
}
$fixtureSrc = $suiteSrc.Substring($bIdx, $eIdx - $bIdx + $MARK_END.Length)
# Define the REAL shipped helper in this scope.
Invoke-Expression $fixtureSrc

Describe 'grepai clean fixture helper (mcpw-zh7)' {

    It 'the shipped helper is extractable and defines New-CleanGrepaiFixture' {
        ($bIdx -ge 0) | Should Be $true
        ($eIdx -gt $bIdx) | Should Be $true
        $fixtureSrc.Contains('function New-CleanGrepaiFixture') | Should Be $true
        (Get-Command New-CleanGrepaiFixture -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }

    It 'synthesizes a clean fixture when the repo has NO .grepai (no exception)' {
        # A throwaway repo root that has no .grepai, exactly like a fresh clone.
        $tmp = Join-Path $env:TEMP ('zh7_norepo_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $savedRepoRoot = $repoRoot
        $savedEap = $ErrorActionPreference
        try {
            $repoRoot = $tmp
            # Match the harness: the original bug only throws under 'Stop'.
            $ErrorActionPreference = 'Stop'
            $proj = Join-Path $tmp 'project'
            $dest = $null
            $err = $null
            try { $dest = New-CleanGrepaiFixture -Parent $proj } catch { $err = $_ }
            ($null -eq $err) | Should Be $true
            # The helper must RETURN the fixture path.
            ($dest -eq (Join-Path $proj '.grepai')) | Should Be $true
            # And it must exist on disk with a config.yaml.
            (Test-Path -LiteralPath (Join-Path $dest 'config.yaml')) | Should Be $true
            # The config MUST declare a store backend. A bare `provider: ollama`
            # config makes grepai print "unknown storage backend:" - the string
            # Repair treats as corruption - so the fixture would be deleted.
            (Get-Content -LiteralPath (Join-Path $dest 'config.yaml') -Raw) | Should Match 'backend:\s*gob'
            # No gobs: the callers' [SKIP] branch must still apply.
            @(Get-ChildItem -LiteralPath $dest -Filter '*.gob' -ErrorAction SilentlyContinue).Count | Should Be 0
        } finally {
            $repoRoot = $savedRepoRoot
            $ErrorActionPreference = $savedEap
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'copies the REAL .grepai whole-dir when one exists' {
        $tmp = Join-Path $env:TEMP ('zh7_real_' + [guid]::NewGuid().ToString('N'))
        $realGrepai = Join-Path $tmp '.grepai'
        New-Item -ItemType Directory -Path $realGrepai -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $realGrepai 'config.yaml') -Value 'provider: ollama'
        [System.IO.File]::WriteAllBytes((Join-Path $realGrepai 'symbols.gob'), [byte[]](1..64))
        $savedRepoRoot = $repoRoot
        try {
            $repoRoot = $tmp
            $proj = Join-Path $tmp 'project'
            $dest = New-CleanGrepaiFixture -Parent $proj
            ($dest -eq (Join-Path $proj '.grepai')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $dest 'config.yaml')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $dest 'symbols.gob')) | Should Be $true
        } finally {
            $repoRoot = $savedRepoRoot
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'the helper copies .grepai only under a Test-Path guard' {
        # Match the real call, not the comment that names Copy-Item earlier.
        $guardIdx = $fixtureSrc.IndexOf('Test-Path -LiteralPath $real')
        $copyIdx = $fixtureSrc.IndexOf('Copy-Item -LiteralPath $real')
        ($guardIdx -ge 0) | Should Be $true
        ($copyIdx -gt $guardIdx) | Should Be $true
        # The unguarded literal that caused the abort must be gone.
        $suiteSrc.Contains("Copy-Item -LiteralPath (Join-Path `$repoRoot '.grepai') -Destination") | Should Be $false
    }

    It 'no unguarded Copy-Item of the repo .grepai remains in launcher_tests.ps1' {
        # Everything OUTSIDE the guarded helper must not copy .grepai at all.
        $outside = $suiteSrc.Remove($bIdx, ($eIdx - $bIdx + $MARK_END.Length))
        @($outside -split "`r?`n" | Where-Object { $_ -match 'Copy-Item' -and $_ -match '\.grepai' }).Count | Should Be 0
    }
}

if (-not $env:MCPW_ZH7_GREPAI_FIXTURE_TEST_RAN) {
    $env:MCPW_ZH7_GREPAI_FIXTURE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
