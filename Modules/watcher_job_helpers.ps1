# Modules/watcher_job_helpers.ps1
# SINGLE SOURCE OF TRUTH for the shared job-scope helpers used by the ###1
# watcher launcher and its Start-ThreadJob / Start-Job supervisor scriptblocks.
#
# WHY THIS MODULE EXISTS (VAD-v14z.5): Start-ThreadJob and Start-Job run their
# scriptblocks in a FRESH runspace that does NOT inherit the launcher's functions
# (nor its script-scope variables). The launcher used to copy-paste these helpers
# into EVERY job scriptblock. The copies drifted and one was missing entirely: the
# grepai supervisor runspace had no Clear-StaleLocks definition, so the stale-lock
# cleaner threw "not recognized" on every restart, stale *.pid* locks were never
# cleared, and each relaunched `grepai watch` died instantly - the 1s
# crash-restart loop seen 2026-08-26. ONE canonical body per helper removes that
# whole drift class.
#
# DOT-SOURCED (literal path, never re-embedded) by:
#   - ###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
#     (top level - replaces the former parent-scope Clear-StaleLocks and
#     Limit-LogSize copies)
#   - the grepai crash-restart supervisor job scriptblock ($supervisorScript)
#   - the litellm crash-restart supervisor job scriptblock ($litellmSupervisorScript)
#   - the memtrace auto-heal supervisor job scriptblock ($memtraceHealScript)
#   - the backend auto-heal supervisor scriptblock ($backendSupervisorScript, vad-10m.2)
# SAFE TO DOT-SOURCE: no top-level side effects (definitions only, no launches,
# no writes, no param() block).
#
# DEDUPED (vad-0si): the grepai supervisor scriptblock no longer keeps inline
# copies of Clear-StaleLocks and Test-LauncherAlive - it dot-sources this file
# (fresh-runspace scope rule). Pinned by tests/launcher_tests.ps1 T22 and
# tests/test_launcher_worktree_quoting.py against the canonical bodies here.
# The supervisor's corrupt-gob repair block stays inline (T10e pins its
# begin/end markers), so this module must not define Repair-CorruptGobIndex.
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

