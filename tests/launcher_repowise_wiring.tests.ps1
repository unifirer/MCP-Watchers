# tests/launcher_repowise_wiring.tests.ps1
# Pester 3.4.0 idiom. Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_repowise_wiring.tests.ps1
# Source-wiring assertions that the repowise pane now (a) carries -RepoRoot so
# the resolver has a repo to diff, and (b) the tailer calls Show-ChangedFiles
# label-aware (unconditionally) instead of the old graphify-rs-only branch.
$launcher = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

Describe 'repowise pane wiring' {
    It 'repowise pane call now passes -RepoRoot $watchersWorkspaceRoot (mcpw-ybs.1)' {
        $c = Get-Content -LiteralPath $launcher
        ($c | Where-Object { $_ -match '-Label "repowise"' -and $_ -match '-RepoRoot \$watchersWorkspaceRoot' }) | Should Not BeNullOrEmpty
    }
    It 'tailer calls Show-ChangedFiles label-aware (unconditional)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'Show-ChangedFiles -Label'
    }
    It 'repowise call site matches Show-ChangedFiles signature (dead -Lines/-Index removed)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        ($c -split "`n" | Where-Object { $_ -match 'Show-ChangedFiles -Label .*-Line ' }) | Should Not BeNullOrEmpty
        ($c -split "`n" | Where-Object { $_ -match 'Show-ChangedFiles .*-Lines ' }) | Should BeNullOrEmpty
        ($c -split "`n" | Where-Object { $_ -match 'Show-ChangedFiles .*-Index ' }) | Should BeNullOrEmpty
    }
    It 'old graphify-rs-only branch guard is gone (now label-aware)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        ($c -split "`n" | Where-Object { $_ -match "if \('__LABEL__' -eq 'graphify-rs'\) \{ Show-ChangedFiles" }) | Should BeNullOrEmpty
    }
}

if (-not $env:RP_WIRING_TEST_RAN) {
    $env:RP_WIRING_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
