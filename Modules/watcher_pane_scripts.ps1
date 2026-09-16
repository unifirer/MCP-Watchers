# Modules/watcher_pane_scripts.ps1
# Pane-script generation for the ###1 watcher launcher (beads vad-uzb, ###1 split).
# Dot-sourced by:
#   - ###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
#   - tests/launcher_watcher_panes.tests.ps1 (AST-extracts New-WatcherPaneScript)
#   - tests/launcher_pane_line_cap.tests.ps1 (AST-extracts New-WatcherPaneScript)
# SAFE TO DOT-SOURCE: defines New-WatcherPaneScript only; no top-level side
# effects (no launches, no writes, no directory creation).
#
# CALLER CONTRACT: New-WatcherPaneScript reads the caller-scope $wtPaneDir
# variable at CALL time to decide where to write tail_<label>.ps1. The launcher
# defines $wtPaneDir before the first call; harnesses define it as a temp dir
# before dot-sourcing this module. No $wtPaneDir is created here on purpose.
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments/hyphens (project rule).
function New-WatcherPaneScript {
    param(
        [string]$Label,
        [string]$LogPath,
        [string]$ErrPath,
        [string]$RepoRoot,
        [string]$HeartbeatPath,
        [string]$WatchPid = '',
        [string]$SupervisorLog = '',
        [string]$LaunchLog = '',
        [string]$LaunchErr = '',
        [string]$LockFile = ''
    )

    $scriptPath = Join-Path $wtPaneDir ("tail_$Label.ps1")
    # Single-quoted template; __LABEL__ / __LOG__ / __ERR__ are filled by simple
    # .Replace() (NOT -f, because the script body is full of literal { } braces
    # that -f would misparse). The pane polls BOTH the stdout log and its stderr
    # sidecar every 500ms in ONE foreground loop, printing only newly-appended
    # lines with a [label] / [label ERR] tag. This is the same reliable polling
    # tailer the original combined view used, adapted per-watcher. A foreground
    # polling loop is required because Get-Content -Wait blocks and a background
    # job's Write-Host does not surface to the pane's own console.
    # Embed the incremental byte-offset log reader (Modules/watcher_log_tail.ps1)
    # into every generated pane (leak fix 2026-09-06). Embedded rather than
    # dot-sourced so a generated pane stays self-contained: the harnesses
    # generate panes against FAKE repo roots, and a pane must not depend on
    # the repo layout at runtime.
    $tailModulePath = $null
    # $PSScriptRoot is EMPTY when the harnesses AST-extract this function and
    # dot-source it from a temp file - only trust it when non-empty, then fall
    # back to $env:VAD_WORKSPACE_ROOT so generation works everywhere.
    $cands = @()
    if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot 'watcher_log_tail.ps1') }
    if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot 'Modules\watcher_log_tail.ps1') }
    if ($env:VAD_WORKSPACE_ROOT) { $cands += (Join-Path $env:VAD_WORKSPACE_ROOT 'Modules\watcher_log_tail.ps1') }
    foreach ($cand in $cands) {
        if (Test-Path -LiteralPath $cand) { $tailModulePath = $cand; break }
    }
    if (-not $tailModulePath) { throw 'watcher_log_tail.ps1 not found next to the launcher or under $env:VAD_WORKSPACE_ROOT\Modules' }
    $tailModuleSrc = Get-Content -LiteralPath $tailModulePath -Raw -Encoding UTF8
    $template = @'