# Clear the stale grepai lock files that make a relaunched `grepai watch` exit
# immediately (the worktree *.pid* locks and the grepai-stop-* markers).
#
# mcpw-eud: %LOCALAPPDATA%\grepai\logs is MACHINE-GLOBAL - every repository on
# this box writes there (J:\audio\VAD and J:\audio\MCP-Watchers both do). The old
# sweep deleted every match unconditionally, so a heal in repo A destroyed repo
# B's LIVE lock and B could then be launched a second time against a lock it
# believed was clear. Removal is now gated on Test-GrepaiLockStale: a lock goes
# only when it is provably stale (its owner PID is gone) or provably OURS (its
# sibling worktree log names $ProjectRoot). Anything we cannot attribute is LEFT
# ALONE - the same trade the mcpw-ybs.2 orphan sweep makes: a leftover lock is
# recoverable, a sibling repository's live watcher is not.
function Clear-StaleLocks {
    param([string]$ProjectRoot)
    $lockDir = Join-Path $env:LOCALAPPDATA 'grepai\logs'
    $stalePatterns = @('grepai-worktree-*.pid*', 'grepai-stop-*')
    foreach ($pat in $stalePatterns) {
        Get-ChildItem -Path $lockDir -Filter $pat -ErrorAction SilentlyContinue |
            Where-Object { Test-GrepaiLockStale -LockFile $_.FullName -ProjectRoot $ProjectRoot } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# mcpw-eud: is this grepai lock/stop marker safe for THIS workspace to remove?
#
# Two shapes live in the shared logs dir (measured 2026-09-20 against grepai
# v1.19.0 on this box):
#   grepai-stop-<pid>           the background watcher's PID marker. The owner
#                               PID is IN THE NAME, so staleness is decidable
#                               for every workspace: stale iff that PID is gone.
#   grepai-worktree-<id>.pid*   older-build worktree locks. They carry no
#                               project key, so the only ownership evidence is
#                               the sibling grepai-worktree-<id>.log, whose
#                               first line reads "Starting grepai watch in
#                               <project>". Removable only when that log names
#                               $ProjectRoot.
# An unrecognised shape is never removed. Returns $true only when removal is
# provably safe.
function Test-GrepaiLockStale {
    param([string]$LockFile, [string]$ProjectRoot)
    if ([string]::IsNullOrWhiteSpace($LockFile)) { return $false }
    $name = [System.IO.Path]::GetFileName($LockFile)
    if ($name -match '^grepai-stop-(\d+)$') {
        return -not [bool](Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)
    }
    if ($name -match '^grepai-worktree-([^.]+)\.pid') {
        if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return $false }
        $dir = [System.IO.Path]::GetDirectoryName($LockFile)
        $sibling = Join-Path $dir ("grepai-worktree-" + $Matches[1] + ".log")
        if (-not (Test-Path -LiteralPath $sibling)) { return $false }
        $mine = ([System.IO.Path]::GetFullPath($ProjectRoot)).TrimEnd('\', '/').ToLowerInvariant()
        try {
            $txt = Get-Content -LiteralPath $sibling -Raw -ErrorAction Stop
            return ([string]$txt).ToLowerInvariant().Contains($mine)
        } catch { return $false }
    }
    return $false
}

# mcpw-0on: per-attempt redirect pair for a grepai (re)spawn.
#
# Start-Process -RedirectStandardOutput truncates its target and holds the handle
# for the child's entire lifetime. Every restart path pointed at the SAME
# grepai-launch.log / .err pair, so a retry either hit a sharing violation or
# interleaved two children's progress bars into one file - which is why the
# launch logs were unreadable mixtures of different runs (92 "exited immediately
# after restart" flaps take that path). Attempt 1 keeps the canonical pair the
# pane tailer watches; every later attempt gets its own suffixed pair, so no two
# children ever share a redirect target and each log stays attributable to one
# run. Nothing is overwritten, so earlier attempts stay on disk for inspection.
function Get-GrepaiSpawnLogPair {
    param([string]$LogPath, [string]$ErrPath, [int]$Attempt = 1)
    if ($Attempt -le 1) {
        return [PSCustomObject]@{ Log = $LogPath; Err = $ErrPath }
    }
    return [PSCustomObject]@{
        Log = "$LogPath.attempt$Attempt"
        Err = "$ErrPath.attempt$Attempt"
    }
}

# VAD-hne6 (2026-09-06): size-cap rotation for append-style watcher/supervisor
# logs. Appending forever let multi-day sessions grow multi-GB logs under
# C:\Temp\vad-watchers and %LOCALAPPDATA%. When $Path exceeds $MaxMb it is
# renamed to "<path>.old" (one previous generation kept, overwritten) and the
# next append recreates it. ONLY call this on logs whose writer REOPENS the
# file per append (Out-File -Append style) - never on pump-held FileStreams
# (gm.log / repowise.log), where truncation by another process would turn the
# pump's next write into a sparse hole. The pane tailers already tolerate
# rotation via Read-WatcherLogTail's Rotated flag.
function Limit-LogSize {
    param([string]$Path, [int]$MaxMb = 16)
    try {
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($fi.Length -gt ($MaxMb * 1MB)) {
                Move-Item -LiteralPath $Path -Destination ("$Path.old") -Force -ErrorAction Stop
            }
        }
    } catch { }
}

# Returns $true while the launcher that wrote the lock file at $Path is still
# alive. The lock file is JSON { Pid, StartedAt, Launcher }; StartedAt guards
# against PID reuse and the Launcher token guards against a same-PID process
# that is not this launcher. This is the canonical liveness gate for the grepai,
# litellm, and memtrace supervisor runspaces (all dot-source this module).
function Test-LauncherAlive {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if (-not $json -or -not $json.Pid) { return $false }
        $proc = Get-Process -Id $json.Pid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $false }
        if ($json.StartedAt) {
            try {
                $lockStarted = [datetime]::ParseExact($json.StartedAt, 'o', $null, [Globalization.DateTimeStyles]::RoundtripKind)
                if ($proc.StartTime -and [math]::Abs(($proc.StartTime - $lockStarted).TotalSeconds) -gt 5) {
                    return $false
                }
            } catch { }
        }
        if ($json.Launcher) {
            $expectedToken = $json.Launcher
            $cmdLine = ''
            try { $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($json.Pid)").CommandLine } catch { Write-Warning "Could not read launcher command line for PID $($json.Pid): $($_.Exception.Message)" }
            if (-not ($cmdLine -and $cmdLine -match [regex]::Escape($expectedToken))) {
                return $false
            }
        }
        return $true
    } catch { return $false }
}

