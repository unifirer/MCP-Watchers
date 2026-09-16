Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_graphify_wiring.tests.ps1
# Pester 3.4.0 idiom (team harness): run via
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_graphify_wiring.tests.ps1
# Headless check of how the launcher wires up graphify-rs: it must no longer
# launch the bare `graphify-rs watch` subcommand, and must now launch the
# ignore-aware wrapper with -WatchMode (keeping the literal "watch" token in
# the CommandLine so the existing teardown -match 'watch' still kills it).
$launcher = 'J:\audio\VAD\###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

Describe 'graphify-rs launch wiring' {
    It 'replaced the bare graphify-rs watch with the ignore-aware wrapper (no stale # OLD comment)' {
        $c = Get-Content -LiteralPath $launcher
        ($c | Where-Object { $_ -match '# OLD:.*Start-WatcherDetached.*graphify-rs' }) | Should BeNullOrEmpty
    }
    It 'launches the wrapper with -WatchMode (so teardown -match "watch" still matches)' {
        $c = Get-Content -LiteralPath $launcher
        ($c -join "`n") | Should Match 'graphify-watch-wrapper\.ps1'
        ($c -join "`n") | Should Match '-WatchMode'
    }
}

Describe 'watcher teardown wiring' {
    It 'launcher dot-sources the shared teardown module' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'Modules\\watcher_teardown\.ps1'
    }
    It 'trap calls Stop-AllWatchers (no longer inlines the per-process kill list)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'trap\s*\{'
        $c | Should Match 'Stop-AllWatchers'
        # The old inline foreach over $childProcs must be gone from the trap.
        ($c -split "`n" | Where-Object { $_ -match 'foreach \(\$p in \$childProcs\)' }) | Should BeNullOrEmpty
    }
    It 'registers a PowerShell.Exiting handler so window [X] close also tears down' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'Register-EngineEvent'
        $c | Should Match 'PowerShell\.Exiting'
    }
    It 'persists tracked root PIDs to the teardown state file' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'teardown-state\.json'
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard with
# an env var so the rediscovery child skips the second Invoke-Pester. -Path keeps
# the run scoped to THIS file (no cross-file contamination) instead of the whole
# tree. (Later Tasks live in tests/ alongside this file; only ONE such guard is
# needed.)
if (-not $env:GF_WIRE_TEST_RAN) {
    $env:GF_WIRE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
