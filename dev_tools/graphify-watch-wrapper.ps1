# dev_tools/graphify-watch-wrapper.ps1
# External, ignore-aware FileSystemWatcher that replaces graphify-rs's built-in
# `watch`. graphify-rs's own watch fired a rebuild on changes under ignored
# paths (e.g. its own output dir), which is wasteful. This wrapper gates every
# change through Test-PathIgnoredByGraphify (Task 1's gate module) and only
# rebuilds on real source edits, using the mandated CLI from
# Get-GraphifyRebuildArgs (which already returns the AGENTS.md --no-llm form).
#
# Launched detached as:
#   powershell.exe -NoProfile -WindowStyle Hidden -File <this> -WatchMode -Repo <path>
# The CommandLine carries the literal token "watch" so the launcher's existing
# `CommandLine -match 'watch'` teardown (###1.updater ... .ps1) still kills it.
#
# LEAK FIX (2026-09-06, beads VAD-iuyp): the old watch loop kept a
# Queue[string] of pending paths and restarted the debounce timer on EVERY
# event. During sustained churn (rebuild cascades write graphify-rs's own
# multi-MB outputs in small chunks -> thousands of Changed events per file)
# the timer never fired and the queue grew without bound; measured 4.3 GB and
# 65 threads after 8 h. Bounded now by: per-path dedupe (Dictionary), a cheap
# enqueue-time filter for .git/tool-output churn, a staleness flush when the
# oldest pending entry ages out, and a hard entry cap. The flush also batches
# the ignore check into ONE `git check-ignore --stdin` call instead of one
# subprocess per path.

# Task 1 exports Test-PathIgnoredByGraphify + Get-GraphifyRebuildArgs (and the
# batch form Test-PathsIgnoredByGraphify). Dot-source it so the gate +
# rebuild-arg logic live in exactly ONE place.
. (Join-Path $PSScriptRoot "..\modules\graphify_ignore_gate.ps1")

# Cheap, subprocess-free pre-filter applied at ENQUEUE time. Only the paths
# that would ALWAYS be rejected downstream are dropped here, so the flush-time
# gate (git check-ignore) semantics stay identical for everything else:
#   - .git internals (a commit writes thousands of chunks there; git
#     check-ignore does not classify .git paths as ignored)
#   - the always-excluded graphify/tool output dirs (same list as the gate)
# Dot-directories in general (e.g. .beads, .repowise state writes) still pass,
# exactly as before - the dedupe + staleness flush bound their volume.
function Test-GraphifyWatchPathWorthEnqueuing {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $RelativePath
    )
    $rel = $RelativePath -replace '\\', '/'
    if (-not $rel) { return $false }
    if ($rel -eq '.git' -or $rel.StartsWith('.git/')) { return $false }
    $safe = @('graphenium-out', 'graphify-rs-out', '.pytest_cache', 'tests/pytest.log', 'tests/_full_run_v2.txt')
    foreach ($d in $safe) {
        if ($rel -eq $d -or $rel.StartsWith("$d/")) { return $false }
    }
    return $true
}