# VAD-yrx (2026-09-13): fail-fast preflight for the litellm proxy config.
# Windows cp1252 redirected output cannot encode non-ASCII placeholders
# (e.g. U+00AB / U+2026 / U+00BB in an api_key), so litellm aborts before
# bind. Validate ASCII-only plus best-effort YAML; on failure emit a clear
# error naming file:line and return $false so callers abort the spawn.
# Dot-sourced into both the launcher and the litellm supervisor runspace.
function Test-LitellmConfig {
    param([string]$ConfigPath)
    if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Error "litellm config not found: $ConfigPath - skipping litellm launch."
        return $false
    }
    try {
        $lines = Get-Content -LiteralPath $ConfigPath -Encoding UTF8
    } catch {
        Write-Error "litellm config unreadable at ${ConfigPath}: $($_.Exception.Message) - skipping litellm launch."
        return $false
    }
    $ln = 0
    foreach ($line in $lines) {
        $ln++
        $col = 0
        foreach ($ch in $line.ToCharArray()) {
            $col++
            $code = [int][char]$ch
            if ($code -gt 127) {
                $hex = ('U+{0:X4}' -f $code)
                if ($line -match 'api_key') {
                    Write-Error "litellm config has non-ASCII api_key char $hex at ${ConfigPath}:${ln} (col $col) - refusing to launch litellm. Fix line $ln to pure ASCII (e.g. api_key: sk-REPLACE-ME)."
                } else {
                    Write-Error "litellm config has non-ASCII char $hex at ${ConfigPath}:${ln} (col $col) - refusing to launch litellm. Fix line $ln to pure ASCII."
                }
                return $false
            }
        }
    }
    try {
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) {
            $pyOut = & python -c "import sys,yaml; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$ConfigPath" 2>&1
            if ($LASTEXITCODE -ne 0) {
                $txt = [string]$pyOut
                if ($txt -match 'No module named') { return $true }
                Write-Error "litellm config YAML parse failed at ${ConfigPath}: $txt - refusing to launch litellm."
                return $false
            }
        }
    } catch { }
    return $true
}

# VAD-0m6 (2026-09-13): exponential backoff for the litellm supervisor.
# Maps consecutive probe failures to a sleep delay: base * 2^(n-1),
# capped at MaxSeconds. Resets to base when the caller resets its
# consecutive-failure counter on a successful probe. PS 5.1 compatible,
# ASCII-only, no side effects (pure function for job runspaces).
function Get-LitellmBackoffDelay {
    param([int]$ConsecutiveFailures, [int]$BaseSeconds = 10, [int]$MaxSeconds = 300)
    if ($ConsecutiveFailures -le 1) { return $BaseSeconds }
    if ($BaseSeconds -lt 1) { $BaseSeconds = 10 }
    if ($MaxSeconds -lt $BaseSeconds) { $MaxSeconds = $BaseSeconds }
    try {
        $delay = [int]([math]::Pow(2, ($ConsecutiveFailures - 1)) * $BaseSeconds)
    } catch {
        return $MaxSeconds
    }
    if ($delay -gt $MaxSeconds) { return $MaxSeconds }
    if ($delay -lt $BaseSeconds) { return $BaseSeconds }
    return $delay
}

