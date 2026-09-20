Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_watcher_teardown.tests.ps1
# Pester 3.4.0 team idiom.
$repo   = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$module = Join-Path $repo 'Modules\watcher_teardown.ps1'

Describe 'watcher_teardown module' {
    It 'module exists and dot-sources with no side effects' {
        Test-Path -LiteralPath $module | Should Be $true
        # Dot-sourcing must NOT throw / launch anything.
        { . $module } | Should Not Throw
    }

    It 'Stop-WatcherTree kills a grandchild spawned by a tracked root' {
        # Spin a REAL process tree: a powershell parent that spawns a long-lived
        # cmd.exe grandchild (ping -n 60). We record the grandchild PID to a file.
        $gcFile = Join-Path $env:TEMP ('gc_' + [guid]::NewGuid().ToString('N') + '.txt')
        $parent = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-Command',
                "& { `$c = Start-Process -FilePath cmd.exe -ArgumentList '/c ping -n 60 127.0.0.1' -PassThru -WindowStyle Hidden; `$c.Id > '$gcFile'; Start-Sleep -Seconds 60 }")
        try {
            # Wait for the grandchild to appear.
            $gchildPid = $null
            for ($i = 0; $i -lt 40; $i++) {
                if (Test-Path -LiteralPath $gcFile) {
                    $gchildPid = [int](Get-Content -LiteralPath $gcFile -Raw).Trim()
                    if ($gchildPid -gt 0) { break }
                }
                Start-Sleep -Milliseconds 200
            }
            $gchildPid | Should BeGreaterThan 0
            # The real shipped function, dot-sourced from the module:
            . $module
            Stop-WatcherTree -RootPid $parent.Id | Out-Null
            # Grandchild (the cmd.exe ping) must be dead now.
            $stillAlive = $null
            try { $stillAlive = Get-Process -Id $gchildPid -ErrorAction SilentlyContinue } catch {}
            $stillAlive | Should BeNullOrEmpty
        } finally {
            # Cleanup any survivor.
            try { Stop-WatcherTree -RootPid $parent.Id | Out-Null } catch {}
            Remove-Item -LiteralPath $gcFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'watcher_teardown sweep matches graphify wrapper' {
    # Regression guard for the root-cause fix. The graphify watcher is a
    # powershell.exe hosting graphify-watch-wrapper.ps1 -WatchMode (NOT a
    # panes\tail_ pane tailer). Stop-AllWatchers sweeps powershell.exe, so its
    # Pattern must match that command line or the wrapper orphans on every
    # launcher exit/crash and piles up (each orphan spawns a full graphify-rs
    # rebuild on every file change -> the launcher "crashes after a few minutes").
    # The matching line in the module is:
    #     $p.CommandLine -match [regex]::Escape($s.Pattern)
    # Replicating that EXACT predicate here locks the contract: the fix uses a
    # dedicated 'graphify-watch-wrapper' entry rather than an alternation glued
    # onto 'panes\tail_' with '|' (which [regex]::Escape neutralizes).
    function Match-Sweep { param([string]$CmdLine, [string]$Pattern) $CmdLine -and $CmdLine -match [regex]::Escape($Pattern) }

    $wrapperCmd = 'powershell.exe -NoProfile -WindowStyle Hidden -File "J:\audio\VAD\dev_tools\graphify-watch-wrapper.ps1" -WatchMode -Repo "J:\audio\VAD"'
    $paneCmd    = 'powershell.exe -File "J:\audio\VAD\Modules\panes\tail_foo.ps1"'

    It 'sweep matches the graphify-watch-wrapper command line (the fix)' {
        Match-Sweep $wrapperCmd 'graphify-watch-wrapper' | Should Be $true
        Match-Sweep $wrapperCmd 'panes\tail_'            | Should Be $false
    }
    It 'sweep still matches pane tailers' {
        Match-Sweep $paneCmd 'panes\tail_' | Should Be $true
    }
    It 'regression: "|"-glued alternation is neutralized by [regex]::Escape (must stay false)' {
        # The old, broken form. [regex]::Escape escapes '|' and '\', so the
        # combined pattern can never match either token. This LOCKS that the bug
        # must not be reintroduced.
        $broken = 'panes\\tail_|graphify-watch-wrapper'
        Match-Sweep $wrapperCmd $broken | Should Be $false
        Match-Sweep $paneCmd    $broken | Should Be $false
    }
}

Describe 'graphify_ignore_gate excludes test artifacts' {
    $gate = Join-Path $repo 'Modules\graphify_ignore_gate.ps1'
      It 'module dot-sources' { { . $gate } | Should Not Throw }

    It 'Test-PathIgnoredByGraphify returns $true for non-ignored test artifacts' {
        . $gate
        # These used to fall through git check-ignore (exit 1 = NOT ignored) and
        # trigger a full graphify-rs rebuild on every pytest run. They are now
        # hard-excluded in $safe, so the watcher no longer rebuilds on them.
        Test-PathIgnoredByGraphify -Repo $repo -RelativePath 'tests/_full_run_v2.txt' | Should Be $true
        Test-PathIgnoredByGraphify -Repo $repo -RelativePath '.pytest_cache'           | Should Be $true
        Test-PathIgnoredByGraphify -Repo $repo -RelativePath 'tests/pytest.log'        | Should Be $true
        # A real source change must still pass the gate (NOT ignored -> rebuild).
        Test-PathIgnoredByGraphify -Repo $repo -RelativePath 'src/grepai/foo.cs'       | Should Be $false
    }

    # mcpw-msy: the graphify-rs pane died ~1 min after the grid was built and the
    # launcher never respawned it. dev_tools\graphify-watch-wrapper.ps1 line 28
    # dot-sources Modules\graphify_ignore_gate.ps1. At the time of the bug that
    # module was missing from this repo - the extraction had not carried it over
    # - and d7389ad (2026-09-18) restored it, so it IS here now. Do not read this
    # comment as saying otherwise; the two tests below are what keep it from
    # going missing again.
    # The dot-source failed, then the first batched flush called
    # Test-PathsIgnoredByGraphify, got CommandNotFoundException, and the wrapper
    # exited - so the tailer saw its PID gone and closed the pane. These two
    # tests pin both halves: the file the wrapper depends on, and the batch form
    # whose absence actually killed the process.
    It 'the gate module the wrapper dot-sources exists' {
        $wrapper = Join-Path $repo 'dev_tools\graphify-watch-wrapper.ps1'
        $src = Get-Content -LiteralPath $wrapper -Raw
        if ($src -notmatch 'graphify_ignore_gate\.ps1') {
            throw 'the wrapper no longer dot-sources graphify_ignore_gate.ps1 - update this test'
        }
        (Test-Path -LiteralPath $gate) | Should Be $true
    }

    It 'Test-PathsIgnoredByGraphify (batch form) resolves and returns only ignored paths' {
        . $gate
        $batch = Test-PathsIgnoredByGraphify -Repo $repo -RelativePaths @('tests/_full_run_v2.txt', 'src/grepai/foo.cs')
        ($batch -contains 'tests/_full_run_v2.txt') | Should Be $true
        ($batch -contains 'src/grepai/foo.cs')      | Should Be $false
    }
}

Describe 'WT-tab heartbeat guard detects a closed tab' {
    # The controller console is hidden, so the only visible surface is the WT
    # tab. The launcher watches per-pane heartbeat tick files; if none tick for
    # the timeout the tab is treated as closed and Stop-AllWatchers runs. These
    # tests reproduce that staleness predicate without spawning real watchers.
    $timeout = 8
    function Get-IsPaneAlive {
        param([string]$Path, [int]$TimeoutSec = $timeout)
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { return $false }
        $ticks = [long]0
        if (-not [long]::TryParse($raw.Trim(), [ref]$ticks)) { return $false }
        try { $tick = [datetime]::FromFileTimeUtc($ticks) } catch { return $false }
        return (([datetime]::UtcNow) - $tick).TotalSeconds -le $TimeoutSec
    }

    It 'treats a freshly written tick file as alive' {
        $hb = Join-Path $TestDrive 'alive.hb'
        [datetime]::UtcNow.ToFileTimeUtc().ToString() | Set-Content -Path $hb
        Get-IsPaneAlive $hb | Should Be $true
    }

    It 'treats a missing tick file as dead (tab closed)' {
        Get-IsPaneAlive (Join-Path $TestDrive 'missing.hb') | Should Be $false
    }

    It 'treats a stale tick file (older than timeout) as dead' {
        $hb = Join-Path $TestDrive 'stale.hb'
        ([datetime]::UtcNow.AddSeconds(-($timeout + 5)).ToFileTimeUtc()) | Set-Content -Path $hb
        Get-IsPaneAlive $hb | Should Be $false
    }

    It 'treats a malformed tick file as dead' {
        $hb = Join-Path $TestDrive 'bad.hb'
        'not-a-tick' | Set-Content -Path $hb
        Get-IsPaneAlive $hb | Should Be $false
    }
}

Describe 'Stop-AllWatchers tree-kills a sweep-found wrapper host AND its rebuild child' {
    It 'kills an IN-SCOPE wrapper host and its graphify-rs rebuild child' {
        . $module
        # Fake wrapper HOST: a powershell whose CommandLine carries the
        # 'graphify-watch-wrapper' token, which spawns a long-lived grandchild
        # (cmd.exe ping) standing in for an in-flight `graphify-rs build`.
        # The grandchild is a TRUE descendant of the host so Stop-WatcherTree
        # (BFS by ParentProcessId) reaches it.
        # mcpw-lqy: this used to pass NO RootPids and rely on the unscoped
        # sweep. Stop-AllWatchers is now PID-SCOPED (deliberately - it is what
        # stops one launcher reaping another's watchers), so an empty scope
        # kills nothing and the assertion could never hold. The host is now
        # handed in as a root, which is how the launcher really calls it.
        $gcFile = Join-Path $env:TEMP ('gf_tree_' + [guid]::NewGuid().ToString('N') + '.txt')
        $hostProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command',
                "& { `$c = Start-Process -FilePath cmd.exe -ArgumentList '/c ping -n 90 127.0.0.1' -PassThru -WindowStyle Hidden; `$c.Id | Set-Content -Path '$gcFile' -Force; Start-Sleep -Seconds 90 }",
                '-WatchMode', '-graphify-watch-wrapper')
        $childPid = $null
        try {
            for ($i = 0; $i -lt 40; $i++) {
                if (Test-Path -LiteralPath $gcFile) {
                    $childPid = [int](Get-Content -LiteralPath $gcFile -Raw).Trim()
                    if ($childPid -gt 0) { break }
                }
                Start-Sleep -Milliseconds 200
            }
            $childPid | Should BeGreaterThan 0
            # In scope as a tracked root: the host dies with its grandchild.
            # Note this no longer isolates the CommandLine sweep path - the
            # step-1 tree-kill of the root reaches the pair first. The sweep's
            # matching rules are unit-covered elsewhere; what is locked here is
            # that an in-scope host never leaves an orphaned rebuild child.
            Stop-AllWatchers -RootPids @($hostProc.Id) | Out-Null
            $stillAlive = $null
            for ($i = 0; $i -lt 25; $i++) {
                try { $stillAlive = Get-Process -Id $childPid -ErrorAction SilentlyContinue } catch { $stillAlive = $null }
                if (-not $stillAlive) { break }
                Start-Sleep -Milliseconds 200
            }
            $stillAlive | Should BeNullOrEmpty
        } finally {
            try { Stop-WatcherTree -RootPid $hostProc.Id | Out-Null } catch {}
            Remove-Item -LiteralPath $gcFile -Force -ErrorAction SilentlyContinue
            try { Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'watchers\teardown-state.json') -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

if (-not $env:WT_TEARDOWN_TEST_RAN) {
    $env:WT_TEARDOWN_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