# Record the intended rebuild and, while the watcher loop is live, actually
# run the graphify-rs rebuild. Extracted from Invoke-GraphifyChangeHandler so
# the batched flush (Invoke-GraphifyPendingFlush) can reuse the same
# record/rebuild behavior after ITS OWN gate decision.
#   -RecordTo  : optional file the wrapper appends a "REBUILD <relpath>" line
#                to (tests assert on this; operators may use it as an audit
#                trail)
#   -WatchMode : when present, a gated change actually runs the graphify-rs
#                rebuild (via Get-GraphifyRebuildArgs). When ABSENT the handler
#                only records - used by -ExportOnly / the test harness.
function Invoke-GraphifyRebuild {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $RelativePath,
        [string] $RecordTo,
        [switch] $WatchMode
    )
    $rel = $RelativePath -replace '\\', '/'
    if ($RecordTo) {
        Add-Content -LiteralPath $RecordTo -Value ("REBUILD " + $rel)
    }
    if (-not $WatchMode) { return }
    $args = Get-GraphifyRebuildArgs   # returns the --no-llm form (do NOT re-add -NoLlm)
    # Resolve graphify-rs.exe: try PATH first (lets tests inject a stub),
    # then fall back to the cargo bin. The launcher spawns this wrapper with
    # -NoProfile -WindowStyle Hidden, so the cargo bin dir is NOT in the
    # child session's PATH -- a bare `graphify-rs` call fails with
    # CommandNotFoundException. Falling back to the full path fixes that.
    $graphifyExe = (Get-Command 'graphify-rs' -ErrorAction SilentlyContinue).Source
    if (-not $graphifyExe) {
        $fallback = 'C:\Users\yuni\.cargo\bin\graphify-rs.exe'
        if (Test-Path -LiteralPath $fallback) { $graphifyExe = $fallback }
    }
    if (-not $graphifyExe) {
        Write-Error 'graphify-rs.exe not found on PATH or in cargo bin'
        return
    }
    # Route the rebuild output to THIS process's stdout. The launcher redirects
    # the child's stdout to the per-run log ($graphifyLog) that the graphify-rs
    # pane tails, so rebuild output is visible there. The old code wrote to a
    # SEPARATE $script:graphifyLog that defaulted to the SHARED
    # $env:TEMP\graphify-watch.log -- a path the pane never tails AND that
    # collided with any second wrapper instance ("file in use by another
    # process"). Writing to stdout removes that shared-path collision entirely.
    & $graphifyExe @args 2>&1
}

# Handle an individual change event (per-path API, unchanged semantics).
function Invoke-GraphifyChangeHandler {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $ChangedPath,
        [string] $RecordTo,
        [switch] $WatchMode
    )
    # Normalize to forward slashes for the gate.
    $rel = $ChangedPath -replace '\\', '/'
    # Output of our own rebuild must never trigger another rebuild. Test
    # artifacts (written by pytest every run) are NOT git-ignored, so without
    # the explicit entries below a single test run would pass the gate and
    # fire a full graphify-rs rebuild per wrapper instance.
    $safe = @('graphenium-out', 'graphify-rs-out', '.pytest_cache', 'tests/pytest.log', 'tests/_full_run_v2.txt')
    foreach ($d in $safe) {
        if ($rel -eq $d -or $rel.StartsWith("$d/")) { return }
    }
    # Primary gate: git check-ignore + .gitignore/.graphifyignore fallback.
    if (Test-PathIgnoredByGraphify -Repo $Repo -RelativePath $rel) { return }

    # Passed the gate: record and (in watch mode) rebuild.
    Invoke-GraphifyRebuild -Repo $Repo -RelativePath $rel -RecordTo $RecordTo -WatchMode:$WatchMode
}

# Drain-and-gate: run the rebuild path for every pending changed path, then
# clear the set. Extracted from the watch loop so the Pester harness can
# exercise the dedupe/flush behavior without a live FileSystemWatcher.
# The whole flush passes through ONE batched git check-ignore call
# (Test-PathsIgnoredByGraphify falls back to per-path checks when git is
# unavailable), so a large cascade costs one subprocess instead of hundreds.
# $Pending is cleared on return; the caller resets its own oldest-timestamp
# tracker afterwards.
function Invoke-GraphifyPendingFlush {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [System.Collections.Generic.Dictionary[string,datetime]] $Pending,
        [string] $RecordTo,
        [switch] $WatchMode
    )
    if ($Pending.Count -eq 0) { return }
    # Normalize to forward slashes ONCE: the batch gate reports and matches
    # forward-slash paths, and the REBUILD audit lines use them too.
    $paths = @($Pending.Keys | ForEach-Object { $_ -replace '\\', '/' })
    $Pending.Clear()
    $ignored = Test-PathsIgnoredByGraphify -Repo $Repo -RelativePaths $paths
    if (-not $ignored) { $ignored = New-Object 'System.Collections.Generic.HashSet[string]' }
    foreach ($rel in $paths) {
        if ($ignored.Contains($rel)) { continue }
        Invoke-GraphifyRebuild -Repo $Repo -RelativePath $rel -RecordTo $RecordTo -WatchMode:$WatchMode
    }
}