# VAD-olv (2026-09-13): reap prior litellm proxy child before relaunch.
# The supervisor dead path used to overwrite $currentProxyPid without killing
# the prior child, so rapid relaunches left multiple litellm contending for
# :4000 (losers die as port already in use while probe still reports dead).
# Best-effort Stop-Process -Force plus short wait for :4000 release.
# Already-exited or never-started PIDs (<=0 or missing) return $false with
# no throw. PS 5.1 compatible, ASCII-only. Dot-sourced into the litellm
# supervisor runspace via Modules\watcher_job_helpers.ps1.
# NOTE (vad-olv): this reaper only knows the PID it is handed. Deciding
# WHICH PID that is - and whether a spawn is safe at all - is
# Get-LitellmProxyRelaunchPlan below, because the launcher's initial detached
# proxy is never handed to the supervisor runspace.
function Stop-PriorLitellmProxy {
    param([int]$PriorPid)
    if ($PriorPid -le 0) { return $false }
    try {
        $p = Get-Process -Id $PriorPid -ErrorAction SilentlyContinue
        if ($null -eq $p) { return $false }
        try { Stop-Process -Id $PriorPid -Force -ErrorAction SilentlyContinue } catch { }
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 100
            $still = Get-Process -Id $PriorPid -ErrorAction SilentlyContinue
            if ($null -eq $still) { break }
        }
        return $true
    } catch { return $false }
}

# VAD-olv (2026-09-15): reap-OR-REUSE plan for the litellm proxy on :4000.
# Root cause of the rapid-relaunch port-4000 contention: the supervisor dead
# path spawned a fresh proxy without knowing whether the previous one was
# still alive. Two proxies then raced for the bind; the loser died as "port
# already in use" while the probe still reported dead, and the loop repeated
# every ~15s. Knowing one PID is not enough - the launcher's initial detached
# proxy is never handed to the supervisor runspace, and litellm.exe is a
# console-script shim whose python child owns the listening socket.
# So this plan looks at BOTH the tracked child and whatever currently LISTENs
# on the port, and answers two questions for the caller:
#   Action 'reuse' -> a live proxy owns :4000 from inside its startup window
#                     (GraceSec). It is BINDING, not hung. Do NOT spawn a
#                     second one; let the next probe decide.
#   Action 'spawn' -> nothing live remains; ReapPids lists every PID the
#                     caller must reap (Stop-PriorLitellmProxy) before the
#                     spawn, so the port is released first.
# Read-only: this function never kills anything. PS 5.1 compatible, ASCII-only.
function Get-LitellmProxyRelaunchPlan {
    param(
        [int]$PriorPid,
        [int]$Port = 4000,
        [int]$GraceSec = 30
    )
    try {
        $listening = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    } catch {
        $listening = @()
    }
    $live = @()
    if ($PriorPid -gt 0) { $live += $PriorPid }
    foreach ($c in $listening) {
        $owner = [int]$c.OwningProcess
        if ($owner -gt 0 -and ($live -notcontains $owner)) { $live += $owner }
    }
    $reap = @()
    foreach ($tid in $live) {
        $p = Get-Process -Id $tid -ErrorAction SilentlyContinue
        if ($null -eq $p) { continue }
        $ageSec = -1
        try { $ageSec = ((Get-Date) -$p.StartTime).TotalSeconds } catch { $ageSec = -1 }
        if ($ageSec -ge 0 -and $ageSec -lt $GraceSec) {
            return [PSCustomObject]@{ Action = 'reuse'; ReapPids = @(); Port = $Port }
        }
        $reap += $tid
    }
    return [PSCustomObject]@{ Action = 'spawn'; ReapPids = $reap; Port = $Port }
}