# Pane tailer for __LABEL__
$ErrorActionPreference = 'SilentlyContinue'
# Incremental byte-offset log reader, embedded from Modules/watcher_log_tail.ps1
# at generation time. LEAK FIX (2026-09-06): the old loop re-read the ENTIRE log
# with Get-Content on every 500ms tick (~173k full reads/day of large-array
# churn -> 4.25 GB and a constant CPU burn after 8 h on this repo).
__TAIL_MODULE__
$log = '__LOG__'
$err = '__ERR__'
$offLog = -1   # byte offset; -1 = not seeded yet (first tick seeds the backlog)
$offErr = -1
# Watcher-liveness guard (orphaned-tailer fix, 2026-08-21): the pane tailer must
# not outlive the watcher it displays. __WATCHPID__ is the watcher PID at launch
# ('' when this pane has no single backing process, e.g. grepai's tracked daemon,
# which is validated via its stale PID file below). Every poll tick we verify the
# watcher is still alive; when it dies we exit so Windows Terminal closes the
# pane (default closeOnExit) instead of leaving an orphaned tailer on a frozen log.
$watchPid = '__WATCHPID__'
function Test-WatcherAlive {
    param([string]$WatchedPid)
    if (-not $WatchedPid) { return $true }   # no tracked pid: no guard
    try {
        $p = Get-Process -Id ([int]$WatchedPid) -ErrorAction SilentlyContinue
        return ($null -ne $p)
    } catch { return $false }
}
# When this pane has no tracked watcher PID (grepai runs as a tracked background
# daemon), fall back to checking whether ANY live grepai process carries a 'watch'
# command line (i.e. a real watcher, not an mcp-serve MCP server).
function Test-GrepaiWatcherAlive {
    # VAD-ltnq (2026-09-06): liveness only needs ~2s resolution (the pane's
    # dead-watch grace window is 30 x 500ms ticks), so cache the verdict for
    # 2s instead of running a WMI/CIM Win32_Process query every 500ms tick
    # (~172k WMI queries/day on a long session). A cheap Get-Process runs
    # first: no grepai.exe at all means definitely not alive (zero CIM); the
    # CIM CommandLine disambiguation (watch vs mcp-serve) runs only when a
    # grepai process actually exists.
    try {
        if ($script:grepaiAliveCacheAt -and (((Get-Date) - $script:grepaiAliveCacheAt).TotalMilliseconds -lt 2000)) {
            return $script:grepaiAliveCache
        }
        $result = $false
        if (@(Get-Process -Name 'grepai' -ErrorAction SilentlyContinue).Count -gt 0) {
            $w = @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' })
            $result = ($w.Count -gt 0)
        }
        $script:grepaiAliveCache = $result
        $script:grepaiAliveCacheAt = Get-Date
        return $result
    } catch { return $false }
}
# VAD-v14z.3 single-healer gate, corrected by VAD-7qf0. The thread-job
# supervisor lives inside the launcher process, but a live launcher PID in the
# lock file is NOT proof the supervisor is alive: the VAD-jmw idle-TTL reap
# RETURNS the supervisor while the launcher keeps running, so the old gate
# (live launcher PID) skipped the pane heal forever and the pane stuck at
# "supervised restart pending". Gate on the supervisor's OWN liveness stamp
# (<lockfile>.sup, refreshed every supervisor tick) instead: a stale or missing
# stamp means the supervisor is gone and the pane heals as the fallback healer.
# An empty or unreadable lock path means unknown -> not alive (pane may heal).
function Test-SupervisorAlive {
    param([string]$LockPath, [int]$MaxAgeSeconds = 60)
    if ([string]::IsNullOrEmpty($LockPath)) { return $false }
    try {
        $stamp = [System.IO.Path]::ChangeExtension($LockPath, '.sup')
        if (-not (Test-Path -LiteralPath $stamp)) { return $false }
        $age = ((Get-Date) - (Get-Item -LiteralPath $stamp -ErrorAction Stop).LastWriteTime).TotalSeconds
        return ($age -lt $MaxAgeSeconds)
    } catch { return $false }
}
function Test-GrapheniumWatcherAlive {
    try {
        $w = @(Get-CimInstance Win32_Process -Filter "Name='gm.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' })
        return ($w.Count -gt 0)
    } catch { return $false }
}
function Test-GraphifyRsWatcherAlive {
    try {
        $w = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'graphify-watch-wrapper' -and $_.CommandLine -match 'WatchMode' })
        return ($w.Count -gt 0)
    } catch { return $false }
}
function Test-RepowiseWatcherAlive {
    try {
        $w = @(Get-CimInstance Win32_Process -Filter "Name='repowise.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' })
        return ($w.Count -gt 0)
    } catch { return $false }
}
# --- graphenium stale-graph AUTO-FIX (beads VAD-be9, 2026-08-25) ------------
# `gm` prints "Flag: .\graphenium-out\needs_update" when the persisted
# graphenium-out/ state is stale and must be rebuilt. Until then every MCP
# graph query answers from stale data and the line just sits in the pane.
# Heal = reap any lingering pre-0.19.4 `gm watch` (the INCREMENTAL watcher that
# replaced graph.json with only the changed files' nodes), drop the needs_update
# marker, then run a FULL `gm run` so the whole graph is rewritten. Incremental
# repair is NOT an option: `gm watch` / `gm run . --update` are what destroy the
# graph in the first place (see the "NO `gm watch`" block in ###1). Output is
# APPENDED to the same log files via cmd redirection so THIS tailer keeps
# reading them seamlessly (Start-Process's own redirect would decode as cp1252
# and mojibake gm's UTF-8 output). A 10-minute cooldown keeps any
# detect -> heal -> re-flag loop self-limiting.
$script:lastGmAutoFixTicks = 0
$script:gmHealUntilTick = 0
function Invoke-GrapheniumAutoFix {
    try {
        $nowTicks = [datetime]::UtcNow.Ticks
        $cooldownTicks = ([TimeSpan]::FromMinutes(10)).Ticks
        if ($script:lastGmAutoFixTicks -and ($nowTicks - $script:lastGmAutoFixTicks) -lt $cooldownTicks) { return }
        $script:lastGmAutoFixTicks = $nowTicks
        Write-Host "[graphenium AUTO-FIX] stale-graph flag detected - running a full gm rebuild..."
        # Reap a lingering PRE-FIX `gm watch`: it was the incremental (0.19.3)
        # watcher that overwrote graph.json with only the changed files' nodes,
        # so any copy still alive would immediately undo this heal.
        try {
            $procs = @(Get-CimInstance Win32_Process -Filter "Name='gm.exe'" -ErrorAction SilentlyContinue)
            foreach ($gp in $procs) {
                if ($gp.CommandLine -and $gp.CommandLine -match 'watch') {
                    try { Invoke-CimMethod -InputObject $gp -MethodName Terminate | Out-Null } catch { Write-Warning "[graphenium AUTO-FIX] failed to terminate stale gm watcher PID $($gp.ProcessId): $($_.Exception.Message)" }
                }
            }
        } catch {
            Write-Warning "[graphenium AUTO-FIX] stale gm watcher sweep failed: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 500   # let the killed watcher release its log handles
        try {
            $marker = Join-Path $repo 'graphenium-out\needs_update'
            if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
        } catch {
            Write-Warning "[graphenium AUTO-FIX] failed to clear needs_update marker: $($_.Exception.Message)"
        }
        $gmCmd = Get-Command 'gm.exe' -ErrorAction SilentlyContinue
        if (-not $gmCmd) {
            Write-Host "[graphenium AUTO-FIX] gm.exe not found on PATH - cannot rebuild; flag will reappear."
            return
        }
        # cmd /c with byte-level >> append keeps UTF-8 intact and lets this
        # tailer keep tailing the same $log/$err paths it opened at startup.
        # FULL build (never --update): gm's incremental mode REPLACES graph.json
        # with only the re-extracted files' nodes.
        $cmdLine = '/c ""' + $gmCmd.Source + '" run . --no-semantic --no-viz --no-report >> "' + $log + '" 2>> "' + $err + '""'
        Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -WorkingDirectory $repo -WindowStyle Hidden | Out-Null
        # Liveness grace: the respawned PID differs from the tracked one and may
        # need a moment to surface via CIM; keep the pane open for 45 s regardless.
        $script:gmHealUntilTick = ([datetime]::UtcNow + [TimeSpan]::FromSeconds(45)).Ticks
        Write-Host "[graphenium AUTO-FIX] full gm rebuild launched; post-heal output continues below."
    } catch {
        Write-Host ("[graphenium AUTO-FIX] heal failed: " + $_.Exception.Message)
    }
}
# Heartbeat file the launcher's controller loop watches. Every 4th poll tick
# (~2s, VAD-ltnq) we rewrite the current UTC tick count so the controller can
# detect when THIS pane (and thus the whole visible WT tab) has died -- closing the WT tab does
# NOT fire the controller's Ctrl+C trap or PowerShell.Exiting, so without this
# heartbeat the watchers would orphan. The filename carries the label so the
# launcher can tell which pane is alive.
$hbFile = '__HB__'
function Write-WatcherHeartbeat { param([string]$Path) try { [datetime]::UtcNow.ToFileTimeUtc().ToString() | Set-Content -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch {} }
# Repository root used to resolve which file graphify-rs changed. graphify-rs's
# "Files changed (N)" line does not name the file, so when exactly one file
# changed we infer it from the most-recently-written file under this root.
$repo = '__REPO__'
# In-memory set of RECENTLY-CHANGED files (canonical path -> DateTime). Instead of
# re-scanning the whole repo on every "N changed file(s)" event, a FileSystemWatcher
# feeds the actual changed paths here incrementally via Add-RecentChange. graphify-rs
# and repowise print ONLY a COUNT of changed files (never the paths), so we capture
# the real paths as the watcher sees them. This is race-free (a rebuild cascade fires
# many events but the SET of distinct files stays correct) and O(changes) instead of
# O(repo), so the pane never stalls on a large repo.
# NOTE: this MUST be $global:, NOT $script:. The FileSystemWatcher events are pumped
# on a SEPARATE runspace from the foreground poll loop, and an event Action block's
# $script: scope does NOT resolve to the main script's scope (it is empty there). Using
# $script: would make Add-RecentChange write to an invisible copy that Resolve-ChangedFiles
# never sees -> the pane shows no paths. $global: is the only per-process scope shared
# across both runspaces. Each pane is its own powershell.exe, so there is no cross-pane
# collision.
$global:recentChanges = @{}
# VAD-zfb6 (2026-09-06): the FSW event actions only ENQUEUE the raw path into
# this queue (O(1), separate-runspace safe via $global:) and the foreground
# poll loop drains it, running Add-RecentChange in the MAIN runspace. The old
# per-event Action did GetFullPath + segment splitting + cap bookkeeping on
# EVERY event on an unbounded PowerShell event queue - a churn burst queued
# faster than the runspaces drained it (transient memory spike).
$global:recentChangesQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

# Ingest a changed-path notification from the FileSystemWatcher. Canonicalizes the
# path (collapse "." / ".." segments, normalize drive-letter case) so the SAME
# physical file reported with different spellings ("J:\a\b.py" vs "j:\a\.\b.py")
# collapses to ONE entry -- this is the fix for the inconsistent-path-display bug.
# Applies the same dot-dir / scratch-dir exclusions as before, at INGEST time, so
# tool-state churn never pollutes the set and the pane surfaces only the user's real
# source edits. Keyed by canonical path with a DateTime value used to sort the
# most-recently-changed file(s) to the top.
function Add-RecentChange {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    try {
        $p = [System.IO.Path]::GetFullPath($Path)
    } catch {
        $p = $Path
    }
    # Normalize drive-letter case (e.g. "j:\..." -> "J:\..."). GetFullPath collapses
    # "." / ".." but does not reliably uppercase the drive letter on Windows.
    if ($p -match '^[a-z]:') {
        $p = [char]::ToUpper($p[0]) + $p.Substring(1)
    }
    # Skip dot-directories and known scratch dirs (the user's real edit, not tool state).
    $excludeDirNames = @('temp', 'panes', 'graphenium-out', 'graphify-out', '!!!AUTO_SCRIPTS!!!', 'node_modules', 'target', 'dist', 'build')
    foreach ($seg in ($p -split '[\\/]')) {
        if ($seg -like '.?*') { return }             # any dot-directory
        if ($excludeDirNames -ccontains $seg) { return }
    }
    $global:recentChanges[$p] = Get-Date
    # Bound the set (leak fix 2026-09-06): the table only exists to resolve
    # graphify-rs/repowise's "N changed file(s)" count into paths, and those
    # events always cite the MOST RECENT edits. Keep the newest 500 entries so
    # a long session cannot grow the table without limit.
    $recentChangesCap = 500
    if ($global:recentChanges.Count -gt $recentChangesCap) {
        $excess = $global:recentChanges.Count - $recentChangesCap
        $oldestKeys = @($global:recentChanges.GetEnumerator() |
            Sort-Object { $_.Value } |
            Select-Object -First $excess |
            ForEach-Object { $_.Key })
        foreach ($k in $oldestKeys) { $global:recentChanges.Remove($k) }
    }
}

# Watch the repo recursively and feed Add-RecentChange on every create/change/
# rename/delete. Exclusions are applied at ingest time (above), so tool-state churn
# never enters the set. Event processing is pumped by the foreground poll loop's
# Start-Sleep below. Guarded so a pane without a resolvable repo (e.g. grepai) simply
# has no watcher but still tails the logs.
if ($repo -and (Test-Path -LiteralPath $repo)) {
    try {
        $fsw = New-Object System.IO.FileSystemWatcher
        $fsw.Path = $repo
        $fsw.IncludeSubdirectories = $true
        $fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
        $fsw.Filter = '*'
        # VAD-zfb6: the default ~4 KB InternalBufferSize overflows on churn
        # bursts; InternalBufferOverflowException is swallowed and events are
        # dropped. 64 KB rides out a git checkout / npm install.
        $fsw.InternalBufferSize = 65536
        $null = Register-ObjectEvent -InputObject $fsw -EventName Created -SourceIdentifier 'repowise-fsw-created' -Action { $global:recentChangesQueue.Enqueue($Event.SourceEventArgs.FullPath) }
        $null = Register-ObjectEvent -InputObject $fsw -EventName Changed -SourceIdentifier 'repowise-fsw-changed' -Action { $global:recentChangesQueue.Enqueue($Event.SourceEventArgs.FullPath) }
        $null = Register-ObjectEvent -InputObject $fsw -EventName Renamed -SourceIdentifier 'repowise-fsw-renamed' -Action { $global:recentChangesQueue.Enqueue($Event.SourceEventArgs.FullPath) }
        $null = Register-ObjectEvent -InputObject $fsw -EventName Deleted -SourceIdentifier 'repowise-fsw-deleted' -Action { $global:recentChangesQueue.Enqueue($Event.SourceEventArgs.FullPath) }
        $fsw.EnableRaisingEvents = $true
    } catch {}
}
# Shared line filter: per-label throttle/suppression.
$throttleCount = 0
function ScrubNulBytes {
    param([string]$Line)
    # remove 0x00 control bytes so the pane shows clean text
    return ($Line -replace "`0", '')
}
function Convert-GrepaiLogLine {
    param([string]$s)
    if ($s -notmatch 'rpg_(full_reconcile_triggered|derived_refresh_ms|persist_ms)=') { return $s }
    $t = ''
    if ($s -match '^\d{4}/\d{2}/\d{2}\s+(\d{2}:\d{2}:\d{2})') { $t = "$($Matches[1]) " }
    if ($s -match 'rpg_full_reconcile_triggered=true') {
        $why = ''
        if ($s -match '(?:^|\s)reason=(\S+)') { $why = $Matches[1] }
        if ($why -eq 'periodic') { return "$($t)Code graph health check running (every 5 min)" }
        if ($why -eq '') { return "$($t)Code graph health check running" }
        return "$($t)Code graph health check running ($why)"
    }
    if ($s -match 'rpg_derived_refresh_ms=(\d+)') {
        $ms = $Matches[1]
        $changed = 0
        if ($s -match '(?:^|\s)changed_files=(\d+)') { $changed = [int]$Matches[1] }
        $queued = 0
        if ($s -match 'rpg_dirty_files_count=(\d+)') { $queued = [int]$Matches[1] }
        if ($changed -eq 0 -and $queued -eq 0) {
            return "$($t)Code graph up to date (checked in $ms ms)"
        }
        $bits = @()
        if ($changed -gt 0) { $bits += "$changed file(s) changed" }
        if ($queued -gt 0) { $bits += "$queued queued for update" }
        return "$($t)Code graph updated in $ms ms - " + ($bits -join ', ')
    }
    if ($s -match 'rpg_persist_ms=(\d+)') {
        return "$($t)Code graph saved to disk in $($Matches[1]) ms"
    }
    return $s
}

function CleanLogLine {
    param([string]$Line, [string]$Label)
    if ($null -eq $Line) { return $null }
    $s = ScrubNulBytes $Line
    # strip gm's own log-level tag (e.g. "[graphenium ERR]" or plain "[graphenium]"
    # that prefixes every line) - it is just a watch-event severity prefix gm
    # prints, NOT a real error, and only clutters the pane. Remove every
    # occurrence so "[graphenium ERR] changed (code): ..." (and plain
    # "[graphenium] Watching ...") display cleanly under the pane's own [graphenium] tag.
    $s = $s -replace '\[graphenium(?: [A-Z]+)?\]\s*', ''
    # grepai prefixes every line with "[grepai-watch]"; the pane already tags
    # lines with its own [grepai] label, so strip that redundant inner prefix.
    if ($Label -eq 'grepai') {
        $gwp = '[grepai-watch]'
        if ($s.StartsWith($gwp)) { $s = $s.Substring($gwp.Length).TrimStart() }
        $s = Convert-GrepaiLogLine $s
    }
    if ($s.Length -eq 0) { return $null }
    if ($Label -eq 'graphify-rs' -and ($s -match 'Large corpus detected|graph too large for interactive viz')) {
        $script:throttleCount++
        if ($script:throttleCount % 10 -ne 0) { return $null }   # show 1-in-10
    }
    # Drop graphify-rs's routine progress chatter - these lines carry no
    # actionable signal in the pane:
    #   Analyzing graph...
    #   Wrote, in <n> ...            (old summary form, if ever emitted)
    #   Wrote C:\...\file            (per-file write form, e.g. the rebuild
    #                                 dumps html/GRAPH_REPORT.md/graph.graphml)
    #   Skipped <n> sensitive file(s)   (prefixed by a warning glyph)
    # NOTE: graphify-rs indents some of these lines with leading whitespace
    # (the pane shows "[graphify-rs]   Wrote ..." where the two extra spaces
    # come from the raw line), so the match is anchored with an optional `\s*`
    # rather than a hard `^` - otherwise the leading spaces defeat the filter.
    if ($Label -eq 'graphify-rs' -and ($s -match '^Analyzing graph\.\.\.$|^\s*Wrote, in |^\s*Wrote |Skipped \d+ sensitive file')) {
        return $null
    }
    # drop repowise's VS Code setup notifications (MCP config + extension recommend)
    if ($Label -eq 'repowise' -and ($s -match 'VS Code')) { return $null }
    # drop repowise's per-file "Skipping oversized file" debug chatter (debug-level
    # noise with no actionable signal in the pane)
    if ($Label -eq 'repowise' -and ($s -match 'Skipping oversized file')) { return $null }
    # drop graphenium's noisy "Non-code files changed" stderr notice - it only
    # means a non-source file (docs/config/etc.) was edited; the semantic nodes
    # are refreshed on demand by `gm run`, so the nag adds no signal to the view
    if ($Label -eq 'graphenium' -and ($s -match 'Non-code files changed')) { return $null }
    $MaxPaneLineLen = 2000
    if ($s.Length -gt $MaxPaneLineLen) {
        $s = $s.Substring(0, $MaxPaneLineLen) + " ...[+$($s.Length - $MaxPaneLineLen) chars truncated]"
    }
    return $s
}
# graphify-rs / repowise log ONLY a COUNT of changed files (never the paths), so we
# resolve them from the in-memory $global:recentChanges set fed by the FileSystemWatcher
# (see Add-RecentChange). When N < 5 we print the resolved paths; for N >= 5 we stay
# silent rather than guess at a long list. Returns an array (may be empty if nothing
# has changed since the pane started, so we never report a file we didn't observe).
#
# WHY A FILESYSTEMWATCHER FEED INSTEAD OF A FULL-REPO SCAN:
# The old code re-scanned the whole repo (Get-ChildItem -Recurse) on every "Files
# changed" event to diff against a launch-time baseline. On this repo that scan takes
# 10-40s; by the time it finished, the user's real edit had aged past the stale
# baseline and the scan returned nothing -> the pane stalled / showed no path. Feeding
# an in-memory set from FSW events is O(changes), so resolution is sub-second and the
# pane never lags.
#
# WHY CANONICALIZATION MATTERS (the reported bug):
# The watcher path and the baseline path spelled the SAME file differently -- a ".\"
# segment ("J:\a\.\b.py") and a differing drive-letter case ("j:\a\b.py" vs "J:\a\b.py").
# Without canonicalization the same edit showed up with inconsistent strings and could
# be reported multiple times across a rebuild cascade. Add-RecentChange collapses every
# spelling to ONE canonical key (GetFullPath + uppercase drive letter), so the path
# displayed is always identical and the change is reported exactly once.
#
# WHY THE EXCLUSIONS MATTER (so the feed reports the USER's edit, not tool state):
# graphify-rs also rebuilds whenever the OTHER watchers write their state (.beads,
# .repowise, .grepai, .codegraph, .hermes, .claude, .codex, .serena, .playwright-mcp,
# .pytest_cache, .agents, .graphify-rs) or this launcher's own scratch (temp/, panes/,
# graphenium-out/) changes. Add-RecentChange excludes every dot-directory plus the
# known scratch dirs at INGEST time, surfacing only the user's real source edits.
# Note: `.?*` in -like matches a literal dot then >=1 char (the leading `.` is NOT a
# PowerShell wildcard in -like), i.e. exactly "dot dirs".
function Resolve-ChangedFiles {
    param([int]$MaxFiles = 1)
    $result = New-Object System.Collections.ArrayList
    if (-not $global:recentChanges -or $global:recentChanges.Count -eq 0) {
        Write-Output -NoEnumerate $result
        return
    }
    # Read the canonical paths from the FSW-fed set, most-recently-changed first.
    # The set is keyed by canonical path and valued by the DateTime it was last seen,
    # so a rebuild cascade (many events for one edit) collapses to exactly the right
    # file(s) and a file changed multiple times is reported exactly once. No repo scan
    # is needed, so this is sub-second even on a large repo (FM1).
    $sorted = $global:recentChanges.GetEnumerator() |
        Sort-Object { $_.Value } -Descending |
        Select-Object -First $MaxFiles |
        ForEach-Object { $_.Key }
    foreach ($p in $sorted) { $null = $result.Add($p) }
    # Return the array WITHOUT enumeration: PowerShell unrolls a 1-element array on
    # `return`, which would turn the single path string into its first CHAR ("J") and
    # break $files[0] in Show-ChangedFiles. -NoEnumerate keeps it an array.
    Write-Output -NoEnumerate $result
}

# Print the resolved changed files for a change-event line.
#  - graphify-rs emits ONLY a COUNT ("Files changed (N)") with no file names,
#    so resolve paths from the in-memory recentChanges set (Resolve-ChangedFiles)
#    for small N (< 5) to avoid flooding the pane.
#  - repowise emits ONLY a COUNT ("N changed file(s)") with no file names,
#    counting changes against ITS OWN content fingerprint index
#    (.repowise/state.json) -- NOT git. repowise also self-commits, so by the
#    time the pane queries `git status` the working tree no longer reflects the
#    files repowise counted; a git-status resolver therefore returns tool noise
#    and already-committed files instead of the user's actual edits. So we
#    resolve repowise's paths with the SAME FileSystemWatcher-fed recentChanges
#    set (Resolve-ChangedFiles) as graphify-rs: the user's real edit is the file
#    most recently fed by the watcher, so sorting by its ingestion time -Descending
#    surfaces exactly the right path(s). As with graphify-rs, paths are printed only
#    for N < 5; N >= 5 stays silent so the pane is not flooded.
# gm/graphenium/grepai already print paths inline, so other labels are no-ops.
function Show-ChangedFiles {
    param(
        [string]$Label,
        [string]$Line
    )
    if ($Label -eq 'graphify-rs') {
        $m = [regex]::Match($Line, 'Files changed \((\d+)\)')
        if ($m.Success) {
            $n = [int]$m.Groups[1].Value
            if ($n -lt 5) {
                $files = Resolve-ChangedFiles -MaxFiles $n
                foreach ($f in $files) { Write-Host ("[graphify-rs]   -> changed file: " + $f) }
            }
        }
        return
    }
    if ($Label -eq 'repowise') {
        # repowise is a git-aware pipx tool. Its change-event line carries ONLY
        # a COUNT of changed files, never the paths. The exact wording has drifted
        # across versions, so match the count robustly rather than a fixed phrase:
        #   old: "Detected N changed file(s), updating..."
        #   new: "<workspace>: N changed file(s), updating..."   (e.g. "vad: 2 changed file(s)")
        # Both contain "<N> changed file(s)", so anchor on that.
        $m = [regex]::Match($Line, '(\d+)\s+changed file\(s\)')
        if ($m.Success) {
            $n = [int]$m.Groups[1].Value
            # Suppress the per-file listing for large bursts (N >= 5) to keep the
            # pane readable -- mirrors the graphify-rs branch's N<5 gate. The user
            # only needs resolved paths for small, reviewable changes; bigger
            # waves are already summarized by repowise's own count line.
            if ($n -ge 5) { return }
            # repowise counts changes against its own content index and
            # self-commits, so `git status` is misaligned with what it reported.
            # Resolve via the mtime baseline diff (same as graphify-rs): the
            # user's real edit is the most-recently-written file, so it surfaces
            # the right path(s) without depending on git.
            $files = Resolve-ChangedFiles -MaxFiles $n
            $seen = @{}
            foreach ($f in $files) {
                if ($seen.ContainsKey($f)) { continue }
                $seen[$f] = $true
                Write-Host ("[repowise]   -> changed file: " + $f)
            }
        }
        return
    }
}
# Seed offsets to show a small recent backlog on open, then only NEW lines after.
# Reads go through Read-WatcherLogTail (UTF-8, byte offsets), so gm's real em
# dash (E2 80 94) shows as "-" instead of mojibake and only NEW bytes are read
# per tick (leak fix 2026-09-06 - the old loop re-read the whole file every
# 500ms). A trailing line without a newline terminator is held back by the
# reader and displayed once the writer finishes it.
$backlogLines = 30
if (Test-Path -LiteralPath $log) {
    # One-time FULL read for the backlog: the leak was re-reading the whole file
    # EVERY 500ms tick; a single seed read keeps the exact old last-N-lines
    # behavior (a multi-MB log line still surfaces its full cap marker once).
    $seed = Read-WatcherLogTail -Path $log -Offset 0
    $startIdx = [Math]::Max(0, $seed.Lines.Count - $backlogLines)
    for ($i = $startIdx; $i -lt $seed.Lines.Count; $i++) {
        $fl = CleanLogLine $seed.Lines[$i] '__LABEL__'
        if ($null -ne $fl) {
            Write-Host ("[__LABEL__] " + $fl)
            Show-ChangedFiles -Label '__LABEL__' -Line $seed.Lines[$i]
        }
    }
    $offLog = $seed.Offset
}
if ($err -and (Test-Path -LiteralPath $err)) {
    $eseed = Read-WatcherLogTail -Path $err -Offset 0
    $estartIdx = [Math]::Max(0, $eseed.Lines.Count - $backlogLines)
    for ($i = $estartIdx; $i -lt $eseed.Lines.Count; $i++) {
        $fl = CleanLogLine $eseed.Lines[$i] '__LABEL__'
        if ($null -ne $fl) { Write-Host ($(if ('__LABEL__' -eq 'graphenium' -or '__LABEL__' -eq 'repowise') { "[__LABEL__] " } else { "[__LABEL__ ERR] " }) + $fl) }
    }
    $offErr = $eseed.Offset
}
# VAD-3cr (2026-08-26): pane-local grepai heal. The generated pane script
# inherits NO launcher functions, so the old tick-30 call to the launcher-scope
# Invoke-GrepaiHealthCheck failed silently under SilentlyContinue and never
# healed. This embedded copy also repairs a corrupt gob index BEFORE relaunch,
# which breaks the 377-byte index.gob "unexpected EOF" crash loop.
function Invoke-GrepaiHealthCheck {
    param(
        [string]$RepoRoot,
        [string]$LaunchLog,
        [string]$LaunchErr,
        [string]$SupervisorLog,
        [string]$LockFile
    )
    $alive0 = @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' }).Count -gt 0
    if ($alive0) { Write-Host "[grepai HEALTH] watch daemon is live - no heal needed"; return $false }
    # VAD-v14z.3 single healer: the thread-job supervisor owns healing while
    # the launcher is alive. The pane heals only as a last resort when the
    # supervisor is gone (launcher dead, pane survived); otherwise concurrent
    # *.pid* clears + relaunches from both loops cause restart storms.
    if (Test-SupervisorAlive -LockPath $LockFile) {
        Write-Host "[grepai HEALTH] supervisor alive - skipping pane heal (single healer)"
        return $false
    }
    # VAD-v14z.3 heal mutex (machine-wide, non-blocking): even in the
    # supervisor-dead window, never clear *.pid* locks while another healer
    # holds the mutex - skip this tick instead of double-relaunching.
    $healMutex = $null
    $healAcquired = $false
    try {
        $healMutex = New-Object System.Threading.Mutex($false, 'Global\VAD_Grepai_Heal')
        try { $healAcquired = $healMutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $healAcquired = $true }
    } catch { $healAcquired = $false }
    if (-not $healAcquired) {
        Write-Host "[grepai HEALTH] heal already in progress - skipping pane heal"
        try { if ($healMutex) { $healMutex.Dispose() } } catch {}
        return $false
    }
    try {
    Write-Host "[grepai HEALTH] watch daemon down - auto-healing (repair + relaunch)..."
    $lockDir = Join-Path $env:LOCALAPPDATA 'grepai\logs'
    foreach ($pat in @('grepai-worktree-*.pid*', 'grepai-stop-*')) {
        Get-ChildItem -Path $lockDir -Filter $pat -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    try {
        $gd = Join-Path $RepoRoot '.grepai'
        if (Test-Path (Join-Path $gd 'config.yaml')) {
            $st = ''
            $hpsi = New-Object System.Diagnostics.ProcessStartInfo
            $hpsi.FileName = 'grepai'
            $hpsi.Arguments = 'status --no-ui'
            $hpsi.RedirectStandardOutput = $true
            $hpsi.RedirectStandardError = $true
            $hpsi.UseShellExecute = $false
            $hpsi.CreateNoWindow = $true
            $hpsi.WorkingDirectory = $RepoRoot
            $hproc = New-Object System.Diagnostics.Process
            $hproc.StartInfo = $hpsi
            try {
                if ($hproc.Start()) {
                    # VAD-1aw0 (2026-09-06): drain both pipes CONCURRENTLY
                    # before WaitForExit (deadlock-then-kill on large status
                    # output) and Dispose the Process in finally.
                    $hOut = $hproc.StandardOutput.ReadToEndAsync()
                    $hErr = $hproc.StandardError.ReadToEndAsync()
                    if (-not $hproc.WaitForExit(15000)) { try { $hproc.Kill() } catch {} }
                    else { $st = $hOut.Result + [Environment]::NewLine + $hErr.Result }
                }
            } catch {
                Write-Warning "[grepai HEALTH] status probe failed: $($_.Exception.Message)"
            }
            finally { try { $hproc.Dispose() } catch {} }
            if ($st -match 'failed to decode index' -or $st -match 'unexpected EOF' -or $st -match 'unknown storage backend') {
                foreach ($n in @('index.gob', 'symbols.gob', 'rpg.gob')) {
                    $p2 = Join-Path $gd $n
                    if (Test-Path $p2) { Remove-Item $p2 -Force -ErrorAction SilentlyContinue }
                }
                Write-Host "[grepai HEALTH] removed corrupted gob index before relaunch."
            }
            Get-ChildItem -LiteralPath $gd -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.Name -like '*.gob.tmp-*' } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Warning "[grepai HEALTH] gob repair failed: $($_.Exception.Message)"
    }
    $gpCmd = Get-Command 'grepai.exe' -ErrorAction SilentlyContinue
    if (-not $gpCmd) { Write-Warning "[grepai HEALTH] grepai.exe not found on PATH"; return $false }
    $gp = Start-Process -FilePath $gpCmd.Source -ArgumentList @('watch') `
        -WorkingDirectory $RepoRoot -WindowStyle Hidden `
        -RedirectStandardOutput $LaunchLog -RedirectStandardError $LaunchErr -PassThru
    Start-Sleep 2
    $alive1 = @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' }).Count -gt 0
    if ($alive1) { Write-Host "[grepai HEALTH] auto-heal SUCCESS - grepai watch relaunched (PID $($gp.Id))"; return $true }
    Write-Warning "[grepai HEALTH] auto-heal FAILED - grepai did not stay up"
    return $false
    } finally {
        try { $healMutex.ReleaseMutex() } catch {}
        try { $healMutex.Dispose() } catch {}
    }
}
Write-Host "=== __LABEL__ live log === (Ctrl+C in the launcher window stops all watchers)"
while ($true) {
    try {
        if (Test-Path -LiteralPath $log) {
            # LEAK FIX (2026-09-06): read only the bytes appended since the last
            # tick instead of the whole file (the old Get-Content-everything
            # per 500ms tick was the pane's memory/CPU leak). The reader holds
            # back a trailing partial line; the Rotated flag covers the old
            # truncation guard (a watcher restart truncating/rotating the log).
            $tail = Read-WatcherLogTail -Path $log -Offset ([Math]::Max(0, $offLog))
            $offLog = $tail.Offset
            if ($tail.Rotated) {
                Write-Host "=== __LABEL__ log rotated/truncated - resuming from tail ==="
            }
            foreach ($line in $tail.Lines) {
                $fl = CleanLogLine $line '__LABEL__'
                if ($null -ne $fl) {
                    Write-Host ("[__LABEL__] " + $fl)
                    Show-ChangedFiles -Label '__LABEL__' -Line $line
                    # graphenium stale-graph AUTO-FIX trigger (beads VAD-be9):
                    # react to gm's "Flag: .\graphenium-out\needs_update" line.
                    if ('__LABEL__' -eq 'graphenium' -and $line -match 'Flag' -and $line -match 'needs_update') { Invoke-GrapheniumAutoFix }
                }
            }
        }
        if ($err -and (Test-Path -LiteralPath $err)) {
            $etail = Read-WatcherLogTail -Path $err -Offset ([Math]::Max(0, $offErr))
            $offErr = $etail.Offset
            if ($etail.Rotated) {
                Write-Host "=== __LABEL__ log rotated/truncated - resuming from tail ==="
            }
            foreach ($line in $etail.Lines) {
                $fl = CleanLogLine $line '__LABEL__'
                if ($null -ne $fl) { Write-Host ($(if ('__LABEL__' -eq 'graphenium' -or '__LABEL__' -eq 'repowise') { "[__LABEL__] " } else { "[__LABEL__ ERR] " }) + $fl) }
                if ('__LABEL__' -eq 'graphenium' -and $line -match 'Flag' -and $line -match 'needs_update') { Invoke-GrapheniumAutoFix }
            }
        }
    } catch { }
    # VAD-zfb6: drain the FSW event queue here (the poll loop owns the per-path
    # canonicalization cost; the event actions only enqueued raw paths).
    $rcPath = $null
    while ($global:recentChangesQueue.TryDequeue([ref]$rcPath)) { Add-RecentChange $rcPath }
    # Watcher-liveness guard (orphaned-tailer fix, 2026-08-21): when the watcher
    # backing this pane is gone, exit so WT closes the pane instead of leaving an
    # orphaned tailer pointing at a dead watcher. For a tracked-PID pane use the
    # PID check with a fallback to an any-watch probe (so a PID rotation doesn't
    # kill the pane); for grepai (tracked daemon, no single PID) check for a live
    # 'grepai ... watch' process so MCP mcp-serve processes never count as a watcher.
    # ---
    # grepai is supervised (crash-restart ~5s). Tolerate a short death window so
    # the pane survives a supervised restart instead of closing mid-cycle.
    # 60 dead ticks @ 500ms ~= 30s > restart(5s)+launch latency. The longer window
    # also spans the tick-30 auto-heal (retried at tick 60), so a slow supervised
    # relaunch still recovers. A watcher still dead after grace closes the pane
    # exactly as before.
    if (-not $script:deadTicks) { $script:deadTicks = 0 }
    $alive = $true
    if ($watchPid) {
        $alive = Test-WatcherAlive $watchPid
        if (-not $alive) {
            if ('__LABEL__' -eq 'graphenium') { $alive = Test-GrapheniumWatcherAlive }
            elseif ('__LABEL__' -eq 'graphify-rs') { $alive = Test-GraphifyRsWatcherAlive }
            elseif ('__LABEL__' -eq 'repowise') { $alive = Test-RepowiseWatcherAlive }
            elseif ('__LABEL__' -eq 'grepai') { $alive = Test-GrepaiWatcherAlive }
        }
    }
    elseif ('__LABEL__' -eq 'grepai') { $alive = Test-GrepaiWatcherAlive }
    elseif ('__LABEL__' -eq 'graphenium') { $alive = Test-GrapheniumWatcherAlive }
    elseif ('__LABEL__' -eq 'graphify-rs') { $alive = Test-GraphifyRsWatcherAlive }
    elseif ('__LABEL__' -eq 'repowise') { $alive = Test-RepowiseWatcherAlive }
    else { $alive = $false }   # tracked pane with no watcher PID and no probe: close immediately
    # graphenium heal grace (beads VAD-be9): right after Invoke-GrapheniumAutoFix
    # kills the old watcher, the respawn may take a moment to surface via CIM;
    # force alive during a short post-heal window so the pane never self-closes.
    if ('__LABEL__' -eq 'graphenium' -and -not $alive -and $script:gmHealUntilTick -and [datetime]::UtcNow.Ticks -lt $script:gmHealUntilTick) { $alive = $true }
    if (-not $alive) {
        if ('__LABEL__' -eq 'grepai') {
            $script:deadTicks++
            Write-Host "=== __LABEL__ watcher down (tick $($script:deadTicks)) - supervised restart pending... ==="
            if ($script:deadTicks -ge 30 -and $script:deadTicks % 30 -eq 0) {
                Write-Host "[grepai HEALTH] auto-check triggered at tick $($script:deadTicks)..."
                $healResult = Invoke-GrepaiHealthCheck -RepoRoot '__REPO__' -LaunchLog '__LAUNCHLOG__' -LaunchErr '__LAUNCHERR__' -SupervisorLog '__SUPLOG__' -LockFile '__LOCKFILE__'
                if ($healResult) { $script:deadTicks = 0; $alive = $true }
            }
            if ($script:deadTicks -lt 60) { $alive = $true }
        } else {
            Write-Host "=== __LABEL__ watcher exited - closing pane ==="
            exit 0
        }
    } else {
        $script:deadTicks = 0
    }
    Start-Sleep -Milliseconds 500
    # VAD-ltnq (2026-09-06): write the heartbeat every 4th tick (~2s) instead
    # of every 500ms (4 panes x 2 file writes/s churned the same tick files).
    # The controller's dead-tab timeout is $hbTimeoutSec = 8s, so a 2s cadence
    # keeps full detection fidelity at 1/4 the churn.
    if (-not $script:hbTick) { $script:hbTick = 0 }
    $script:hbTick++
    if ($script:hbTick -ge 4) { $script:hbTick = 0; Write-WatcherHeartbeat $hbFile }
}
'@
    $body = $template.Replace('__LABEL__', $Label).Replace('__LOG__', $LogPath).Replace('__ERR__', $ErrPath).Replace('__REPO__', $RepoRoot).Replace('__HB__', $HeartbeatPath).Replace('__WATCHPID__', $WatchPid).Replace('__SUPLOG__', $SupervisorLog).Replace('__LAUNCHLOG__', $LaunchLog).Replace('__LAUNCHERR__', $LaunchErr).Replace('__LOCKFILE__', $LockFile).Replace('__TAIL_MODULE__', $tailModuleSrc)
    Set-Content -LiteralPath $scriptPath -Value $body -Encoding UTF8
    return $scriptPath
}