# Flush decision for the watch loop, extracted so the Pester harness can
# exercise the staleness/cap logic without a live FileSystemWatcher: flush
# when the oldest pending entry has aged past -MaxDebounceMs, or when the
# distinct-path cap is reached.
function Test-GraphifyWatchShouldFlush {
    param(
        [Parameter(Mandatory)] [int] $PendingCount,
        [Parameter(Mandatory)] [long] $OldestTicks,
        [Parameter(Mandatory)] [int] $MaxDebounceMs,
        [Parameter(Mandatory)] [int] $MaxPendingPaths
    )
    if ($PendingCount -le 0) { return $false }
    if ($PendingCount -ge $MaxPendingPaths) { return $true }
    if ($OldestTicks -le 0) { return $false }
    $ageMs = ([datetime]::UtcNow.Ticks - $OldestTicks) / 10000
    return ($ageMs -ge $MaxDebounceMs)
}

# Start the debounced FileSystemWatcher loop.
#   -Repo            : repo root to watch (IncludeSubdirectories)
#   -DebounceMs      : coalesce editor save bursts (default 1500ms)
#   -MaxDebounceMs   : staleness flush age - during sustained churn every
#                      event restarts the debounce timer, so without this the
#                      normal flush can be starved forever (default 30000ms)
#   -MaxPendingPaths : hard cap on distinct pending paths before an early
#                      flush (default 5000)
#   -RecordTo        : optional audit-log file (passed through to the handler)
function Start-GraphifyWatchLoop {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [int] $DebounceMs = 1500,
        [int] $MaxDebounceMs = 30000,
        [int] $MaxPendingPaths = 5000,
        [string] $RecordTo
    )
    # We use Register-ObjectEvent (no -Action) + Wait-Event. Registering WITHOUT
    # -Action keeps the events in the session queue; we then drain them in the
    # main loop below, where $Repo/$pending/$timer/$RecordTo are all in scope.
    # (Using -Action would run the callback in a separate scope where the closure
    # variables are NOT visible, so the enqueue/rebuild would silently no-op.)
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $Repo
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
    $watcher.EnableRaisingEvents = $true

    # Debounce state: collect changed relative paths, flush once the burst cools.
    # Dictionary (path -> last-seen time), NOT the old Queue[string]: a rebuild
    # cascade writes one file in many small chunks, and the old queue stored
    # EVERY event -> thousands of duplicate entries for the same path.
    $pending = New-Object 'System.Collections.Generic.Dictionary[string,datetime]'
    $pendingOldestTicks = [long]0
    $timer = New-Object System.Timers.Timer
    $timer.Interval = $DebounceMs
    $timer.AutoReset = $false

    Register-ObjectEvent -InputObject $watcher -EventName Changed  -SourceIdentifier 'gfChanged'  | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Created  -SourceIdentifier 'gfCreated'  | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed  -SourceIdentifier 'gfRenamed'  | Out-Null
    Register-ObjectEvent -InputObject $timer   -EventName Elapsed -SourceIdentifier 'gfTimer'    | Out-Null

    # Parent-death guard: this wrapper is spawned DETACHED by the launcher, so
    # it survives a hard-killed/crashed launcher (no teardown runs). Poll our
    # own parent PID every second; if it is gone, exit. This is the layer that
    # stops an orphaned wrapper even when the launcher never runs Stop-AllWatchers.
    $parentPid = 0
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction SilentlyContinue
        if ($me) { $parentPid = [int]$me.ParentProcessId }
    } catch {}
    if ($parentPid -le 0) { $parentPid = 0 }   # unknown -> treat as orphan-proof (skip guard)

    $timer.Start()
    try {
        # Block forever; the LAUNCHER teardown matches 'watch' in our CommandLine
        # and kills this process when the session ends. Wait-Event pumps the
        # registered .NET events so the watcher/timer callbacks actually run.
        while ($true) {
            if ($parentPid -gt 0) {
                try {
                    $parentAlive = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
                    if (-not $parentAlive) {
                        Write-Host "Parent launcher (PID $parentPid) is gone - exiting wrapper."
                        break
                    }
                } catch {}
            }
            $ev = Wait-Event -Timeout 1
            if ($ev) {
                try {
                    if ($ev.SourceIdentifier -eq 'gfTimer') {
                        # Cooldown elapsed: flush the pending burst.
                        Invoke-GraphifyPendingFlush -Repo $Repo -Pending $pending -RecordTo $RecordTo -WatchMode
                        $pendingOldestTicks = 0
                    } else {
                        # A file changed/created/renamed: enqueue (deduped) + restart debounce.
                        $full = $ev.SourceEventArgs.FullPath
                        if ($full) {
                            $rel = $full.Substring($Repo.Length).TrimStart('\', '/')
                            if ($rel -and (Test-GraphifyWatchPathWorthEnqueuing -Repo $Repo -RelativePath $rel)) {
                                if ($pending.Count -eq 0) { $pendingOldestTicks = [datetime]::UtcNow.Ticks }
                                $pending[$rel] = [datetime]::UtcNow
                                $timer.Stop(); $timer.Start()
                            }
                        }
                    }
                } finally {
                    Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
                }
            }
            # Staleness/cap flush: sustained churn restarts the debounce timer on
            # every event, so the normal timer flush can be starved indefinitely
            # and the pending set would grow without bound (the measured leak).
            # This check runs at least once per second (the Wait-Event timeout),
            # keeping the set bounded no matter how noisy the repo gets.
            if (Test-GraphifyWatchShouldFlush -PendingCount $pending.Count -OldestTicks $pendingOldestTicks -MaxDebounceMs $MaxDebounceMs -MaxPendingPaths $MaxPendingPaths) {
                Invoke-GraphifyPendingFlush -Repo $Repo -Pending $pending -RecordTo $RecordTo -WatchMode
                $pendingOldestTicks = 0
            }
        }
    } finally {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        $timer.Stop(); $timer.Dispose()
        Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue
    }
}