# VAD-gfn (2026-09-13): preserve litellm crash stderr across restarts.
# Start-Process -RedirectStandardError overwrites $Log.err each spawn, so a
# crash (e.g. UnicodeEncodeError/charmap) is lost on the next relaunch.
# Before each spawn, append the prior $Log.err to $Log.err.history with a
# timestamp header, then let the spawn overwrite $Log.err as latest.
# Bounded via Limit-LogSize (default 16MB + one .old generation).
# PS 5.1 compatible, ASCII-only. Dot-sourced into the litellm supervisor
# runspace via Modules\watcher_job_helpers.ps1.
function Backup-LitellmStderr {
    param([string]$LogPath, [int]$MaxMb = 16)
    try {
        if (-not $LogPath) { return }
        $err = "$LogPath.err"
        if (-not (Test-Path -LiteralPath $err)) { return }
        $fi = Get-Item -LiteralPath $err -ErrorAction Stop
        if (-not $fi -or $fi.Length -eq 0) { return }
        $history = "$LogPath.err.history"
        Limit-LogSize -Path $history -MaxMb $MaxMb
        $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        $header = "===== $ts preserving $err ($($fi.Length) bytes) ====="
        $header | Out-File -FilePath $history -Append -Encoding UTF8
        try {
            Get-Content -LiteralPath $err -Raw -ErrorAction Stop | Out-File -FilePath $history -Append -Encoding UTF8
        } catch {
            try { Get-Content -LiteralPath $err -ErrorAction Stop | Out-File -FilePath $history -Append -Encoding UTF8 } catch { }
        }
        Limit-LogSize -Path $history -MaxMb $MaxMb
    } catch { }
}

# --- VAD-jmw (2026-09-15): grepai idle TTL -----------------------------------
# grepai has no idle timeout of its own (`grepai watch --help` exposes none) and
# no query counter, so the long-running `grepai watch` daemon holds the embedding
# model (~1.9 GB RSS measured on this repo) forever after its index scan ends.
# The grepai crash-restart supervisor owns the only long-lived poll loop, so the
# TTL lives there: it reaps the watcher once the index has been idle for the TTL
# and RETURNS, so an idle exit is never mistaken for a crash (no relaunch loop).
# The decision logic stays here, dot-sourced into that fresh supervisor runspace,
# like every other helper in this module.
#
# Idle is measured from grepai's OWN worktree log: the newest line that is real
# indexing work. grepai emits housekeeping lines on a fixed cadence (a periodic
# rpg_full_reconcile every rpg_full_reconcile_interval_sec - 300s in this repo -
# plus a 60s rpg_persist), so a bare log-mtime clock resets every 5 minutes and
# would never expire. Observed 2026-09-15: the log grew every 5 min with
# changed_files=0 while the watcher sat idle at ~1.9 GB.

# $true when the grepai log line is real indexing work. Housekeeping lines (the
# watcher's own periodic reconciles and index persists) return $false so they do
# not reset the idle clock.
function Test-GrepaiActivityLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    if ($Line -match 'rpg_full_reconcile_triggered=') { return $false }
    if ($Line -match 'rpg_derived_refresh_ms=\d+.*changed_files=0(\s|$)') { return $false }
    if ($Line -match 'rpg_persist_ms=') { return $false }
    return $true
}

# Newest start time among live `grepai.exe ... watch` processes, or $null when
# no watcher runs. Used only as a freshness reference for the log clock below.
function Get-GrepaiWatchStartTime {
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' })
        if ($procs.Count -eq 0) { return $null }
        return @($procs | ForEach-Object { $_.CreationDate } | Sort-Object -Descending)[0]
    } catch { return $null }
}

# Idle minutes from grepai's OWN state file. grepai rewrites
# <repo>\.grepai\config.yaml on every index operation and stamps
# watch.last_index_time there, so this clock is authoritative AND independent of
# how the watcher was launched - a watcher started with -RedirectStandardOutput
# still updates it. Returns $null when the value is absent or unparseable.
#
# VAD-1ak (2026-09-17): this is the fix for the reap loop. The log clock below
# only works for an UN-redirected watcher; every launcher-spawned watcher is
# redirected, so the worktree log went hours stale and the supervisor computed
# idle ages of 156-584 min against a 20-min TTL and reaped a healthy watcher on
# every ###1 launch.
function Get-GrepaiIdleMinutesFromConfig {
    param([string]$ConfigPath)
    if (-not $ConfigPath) { return $null }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    try {
        $txt = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        if ($txt -match '(?m)^\s*last_index_time:\s*(\S+)\s*$') {
            $ts = [datetime]::MinValue
            if ([datetime]::TryParse($Matches[1], [ref]$ts)) {
                return [math]::Round(((Get-Date) - $ts).TotalMinutes, 1)
            }
        }
    } catch { }
    return $null
}

