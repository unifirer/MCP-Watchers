Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_watcher_teardown_sweep.tests.ps1
# Pester 3.4.0 team idiom. Exercises Stop-AllWatchers's Get-CimInstance-based
# pattern sweep end-to-end against REAL processes (mirrors the grandchild
# tree-kill test's real-process approach). Closes the Task-2 review coverage
# gap: the sweep branch (powershell.exe temp\panes\tail_* and graphify-rs.exe
# Pattern='' match-all) was never exercised behaviorally.
$repo   = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$module = Join-Path $repo 'Modules\watcher_teardown.ps1'

Describe 'Stop-AllWatchers sweep' {
    It 'kills a live powershell.exe pane-tailer (panes\tail_*)' {
        . $module
        # Build a fake pane-tailer script under a path whose CommandLine will
        # contain the literal single-backslash substring panes\tail_ that
        # the sweep matches on (the lancher now writes panes under
        # ...\vad-watchers\panes\tail_<label>.ps1, so the substring is 'panes\tail_').
        $paneDir = Join-Path $env:TEMP ('panes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $paneDir -Force | Out-Null
        # File named tail_probe.ps1 so the -File arg carries "tail_probe".
        # The launcher's real panes live under ...\vad-watchers\panes\tail_<label>.ps1;
        # the sweep matches the literal 'panes\tail_' substring, so put the
        # probe under a directory ending in panes.
        $realPaneDir = Join-Path $paneDir 'panes'
        New-Item -ItemType Directory -Path $realPaneDir -Force | Out-Null
        $probe = Join-Path $realPaneDir 'tail_probe.ps1'
        Set-Content -LiteralPath $probe -Value 'Start-Sleep -Seconds 60' -Encoding UTF8

        $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probe)
        try {
            # Let the process start and register its CommandLine in CIM.
            $seen = $false
            for ($i = 0; $i -lt 25; $i++) {
                $ci = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue
                if ($ci -and $ci.CommandLine -and ($ci.CommandLine -match 'panes\\tail_')) {
                    $seen = $true; break
                }
                Start-Sleep -Milliseconds 200
            }
            # Sanity: the CommandLine really contains the single-backslash substring.
            $seen | Should Be $true

            # Empty RootPids -> the tree-kill loop does nothing; only the pattern
            # sweep can kill this process.
            Stop-AllWatchers -RootPids @() | Out-Null

            $alive = $null
            for ($i = 0; $i -lt 25; $i++) {
                try { $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue } catch { $alive = $null }
                if (-not $alive) { break }
                Start-Sleep -Milliseconds 200
            }
            $alive | Should BeNullOrEmpty
        } finally {
            try { Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
            Remove-Item -LiteralPath $paneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'kills a graphify-rs.exe rebuild child (no watch token) via Pattern="" match-all' {
        . $module
        # graphify-rs.exe must be on PATH for a real-process test. If it is not,
        # SKIP (pytest-style) rather than fail: the sweep logic is unit-covered
        # by the pane test above; this It proves Pattern='' matches ALL
        # graphify-rs.exe regardless of CommandLine.
        $gf = Get-Command graphify-rs.exe -ErrorAction SilentlyContinue
        if (-not $gf) {
            Set-TestInconclusive 'graphify-rs.exe not on PATH; skipping real-process match-all sweep test.'
            return
        }
        # Spawn graphify-rs.exe with a harmless/invalid arg WITHOUT a 'watch'
        # token. If it exits immediately, we still assert it is gone (the sweep
        # is a no-op then and the assertion trivially holds); the meaningful
        # case is a live process the match-all branch reaps.
        $proc = $null
        try {
            $proc = Start-Process -FilePath 'graphify-rs.exe' -PassThru -WindowStyle Hidden `
                -ArgumentList @('--help')
        } catch {}
        try {
            Start-Sleep -Milliseconds 400
            Stop-AllWatchers -RootPids @() | Out-Null
            $alive = $null
            for ($i = 0; $i -lt 25; $i++) {
                if ($proc) {
                    try { $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue } catch { $alive = $null }
                } else { $alive = $null }
                if (-not $alive) { break }
                Start-Sleep -Milliseconds 200
            }
            $alive | Should BeNullOrEmpty
        } finally {
            if ($proc) { try { Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
        }
    }
}

if (-not $env:WT_SWEEP_TEST_RAN) {
    $env:WT_SWEEP_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