# Entry point. We deliberately avoid a top-level `param()` block: when this file
# is dot-sourced by the Pester harness (or re-run by Pester's own re-discovery),
# a `param()` block would try to bind the caller's stray $args positionally and
# throw. Parsing $args manually is bulletproof for both call styles:
#   - dot-source (tests):  . ".\graphify-watch-wrapper.ps1"  -> defines funcs, no-op
#   - launcher (live):     ... graphify-watch-wrapper.ps1 -WatchMode -Repo <path> [-DebounceMs N] [-RecordTo <log>]
# The `-WatchMode` token keeps the literal string "watch" in the CommandLine so
# the LAUNCHER's teardown (`CommandLine -match 'watch'`) still kills this process.
$GraphifyWatchWatchMode  = $false
$GraphifyWatchRepo       = ''
$GraphifyWatchDebounceMs = 1500
$GraphifyWatchRecordTo   = ''
# Rebuild output is written to this process's stdout (see Invoke-GraphifyRebuild),
# which the launcher redirects to the per-run log the graphify-rs pane tails. No
# separate log file is opened here, so there is no shared-path collision across
# wrapper instances (the old $env:TEMP\graphify-watch.log design did collide).
$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        '-WatchMode'  { $GraphifyWatchWatchMode  = $true }
        '-ExportOnly' { # defines functions only; no-op: funcs already in scope from dot-source
                         $null
                       }
        '-Repo'       { $i++; $GraphifyWatchRepo = $args[$i] }
        '-DebounceMs' { $i++; $GraphifyWatchDebounceMs = [int]$args[$i] }
        '-RecordTo'   { $i++; $GraphifyWatchRecordTo = $args[$i] }
    }
    $i++
}
# -ExportOnly is implicit when dot-sourced (no -WatchMode): we leave the functions
# available to the caller (e.g. Pester) and do not start the loop.
if ($GraphifyWatchWatchMode) {
    if (-not $GraphifyWatchRepo) { throw 'Start-GraphifyWatchLoop requires -Repo' }
    Start-GraphifyWatchLoop -Repo $GraphifyWatchRepo -DebounceMs $GraphifyWatchDebounceMs -RecordTo $GraphifyWatchRecordTo
}