# Minutes since the newest real indexing work in the newest grepai worktree log.
# Returns -1 when the idle age is UNKNOWN (no log, a log the live watcher
# predates, unreadable, unparseable timestamp, or a window holding only
# housekeeping). Callers must treat -1 as "do not reap": never kill a watcher
# whose idle age cannot be measured.
function Get-GrepaiIdleMinutesFromLog {
    param([string]$LogDir, [int]$MaxLines = 300)
    if (-not $LogDir) { $LogDir = Join-Path $env:LOCALAPPDATA 'grepai\logs' }
    try {
        $newest = Get-ChildItem -Path $LogDir -Filter 'grepai-worktree-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) { return -1 }
        # Freshness guard (VAD-1ak): a redirected watcher never writes this file,
        # so a log older than the watcher running now was left by a DEAD instance.
        # Measuring idle against it reaped healthy watchers. Return -1 instead.
        $watchStart = Get-GrepaiWatchStartTime
        if ($watchStart -and $newest.LastWriteTime -lt $watchStart) { return -1 }
        $lines = @(Get-Content -LiteralPath $newest.FullName -Tail $MaxLines -ErrorAction SilentlyContinue)
        if ($lines.Count -eq 0) { return -1 }
        $stampLine = $null
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if (Test-GrepaiActivityLine -Line $lines[$i]) { $stampLine = $lines[$i]; break }
        }
        # Window holds housekeeping only: real work is older than the window, so
        # the idle age is UNKNOWN. Return -1 (do not reap) rather than sampling
        # the oldest line, which overstates idle and can reap a healthy watcher
        # (VAD-z0mg; observed 346.4 min idle tripping the 20-min TTL).
        if (-not $stampLine) { return -1 }
        if ($stampLine -match '(\d{4}/\d{2}/\d{2}) (\d{2}:\d{2}:\d{2})') {
            $ts = [datetime]::ParseExact("$($Matches[1]) $($Matches[2])", 'yyyy/MM/dd HH:mm:ss', $null)
            return [math]::Round(((Get-Date) - $ts).TotalMinutes, 1)
        }
        return -1
    } catch { return -1 }
}

# Minutes since grepai last did real indexing work. Returns -1 when the idle age
# is UNKNOWN; callers must treat -1 as "do not reap".
#
# Two clocks, because neither is complete alone (VAD-1ak, 2026-09-17):
#   - .grepai/config.yaml watch.last_index_time: grepai's own clock, written on
#     every index operation regardless of how the watcher was launched.
#   - the newest grepai-worktree-*.log: written only by UN-redirected watchers,
#     and now guarded against stale instances left by a dead watcher.
# The result is the MOST RECENT activity either clock can prove, so a watcher is
# reported idle only when both agree. Overstating idle is what reaped healthy
# watchers; understating it merely delays a reap.
function Get-GrepaiIdleMinutes {
    param([string]$LogDir, [int]$MaxLines = 300, [string]$ConfigPath)
    $known = @()
    $fromConfig = Get-GrepaiIdleMinutesFromConfig -ConfigPath $ConfigPath
    if ($null -ne $fromConfig) { $known += [double]$fromConfig }
    $fromLog = Get-GrepaiIdleMinutesFromLog -LogDir $LogDir -MaxLines $MaxLines
    if ($fromLog -ge 0) { $known += [double]$fromLog }
    if ($known.Count -eq 0) { return -1 }
    return [math]::Round(($known | Measure-Object -Minimum).Minimum, 1)
}

# Idle TTL in minutes for the grepai watcher. Operators tune it per environment
# with `watch.idle_timeout_minutes` in .grepai/config.yaml; 0 disables the TTL.
# The key is only READ here - grepai owns that file and rewrites it, so never
# write to it. Absent key or absent file falls back to $DefaultMinutes.
function Get-GrepaiIdleTimeoutMinutes {
    param([string]$ConfigPath, [int]$DefaultMinutes = 20)
    $minutes = $DefaultMinutes
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $txt = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
            if ($txt -match '(?m)^\s*idle_timeout_minutes:\s*(\d+)\s*$') { $minutes = [int]$Matches[1] }
        } catch { }
    }
    if ($minutes -lt 0) { $minutes = 0 }
    return $minutes
}

# ---------------------------------------------------------------------------
# vad-r0i (2026-09-15): PARENT-DEATH PROPAGATION for detached watcher children.
#
# `grepai watch` is spawned DETACHED, so it inherits nothing that could end it.
# On a hard kill / crash / [X] close / Ctrl+C the launcher runs no teardown and
# grepai survived as an orphan, holding ~2 GB RAM and the Ollama embedding model
# lock (observed 2026-09-15: two orphaned grepai.exe, no launcher alive). The
# layers that CAN run no handler (kill -9 / TerminateProcess) need a mechanism
# the kernel enforces, not a handler: a Windows Job Object created with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. The job handle is owned by the launcher
# process; when that process dies for ANY reason the handle closes, the kernel
# closes the job, and every process still inside it is terminated. A worker the
# watcher spawns AFTER the assignment inherits the job, so the workers are
# covered too.
#
# These live in the shared job-scope module because BOTH sides need them:
#   - the launcher, for the initial detached grepai spawn, and
#   - the grepai supervisor runspace (Start-ThreadJob / Start-Job relaunches),
#     which already dot-sources this file from a literal path.
# Definitions only: no top-level side effects (Add-Type runs on first use).
# ---------------------------------------------------------------------------
function New-WatcherParentDeathJob {
    # Returns the job handle as [IntPtr]; [IntPtr]::Zero means "no job" (the
    # caller then runs without this backstop). Never throws.
    try {
        if (-not ('Vad.WatcherParentDeath' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Vad {
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    public static class WatcherParentDeath {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        private const int JobObjectExtendedLimitInformation = 9;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_SET_QUOTA = 0x0100;

        public static IntPtr CreateKillOnClose() {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { return IntPtr.Zero; }
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            ext.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buf = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(ext, buf, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buf, (uint)size)) {
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
            } finally {
                Marshal.FreeHGlobal(buf);
            }
            return job;
        }

        public static bool Assign(IntPtr job, uint pid) {
            if (job == IntPtr.Zero || pid == 0) { return false; }
            IntPtr proc = OpenProcess(PROCESS_TERMINATE | PROCESS_SET_QUOTA, false, pid);
            if (proc == IntPtr.Zero) { return false; }
            try { return AssignProcessToJobObject(job, proc); }
            finally { CloseHandle(proc); }
        }
    }
}
'@
        }
        return [Vad.WatcherParentDeath]::CreateKillOnClose()
    } catch {
        Write-Warning "parent-death job unavailable: $($_.Exception.Message)"
        return [IntPtr]::Zero
    }
}

# Assign a live process (and therefore every worker it spawns afterwards) to the
# kill-on-close job from New-WatcherParentDeathJob. Returns $true on success.
# Safe no-op for a zero handle, a zero PID, or a dead PID.
function Add-ProcessToWatcherDeathJob {
    param(
        [IntPtr]$Job = [IntPtr]::Zero,
        [int]$ProcessId = 0
    )
    if ($ProcessId -le 0) { return $false }
    if ($null -eq $Job) { return $false }
    if ($Job -eq [IntPtr]::Zero) { return $false }
    try {
        if (-not ('Vad.WatcherParentDeath' -as [type])) { return $false }
        return [Vad.WatcherParentDeath]::Assign($Job, [uint32]$ProcessId)
    } catch {
        Write-Warning "parent-death assign failed for PID ${ProcessId}: $($_.Exception.Message)"
        return $false
    }
}
