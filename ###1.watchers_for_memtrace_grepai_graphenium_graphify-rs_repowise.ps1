# Resolve script directory to ensure we run inside the correct project/repository
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# --- Workspace identity (beads mcpw-ybs.2, mcpw-ybs.1) ------------------------
# Capture the INVOCATION directory. That directory is the repository the user
# meant, and it keys every machine-global resource this launcher owns: the
# teardown state file and the pane + log scratch dirs. Without this key a
# launcher started for repo B reads repo A's teardown state and kills repo A's
# watchers.
# $scriptDir stays a SEPARATE concept: it locates the Modules\watcher_*.ps1
# siblings and must never become the watched workspace.
# mcpw-ybs.1: the launcher NO LONGER changes directory. It used to Set-Location
# into $scriptDir at startup, so every pane, log path and indexer resolved
# against the launcher folder instead of the caller's repository. The panes now
# open at $watchersWorkspaceRoot (the grid steps pass it as -d) and the tailers
# work there (-RepoRoot). Module loads keep using absolute Join-Path $scriptDir
# entries, so they are unaffected.
$watchersWorkspaceRoot = (Get-Location).ProviderPath
if (-not $watchersWorkspaceRoot) { $watchersWorkspaceRoot = (Get-Location).Path }
if ($watchersWorkspaceRoot) { $watchersWorkspaceRoot = $watchersWorkspaceRoot.TrimEnd('\', '/') }
# An empty root would make Join-Path throw and silently un-key the guards
# (same lesson as mcpw-ybs.4), so degrade visibly to the launcher folder.
if (-not $watchersWorkspaceRoot) { $watchersWorkspaceRoot = $scriptDir }

# Workspace key derivation (beads mcpw-ybs.2). Dot-sourced BEFORE the teardown
# module so Get-WatchersWorkspaceKey is defined for every consumer. The key comes
# from ONE canonical implementation, so the launcher, the teardown module and the
# tests can never disagree about it.
$watcherWorkspaceModule = Join-Path $scriptDir 'Modules\watcher_workspace.ps1'
if (Test-Path -LiteralPath $watcherWorkspaceModule) { . $watcherWorkspaceModule }
if (-not (Get-Command Get-WatchersWorkspaceKey -ErrorAction SilentlyContinue)) {
    # Inline fallback. A missing module must never silently UN-KEY the guard: an
    # un-keyed teardown state file makes one repo tear down another repo.
    function Get-WatchersWorkspaceKey {
        param([string]$Path)
        if (-not $Path) { $Path = (Get-Location).ProviderPath }
        $n = $Path.TrimEnd('\', '/').ToLowerInvariant()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $b = [System.Text.Encoding]::UTF8.GetBytes($n)
            return ([System.BitConverter]::ToString($sha.ComputeHash($b)) -replace '-', '').Substring(0, 8).ToLowerInvariant()
        } finally { $sha.Dispose() }
    }
}
$workspaceKey = Get-WatchersWorkspaceKey -Path $watchersWorkspaceRoot
# mcpw-ybs.4: the key is now a PATH COMPONENT (the lock dir) as well as a name
# suffix (the mutexes). An empty key would make Join-Path throw at startup and
# would silently recreate ONE machine-global mutex, so degrade to a visible
# placeholder instead of to the empty string.
if (-not $workspaceKey) { $workspaceKey = 'default' }
# Export for the child pane tailers and for dot-sourced modules that run on a
# path with no script scope, such as the PowerShell.Exiting handler.
$env:VAD_WATCHERS_WORKSPACE_KEY = $workspaceKey
$env:VAD_WATCHERS_WORKSPACE_ROOT = $watchersWorkspaceRoot

# Shared watcher teardown (tree-kill + sweep). Safe to dot-source: no
# top-level side effects. Provides Stop-WatcherTree / Stop-AllWatchers.
$teardownModule = Join-Path $scriptDir 'Modules\watcher_teardown.ps1'
if (Test-Path -LiteralPath $teardownModule) { . $teardownModule }

# vad-r0i parent-death helpers (New-WatcherParentDeathJob / Add-ProcessToWatcherDeathJob).
# Dot-sourced EARLY so the initial grepai spawn below can assign into the
# kill-on-close job. The later job-scope block re-resolves + re-dotsources the
# same file for the supervisor runspaces (idempotent, kept as-is).
$script:DeathJob = [IntPtr]::Zero
$earlyJobHelpers = Join-Path $scriptDir 'Modules\watcher_job_helpers.ps1'
if ($earlyJobHelpers -and (Test-Path -LiteralPath $earlyJobHelpers)) { . $earlyJobHelpers }

$watcherPatternsModule = Join-Path $scriptDir 'Modules\watcher_patterns.ps1'
if (Test-Path -LiteralPath $watcherPatternsModule) { . $watcherPatternsModule }

# Pane-script generation (New-WatcherPaneScript) lives in Modules/watcher_pane_scripts.ps1
# (beads vad-uzb ###1 split). Dot-sourced here; the function body was moved verbatim
# except for one added sibling lookup for watcher_log_tail.ps1. No behavior change.
$watcherPaneScriptsModule = Join-Path $scriptDir 'Modules\watcher_pane_scripts.ps1'
if (Test-Path -LiteralPath $watcherPaneScriptsModule) { . $watcherPaneScriptsModule }

# Single-instance guard (FIRST-WINS). Uses BOTH a Windows Named Mutex
# (Global\VAD_Watchers_Launcher_<workspaceKey>, keyed per repo by mcpw-ybs.4)
# for kernel-atomic ownership that auto-releases on
# crash, AND an exclusive FileStream lock on the lock file (FileShare.Read) that
# holds the launcher PID for observability and stale-lock detection. A second
# launcher that finds a LIVE holder exits silently (FIRST-WINS); a stale lock (dead
# PID) is broken and re-acquired with retry-with-jitter. Replaces the old
# TOCTOU-racy Stop-PriorLauncherInstances sweep that crashed when two launchers
# launched close together (race on log-dir deletion, port conflicts, grepai lock
# conflicts, WT pane grid resets, and supervisor orphans).
$launcherName = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
# Normalize the script name to a stable token. The launcher filename begins with
# "###1." -- match on that prefix so a renamed copy (.titan-run etc.) still
# counts as the same instance family.
if ($launcherName -match '^###1') { $launcherToken = '###1' } else { $launcherToken = $launcherName }

# mcpw-ybs.4: the FIRST-WINS lock and BOTH launcher mutexes are keyed PER
# WORKSPACE. They used to be machine-global, so a launcher started for repo B
# contended with repo A's live launcher: it either exited 0 and never opened its
# own pane grid, or (through Stop-PriorLauncherInstances) took over and killed
# repo A's watchers. FIRST-WINS is preserved WITHIN one workspace.
# The key is a DIRECTORY component and the file name is unchanged - the same
# shape as Modules\watcher_teardown.ps1 (watchers\<key>\teardown-state.json) -
# so the '###1-launcher.lock' literal that the pane tailers and the tests match
# on still holds.
$lockDir = Join-Path (Join-Path $env:LOCALAPPDATA 'watchers') $workspaceKey
try { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null } catch {}
$lockFile = Join-Path $lockDir '###1-launcher.lock'
# Canonical mutex names, defined once here so the acquisition path and the
# PowerShell.Exiting release path cannot drift apart.
$launcherMutexName = "Global\VAD_Watchers_Launcher_$workspaceKey"
$takeoverMutexName = "Global\VAD_Watchers_Takeover_$workspaceKey"

# FIRST-WINS single-instance acquisition. Returns a disposable object holding BOTH
# the named mutex (kept alive for launcher lifetime) and an exclusive FileStream
# lock on the lock file. Returns $null if a LIVE launcher already holds the lock
# (caller must exit 0). Retries up to 3 times with 50-200ms jitter to handle a
# stale lock (dead PID in the lock file) left by a crashed launcher.
#
# DESIGN - why the FileStream is the authoritative gate and not the Named Mutex:
# The .NET ``Mutex(Boolean, String, Boolean&)`` constructor has a documented race
# under concurrent creation: when two processes call it near-simultaneously, BOTH
# can observe ``createdNew=true`` and both can succeed ``WaitOne(0)``, so a raw
# Named-Mutex-first design admits two concurrent ``winners``. We therefore make the
# exclusive FileStream the atomic gate: ``FileShare.Read`` gives the holder sole
# write access while still letting a contender OPEN the file for reading to learn
# the holder's PID (for the liveness check / stale-break). The kernel serialises
# ``FileMode.Create``+``FileShare.Read`` so exactly one process gets write access -
# no TOCTOU. Only AFTER holding the file lock do we create/open the Named Mutex;
# since creation now happens under the file lock's exclusion, the mutex-creation
# race cannot occur. The mutex is then a secondary, crash-auto-released signal that
# also doubles as the fast liveness gate (a live holder owns it).
function Acquire-LauncherLock {
    param(
        [string]$LockFile,
        [string]$LauncherName,
        [string]$MutexName
    )
    # mcpw-ybs.4: keyed per workspace; see $launcherMutexName above. An absent
    # name is rebuilt from the environment rather than defaulting to the bare
    # legacy name, which would silently restore the machine-global hazard.
    if (-not $MutexName) {
        $mk = $env:VAD_WATCHERS_WORKSPACE_KEY
        if (-not $mk) { $mk = 'default' }
        $MutexName = "Global\VAD_Watchers_Launcher_$mk"
    }
    $maxRetries = 3
    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        if ($attempt -gt 0) {
            $jitter = Get-Random -Minimum 50 -Maximum 200
            Start-Sleep -Milliseconds $jitter
        }
        # --- Authoritative atomic gate: exclusive FileStream (FileShare.Read). ---
        # Exactly one process can hold CREATE+WRITE here; contenders get an
        # IOException and fall through to the liveness check below.
        $parentDir = Split-Path $LockFile -Parent
        if (-not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        $fileStream = $null
        try {
            $fileStream = New-Object System.IO.FileStream($LockFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        } catch {
            # File is held by another process (live or crashed-but-not-yet-released).
            # Try to read the holder's PID to decide FIRST-WINS vs stale-break.
            try {
                $holderPid = 0
                $rfs = New-Object System.IO.FileStream($LockFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $rd = New-Object System.IO.StreamReader($rfs)
                $content = $rd.ReadToEnd()
                $rd.Close(); $rfs.Close()
                if ($content) {
                    $json = $content | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($json -and $json.Pid) { $holderPid = [int]$json.Pid }
                }
                if ($holderPid -gt 0) {
                    $liveProc = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
                    if ($liveProc) {
                        # LIVE holder -> FIRST-WINS loser. Report and exit.
                        Write-Host "Launcher already running (PID $holderPid) - exiting"
                        return $null
                    }
                }
            } catch { }
            # Stale lock (holder dead or unreadable) - retry after jitter.
            continue
        }

        # We hold the exclusive file lock. Write our PID, then create the Named
        # Mutex UNDER the file-lock exclusion so the creation race cannot occur.
        try {
            $jsonObj = [PSCustomObject]@{
                Pid       = $PID
                StartedAt = (Get-Date).ToString('o')
                Launcher  = $LauncherName
            } | ConvertTo-Json -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonObj)
            $fileStream.Write($bytes, 0, $bytes.Length)
            $fileStream.Flush()
        } catch {
            # Failed to write our PID - release file lock and retry.
            try { $fileStream.Close(); $fileStream.Dispose() } catch {}
            continue
        }

        # Create/open the Named Mutex now that we exclusively hold the file lock.
        $mutex = $null
        try {
            $createdNew = $false
            $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
        } catch {
            # Could not create the mutex - still hold a valid file lock, so we are
            # the live launcher. Proceed without the mutex (file lock is authoritative).
            $mutex = $null
        }

        return [PSCustomObject]@{
            Mutex      = $mutex
            FileStream = $fileStream
            LockFile   = $LockFile
        }
    }
    Write-Host "Launcher lock could not be acquired after $($maxRetries + 1) attempts - exiting"
    return $null
}

function Release-LauncherLock {
    param($LockObj)
    if ($null -eq $LockObj) { return }
    try { if ($LockObj.FileStream) { $LockObj.FileStream.Flush(); $LockObj.FileStream.Close(); $LockObj.FileStream.Dispose() } } catch {}
    try { if ($LockObj.Mutex) { $LockObj.Mutex.ReleaseMutex(); $LockObj.Mutex.Dispose() } } catch {}
    try { if (Test-Path -LiteralPath $LockObj.LockFile) { Remove-Item -LiteralPath $LockObj.LockFile -Force -ErrorAction SilentlyContinue } } catch {}
}

# LAST-WINS takeover (restored 2026-09-15): a double-click must ALWAYS bring up
# the 4-pane grid, even when a prior launcher is still alive. This helper stops
# the prior instance - its watchers PID-scoped first, then the launcher itself -
# BEFORE the lock is claimed, so every launch starts a fresh grid. VAD-v14z.8
# had replaced this with a silent FIRST-WINS exit, which left an established
# headless launcher blocking every later double-click: the new instance exited
# at Acquire-LauncherLock and no panes ever appeared.
#
# The VAD-v14z.8 anti-race fix is preserved by two guards, so two launchers can
# never kill each other and orphan watchers:
#   1. A machine-wide takeover mutex serializes the takeover: only one launcher
#      inspects and kills at a time.
#   2. A holder younger than $MinAgeSec is still STARTING UP (the concurrent
#      double-click case) and is left alone; Acquire-LauncherLock then reports
#      it as a live holder and this instance exits 0. Only an ESTABLISHED prior
#      is replaced.
function Stop-PriorLauncherInstances {
    param(
        [string]$LockDir,
        [string]$CurrentPid,
        [int]$MinAgeSec = 30,
        [string]$TakeoverMutexName
    )
    # mcpw-ybs.4: the takeover mutex is keyed per workspace, so two repositories
    # can each replace their OWN prior launcher without waiting on each other.
    # Serialisation is only needed between launchers of the SAME workspace.
    if (-not $TakeoverMutexName) {
        $tk = $env:VAD_WATCHERS_WORKSPACE_KEY
        if (-not $tk) { $tk = 'default' }
        $TakeoverMutexName = "Global\VAD_Watchers_Takeover_$tk"
    }
    # Guard 1: serialize the takeover. Bounded wait so a slow peer takeover
    # cannot stall this launch forever.
    $takeoverMutex = $null
    $takeoverHeld = $false
    try {
        $takeoverMutex = New-Object System.Threading.Mutex($false, $TakeoverMutexName)
        try { $takeoverHeld = $takeoverMutex.WaitOne(15000) }
        catch [System.Threading.AbandonedMutexException] { $takeoverHeld = $true }
    } catch { $takeoverHeld = $false }
    if (-not $takeoverHeld) {
        # A peer is mid-takeover - let Acquire-LauncherLock settle this instance.
        return
    }
    try {
        $lockPattern = Join-Path $LockDir "###1-launcher.lock"
        if (-not (Test-Path -LiteralPath $lockPattern)) { return }
        $holderPid = 0
        $holderAgeSec = -1
        try {
            $rfs = New-Object System.IO.FileStream($lockPattern, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $rd = New-Object System.IO.StreamReader($rfs)
            $content = $rd.ReadToEnd()
            $rd.Close(); $rfs.Close()
            if (-not $content) { return }
            $json = $content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $json -or -not $json.Pid) { return }
            $holderPid = [int]$json.Pid
            if ($json.StartedAt) {
                try { $holderAgeSec = ((Get-Date) - [datetime]$json.StartedAt).TotalSeconds } catch { $holderAgeSec = -1 }
            }
        } catch {
            # Lock file unreadable or unwritable - proceed without killing
            return
        }
        if ($holderPid -eq 0 -or $holderPid -eq [int]$CurrentPid) { return }
        $holderProc = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        if ($null -eq $holderProc) { return }
        # Guard 2: a young holder is still starting (concurrent double-click).
        if ($holderAgeSec -ge 0 -and $holderAgeSec -lt $MinAgeSec) { return }
        # Tear down the prior launcher's watchers PID-SCOPED (from its own
        # teardown-state.json) BEFORE killing the launcher, so no detached
        # daemon - litellm / gm / repowise / graphify wrapper / grepai - is
        # orphaned when the prior PID dies.
        if (Get-Command Stop-AllWatchers -ErrorAction SilentlyContinue) {
            try { Stop-AllWatchers | Out-Null } catch {}
        }
        try { Stop-Process -Id $holderPid -Force -ErrorAction SilentlyContinue } catch { Write-Warning "Failed to stop prior ###1 launcher (PID $holderPid): $($_.Exception.Message)" }
        # Bounded wait for the holder to exit so its exclusive lock-file stream
        # is released before Acquire-LauncherLock contends on it.
        $killDeadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $killDeadline) {
            if ($null -eq (Get-Process -Id $holderPid -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
        Write-Host "Stopped prior ###1 launcher (PID $holderPid) - taking over for a fresh pane grid"
    } finally {
        try { if ($takeoverMutex) { $takeoverMutex.ReleaseMutex() } } catch {}
        try { if ($takeoverMutex) { $takeoverMutex.Dispose() } } catch {}
    }
    # Sweep orphaned watcher processes left by the prior launcher. These are
    # child processes (watchers) that the parent launcher spawned and must be
    # cleaned up so they don't keep FileSystemWatchers alive over the repo.
    # Uses the shared sweep pattern list from Modules/watcher_patterns.ps1.
    # vad-10m.3: entries flagged Persistent (port-singleton backends) are
    # SKIPPED here - they are reused across launchers by design, and the
    # backend-duplicate pass in Stop-WatcherOrphans reaps real duplicates.
    #
    # mcpw-ybs.2 attribution gate. This sweep is a FALLBACK for orphans the
    # PID-scoped Stop-AllWatchers could not reach; it is NOT the primary kill
    # path. It must therefore FAIL SAFE. A matching process is terminated ONLY
    # when its command line can be attributed to THIS workspace. An
    # unattributable match is SKIPPED and counted: an orphan is harmless, a
    # sibling repository's live watcher is not.
    # The match-all entries (graphify-rs.exe, memtrace.exe, memcortex-daemon.exe
    # all carry an EMPTY Pattern) are the reason this gate exists - without it the
    # sweep kills EVERY such process on the machine, whatever repository it
    # belongs to.
    # NOTE: this inline match is deliberately NOT Test-WatcherSweepMatch. The
    # shared helper returns $false for a match-all pattern when the command line
    # is empty; this check treats it as a candidate. With the attribution gate
    # below both behave identically (an unreadable command line is never
    # attributable, so it is skipped). Kept inline so the diff stays minimal.
    if ($null -eq $script:WatcherSweepPatterns) { return }
    $sweepSkipped = 0
    foreach ($entry in $script:WatcherSweepPatterns) {
        if ($entry.Persistent) { continue }
        $pattern = $entry.Pattern
        $name = $entry.Name
        try {
            $procs = @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue)
            foreach ($proc in $procs) {
                $cmdLine = ''
                try { $cmdLine = $proc.CommandLine } catch { $cmdLine = '' }
                if (-not ($pattern -eq '' -or ($cmdLine -and $cmdLine -match [regex]::Escape($pattern)))) { continue }
                $attributed = $false
                if (Get-Command Test-WatchersProcessAttribution -ErrorAction SilentlyContinue) {
                    $attributed = Test-WatchersProcessAttribution -CommandLine $cmdLine `
                        -WorkspaceKey $workspaceKey -WorkspaceRoot $watchersWorkspaceRoot
                } else {
                    # Inline fallback. If the helper is unavailable the sweep must
                    # still not kill machine-wide, so match on the key alone.
                    $attributed = [bool]($workspaceKey -and $cmdLine -and
                        $cmdLine.IndexOf($workspaceKey, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
                }
                if (-not $attributed) {
                    $sweepSkipped++
                    continue
                }
                try {
                    Invoke-CimMethod -InputObject $proc -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
                    Write-Host "Swept orphaned watcher: $name (PID $($proc.ProcessId))"
                } catch {
                    Write-Warning "Failed to sweep orphaned watcher $name (PID $($proc.ProcessId)): $($_.Exception.Message)"
                }
            }
        } catch {
            Write-Warning "Orphan watcher sweep failed for ${name}: $($_.Exception.Message)"
        }
    }
    if ($sweepSkipped -gt 0) {
        Write-Warning "Startup orphan sweep skipped $sweepSkipped process(es) not attributable to this workspace (key $workspaceKey). They may belong to another repository; leaving them running is the safe choice."
    }
}

# Write the launcher lock (FIRST-WINS entry point).
# This is the single-instance guard that prevents two launchers from running.
function Write-LauncherLock {
    param(
        [string]$LockFile,
        [string]$LauncherName,
        [string]$MutexName
    )
    return Acquire-LauncherLock -LockFile $LockFile -LauncherName $LauncherName -MutexName $MutexName
}

# LAST-WINS takeover before claiming the lock (restored 2026-09-15): a
# double-click must ALWAYS bring up the pane grid, so an ESTABLISHED prior ###1
# launcher is stopped (with its watchers) first. A young prior - the concurrent
# double-click case - is left alone and loses at Acquire-LauncherLock instead.
Stop-PriorLauncherInstances -LockDir $lockDir -CurrentPid $PID -TakeoverMutexName $takeoverMutexName

# Claim the launcher lock. If a live launcher still holds it (a concurrent
# starter, or a takeover that could not complete), report the holder and exit 0.
# Acquire-LauncherLock writes the "already running" message and returns $null.
$global:LauncherLock = Write-LauncherLock -LockFile $lockFile -LauncherName $launcherName -MutexName $launcherMutexName
if ($null -eq $global:LauncherLock) { exit 0 }

# Track child PIDs so teardown is PID-scoped (only kill processes THIS launcher
# spawned, never another launcher's watchers).
# VAD-v14z.4 daemon PID model (PID-scoped teardown):
# - Killable watchers (gm, graphenium, graphify-rs wrapper, repowise, litellm):
#   spawned via Start-WatcherDetached, PIDs enter $global:WatcherChildren and
#   persist to teardown-state.json RootPids for Stop-AllWatchers tree-kill.
# - grepai: PID in $script:GrepaiPid, persists to teardown-state.json GrepaiPid
#   (PID-scoped graceful `grepai watch --stop`, VAD-49om).
# - memtrace: singleton daemon on :50051 started inside a background job;
#   daemon PID lives in .memdb/daemon-state.json, whose path persists to
#   teardown-state.json MemtraceStatePath (Stop-AllWatchers step 4 kills by
#   recorded pid). Start-job handle kept in $script:memtraceStartJob.
# - cerememory (:8420), claude-mcp-server (:8080), mail (:8765),
#   graphiti-embed (:8003), graphiti-mcp-proxy (:8004): port-singleton
#   persistent services, deduped by in-job port probe and REUSED across
#   launchers/logon sessions. They PERSIST after launcher exit and are
#   intentionally NOT added to $global:WatcherChildren / teardown (same rule
#   as the mail block below). Start-job handles kept in
#   $script:cerememoryStartJob / $script:claudeMcpStartJob / $script:mailMcpStartJob
#   / $script:graphitiEmbedStartJob / $script:graphitiMcpProxyStartJob
#   so no daemon job is fire-and-forget (Out-Null discarded).
#   graphiti-mcp (:8002) is a Docker container (restart: always), NOT a
#   launcher child - never spawned or supervised here.
# - litellm (:4000): tracked detached child ($script:litellmProc via
#   Start-WatcherDetached, in WatcherChildren/RootPids); its readiness probe
#   ($script:litellmProbeJob) and crash-restart supervisor
#   ($script:litellmSupJob) are transient/in-process jobs that exit with the
#   launcher (supervisor kills its own child on lock release).
$global:WatcherChildren = @()
$script:memtraceStartJob = $null
$script:cerememoryStartJob = $null
$script:claudeMcpStartJob = $null
$script:mailMcpStartJob = $null
$script:graphitiEmbedStartJob = $null
$script:graphitiMcpProxyStartJob = $null

# PORT CONFLICT FAIL-FAST: before starting memtrace/cerememory, check whether the
# port is held by a launcher-owned process (a memtrace/cerememory daemon). If a
# live launcher-spawned daemon owns the port, a sibling launcher is already
# running - by default fail fast and exit 0 (consistent with FIRST-WINS).
# With -AutoHeal, the stale daemon is force-killed and the launcher proceeds
# (self-healing: the new launcher takes over the port).
function Test-PortHeldByLauncherDaemon {
    param(
        [int]$Port,
        [string[]]$DaemonProcessNames,
        # No '= $null' default here. A default value on a [ref]-typed parameter
        # throws ParameterBindingArgumentTransformationException ("Reference type
        # is expected in argument") whenever the caller omits -OwningPid. An
        # OMITTED [ref] parameter binds as $null cleanly, which the guards below
        # already handle.
        [ref]$OwningPid
    )
    try {
        if ($OwningPid) { $OwningPid.Value = 0 }
        $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        foreach ($c in $conns) {
            $ownerPid = $c.OwningProcess
            if (-not $ownerPid) { continue }
            # Tight match (never kill an unrelated process just because it owns
            # the port): exact image leaf name, or the daemon token inside the
            # owning PID's command line. Generic runtime images (node/python/
            # powershell/pwsh/cmd) never match on image name alone; a token that
            # equals the image leaf proves nothing and is ignored.
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
            if (-not $proc) { continue }
            $imageLeaf = $null
            if ($proc.ExecutablePath) { $imageLeaf = [System.IO.Path]::GetFileNameWithoutExtension($proc.ExecutablePath) }
            $genericImages = @('node', 'python', 'python3', 'pythonw', 'powershell', 'pwsh', 'cmd')
            $isGenericImage = $imageLeaf -and ($genericImages -contains $imageLeaf.ToLower())
            foreach ($name in $DaemonProcessNames) {
                $viaImage = $imageLeaf -and (-not $isGenericImage) -and ($imageLeaf -ieq $name)
                $viaCmdline = $proc.CommandLine -and
                    ($proc.CommandLine.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                    (-not ($imageLeaf -ieq $name))
                if ($viaImage -or $viaCmdline) {
                    if ($OwningPid) { $OwningPid.Value = $ownerPid }
                    return $true
                }
            }
        }
    } catch {
        Write-Warning "Port-owner probe failed for port $Port - $($_.Exception.Message)"
    }
    return $false
}
# PERSISTENT-SINGLETON STALENESS RULE (mcpw-d0m, decided 2026-09-18)
# ---------------------------------------------------------------------------
# A daemon that holds the port AND answers an HTTP request is NOT stale. It is
# the machine's resident singleton, and a second repo must ADOPT it, not kill
# it. Killing it only because this launcher started later took :8420/:8080/
# :8765 down for the other repo (observed 2026-09-18 from a sibling checkout).
#
# Source of truth for "which daemons are machine-wide singletons":
# Modules\watcher_patterns.ps1, the entries carrying Persistent = $true. The
# startup takeover sweep honours that marker. This auto-heal path honours it
# through -DeferToHealthy below, which every PERSISTENT call site passes.
#
# :50051 memtrace does NOT pass it, on purpose. memtrace is REPO-SCOPED: its
# store lives in <repo>\.memdb ($script:memtraceStateFile) and the start job is
# handed $watchersWorkspaceRoot. A foreign memtrace holding :50051 serves the
# WRONG repo's store, so replacing it is correct - it stays kill-on-conflict.
#
# :8765 (mcp_agent_mail) has no call site here at all. Its process is
# python.exe, too broad a name match; the in-job port dedup covers it. See the
# comment at the mail block.
# ---------------------------------------------------------------------------
# Liveness probe: TCP connect plus a short HTTP GET. ANY HTTP status line
# (200/401/404/405...) proves an application is behind the socket and
# answering; only refusal, reset or timeout means dead. Verified live
# 2026-09-18 against the running daemons: :8420 cerememory, :8080
# claude-mcp-server and :8765 mcp_agent_mail each answered HTTP 404 to
# "GET /" - all three are alive by this rule. Deliberately does NOT depend on
# a documented health endpoint existing.
function Test-HttpPortAnswering {
    param(
        [string]$Address = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMs = 3000
    )
    $sock = $null
    try {
        $sock = New-Object System.Net.Sockets.TcpClient
        $iar = $sock.BeginConnect($Address, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        if (-not $sock.Connected) { return $false }
        [void]$sock.EndConnect($iar)
    } catch {
        return $false
    } finally {
        if ($sock) { try { $sock.Close() } catch { Write-Warning "Port-owner probe: socket close failed - $($_.Exception.Message)" } }
    }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://$($Address):$Port/")
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.KeepAlive = $false
        $req.UserAgent = 'watchers-launcher-liveness'
        $resp = $req.GetResponse()
        return $true
    } catch [System.Net.WebException] {
        # A WebException that CARRIES a response is a normal HTTP status such as
        # 404 - the server answered, so it is alive.
        if ($_.Exception.Response) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($resp) { try { $resp.Close() } catch { Write-Warning "Port-owner probe: response close failed - $($_.Exception.Message)" } }
    }
}

function Exit-IfPortHeldByLauncherDaemon {
    param(
        [int]$Port,
        [string[]]$DaemonProcessNames,
        [string]$Label,
        [switch]$AutoHeal = $false,
        # mcpw-d0m: pass for a machine-wide PERSISTENT singleton. When the port
        # holder answers an HTTP probe it is the resident singleton, not a stale
        # daemon: adopt it and return instead of killing it. See the staleness
        # rule comment above.
        [switch]$DeferToHealthy = $false
    )
    $stalePid = 0
    $held = Test-PortHeldByLauncherDaemon -Port $Port -DaemonProcessNames $DaemonProcessNames -OwningPid ([ref]$stalePid)
    if (-not $held) { return }

    if ($AutoHeal) {
        # PERSISTENT SINGLETON: a resident that answers is healthy. Adopt it.
        # Safe because the downstream start job dedupes against an
        # already-listening port ($cerememoryJobScript, $claudeMcpJobScript).
        if ($DeferToHealthy -and (Test-HttpPortAnswering -Port $Port)) {
            Write-Host "[$Label AUTO-HEAL] port $Port held by a healthy resident daemon (PID $stalePid) - adopting it, not killing it."
            return
        }
        # SELF-HEAL: kill the stale daemon so this launcher can take over the port.
        if ($stalePid -gt 0) {
            try {
                $staleProc = Get-Process -Id $stalePid -ErrorAction SilentlyContinue
                if ($staleProc) {
                    Write-Host "[$Label AUTO-HEAL] killing stale daemon PID $stalePid ($($staleProc.ProcessName) holding port $Port..."
                    $staleProc | Stop-Process -Force -ErrorAction SilentlyContinue
                    # Wait for the port to free up (up to 8s) before proceeding.
                    # VAD-lnhe (2026-09-06): the loop's own check is the single
                    # verdict - the old unconditional re-check AFTER the loop
                    # duplicated it (the loop breaks the moment the port is free).
                    $deadline = (Get-Date).AddSeconds(8)
                    $stillHeld = $true
                    while ((Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 500
                        $stillHeld = Test-PortHeldByLauncherDaemon -Port $Port -DaemonProcessNames $DaemonProcessNames
                        if (-not $stillHeld) { break }
                    }
                    if (-not $stillHeld) {
                        Write-Host "[$Label AUTO-HEAL] port $Port is now free - proceeding with launch."
                        return
                    }
                    Write-Warning "[$Label AUTO-HEAL] port $Port still held after killing PID $stalePid - falling back to FIRST-WINS exit."
                }
            } catch {
                Write-Warning "[$Label AUTO-HEAL] failed to kill stale daemon PID $stalePid : $($_.Exception.Message)"
            }
        }
    }

    Write-Warning "$Label port $Port is held by a launcher-spawned daemon (a sibling launcher is running). Exiting (FIRST-WINS)."
    # VAD-ygdo.7: FIRST-WINS exit runs AFTER detached spawns (litellm, gm,
    # graphify-rs, repowise, grepai) but BEFORE teardown-state.json is written
    # and BEFORE the PowerShell.Exiting handler is registered -- a bare exit
    # orphans five watchers. Teardown PID-scoped children explicitly first.
    # State file does not exist yet, so pass RootPids/GrepaiPid explicitly.
    try {
        $ygdoRoots = @($global:WatcherChildren | ForEach-Object { $_ })
        $ygdoGrepai = 0
        try { $ygdoGrepai = [int]($script:GrepaiPid) } catch {}
        $ygdoMtState = ''
        try { $ygdoMtState = [string]($script:memtraceStateFile) } catch {}
        $ygdoRepo = ''
        try { $ygdoRepo = [string]($script:memtraceGitRoot) } catch {}
        if (($ygdoRoots.Count -gt 0) -or ($ygdoGrepai -gt 0)) {
            if (Get-Command Stop-AllWatchers -ErrorAction SilentlyContinue) {
                Stop-AllWatchers -RootPids $ygdoRoots -MemtraceStatePath $ygdoMtState -RepoRoot $ygdoRepo -GrepaiPid $ygdoGrepai | Out-Null
            }
        }
        try { Stop-GmSemanticLive } catch {}
    } catch {}
    try { Release-LauncherLock $global:LauncherLock } catch {}
    $global:LauncherLock = $null
    exit 0
}

# grepai is launched by this script as a long-running watcher. The launcher does NOT
# exit immediately after spawning it - it waits until grepai confirms it is running
# (via `grepai watch --status`) and only then exits, leaving grepai's own process
# running for real-time indexing. If grepai is missing or fails to start, the launcher
# holds the console ("Press Enter to exit") so the error is visible instead of the
# window vanishing.
# VAD-lnhe (2026-09-06): the dead Invoke-GrepaiSafe helper that lived here was
# deleted (never called; grepai launches go through Start-Process with explicit
# redirects, and status capture goes through Get-GrepaiStatusText).

# === grepai health check (begin) ===
# grepai index health: detect a corrupted index (the "unexpected EOF" gob class
# documented 2026-06-29, where index.gob is a truncated header-only stub) and
# repair it by deleting the corrupted index files so the index rebuilds them on
# the next scan. Also verify Ollama (grepai's nomic-embed-text embeddings
# backend) is running in the background. These run BEFORE grepai watch launches
# so the watcher starts against a clean index.

# Capture `grepai status --no-ui` output (stdout + stderr) for a given project dir.
# Returns $null if grepai cannot be launched (fail-safe: caller skips on null).
function Get-GrepaiStatusText {
    param([string]$Path = $scriptDir)
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "grepai"
        $psi.Arguments = "status --no-ui"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $Path
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { return $null }
        # VAD-1aw0 (2026-09-06): drain BOTH pipes CONCURRENTLY before waiting.
        # WaitForExit-before-ReadToEnd deadlocks when the child writes more than
        # the ~4 KB pipe buffer (child blocks on write, the wait times out, and
        # the process is killed - corruption detection silently fails exactly
        # when status output is large). Dispose in finally (handle leak).
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(15000)) { try { $proc.Kill() } catch {}; return $null }
        return ($outTask.Result + [Environment]::NewLine + $errTask.Result)
    } catch { return $null }
    finally { if ($proc) { try { $proc.Dispose() } catch {} } }
}

# Detect a corrupted grepai index in one .grepai dir and repair it.
# Returns $true if a corrupted gob was found and deleted, $false if clean / unreadable.
function Repair-GrepaiIndexIfCorrupted {
    param([string]$GrepaiDir)
    $cfg = Join-Path $GrepaiDir 'config.yaml'
    if (-not (Test-Path $cfg)) { return $false }   # not an initialized project; skip
    $projectDir = Split-Path $GrepaiDir -Parent
    $statusText = Get-GrepaiStatusText -Path $projectDir
    if ($null -eq $statusText) { return $false }   # could not read status; do not delete
    # Match the documented corruption class ("failed to decode index" /
    # "unexpected EOF", 2026-06-29) AND the signal the CURRENT grepai binary
    # emits for a truncated/garbage gob ("unknown storage backend:"). Both mean
    # the index is unreadable and must be rebuilt by deleting it.
    if ($statusText -match 'failed to decode index' -or $statusText -match 'unexpected EOF' -or $statusText -match 'unknown storage backend') {
        # Corrupted gob index detected. Delete the index gob files so grepai
        # regenerates a clean index on the next scan (matches 2026-06-29 fix).
        foreach ($f in @('index.gob', 'symbols.gob', 'rpg.gob')) {
            $p = Join-Path $GrepaiDir $f
            if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "Removed corrupted grepai index in: $GrepaiDir (grepai will rebuild it on next scan)."
        return $true
    }
    return $false
}

# Read the Ollama endpoint grepai is configured to use, from .grepai/config.yaml
# (embedder.ollama.endpoint). Falls back to grepai's documented default 11434.
# Shared by Test-OllamaRunning and the orchestrator's status message so they
# never disagree (and stay correct after the repo relocated Ollama to 12134).
function Get-GrepaiOllamaTarget {
    # mcpw-ybs.7: repository-scoped - read the WATCHED repo's .grepai, not the
    # script's own folder, so a foreign cwd consults its own config.
    $ghGrepai = Join-Path $watchersWorkspaceRoot '.grepai'
    $ghCfg = Join-Path $ghGrepai 'config.yaml'
    $target = '127.0.0.1:11434'   # grepai's documented default when none configured
    if (Test-Path $ghCfg) {
        try {
            $txt = Get-Content -LiteralPath $ghCfg -Raw -ErrorAction Stop
            if ($txt -match '(?<![\w])endpoint:\s*"?https?://([0-9a-zA-Z.\-]+:\d+)"?') { $target = $Matches[1] }
        } catch {
            Write-Verbose "Could not read grepai Ollama endpoint from ${ghCfg}: $($_.Exception.Message)"
        }
    }
    return $target
}

# Fix the Windows reserved-port blocker for grepai's Ollama target. The default
# Ollama port (11434) sits inside Windows' administratively-reserved range
# 11408-11507, so Ollama cannot bind it and grepai's watcher runs without
# embeddings (its index never rebuilds). If the configured target is reserved or
# unreachable, redirect by setting OLLAMA_HOST (session + persisted User level)
# so grepai watch and the Ollama auto-start both use a working port. Returns
# $true only when it actually applied a redirect to a different reachable
# endpoint; $false (honest no-op, sets nothing) otherwise.
function Enable-GrepaiOllamaPortFix {
    $target = Get-GrepaiOllamaTarget
    $hostPart = ($target -split ':')[0]
    $portPart = [int](($target -split ':')[1])
    # Already bound and answering? Nothing to fix.
    $alreadyUp = $false
    try {
        $r = Invoke-WebRequest -Uri ("http://" + $target + "/") -Method Get -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $alreadyUp = ($r.StatusCode -eq 200)
    } catch { $alreadyUp = $false }
    # Is the target port inside a Windows administratively-reserved range?
    # netsh lists two kinds of excluded ports:
    #   1. System-managed dynamic exclusions (no marker) - NOT truly reserved;
    #      Windows adds these automatically for bound sockets (TcpListener,
    #      HttpListener, etc.). Treating them as reserved causes false positives
    #      on the very port the caller just bound.
    #   2. Administered port exclusions (marked with '*') - genuinely reserved
    #      via "netsh interface ipv4 add excludedportrange". Only these block us.
    $reserved = $false
    try {
        $excl = netsh int ipv4 show excludedportrange protocol=tcp 2>$null
        foreach ($line in $excl) {
            if ($line -match '^\s*(\d+)\s+(\d+)\s+\*\s*$') {
                $s = [int]$Matches[1]; $e = [int]$Matches[2]
                if ($portPart -ge $s -and $portPart -le $e) { $reserved = $true; break }
            }
        }
    } catch {
        Write-Warning "netsh reserved-port probe failed: $($_.Exception.Message)"
    }
    if ($alreadyUp -and -not $reserved) {
        Write-Host "Ollama endpoint $target is reachable and not reserved - no port fix needed."
        return $false
    }
    if ($reserved) {
        if ($alreadyUp) {
            Write-Host "Ollama endpoint $target is reachable but in a Windows reserved port range - leaving OLLAMA_HOST unchanged (no redirect needed while it answers)."
            return $false
        }
        # Redirecting onto a reserved port would not help; leave as-is and ask the
        # user to reconfigure the endpoint to a free port.
        Write-Warning "grepai's Ollama target $target is in a Windows reserved port range and unreachable. Pointing OLLAMA_HOST at it would not help - please reconfigure the endpoint to a free port (e.g. 12134)."
        return $false
    }
    # Not reserved but unreachable: setting OLLAMA_HOST to the same dead target
    # would be a no-op with a false "fix applied" claim (VAD-v14z.6). Probe the
    # known-good fallback first; only redirect when it actually answers.
    $fallbacks = @('127.0.0.1:12134')
    foreach ($fb in $fallbacks) {
        if ($fb -eq $target) { continue }
        try {
            $fr = Invoke-WebRequest -Uri ("http://" + $fb + "/") -Method Get -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($fr.StatusCode -eq 200) {
                $env:OLLAMA_HOST = $fb
                try { [Environment]::SetEnvironmentVariable('OLLAMA_HOST', $fb, 'User') } catch { Write-Warning "Failed to persist OLLAMA_HOST=$fb at User level: $($_.Exception.Message)" }
                Write-Host "Applied Ollama port fix: grepai target $target is down; redirected OLLAMA_HOST=$fb (session + persisted) to known-good reachable endpoint."
                return $true
            }
        } catch {
            Write-Warning "Ollama fallback probe failed for $fb - $($_.Exception.Message)"
        }
    }
    # No reachable fallback: honest no-op. Leave OLLAMA_HOST untouched so the
    # caller (and the Ollama auto-start below) can start Ollama on $target.
    Write-Warning "grepai's Ollama target $target is not reserved but unreachable (Ollama down). No port fix applied - OLLAMA_HOST left unchanged; start Ollama on $target or ensure a reachable endpoint (e.g. 127.0.0.1:12134)."
    return $false
}

# Check whether Ollama is running in the background (grepai needs it for
# nomic-embed-text embeddings). Probes the Ollama endpoint grepai is configured
# to use (read from .grepai/config.yaml embedder.endpoint, default 127.0.0.1:11434),
# so this stays correct after the repo relocated Ollama to 12134.
function Test-OllamaRunning {
    $target = Get-GrepaiOllamaTarget
    $url = "http://$target/"
    try {
        $r = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

# Orchestrator: check + repair the repo root and every linked worktree that has a
# .grepai/config.yaml, then report Ollama status. Always returns $true (the check
# completed; repairs are side effects). Safe to call before grepai watch launches.
function Test-GrepaiIndexHealth {
    # mcpw-ybs.7: health-check the WATCHED repo's index, not the script folder's.
    # mcpw-9lf: Windows PowerShell 5.1 DROPS a null operand handed to a native
    # command, so `git -C "$null" rev-parse` becomes `git -C rev-parse` and git
    # takes 'rev-parse' as the -C operand. The resulting stderr is a TERMINATING
    # error under $ErrorActionPreference = Stop even with 2>$null, so the
    # operand is checked before git is called at all.
    $gitRoot = $null
    if (-not ([string]::IsNullOrWhiteSpace($watchersWorkspaceRoot))) {
        $gitRoot = git -C "$watchersWorkspaceRoot" rev-parse --show-toplevel 2>$null
    }
    $dirs = @($watchersWorkspaceRoot)
    if ($gitRoot) {
        $dirs += git -C "$gitRoot" worktree list --porcelain 2>$null |
            Where-Object { $_ -match '^worktree ' } |
            ForEach-Object { ($_ -split ' ', 2)[1] } |
            ForEach-Object { $gp = Join-Path $_ '.grepai'; if ($_ -and (Test-Path (Join-Path $gp 'config.yaml'))) { $_ } }
    }
    $repaired = 0
    $gobTmpRemoved = 0
    # Sweep orphaned *.gob.tmp-* crash leftovers from every .grepai/ (root and
    # linked worktrees). A grepai crash mid-write leaves partial-write temp files
    # named *.gob.tmp-* next to the live index.gob/symbols.gob/rpg.gob. grepai
    # regenerates its index from scratch on every scan, so these incomplete temp
    # files are always safe to delete (they are stale partial writes, never locks
    # or live data). Only the *.gob.tmp-* shape is matched; the live gobs are
    # never touched. Mirrors the cleanup_junk.ps1 section 7 sweep.
    foreach ($d in $dirs) {
        $gd = Join-Path $d '.grepai'
        if (Test-Path $gd) {
            if (Repair-GrepaiIndexIfCorrupted -GrepaiDir $gd) { $repaired++ }
            Get-ChildItem -LiteralPath $gd -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.Name -like '*.gob.tmp-*' } |
                ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    $gobTmpRemoved++
                }
        }
    }
    if ($repaired -gt 0) {
        Write-Host "grepai index health: repaired $repaired corrupted index file(s) before launch."
    } else {
        Write-Host "grepai index health: no corrupted index detected."
    }
    if ($gobTmpRemoved -gt 0) {
        Write-Host "grepai index health: removed $gobTmpRemoved orphaned *.gob.tmp-* crash leftover(s) before launch."
    }
    # Ollama is required by grepai for nomic-embed-text embeddings.
    # Port-reservation fix: ensure grepai's Ollama target is reachable & not
    # reserved; sets OLLAMA_HOST (session env var read by the auto-start below).
    $ghDir = Join-Path $watchersWorkspaceRoot '.grepai'
    $ollamaUp = Test-OllamaRunning
    if (-not $ollamaUp) {
        # Accurate: Ollama is NOT up yet, but it WILL be auto-started by the
        # background readiness gate launched further below (VAD-kesg, 2026-09-06).
        # This health-check block runs first and must not duplicate that start.
        Write-Host "Ollama is not yet running in the background; it will be auto-started in the readiness gate below."
    } else {
        $ollamaTarget = Get-GrepaiOllamaTarget
        Write-Host "Ollama is running in the background (port $ollamaTarget) - grepai embeddings available."
    }
    return $true
}
# === grepai health check (end) ===

# Prerequisites Check: grepai executable must be on PATH.
# This is a hard requirement: the script's purpose is to launch the grepai watcher.
# If grepai is missing the watcher cannot run, so we hold the console ("Press Enter")
# rather than silently exiting - matching the launch-script error rules.
if (-not (Get-Command "grepai" -ErrorAction SilentlyContinue)) {
    Write-Error "grepai executable not found on PATH. Please install it first."
    Write-Host "Press Enter to exit..."
    $null = Read-Host
    exit 1
}

# Detect an already-running background watcher WITHOUT relying on
# `grepai watch --status` (unreliable here: reports "not running" even when a
# tracked watcher is live). Use a process + .ready-file check instead, and DO NOT
# exit - the launcher still needs to open the pane grid.
$grepaiOk = $false
$logFile = $null
$script:GrepaiPid = 0   # tracked so teardown can stop OUR grepai only (VAD-49om)
$grepaiLogsDir = Join-Path $env:LOCALAPPDATA 'grepai\logs'
# `grepai watch --background` daemonizes: it runs as a `grepai.exe` process whose
# command line is just `...grepai.exe" watch --background` (NO `mcp-serve` token),
# and it writes a `grepai-worktree-<id>.log` (and, in some builds, a `.ready` file)
# under the logs dir. We detect the live watcher by process liveness OR the worktree
# log/ready file -- NOT by `grepai watch --status` (unreliable: reports "not running"
# while a tracked watcher is alive) and NOT by an `mcp-serve` command-line token
# (that is a different grepai mode, `grepai mcp-serve`, never spawned by this launcher).
# STRICT watcher detection (orphaned-tailer root cause, 2026-08-20): only a
# grepai.exe whose CommandLine carries 'watch' counts as the WATCHER. A bare
# process count was too broad - grepai mcp-serve MCP servers are live
# grepai.exe processes that are NOT watchers, so the old check reported
# "already running" and skipped the watch launch entirely, leaving grepai down
# while its pane tailed a stale log. The 'watch' token appears only in the
# daemon's `grepai watch --background` command line.
$alreadyProc = @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' }).Count -gt 0
if ($alreadyProc) {
    Write-Host "grepai watch already running (process/log detected). Reusing it for the pane view."
    $grepaiOk = $true
    $lf = Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lf) { $logFile = $lf.FullName }
}

# Check grepai index integrity (and repair if corrupted) + Ollama readiness
# BEFORE launching the watch, so the watcher starts against a clean index.
try {
    Test-GrepaiIndexHealth
} catch {
    Write-Warning "grepai index health check failed: $($_.Exception.Message). Continuing - the watch launch below will surface any real error."
}

# Prerequisites Check: Ollama service.
# VAD-kesg (2026-09-06): probe the CONFIG-DRIVEN endpoint (Get-GrepaiOllamaTarget,
# the same target Test-OllamaRunning uses) instead of a hardcoded 12134. The old
# hardcoded gate reported "not running" whenever the configured endpoint
# differed and spawned a redundant `ollama serve` while Ollama already served on
# the configured port. 12134 stays only as a documented fallback probe.
$ollamaTarget = Get-GrepaiOllamaTarget          # config-driven, e.g. 127.0.0.1:11434
$ollamaLegacyPort = 12134                       # documented fallback (pre-relocation default)
$ollamaUrls = @("http://$ollamaTarget/", "http://127.0.0.1:$ollamaLegacyPort/")
# VAD-7m1y (2026-09-06): the Ollama readiness gate (probe, spawn-on-not-ready,
# 20s ready wait) no longer blocks the launcher inline. It runs as a background
# job OVERLAPPED with the grepai watch launch + ready-wait below and is joined
# right after the grepai gate. Same probes, same timeouts, same spawn-on-not-ready
# behavior and same messages - only the wall-clock ordering changes. Jobs inherit
# NO script variables, so the gate receives $ollamaUrls explicitly.
$ollamaGateScript = {
    param($OllamaUrls)
    $ollamaRunning = $false
    $ollamaUrl = $OllamaUrls[0]

    try {
        foreach ($u in $OllamaUrls) {
            try {
                # Perform a lightweight HTTP request to check Ollama
                $response = Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 5 -ErrorAction Stop
                $ollamaRunning = $true
                $ollamaUrl = $u
                break
            } catch { }
        }
    } catch {
        $ollamaRunning = $false
    }

    # Ollama is only needed by grepai (embeddings). Since grepai is skipped this session,
    # Ollama failures must NOT crash the watcher. Wrap in try/catch and degrade gracefully.
    try {
        if (-not $ollamaRunning) {
            # Check if ollama is on PATH or default location to auto-start it
            $ollamaCmd = Get-Command "ollama" -ErrorAction SilentlyContinue
            $ollamaPath = $null
            if ($ollamaCmd) {
                $ollamaPath = $ollamaCmd.Source
            } else {
                $defaultPaths = @(
                    "$env:LocalAppData\Programs\Ollama\ollama.exe",
                    "$env:ProgramFiles\Ollama\ollama.exe"
                )
                foreach ($path in $defaultPaths) {
                    if (Test-Path $path) {
                        $ollamaPath = $path
                        break
                    }
                }
            }

            if ($ollamaPath) {
                Write-Host "Ollama service is offline. Attempting to start Ollama from $ollamaPath..."
                # OLLAMA_HOST (set by Enable-GrepaiOllamaPortFix as a PROCESS env
                # var earlier in this launcher, persisted at User level) tells this
                # build of Ollama (v0.30.11) which port to bind; a thread job shares
                # the launcher process so it sees $env:OLLAMA_HOST, and a Start-Job
                # child inherits it. `serve` accepts no --host flag, so pass it
                # only the subcommand.
                Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden

                # Wait up to 20 seconds for Ollama to become ready
                $waitLimit = 20
                $waited = 0
                $ollamaRunning = $false
                while ($waited -lt $waitLimit) {
                    Start-Sleep -Seconds 1
                    $waited++
                    foreach ($u in $OllamaUrls) {
                        try {
                            $response = Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 2 -ErrorAction Stop
                            $ollamaRunning = $true
                            $ollamaUrl = $u
                            Write-Host "Ollama service started successfully!"
                            break
                        } catch {
                            # Continue waiting
                        }
                    }
                    if ($ollamaRunning) { break }
                }
            }
        }

        if (-not $ollamaRunning) {
            # Non-fatal this session: grepai is skipped, so Ollama is not required.
            Write-Warning "Ollama service is not running on $($OllamaUrls -join ' or ') and could not be started. Skipping Ollama-dependent startup."
        }
    } catch {
        Write-Warning "Ollama prerequisite check failed: $($_.Exception.Message). Continuing without Ollama."
    }
}
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $ollamaGateJob = Start-ThreadJob -ScriptBlock $ollamaGateScript -ArgumentList $ollamaUrls
} else {
    $ollamaGateJob = Start-Job -ScriptBlock $ollamaGateScript -ArgumentList $ollamaUrls
}
if (-not $ollamaGateJob) {
    # Degrade to the original inline gate if job creation failed.
    & $ollamaGateScript $ollamaUrls
    $ollamaGateJob = $null
}

# --- mcpw-759: grepai worktree hygiene ----------------------------------------
#
# A linked worktree whose `.git` gitfile is missing or truncated is DEGRADED.
# Measured with the real git on a throwaway repo (temp\mcpw759):
#   rev-parse --is-inside-work-tree  -> (no output)              exit 128
#   rev-parse HEAD                   -> (no output)              exit 128
#   status --porcelain               -> fatal: not a git repo    exit 128
#   worktree remove <wt> --force     -> fatal: validation failed exit 128
#   worktree list --porcelain        -> STILL LISTS THE PATH
#
# The old Layer 1 guard was `if ($wtHead -and $wtHead -eq $mainHead)`. $wtHead
# is EMPTY for exactly this case, so the guard was FALSE and the degraded
# worktree was skipped in silence on every run. `worktree remove --force`
# refuses it too, and `worktree prune` only drops the registration when the
# gitfile is gone - the directory survives either way. grepai then re-used the
# dead path and indexing failed inside grepai's own log.
#
# Detection now keys on `rev-parse --is-inside-work-tree`, the test git itself
# uses to decide a path is a worktree at all. Toplevel identity is also
# required: a corrupted directory NESTED inside another repository makes
# `--is-inside-work-tree` answer "true" for the OUTER repo (measured), so
# without identity check a nested dead path reads as healthy.

function Test-GitWorktreeUsable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $inside = git -C "$Path" rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($inside -ne 'true') { return $false }
    $top = git -C "$Path" rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $top) { return $false }
    $self = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetFullPath($top).TrimEnd('\', '/')
    return ($self -ieq $root)
}

# Layer 2 (reordered to run second). Drops a stale .grepai/index.gob left in a
# surviving linked worktree that has no .grepai/config.yaml.
function Invoke-GrepaiWorktreeValidate {
    param([string]$RepoRoot)
    # mcpw-9lf: guard the -C operand. An empty one is silently dropped by
    # Windows PowerShell 5.1 and git then fails with "cannot change to
    # 'rev-parse'", which is terminating under $ErrorActionPreference = Stop.
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return }
    $gitRoot = git -C "$RepoRoot" rev-parse --show-toplevel 2>$null
    if (-not $gitRoot) { return }
    $gitRootFull = [System.IO.Path]::GetFullPath($gitRoot).TrimEnd('\', '/')
    $worktreeDirs = git -C "$gitRoot" worktree list --porcelain 2>$null |
        Where-Object { $_ -match '^worktree ' } |
        ForEach-Object { ($_ -split ' ', 2)[1] } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($wt in $worktreeDirs) {
        $candFull = [System.IO.Path]::GetFullPath($wt).TrimEnd('\', '/')
        if ($candFull -ieq $gitRootFull) { continue }
        $idx = Join-Path $wt '.grepai/index.gob'
        $cfg = Join-Path $wt '.grepai\config.yaml'
        if ((Test-Path $idx) -and -not (Test-Path $cfg)) {
            Write-Host "Removing stale .grepai/index.gob in linked worktree: $wt"
            Remove-Item $idx -Force
        }
    }
}

# Layer 1 (runs FIRST). Removes worktrees that git reports - or that sit at the
# launcher's own grepai worktree path - but that git cannot open as a worktree,
# plus (unchanged) fully-merged worktrees with no uncommitted changes. Returns
# the removed paths so a caller or test can assert on them.
#
# Safety: only two path sources are considered, both authoritative. (1) `git
# worktree list --porcelain`, git's own registration. (2) -ExpectedWorktreePath,
# provably this launcher's own scaffolding. No other path is ever removed.
function Invoke-GrepaiWorktreePrune {
    param(
        [string]$RepoRoot,
        [string]$ExpectedWorktreePath = '',
        [string]$ProtectedPath = ''
    )
    $removed = @()
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return @() }
    $gitRoot = git -C "$RepoRoot" rev-parse --show-toplevel 2>$null
    if (-not $gitRoot) { return @() }
    $gitRootFull = [System.IO.Path]::GetFullPath($gitRoot).TrimEnd('\', '/')
    $protectFull = ''
    if (-not [string]::IsNullOrWhiteSpace($ProtectedPath)) {
        $protectFull = [System.IO.Path]::GetFullPath($ProtectedPath).TrimEnd('\', '/')
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    git -C "$gitRoot" worktree list --porcelain 2>$null |
        Where-Object { $_ -match '^worktree ' } |
        ForEach-Object { ($_ -split ' ', 2)[1] } |
        ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $candidates.Add($_) } }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedWorktreePath)) {
        $candidates.Add($ExpectedWorktreePath)
    }

    # `worktree list` prints forward slashes while a Join-Path candidate uses
    # backslashes. Deduplicate on the NORMALIZED path so the same worktree is
    # not walked twice (it was warned about twice before).
    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($c in $candidates) {
        $k = ([System.IO.Path]::GetFullPath($c).TrimEnd('\', '/')).ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $unique.Add($c) }
    }

    $mainHead = git -C "$gitRoot" rev-parse HEAD 2>$null
    foreach ($wt in $unique) {
        # mcpw-759: a blank path here makes PowerShell 5.1 DROP the operand, so
        # `git -C "$wt" rev-parse HEAD` becomes `git -C rev-parse HEAD` and
        # fails with "fatal: cannot change to 'rev-parse'". Under
        # $ErrorActionPreference='Stop' that aborts this whole block - the exact
        # T6/T7 warning. Never hand git an empty -C operand.
        if ([string]::IsNullOrWhiteSpace($wt)) { continue }
        if (-not (Test-Path -LiteralPath $wt -PathType Container)) { continue }
        $candFull = [System.IO.Path]::GetFullPath($wt).TrimEnd('\', '/')
        # Never remove the main worktree: that IS the repository.
        if ($candFull -ieq $gitRootFull) { continue }
        # Never remove the workspace we run in, or any parent of it.
        if ($protectFull -and ($candFull -ieq $protectFull -or
            $protectFull.StartsWith($candFull + '\', [System.StringComparison]::OrdinalIgnoreCase))) { continue }

        if (Test-GitWorktreeUsable -Path $wt) {
            $wtHead = git -C "$wt" rev-parse HEAD 2>$null
            if (-not $wtHead -or $wtHead -ne $mainHead) { continue }
            # Never --force-remove a worktree holding uncommitted changes.
            $dirty = @(git -C "$wt" status --porcelain 2>$null)
            if ($dirty.Count -gt 0) {
                Write-Warning "Skipping worktree '$wt': HEAD matches main but uncommitted changes exist."
                continue
            }
            $branch = git -C "$wt" rev-parse --abbrev-ref HEAD 2>$null
            Write-Host "Pruning stale worktree '$wt' (HEAD matches main, branch: $branch)..."
            git -C "$gitRoot" worktree remove "$wt" --force 2>$null
            if ($LASTEXITCODE -eq 0) { $removed += $wt; continue }
            Write-Warning "Failed to remove worktree: $wt"
            continue
        }

        # DEGRADED. git lists the path but cannot open it as a worktree, so
        # there is no index and no HEAD here to hold uncommitted work, and
        # `status` cannot answer at all - which is why the dirty guard cannot
        # apply. Ask git first; it is the only tool that also unregisters the
        # worktree cleanly. Only if git refuses do we delete the directory.
        Write-Host "Removing degraded worktree '$wt' (not openable as a worktree)..."
        git -C "$gitRoot" worktree remove "$wt" --force 2>$null
        if (-not (Test-Path -LiteralPath $wt)) { $removed += $wt; continue }
        Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $wt) {
            Write-Warning "Failed to remove degraded worktree directory: $wt"
            continue
        }
        $removed += $wt
    }
    git -C "$gitRoot" worktree prune 2>$null
    return @($removed)
}

# Layer 1: Prune fully-merged stale worktrees to prevent grepai auto-discovery.
# mcpw-759: Layer 1 now runs BEFORE Layer 2 so a degraded path is deleted
# first and Layer 2 never validates something about to be removed.
try {
    $prunedWorktrees = Invoke-GrepaiWorktreePrune `
        -RepoRoot $watchersWorkspaceRoot `
        -ExpectedWorktreePath (Join-Path $watchersWorkspaceRoot "$workspaceKey\worktree") `
        -ProtectedPath $watchersWorkspaceRoot
    if (@($prunedWorktrees).Count -gt 0) {
        Write-Host ("Worktree prune removed {0} path(s): {1}" -f @($prunedWorktrees).Count, ($prunedWorktrees -join ', '))
    }
} catch {
    Write-Warning "Worktree pruning failed: $($_.Exception.Message)"
}

# Layer 2: Validate .grepai/ state in linked worktrees before starting grepai
try {
    Invoke-GrepaiWorktreeValidate -RepoRoot $watchersWorkspaceRoot
} catch {
    Write-Warning "Worktree .grepai validation failed: $($_.Exception.Message)"
}

# --- Log directory + paths (defined early so both the grepai launch below and the
# detached watcher launches further down can redirect to it) --------------------
# Logs live OUTSIDE the repo. `gm watch` is ignore-blind (it does not apply
# .grapheniumignore to live change events; only full rebuilds honor it), so any
# scratch under the repo root -- including the old temp\watchers -- gets watched,
# patched, and flagged as `(non-code)` noise (and temp .py files even insert live
# graph nodes). Relocation to a scratch root off the watched tree silences all of
# that. Prefer C:\Temp (off-repo scratch on the now-massive C: drive); fall back to
# $env:TEMP\vad-watchers if C:\Temp is unavailable. See change log 2026-07-12.
$scratchRoot = $null
if (Test-Path -LiteralPath "C:\Temp") { $scratchRoot = "C:\Temp" }
else { $scratchRoot = Join-Path $env:TEMP "vad-watchers" }
# mcpw-ybs.2: the logs dir carries the WORKSPACE KEY, so two repositories never
# share a log file. Without the key repo B's grepai pane tails repo A's log and
# both launchers write the same grepai-launch.log.err.
$logsDir = Join-Path $scratchRoot "vad-watchers\$workspaceKey\watchers"
try { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null } catch {}
$grepaiLaunchLog = Join-Path $logsDir "grepai-launch.log"
$grepaiLaunchErr = Join-Path $logsDir "grepai-launch.log.err"

# Start grepai watch in FOREGROUND (detached, hidden) mode. We intentionally do NOT
# use `--background`. VAD-ksg2 (2026-08-26) found `--background` carries a HARD-CODED
# 30s internal "become ready" probe: `Error: timeout waiting for process to become
# ready after 30s`. This repo has ~38k files (15.6k under tests/, 5.9k under
# graphify-out/, plus .opencode/node_modules and ###swe-books-md markdown), so the
# initial scan cannot finish in 30s. Every `--background` launch therefore self-kills
# mid-scan, the supervisor relaunches, it dies again, and the pane loops on
# "tick 1" forever (`grepai status` shows Files indexed: 0 / Last updated: Never).
# A FOREGROUND `grepai watch` (started detached + hidden, as the other three watchers
# are) has NO such gate, finishes the scan at its own pace, and `grepai status
# --no-ui` DOES report it as running (Verified 2026-08-27: PID 105996 reported
# `Watcher: running`). Liveness in this launcher is the watch-CommandLine CIM probe
# at Test-GrepaiWatcherAlive, which matches the foreground `grepai.exe watch` process
# correctly. The launcher's own console still tails grepai's live log until Ctrl+C.
# --- grepai background watcher (robust launch + readiness) ---
# NOTE: `grepai watch --status` is UNRELIABLE in this environment - it reports
# "Status: not running" even while a tracked background watcher is alive and
# serving. So readiness is judged by the .ready file grepai writes when serving
# (plus process liveness), NOT by --status. Also, when grepai refuses to start due
# to a stale worktree lock it exits with a BLANK exit code (not a number), which
# previously made `if ($ec -ne 0)` throw and crash the whole launcher. Both are
# fixed below: a clearly numeric non-zero exit = hard failure; blank/0 = recover.
# VAD-ksg2 (2026-08-26, amended 2026-08-27): `grepai watch --background` carries a
# FIXED internal 30s readiness probe ("timeout waiting for process to become ready
# after 30s"). This ~38k-file repo cannot finish its initial scan in 30s, so EVERY
# `--background` launch self-kills mid-scan (exit -1 / 0xFFFFFFFF) and the supervisor
# relaunches it in an infinite loop ("tick 1" forever, index stuck at 0 files). The
# fix is to launch `grepai watch` in FOREGROUND (detached + hidden). Foreground watch
# has no such gate, finishes the scan at its own pace, and `grepai status --no-ui`
# reports it as running. We still give the launch a generous wait to confirm the
# process stays up (it should NOT exit on its own anymore), then proceed.
$grepaiLogsDir = Join-Path $env:LOCALAPPDATA 'grepai\logs'
if (-not $grepaiOk) {
    Write-Host "Starting grepai watch (foreground, detached + hidden)..."
    # vad-r0i parent-death: build the kill-on-close job BEFORE the spawn so the
    # fresh grepai is assigned immediately (workers it spawns inherit the job).
    if (Get-Command New-WatcherParentDeathJob -ErrorAction SilentlyContinue) {
        if ($null -eq $script:DeathJob -or $script:DeathJob -eq [IntPtr]::Zero) { $script:DeathJob = New-WatcherParentDeathJob }
    }
    try {
        $gp = Start-Process -FilePath (Get-Command "grepai.exe").Source -ArgumentList "watch" `
            -WorkingDirectory $watchersWorkspaceRoot -WindowStyle Hidden `
            -RedirectStandardOutput $grepaiLaunchLog -RedirectStandardError $grepaiLaunchErr -PassThru
        # vad-r0i parent-death: the kill-on-close job handle is owned by THIS
        # launcher process, so a hard kill / crash of the launcher (where neither
        # the trap nor the PowerShell.Exiting handler can run) still reaps grepai
        # and every worker it spawns. The graceful path stays the teardown below.
        if ($null -ne $script:DeathJob -and $script:DeathJob -ne [IntPtr]::Zero) {
            $assigned = Add-ProcessToWatcherDeathJob -Job $script:DeathJob -ProcessId $gp.Id
            if (-not $assigned) { Write-Warning "grepai parent-death assign failed for PID $($gp.Id) - job Zero or already-in-job; relying on graceful teardown only." }
        } else {
            Write-Warning "grepai parent-death job unavailable - relying on graceful teardown only."
        }
        # FOREGROUND watch has no internal 30s self-kill, so it should stay up. We wait
        # ~10s: if it exits on its own within that window it is a genuine launch failure
        # (missing exe, immediate crash), and we route to recovery below.
        $exited = $gp.WaitForExit(10000)
        $script:GrepaiPid = $gp.Id
        $ec = $gp.ExitCode
        # Blank or 0 exit = daemonized / refused-with-recoverable-lock; only a real
        # numeric non-zero exit is a hard launch failure.
        if ($exited -and ($ec -is [int]) -and $ec -ne 0) {
            throw "grepai watch exited with code $ec"
        }
    } catch {
        # Recover from a stale worktree lock ("Error: watcher is already running (PID N)")
        # or any genuine launch failure: clear stale pid lock files, then retry the
        # launch exactly once (FOREGROUND, not --background, to avoid the 30s gate).
        $errText = ""
        if (Test-Path $grepaiLaunchErr) { $errText = (Get-Content $grepaiLaunchErr -Raw -ErrorAction SilentlyContinue) }
        if ($errText -match 'already running' -or $errText -match 'timeout waiting for process to become ready') {
            Write-Warning "Stale grepai lock detected - recovering (kill orphan + clear lock, then retry once)..."
            if ($errText -match 'already running' -and $errText -match 'PID (\d+)') {
                $op = Get-Process -Id $Matches[1] -ErrorAction SilentlyContinue
                if ($op) { try { $op.Kill() } catch { Write-Warning "Failed to kill stale grepai PID $($op.Id): $($_.Exception.Message)" } }
            }
            Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*.pid*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            try {
                $gp2 = Start-Process -FilePath (Get-Command "grepai.exe").Source -ArgumentList "watch" `
                    -WorkingDirectory $watchersWorkspaceRoot -WindowStyle Hidden `
                    -RedirectStandardOutput $grepaiLaunchLog -RedirectStandardError $grepaiLaunchErr -PassThru
                # vad-r0i parent-death: the retried spawn is the tracked watcher
                # now, so it must be inside the kill-on-close job too.
                if ($null -ne $script:DeathJob -and $script:DeathJob -ne [IntPtr]::Zero) {
                    $assigned = Add-ProcessToWatcherDeathJob -Job $script:DeathJob -ProcessId $gp2.Id
                    if (-not $assigned) { Write-Warning "grepai parent-death assign failed for PID $($gp2.Id) - job Zero or already-in-job; relying on graceful teardown only." }
                } else {
                    Write-Warning "grepai parent-death job unavailable - relying on graceful teardown only."
                }
                $script:GrepaiPid = $gp2.Id
                $gp2.WaitForExit(35000) | Out-Null
            } catch { Write-Warning "grepai relaunch failed: $($_.Exception.Message)" }
        } else {
            Write-Warning "grepai launch error: $($_.Exception.Message)"
        }
    }
    # Readiness: wait for a live watch process or the worktree log/ready artifact, max 20s.
    $ready = $null
    for ($i = 0; $i -lt 20; $i++) {
        $ready = Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } | Select-Object -First 1
        if ($ready) { break }
        $live = @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' }).Count -gt 0
        if ($live) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    $lf = Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lf) { $logFile = $lf.FullName }
    if ($ready -or $lf) { $grepaiOk = $true }
}

if (-not $grepaiOk) {
    Write-Warning "grepai watch did not start. The grepai pane will show the launch error; the other 3 watchers still run."
    if (-not $logFile) { $logFile = $grepaiLaunchErr }
}

# VAD-7m1y (2026-09-06): join the Ollama readiness gate job started above. It
# ran concurrently with the grepai watch launch + ready-wait, so its probes and
# 20s spawn-wait no longer add serial wall-clock latency. The gate is inherently
# bounded (2x5s probes + 20x(1s sleep + up to 2x2s probes)), so a plain Wait-Job
# matches the old inline blocking semantics exactly; Receive-Job replays the
# gate's console/warning messages verbatim in the main runspace.
if ($ollamaGateJob) {
    try { Wait-Job -Job $ollamaGateJob -ErrorAction Stop | Out-Null } catch { }
    Receive-Job -Job $ollamaGateJob -ErrorAction Continue 2>&1 | Out-Host
    Remove-Job -Job $ollamaGateJob -Force -ErrorAction SilentlyContinue
}

# --- grepai crash-restart supervisor (in-process child job) ----------------
# Supervisor script name: vad-grepai-sup.ps1 (generated by the launcher planning step).
# A grepai crash must not leave the index unattended in silence. After the initial
# (robust, foreground-detached) launch above succeeds, spawn an in-process child job
# (thread job) that polls ~every 5s and relaunches `grepai watch` (FOREGROUND, hidden)
# on death -- BUT ONLY while its parent launcher is still alive. Key constraints:
#  - We deliberately launch foreground `watch` (NOT --background): --background has a
#    hard-coded 30s "become ready" self-kill that this ~38k-file repo cannot beat,
#    so it crash-loops. Foreground `watch` is reported as running by `grepai status
#    --no-ui` and is matched by the watch-CommandLine liveness probe. The supervisor
#    relaunches the same foreground mode.
#  - Liveness gate: on each poll the supervisor checks the launcher lock file. If
#    the file is missing OR the PID in it is no longer live, the supervisor EXITS
#    (with a log line) instead of re-launching. This is the persistent
#    representation of $global:LauncherLock - when the launcher exits,
#    Release-LauncherLock removes the lock file, so the supervisor detects it.
#  - The supervisor is a CHILD JOB of the launcher process: when the launcher exits
#    (Ctrl+C / [X] / exit), the thread job is terminated with it. No detached
#    orphan, no sweep pattern needed.
$supSupervisorLog = Join-Path $env:LOCALAPPDATA 'grepai\logs\supervisor.log'
$script:watchersLog = Join-Path $logsDir "watchers.log"

# --- Shared job-scope helpers: ONE definition, dot-sourced everywhere ---------
# VAD-v14z.5: Clear-StaleLocks / Limit-LogSize / Test-LauncherAlive used to be
# copy-pasted into the parent scope AND every Start-ThreadJob / Start-Job
# scriptblock, because a job gets a FRESH runspace that inherits neither the
# launcher's functions nor its script-scope variables. The copies drifted (the
# grepai supervisor even lost Clear-StaleLocks -> stale locks survived -> the
# 2026-08-26 1s crash-restart loop). They now live ONCE in
# Modules\watcher_job_helpers.ps1 and are dot-sourced from a LITERAL path. This
# resolves that path with the same portable candidate list as
# Modules\watcher_log_tail.ps1; each job gets the resolved literal path via
# -ArgumentList and dot-sources it. Never re-embed the helper bodies.
$jobHelpersModule = $null
$jobHelpersCands = @()
if ($PSScriptRoot) { $jobHelpersCands += (Join-Path $PSScriptRoot 'Modules\watcher_job_helpers.ps1') }
if ($env:VAD_WORKSPACE_ROOT) { $jobHelpersCands += (Join-Path $env:VAD_WORKSPACE_ROOT 'Modules\watcher_job_helpers.ps1') }
foreach ($cand in $jobHelpersCands) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { $jobHelpersModule = $cand; break }
}
if (-not $jobHelpersModule) {
    Write-Error 'watcher_job_helpers.ps1 not found next to the launcher or under $env:VAD_WORKSPACE_ROOT\Modules. Expected Modules\watcher_job_helpers.ps1 relative to the launcher or $env:VAD_WORKSPACE_ROOT.'
    Write-Host 'Press Enter to exit...'
    $null = Read-Host
    exit 1
}
. $jobHelpersModule

$supervisorJob = $null
if ($grepaiOk) {
    $supervisorScript = {
        param($RepoRoot, $LaunchLog, $LaunchErr, $SupervisorLog, $LockFile, $WatchersLog, $JobHelpersModule)
        $ErrorActionPreference = 'Continue'
        # THREAD-JOB SCOPE RULE: Start-ThreadJob gives this scriptblock a FRESH
        # runspace that does NOT inherit the launcher's functions or its
        # script-scope variables. VAD-v14z.5: the shared helpers (Limit-LogSize /
        # Clear-StaleLocks / Test-LauncherAlive) are dot-sourced from
        # Modules\watcher_job_helpers.ps1 via the literal path bound in
        # -ArgumentList, so this runspace gets them without a copy-pasted body.
        . $JobHelpersModule
        function Write-SupLog {
            param([string]$Msg)
            Limit-LogSize -Path $SupervisorLog
            $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            "[$ts] $Msg" | Out-File -FilePath $SupervisorLog -Append -Encoding UTF8
        }

        # THREAD-JOB SCOPE RULE: Start-ThreadJob gives this scriptblock a FRESH
        # runspace that does NOT inherit the launcher's functions. Clear-StaleLocks
        # comes from the dot-sourced Modules\watcher_job_helpers.ps1 above
        # (vad-0si; T22 pins that wiring). Do not re-embed a copy here - silent
        # drift caused the 2026-08-26 1s crash-restart loop.

        # === gob repair inline (begin) ===
        # VAD-3cr (2026-08-26): corrupt-index repair for the supervisor runspace.
        # A truncated index.gob (the 377-byte "unexpected EOF" class) kills every
        # relaunched daemon on load; deleting the gob trio plus *.gob.tmp-* crash
        # leftovers lets grepai rebuild cleanly instead of crash-looping.
        # VAD-v14z.5: NOT shared via Modules\watcher_job_helpers.ps1 because
        # tests/launcher_tests.ps1 T10e pins these begin/end markers AND
        # re-executes the block standalone to obtain the repair helper.
        function Repair-CorruptGobIndex {
            param([string]$ProjectRoot)
            $gd = Join-Path $ProjectRoot '.grepai'
            if (-not (Test-Path (Join-Path $gd 'config.yaml'))) { return }
            $statusText = ''
            $proc = $null
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'grepai'
                $psi.Arguments = 'status --no-ui'
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.WorkingDirectory = $ProjectRoot
                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $psi
                if (-not $proc.Start()) { return }
                # VAD-1aw0 (2026-09-06): drain both pipes CONCURRENTLY before
                # WaitForExit (deadlock-then-kill when status output exceeds the
                # pipe buffer) and Dispose the Process in finally.
                $outTask = $proc.StandardOutput.ReadToEndAsync()
                $errTask = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit(15000)) { try { $proc.Kill() } catch {}; return }
                $statusText = $outTask.Result + [Environment]::NewLine + $errTask.Result
            } catch { return }
            finally { if ($proc) { try { $proc.Dispose() } catch {} } }
            if ($statusText -match 'failed to decode index' -or $statusText -match 'unexpected EOF' -or $statusText -match 'unknown storage backend') {
                foreach ($n in @('index.gob', 'symbols.gob', 'rpg.gob')) {
                    $p2 = Join-Path $gd $n
                    if (Test-Path $p2) { Remove-Item $p2 -Force -ErrorAction SilentlyContinue }
                }
                Write-SupLog 'corrupt gob index detected - deleted index/symbols/rpg for clean rebuild'
            }
            foreach ($tmp in @(Get-ChildItem -LiteralPath $gd -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer -and $_.Name -like '*.gob.tmp-*' })) {
                Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        # === gob repair inline (end) ===

        function Write-WatchersLog {
            param([string]$Msg)
            Limit-LogSize -Path $WatchersLog
            try {
                $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
                "[$ts] [supervisor] $Msg" | Out-File -FilePath $WatchersLog -Append -Encoding UTF8
            } catch { }
        }
        # Liveness comes from the dot-sourced Modules\watcher_job_helpers.ps1
        # (vad-0si; the worktree-quoting heal test pins the canonical body there).
        # Do not re-embed a copy here - silent drift caused the 2026-08-26 loop.
        Write-SupLog 'supervisor started (enhanced: auto-heal + stale-lock cleanup)'
        # VAD-pp50 (2026-09-06): back off when grepai is PERMANENTLY broken (a
        # crash no gob repair can fix). Without this the supervisor relaunched
        # watch every ~5s forever - process churn + unbounded supervisor.log
        # growth. Mirrors the memtrace auto-heal pattern: count consecutive
        # failed restarts, sleep through a 10-minute cooldown after 5, reset
        # after the cooldown (a later manual fix resumes healing normally).
        # vad-r0i parent-death for the RELAUNCHES. A thread job runs inside the
        # launcher process, so this job handle is owned by the launcher: a hard
        # kill of the launcher closes it and the kernel reaps the relaunched
        # grepai + its workers. Without it only the launcher's FIRST spawn was
        # covered, and a crash-restart (then launcher kill) still orphaned one.
        $deathJob = [IntPtr]::Zero
        if (Get-Command New-WatcherParentDeathJob -ErrorAction SilentlyContinue) {
            $deathJob = New-WatcherParentDeathJob
        }
        # VAD-jmw idle TTL (2026-09-15): grepai has no idle timeout of its own, so
        # the daemon would hold the embedding model (~1.9 GB measured) forever
        # after its scan ends. The supervisor owns the only long-lived poll loop,
        # so it reaps the watcher once the index has been idle for the TTL and
        # RETURNS - an idle exit is NOT a crash, so the restart path below must
        # never see it (that relaunch loop is the bug). Knob + idle clock:
        # Modules\watcher_job_helpers.ps1 (Get-GrepaiIdleTimeoutMinutes /
        # Get-GrepaiIdleMinutes). 0 disables the TTL. Tune with
        # watch.idle_timeout_minutes in .grepai/config.yaml.
        $idleTtlMin = Get-GrepaiIdleTimeoutMinutes -ConfigPath (Join-Path $RepoRoot '.grepai\config.yaml')
        $idleTicks = 0
        Write-SupLog "grepai idle TTL armed: $idleTtlMin minute(s) (0 = disabled)"
        $consecutiveRestarts = 0
        # vad-v02 (2026-09-15): PID-scoped idle reap. The old reap killed every
        # grepai.exe with CommandLine match watch, so a manual watch or a
        # sibling launcher watcher died too. Track only the PID this
        # supervisor owns: adopt the single live watcher once, then record
        # every PID this runspace restarts. The idle reap kills that PID tree
        # only, via Invoke-CimMethod Terminate (CimInstance has no .Kill()).
        $trackedGrepaiPid = 0
        function Test-TrackedGrepaiWatchAlive {
            param([int]$PidToCheck)
            if ($PidToCheck -le 0) { return $false }
            try {
                $c = Get-CimInstance Win32_Process -Filter "ProcessId=$PidToCheck" -ErrorAction SilentlyContinue
                if ($null -eq $c) { return $false }
                if ($c.Name -ne 'grepai.exe') { return $false }
                if (-not $c.CommandLine) { return $false }
                if ($c.CommandLine -notmatch 'watch') { return $false }
                if ($null -eq (Get-Process -Id $PidToCheck -ErrorAction SilentlyContinue)) { return $false }
                return $true
            } catch { return $false }
        }
        function Stop-TrackedGrepaiTree {
            param([int]$RootPid)
            if ($RootPid -le 0) { return }
            try {
                $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
                $byParent = @{}
                foreach ($p in $all) {
                    $ppid = [uint32]$p.ParentProcessId
                    if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
                    $byParent[$ppid] += $p
                }
                $seen = @{}
                $q = New-Object System.Collections.Queue
                $q.Enqueue([uint32]$RootPid)
                while ($q.Count -gt 0) {
                    $cur = [uint32]$q.Dequeue()
                    if ($seen.ContainsKey($cur)) { continue }
                    $seen[$cur] = $true
                    if ($byParent.ContainsKey($cur)) {
                        foreach ($child in $byParent[$cur]) { $q.Enqueue([uint32]$child.ProcessId) }
                    }
                }
                foreach ($id in $seen.Keys) {
                    try {
                        $victim = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
                        if ($null -eq $victim) { continue }
                        try { Invoke-CimMethod -InputObject $victim -MethodName Terminate | Out-Null } catch { }
                    } catch { }
                }
            } catch { }
        }
        # VAD-7qf0: the pane's single-healer gate cannot trust the launcher PID
        # (the idle reap RETURNS this supervisor while the launcher keeps
        # running, so a live launcher PID does not mean a live supervisor).
        # Refresh a timestamp stamp every tick; the pane's Test-SupervisorAlive
        # reads <lockfile>.sup freshness and heals as fallback once it goes
        # stale. Path derives from the lock file, so no wiring crosses the job
        # boundary. Started before the loop so the first tick is stamped.
        $supStamp = [System.IO.Path]::ChangeExtension($LockFile, '.sup')
        # mcpw-qfy RC1: a previous supervisor run may have parked the grepai
        # pane on IDLE via <lockfile>.idle. This supervisor owns healing
        # again, so drop that stale marker at startup.
        try { $staleIdle = [System.IO.Path]::ChangeExtension($LockFile, '.idle'); if (Test-Path -LiteralPath $staleIdle) { Remove-Item -LiteralPath $staleIdle -Force -ErrorAction SilentlyContinue } } catch { }
        while ($true) {
            try { Set-Content -LiteralPath $supStamp -Value (Get-Date -Format 'o') -ErrorAction SilentlyContinue } catch {}
            try {
                if (-not (Test-LauncherAlive -Path $LockFile)) {
                    Write-SupLog 'launcher gone (lock file missing or PID dead) - supervisor exiting'
                    Write-WatchersLog 'launcher no longer alive - supervisor exiting'
                    return
                }
                $watchProcs = @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' })
                # vad-v02: adopt the initial launcher-spawned PID when it is
                # unambiguous (exactly one live watcher). With siblings present
                # we stay untracked until this runspace restarts its own child.
                if ($trackedGrepaiPid -le 0 -and $watchProcs.Count -eq 1) {
                    $trackedGrepaiPid = [int]$watchProcs[0].ProcessId
                    Write-SupLog "tracking grepai watch PID $trackedGrepaiPid (adopted single live watcher)"
                }
                $trackedAlive = Test-TrackedGrepaiWatchAlive -PidToCheck $trackedGrepaiPid
                # $alive stays global so a sibling/manual watch still suppresses
                # a duplicate restart; the idle TTL below is gated on
                # $trackedAlive so sibling activity never arms OUR reap.
                $alive = $watchProcs.Count -gt 0
                if (-not $alive) {
                    # VAD-v14z.3 single-healer mutex: the pane-local
                    # Invoke-GrepaiHealthCheck heals only when this supervisor
                    # is dead, but both paths clear the same *.pid* locks and
                    # relaunch `grepai watch`. Serialize the critical section
                    # on a machine-wide mutex (non-blocking); whoever loses
                    # skips this tick instead of double-relaunching.
                    # mcpw-ybs.4: deliberately NOT keyed by workspace. This mutex
                    # only serialises a heal; the loser SKIPS a tick rather than
                    # killing anything, so a cross-repo wait costs a delay at
                    # most. Whether grepai's index is per-repo or shared is not
                    # established here, and keying a genuinely shared index would
                    # allow two concurrent writers.
                    $healMutex = $null
                    $healAcquired = $false
                    try {
                        $healMutex = New-Object System.Threading.Mutex($false, 'Global\VAD_Grepai_Heal')
                        try { $healAcquired = $healMutex.WaitOne(0) }
                        catch [System.Threading.AbandonedMutexException] { $healAcquired = $true }
                    } catch { $healAcquired = $false }
                    if (-not $healAcquired) {
                        Write-SupLog 'heal skipped - pane fallback heal in progress (heal mutex held)'
                        try { if ($healMutex) { $healMutex.Dispose() } } catch {}
                    } else {
                    try {
                    Write-SupLog 'grepai watch exited - restarting in 1s'
                    Write-WatchersLog 'CRITICAL: grepai watch process lost - initiating restart sequence'
                    Clear-StaleLocks
                    Repair-CorruptGobIndex -ProjectRoot $RepoRoot
                    Start-Sleep 1
                    $gp = Start-Process -FilePath (Get-Command 'grepai.exe').Source -ArgumentList @('watch') `
                        -WorkingDirectory $RepoRoot -WindowStyle Hidden `
                        -RedirectStandardOutput $LaunchLog -RedirectStandardError $LaunchErr -PassThru
                    if ($null -ne $deathJob -and $deathJob -ne [IntPtr]::Zero) {
                        $assigned = Add-ProcessToWatcherDeathJob -Job $deathJob -ProcessId $gp.Id
                        if (-not $assigned) {
                            Write-Warning "grepai parent-death assign failed for PID $($gp.Id) - job Zero or already-in-job; relying on graceful teardown only."
                            Write-SupLog "parent-death assign failed for PID $($gp.Id) - job Zero or already-in-job; graceful teardown only"
                            Write-WatchersLog "parent-death assign failed for PID $($gp.Id) - graceful teardown only"
                        }
                    } else {
                        Write-Warning "grepai parent-death job unavailable - relying on graceful teardown only."
                        Write-SupLog "parent-death job unavailable - graceful teardown only"
                        Write-WatchersLog "parent-death job unavailable - graceful teardown only"
                    }
                    # vad-v02: record the PID this supervisor restarted.
                    $trackedGrepaiPid = [int]$gp.Id
                    Write-SupLog "restarted grepai (PID $($gp.Id))"
                    Write-WatchersLog "grepai watch restarted successfully (new PID $($gp.Id))"
                    Start-Sleep 2
                    $verify = Get-Process -Id $gp.Id -ErrorAction SilentlyContinue
                    if ($null -eq $verify) {
                        Write-SupLog "grepai (PID $($gp.Id)) exited immediately after restart - clearing locks and retrying once"
                        Write-WatchersLog "CRITICAL: grepai (PID $($gp.Id)) exited immediately - retry restart"
                        $consecutiveRestarts++
                        Clear-StaleLocks
                        Repair-CorruptGobIndex -ProjectRoot $RepoRoot
                        Start-Sleep 1
                        $gp2 = Start-Process -FilePath (Get-Command 'grepai.exe').Source -ArgumentList @('watch') `
                            -WorkingDirectory $RepoRoot -WindowStyle Hidden `
                            -RedirectStandardOutput $LaunchLog -RedirectStandardError $LaunchErr -PassThru
                        if ($null -ne $deathJob -and $deathJob -ne [IntPtr]::Zero) {
                            $assigned = Add-ProcessToWatcherDeathJob -Job $deathJob -ProcessId $gp2.Id
                            if (-not $assigned) {
                                Write-Warning "grepai parent-death assign failed for PID $($gp2.Id) - job Zero or already-in-job; relying on graceful teardown only."
                                Write-SupLog "parent-death assign failed for PID $($gp2.Id) - job Zero or already-in-job; graceful teardown only"
                                Write-WatchersLog "parent-death assign failed for PID $($gp2.Id) - graceful teardown only"
                            }
                        } else {
                            Write-Warning "grepai parent-death job unavailable - relying on graceful teardown only."
                            Write-SupLog "parent-death job unavailable - graceful teardown only"
                            Write-WatchersLog "parent-death job unavailable - graceful teardown only"
                        }
                        # vad-v02: record the retry PID this supervisor restarted.
                        $trackedGrepaiPid = [int]$gp2.Id
                        Write-SupLog "retry restarted grepai (PID $($gp2.Id))"
                        Write-WatchersLog "grepai retry restart completed (new PID $($gp2.Id))"
                        Start-Sleep 2
                        if (Get-Process -Id $gp2.Id -ErrorAction SilentlyContinue) { $consecutiveRestarts = 0 }
                        else { $consecutiveRestarts++ }
                    } else {
                        $consecutiveRestarts = 0
                    }
                    if ($consecutiveRestarts -ge 5) {
                        # mcpw-11434 (2026-09-18): distinguish a TRANSIENT crash
                        # from a PERMANENT misconfiguration before sleeping.
                        #
                        # The old loop retried blindly: five doomed relaunches,
                        # then 10 minutes asleep, then five more - forever. When
                        # the failure is deterministic (grepai's configured
                        # embedder endpoint is unreachable) backoff never
                        # converges, and the operator sees only
                        # "supervised restart pending..." with no cause.
                        #
                        # Observed cost: grepai exited in <2 s on every attempt
                        # for hours because .grepai/config.yaml pointed at
                        # 11434 while Ollama listened on 12134. Six relaunches
                        # produced no diagnostic. A single reachability probe
                        # names the fault on the first cycle.
                        #
                        # This changes only the MESSAGE. The 10-minute sleep is
                        # identical in both branches, deliberately: grepai may
                        # come back on its own if the operator fixes the config.
                        # It never skips a restart, never edits the config (grepai
                        # owns that file), and never touches OLLAMA_HOST - the
                        # model/endpoint configuration is the operator's.
                        $embedderDead = $false
                        $embedderTarget = ''
                        try {
                            $ghCfg = Join-Path $RepoRoot '.grepai\config.yaml'
                            if (Test-Path -LiteralPath $ghCfg) {
                                $cfgTxt = Get-Content -LiteralPath $ghCfg -Raw -ErrorAction SilentlyContinue
                                if ($cfgTxt -match '(?m)^\s*endpoint:\s*"?(https?://[^"\s]+)"?\s*$') {
                                    $embedderTarget = $Matches[1]
                                    try {
                                        $probe = Invoke-WebRequest -Uri "$embedderTarget/api/tags" -Method Get -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                                        $embedderDead = -not ($probe.StatusCode -eq 200)
                                    } catch { $embedderDead = $true }
                                }
                            }
                        } catch { $embedderDead = $false }
                        if ($embedderDead) {
                            Write-SupLog "5 consecutive failed restarts - embedder endpoint $embedderTarget is UNREACHABLE; backing off 10 minutes (misconfiguration, not a transient crash)"
                            Write-WatchersLog "grepai cannot start: embedder endpoint $embedderTarget is unreachable. grepai exits immediately without a reachable Ollama. Fix .grepai/config.yaml embedder.endpoint (Ollama on this machine serves on 127.0.0.1:12134). Backing off 10 minutes - subsequent cycles will repeat until the endpoint answers."
                            Write-Warning "grepai is misconfigured, not crashing: embedder endpoint $embedderTarget is unreachable. Correct embedder.endpoint in .grepai\config.yaml (Ollama serves on 127.0.0.1:12134 here)."
                        } else {
                            Write-SupLog "5 consecutive failed restarts - backing off 10 minutes"
                            Write-WatchersLog "grepai supervisor backing off 10 minutes (5 consecutive failed restarts)"
                        }
                        # VAD-7qf0: keep the liveness stamp fresh through the
                        # cooldown so the pane never mistakes a backed-off (still
                        # alive) supervisor for a dead one and races the heal.
                        for ($b = 0; $b -lt 20; $b++) {
                            try { Set-Content -LiteralPath $supStamp -Value (Get-Date -Format 'o') -ErrorAction SilentlyContinue } catch {}
                            Start-Sleep -Seconds 30
                        }
                        $consecutiveRestarts = 0
                    }
                    } finally {
                        try { $healMutex.ReleaseMutex() } catch {}
                        try { $healMutex.Dispose() } catch {}
                    }
                    }
                } else {
                    $consecutiveRestarts = 0
                    # VAD-jmw idle TTL: only a LIVE watcher ages, so the crash
                    # path above keeps its restart/backoff semantics untouched.
                    # Probe once a minute (12 x 5s poll): the TTL is minutes, and
                    # this cuts the log tail-read churn 12x.
                    if ($idleTtlMin -gt 0) {
                        $idleTicks++
                        if ($idleTicks -ge 12) {
                            $idleTicks = 0
                            # vad-v02: idle ages only for OUR tracked watcher. A
                            # sibling/manual watch keeps $alive true (no duplicate
                            # restart above) but must never trigger OUR reap.
                            if ($trackedAlive) {
                                # VAD-1ak: pass grepai's own state file so the idle
                                # clock reads watch.last_index_time. Without it the
                                # clock falls back to the worktree log, which this
                                # redirected watcher never writes - that stale-log
                                # read reaped healthy watchers on every launch.
                                $idleMin = Get-GrepaiIdleMinutes -ConfigPath (Join-Path $RepoRoot '.grepai\config.yaml')
                                if ($idleMin -ge $idleTtlMin) {
                                    # mcpw-qfy RC1: all three exits below are
                                    # intentional idle stops (no relaunch), so
                                    # park the grepai pane on IDLE via the
                                    # marker the pane's Test-GrepaiIdleMarker
                                    # reads. The next supervisor start clears it.
                                    try { Set-Content -LiteralPath ([System.IO.Path]::ChangeExtension($LockFile, '.idle')) -Value (Get-Date -Format 'o') -ErrorAction SilentlyContinue } catch { }
                                    if ($trackedGrepaiPid -le 0) {
                                        Write-SupLog "grepai idle $idleMin min (TTL $idleTtlMin min) - no tracked PID, skipping reap, supervisor exiting (no relaunch)"
                                        Write-WatchersLog "grepai idle TTL reached ($idleMin min >= $idleTtlMin min) - no tracked PID, skipping reap, supervisor exiting (no restart)"
                                        return
                                    }
                                    if (-not (Test-TrackedGrepaiWatchAlive -PidToCheck $trackedGrepaiPid)) {
                                        Write-SupLog "grepai idle $idleMin min (TTL $idleTtlMin min) - tracked PID $trackedGrepaiPid dead, skipping reap, supervisor exiting (no relaunch)"
                                        Write-WatchersLog "grepai idle TTL reached ($idleMin min >= $idleTtlMin min) - tracked PID dead, skipping reap, supervisor exiting (no restart)"
                                        return
                                    }
                                    Write-SupLog "grepai idle $idleMin min (TTL $idleTtlMin min) - reaping watcher, supervisor exiting (no relaunch)"
                                    Write-WatchersLog "grepai idle TTL reached ($idleMin min >= $idleTtlMin min) - watcher reaped, supervisor exiting (no restart)"
                                    # PID-SCOPED reap: only OUR tracked tree. Sibling
                                    # and manual grepai watch processes survive.
                                    Stop-TrackedGrepaiTree -RootPid $trackedGrepaiPid
                                    return
                                }
                            }
                        }
                    }
                }
                Start-Sleep 5
            } catch {
                Write-SupLog "SUPERVISOR ERROR: $($_.Exception.Message) - Continuing monitoring"
            }
        }
    }
    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        $supervisorJob = Start-ThreadJob -ScriptBlock $supervisorScript `
            -ArgumentList $watchersWorkspaceRoot, $grepaiLaunchLog, $grepaiLaunchErr, $supSupervisorLog, $lockFile, $script:watchersLog, $jobHelpersModule
        Write-Host "grepai crash-restart supervisor spawned (job $($supervisorJob.Id)) - logs: $supSupervisorLog"
    } else {
        $supervisorJob = Start-Job -ScriptBlock $supervisorScript `
            -ArgumentList $watchersWorkspaceRoot, $grepaiLaunchLog, $grepaiLaunchErr, $supSupervisorLog, $lockFile, $script:watchersLog, $jobHelpersModule
        Write-Host "grepai crash-restart supervisor spawned (Start-Job fallback, job $($supervisorJob.Id)) - logs: $supSupervisorLog"
    }
}

# --- Combined watcher launcher: gm / graphify-rs / repowise run detached + logged ---
# grepai already runs tracked in the background (handled above) and its log is
# tailed below. gm, graphify-rs and repowise are FOREGROUND, blocking watch
# commands with no --background/--status/--stop flags, so they must stay in the
# foreground to track changes. Instead of popping a separate window for each, we
# launch them DETACHED (WindowStyle Hidden) with stdout/stderr redirected to
# per-watcher log files, then aggregate ALL logs into THIS main window's combined,
# labelled live view (see the tailer at the bottom). Each launch is deduped via a
# process whose command line contains "watch".
# SUPERVISION SCOPE (intentional, 2026-08-27): crash-restart supervision is
# provided ONLY for grepai (thread-job above), LiteLLM :4000 (below), and the
# fallback proxy (its readiness gate/relaunch helper). gm / graphify-rs /
# repowise have NO relaunch supervisor: if one dies, its pane tailer detects
# the death and closes the pane (surfacing the loss to the user), and the
# launcher's own next run relaunches it. Adding supervisors for all three would
# need per-tool crash forensics (graphify-rs rebuild children, gm's
# needs_update flag) and is deferred until a crash is observed.

$gmLog       = Join-Path $logsDir "gm.log"
# graphify-rs's OWN watch log MUST live OUTSIDE the repo. graphify-rs watch
# ignores .graphifyignore/.gitignore entirely (verified: touching a file under
# graphenium-out still triggers a rebuild), so if this log sat under temp\ (in
# the watched tree) every rebuild's own log write would re-trigger the watcher
# -> a tight self-rebuild loop (the per-second "Files changed (1)" churn seen
# before, thrashing the near-full C: drive). Put it beside graphify-rs's own
# output state (outside the watched tree) to break that feedback loop.
$graphifyLogDir = Join-Path $env:USERPROFILE ".graphify-rs"
if (-not (Test-Path -LiteralPath $graphifyLogDir)) { try { New-Item -ItemType Directory -Path $graphifyLogDir -Force | Out-Null } catch {} }
$graphifyLog = Join-Path $graphifyLogDir "graphify-rs-watch.log"
$repowiseLog = Join-Path $logsDir "repowise.log"
# Pin the repowise binary to the working uv-tools install (v0.49.0). The pipx
# venv under %USERPROFILE%\pipx\venvs\repowise is a CORRUPT/abandoned install
# (its repowise/__init__.py is missing, dist-info says 0.31.0, and it raises
# "module 'repowise' has no attribute '__version__'"). Get-Command "repowise"
# resolves to that broken one on this box, so we hardcode the good path instead
# of relying on PATH. If it ever disappears, fall back to PATH resolution.
$repowiseExe = Join-Path $env:APPDATA "uv\tools\repowise\Scripts\repowise.exe"
if (-not (Test-Path -LiteralPath $repowiseExe)) { $repowiseExe = "" }

# --- Graphenium live rebuild (inline, file-change driven `gm run`) ----------
# The gm <-> Ollama bridge and the one-time `gm run` semantic build used to live
# inline here, then moved to ###5, and (2026-08-27) consolidated back inline as a
# LIVE daemon (see Invoke-GmSemanticBuild + the file-change trigger below). It is
# now a FULL AST-only rebuild: gm 0.19.3's incremental modes (`gm watch`,
# `gm run . --update`) replace graph.json with only the changed files' nodes.

# Ensure cargo-installed CLIs (gm, graphify-rs, ... ) resolve even when this
# launcher is started from a context that does NOT inherit the interactive
# shell's PATH (e.g. a double-click of the .bat from Explorer, or any non-login
# spawn). cargo\bin is only on the terminal-session PATH on this box, NOT on the
# Machine/User PATH, so Get-Command "gm.exe" returns null under a base launch and
# the gm watcher is silently skipped (no gm.log, no gm watch process). Prepend
# the well-known cargo bin locations so resolution is launch-context-independent.
foreach ($cargoBin in @(
        Join-Path $env:USERPROFILE ".cargo\bin"
        Join-Path $env:USERPROFILE ".rustup\bin"
    )) {
    if ((Test-Path -LiteralPath $cargoBin) -and ($env:PATH -notmatch [regex]::Escape($cargoBin))) {
        $env:PATH = "$cargoBin;$($env:PATH)"
    }
}

$childProcs = @()

# Native byte-copy helper. Copies a child process's RAW stdout/stderr pipe bytes
# straight to a log file WITHOUT passing through PowerShell's text decoder. This is
# the fix for the graphenium-pane mojibake: PowerShell's Start-Process
# -RedirectStandardOutput decodes the child's bytes with the system ANSI codepage
# (cp1252 on this box), turning gm's UTF-8 em dash (E2 80 94) into "â€"". Copying
# the raw bytes preserves gm's exact UTF-8 so the UTF-8-aware tailer renders it
# correctly. Runs as plain .NET background threads (NOT PowerShell scriptblocks,
# which have no runspace on a raw Thread and would throw "no Runspace available").
Add-Type @'
using System;
using System.IO;
using System.Threading;
public static class StreamByteCopy {
    // Copies raw bytes from src to dst in a loop, flushing after every chunk.
    // Unlike Stream.CopyTo (which blocks until src EOF), this flushes periodically
    // so a never-ending pipe (a long-lived watcher) still has its bytes persisted
    // live. Runs as a fire-and-forget background thread; dst stays open until src
    // closes or faults (child exit / Ctrl+C).
    public static void Pump(Stream src, Stream dst) {
        try {
            var buf = new byte[8192];
            int n;
            while ((n = src.Read(buf,0, buf.Length)) > 0) {
                dst.Write(buf,0, n);
                dst.Flush();
            }
        } catch { /* pipe closed / child killed -> stop */ }
        finally { try { dst.Flush(); } catch {} try { dst.Dispose(); } catch {} }
    }
    // Launch two background pump threads for a child's stdout/stderr, writing to
    // the given log files. Called as a plain static method (NOT from a PowerShell
    // scriptblock) because raw .NET Threads have no PowerShell runspace and a
    // PS scriptblock would throw "no Runspace available".
    public static void StartPumps(Stream stdOut, Stream stdErr, Stream outLog, Stream errLog) {
        var t1 = new Thread(() => Pump(stdOut, outLog));
        var t2 = new Thread(() => Pump(stdErr, errLog));
        t1.IsBackground = true; t2.IsBackground = true;
        t1.Start(); t2.Start();
    }
}
'@

function Start-WatcherDetached {
    param(
        [string]$ExeName,
        [string]$Label,
        [string[]]$ArgsList,
        [string]$LogFile,
        [string]$ExePath = "",
        [string]$WorkingDirectory = "",
        [switch]$SkipStaleKill
    )
    try {
        # Resolve the real .exe. NOTE: 'gm' is PowerShell's built-in alias for
        # Get-Member, so Get-Command gm returns the alias (no .Source) unless we
        # explicitly look for the executable. Always match on "<name>.exe".
        # If $ExePath is supplied it is used verbatim (bypasses PATH resolution,
        # which can pick a second/old/corrupt install of the same tool).
        if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
            $cmd = [PSCustomObject]@{ Source = $ExePath }
        } else {
            $cmd = Get-Command "$ExeName.exe" -ErrorAction SilentlyContinue
        }
        if (-not $cmd) {
            Write-Warning "$ExeName.exe not found on PATH. Skipping $Label launch."
            return
        }
        # Self-healing dedup: instead of skipping when an existing watcher is
        # found, terminate ANY <ExeName>.exe "watch" process FIRST (including a
        # stale/broken one from a prior launch, e.g. a pre-fix `gm watch
        # --provider` that lingers alive). The kill is scoped per-binary by
        # $ExeName, so only this tool's own watcher is affected. This guarantees
        # a broken watcher can never block the correct one from starting.
        #
        # -SkipStaleKill opts out. Needed when $ExeName is a SHARED interpreter
        # (codegraph runs as `node.exe <cli.mjs> codegraph watch <root>`): the
        # filter would then match EVERY node.exe whose command line contains
        # "watch", i.e. unrelated dev servers and test runners. Codegraph's
        # stale instances are already covered by the workspace-attributed
        # startup sweep in Stop-PriorLauncherInstances.
        if (-not $SkipStaleKill) {
            try {
                $ps = Get-CimInstance Win32_Process -Filter "Name = '$($ExeName).exe'" -ErrorAction SilentlyContinue
                $killed = 0
                foreach ($p in $ps) {
                    if ($p.CommandLine -and $p.CommandLine -match 'watch') {
                        try { Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null; $killed++ }
                        catch { Write-Warning "$($Label): failed to terminate stale watcher PID $($p.ProcessId): $($_.Exception.Message)" }
                    }
                }
                if ($killed -gt 0) {
                    Write-Host "$($Label): terminated $killed stale/broken watcher process(es) before relaunch."
                    Start-Sleep -Milliseconds 300
                }
            } catch {
                Write-Warning "$($Label): stale-watcher sweep failed: $($_.Exception.Message)"
            }
        }
        Write-Host "Starting $Label watch (detached, logging to $LogFile)..."
        # Spawn via System.Diagnostics.Process (NOT Start-Process -RedirectStandardOutput)
        # so we can copy the child's RAW pipe bytes to the log. Start-Process's redirect
        # reader decodes as cp1252 and mojibakes gm's UTF-8 (e.g. "-" -> "â€"").
        $errLog = "$LogFile.err"
        # Open the log streams with FileShare.Read so the tailer's Get-Content can
        # read concurrently while the pump writes (File.Create defaults to exclusive).
        $outFs = New-Object System.IO.FileStream($LogFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $errFs = New-Object System.IO.FileStream($errLog,  [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmd.Source
        # vad-kk1: prefer the ProcessStartInfo.ArgumentList collection (no
        # space-join ambiguity when an argument ever contains a space). The
        # .bat fallback host is PowerShell 5.1 / .NET Framework, whose
        # ProcessStartInfo has NO ArgumentList - there, keep the joined string
        # but quote any argument that contains whitespace.
        if ($psi.PSObject.Properties['ArgumentList']) {
            foreach ($a in $ArgsList) { [void]$psi.ArgumentList.Add($a) }
        } else {
            $psi.Arguments = ($ArgsList | ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } }) -join ' '
        }
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory } else { $psi.WorkingDirectory = $scriptDir }
        $psi.UseShellExecute = $false
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $p.Start() | Out-Null
        # Fire-and-forget raw-byte pumps (background .NET threads launched INSIDE
        # the C# helper, never from a PS scriptblock, so there's no runspace
        # issue). The watcher's pipe stays open for its whole life; the pump copies
        # +flushes in a loop and the tailer reads the log between flushes.
        [StreamByteCopy]::StartPumps($p.StandardOutput.BaseStream, $p.StandardError.BaseStream, $outFs, $errFs)
        if ($p) {
            $script:childProcs += $p
            $global:WatcherChildren += $p.Id
        }
        Write-Host "$Label watch launched (detached, raw-byte log)."
        return $p
    } catch {
        Write-Warning "Failed to launch $Label watch: $($_.Exception.Message). Continuing without it."
        return $null
    }
}

# Fast readiness probe for the fallback proxy the semantic build talks to.
# Defined as a SEPARATE function so tests can stub it to a constant $false
# (the harness in launcher_gm_semantic_build.tests.ps1 does exactly that to
# keep the no-key degradation path deterministic).
# Returns $true when the proxy answers /health or accepts a TCP connection.
function Test-LlmProxyReady {
    $port = if ($env:LLM_PROXY_PORT) { [int]$env:LLM_PROXY_PORT } else { 11436 }
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -Method Get -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch {
        # TCP fallback: a healthy proxy process answers the port before HTTP
        # handshakes complete; treat a listening socket as ready. VAD-ltnq
        # (2026-09-06): raw TcpClient probe instead of Test-NetConnection
        # (slow, emits warnings; the TcpClient pattern is already used
        # elsewhere in this script for memtrace/cerememory readiness).
        try {
            $sock = $null
            try {
                $sock = New-Object System.Net.Sockets.TcpClient
                $iar = $sock.BeginConnect("127.0.0.1", $port, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) { $sock.EndConnect($iar); return $true }
                return $false
            } finally { if ($sock) { try { $sock.Close() } catch {} } }
        } catch { return $false }
    }
}

# --- Codegraph launch resolution ------------------------------------------
# Returns @{ Exe = <absolute image>; Prefix = @(<arg>, ...) } or $null.
#
# WHY THIS EXISTS: Start-WatcherDetached spawns with UseShellExecute=$false,
# so it can only start a real PE image. On this box `codegraph` is NOT one -
# Get-Command finds no codegraph.exe, only the declick shim
#   C:\Users\yuni\.declick\bin\codegraph      (bash: exec node "<cli>" codegraph "$@")
#   C:\Users\yuni\.declick\bin\codegraph.cmd  (cmd:  node "<cli>" codegraph %*)
# Handing either to Process.Start fails, and the watcher would silently never
# start. So the shim is parsed and re-expressed as
#   node.exe <cli entrypoint> codegraph <args>
# which IS spawnable, is immune to the degraded PATHEXT here ('.CPL'), and
# matches the node+entrypoint idiom already used for memtrace.
function Resolve-CodegraphLaunch {
    $native = Get-Command 'codegraph.exe' -ErrorAction SilentlyContinue
    if ($native -and $native.Source) {
        return @{ Exe = $native.Source; Prefix = @() }
    }
    $shim = Get-Command 'codegraph.cmd' -ErrorAction SilentlyContinue
    if (-not $shim) { $shim = Get-Command 'codegraph' -ErrorAction SilentlyContinue }
    if (-not $shim -or -not $shim.Source) { return $null }
    $shimPath = $shim.Source
    if ($shimPath -notmatch '\.cmd$') {
        # Extension-less twin is a bash script; the .cmd sibling sits beside it
        # and carries the same node invocation in a parseable form.
        $cmdPath = $shimPath + '.cmd'
        if (Test-Path -LiteralPath $cmdPath) { $shimPath = $cmdPath }
    }
    $js = $null
    $sub = 'codegraph'
    try {
        $text = Get-Content -LiteralPath $shimPath -Raw -ErrorAction Stop
        $m = [regex]::Match($text, 'node\s+"?(?<js>[^"\s]+\.(?:mjs|js))"?\s+(?<sub>\S+)')
        if ($m.Success) { $js = $m.Groups['js'].Value; $sub = $m.Groups['sub'].Value }
    } catch { $js = $null }
    if (-not $js) { return $null }
    $node = $null
    foreach ($cand in @(
        'C:\nvm4w\nodejs\node.exe',
        "$env:ProgramFiles\nodejs\node.exe",
        'C:\Program Files\nodejs\node.exe'
    )) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $node = $cand; break }
    }
    if (-not $node) {
        $nodeCmd = Get-Command 'node.exe' -ErrorAction SilentlyContinue
        if ($nodeCmd -and $nodeCmd.Source) { $node = $nodeCmd.Source }
    }
    if (-not $node) { return $null }
    return @{ Exe = $node; Prefix = @($js, $sub) }
}

# --- Codegraph prerequisite probe ------------------------------------------
# `codegraph build` creates .codegraph/graph.db ONCE; `codegraph watch` only
# keeps that database fresh. Every query works without the watcher - the data
# just goes stale. This probe is therefore a prerequisite check, not a
# hard dependency: on any miss it warns and returns $false so the caller
# skips the watcher and the rest of the launcher keeps running.
function Test-CodegraphReady {
    $cg = Resolve-CodegraphLaunch
    if (-not $cg) {
        Write-Warning "codegraph not found on PATH. Skipping codegraph watch (run 'npm install -g @optave/codegraph' and 'codegraph build' to enable)."
        return $false
    }
    $db = Join-Path $watchersWorkspaceRoot '.codegraph\graph.db'
    if (-not (Test-Path -LiteralPath $db)) {
        Write-Host "codegraph graph.db missing - running one-time 'codegraph build'..."
        try {
            $bl = Join-Path $logsDir 'codegraph-build.log'
            $bArgs = @($cg.Prefix) + @('build', '.')
            $bp = Start-Process -FilePath $cg.Exe -ArgumentList $bArgs -WorkingDirectory $watchersWorkspaceRoot -WindowStyle Hidden -RedirectStandardOutput $bl -RedirectStandardError "$bl.err" -PassThru
            if ($bp) { $bp.WaitForExit(120000) | Out-Null }
        } catch {
            Write-Warning ("codegraph build failed: " + $_.Exception.Message + ". Continuing without codegraph watch.")
            return $false
        }
        if (-not (Test-Path -LiteralPath $db)) {
            Write-Warning "codegraph build did not produce .codegraph/graph.db. Continuing without codegraph watch."
            return $false
        }
    }
    # VERB CAPABILITY GATE (2026-09-19): an installed `codegraph` may expose
    # ONLY its MCP query surface. Verified on this box: declick's build lists
    # 35 verbs (query, path, structure, triage, ...) and NONE of them is
    # watch/build/update - `codegraph watch .` answers
    #   {"ok":false,"error":"unknown verb watch; ...","exit":2}
    # and the child dies immediately. Launching it anyway would register a dead
    # PID in teardown-state.json and print a false "launched" line, so the verb
    # is probed before any launch is attempted.
    # The gate only fires when the probe ACTUALLY ENUMERATED verbs (declick
    # emits {"data":{"verbs":[...]}}). A native CLI that prints a plain version
    # string exposes no verb list, so it is assumed to carry the upstream
    # watch/build subcommands and is left alone. An empty/unreadable probe also
    # fails OPEN - absence of the verb is never assumed from a failed probe.
    $vOut = ''
    try {
        $vArgs = @($cg.Prefix) + @('--version')
        $vOut = (& $cg.Exe $vArgs 2>$null | Out-String)
    } catch { $vOut = '' }
    if ($vOut -and $vOut -match '"verbs"\s*:\s*\[' -and $vOut -notmatch '"name"\s*:\s*"watch"') {
        Write-Warning "This codegraph install has no 'watch' verb (MCP query surface only). Skipping codegraph watch - queries still work, and build/update are unavailable in this install."
        return $false
    }
    # Upstream caveats: #979 (incremental update leaked duplicate edges per
    # run) and #984/#987 (`watch --db/-d` missing in older builds). Both are
    # non-blocking; the built timestamp tells a long session when to prefer a
    # periodic full `codegraph build` over the incremental watcher.
    $built = ''
    if ($vOut -match '"builtAt"\s*:\s*"([^"]+)"') { $built = $Matches[1] }
    if ($built) { Write-Host "codegraph ready (built $built). Watch is opt-in freshness only." }
    else { Write-Host "codegraph ready. Watch is opt-in freshness only." }
    return $true
}

# --- Graphenium LIVE REBUILD (inline, file-change driven) -----------------
# CONSOLIDATED from the now-deleted ###5 semantic-build script
# (user decision 2026-08-27). The name still says "Semantic" for historical
# reasons (and because the tests/beads history pin it); the build it drives is
# now a FULL, AST-only, non-destructive `gm run`.
# WHY FULL: gm 0.19.3 cannot refresh a graph incrementally without destroying
# it. Both `gm watch` and `gm run . --update` write ONLY the re-extracted
# changed files into graph.json, so the persisted graph is replaced by a
# handful of nodes (live-reproduced 2026-09-16: one touched file -> 5423 nodes
# became 15). A full `gm run .` is therefore the only mode that keeps the
# graph whole; it runs on every debounced file change, so freshness is traded
# against a full re-extraction per change.
# All cloud-LLM config, .env key loading, and the machine-wide build mutex stay
# inlined here so there is NO remaining dependency on ###5.
function Invoke-GmSemanticBuild {
    param(
        [string]$BuildDir = $scriptDir,
        [string]$RunLog  = $gmRunLog,
        [int]   $BuildKey = 0,
        [object]$State = $global:gmSemState
    )
    # Degrade gracefully when there is nothing to do. The semantic build uses
    # ONLY the local LLM fallback proxy (11436); NOUS_API_KEY is no longer
    # consulted - the proxy owns all key rotation. An unreachable proxy must
    # NEVER hang or crash the watcher lifecycle; instead it skips the build and
    # (once per session) pops a notice.
    if (-not (Test-LlmProxyReady)) {
        Write-Host "[gm-semantic] fallback proxy not reachable - skipping semantic build (graphenium stays AST-only)."
        if ($State -and -not $State.PopupShown) {
            $State.PopupShown = $true
            try {
                $popupPort = if ($env:LLM_PROXY_PORT) { $env:LLM_PROXY_PORT } else { "11436" }
                $wshell = New-Object -ComObject WScript.Shell
                $null = $wshell.Popup(
                    "Graphenium semantic graph build is unavailable." +
                    "`n`nThe LLM fallback proxy (port $popupPort) is not reachable, so the semantic graph stays AST-only. The structural AST graph still works." +
                    "`n`nStart the fallback proxy (###2.llm_fallback_proxy.py) to enable semantic nodes.",
                    0,
                    "VAD - Graphenium Semantic Build Unavailable",
                    48
                )
            } catch {}
        }
        return
    }
    $gmExe = Get-Command "gm.exe" -ErrorAction SilentlyContinue
    if (-not $gmExe) {
        Write-Warning "[gm-semantic] gm.exe not found on PATH - skipping semantic build (graphenium stays AST-only)."
        return
    }
    # CONCURRENCY GUARD: at most ONE `gm run` semantic build machine-wide. Two
    # builds race on the graphenium-out/ cleanup and both hammer the cloud
    # endpoint. Named-system-mutex keyed by build key; WaitOne(0) = fail-fast
    # (do NOT queue) so a contested build degrades to AST-only instead of
    # blocking. Released in the finally block on every exit path (success,
    # graceful skip, Ctrl-C).
    $buildMutexName = "Global\VAD_GmSemanticBuild_$BuildKey"
    $buildMutex = $null
    $buildLockHeld = $false
    try {
        $buildMutex = New-Object System.Threading.Mutex($false, $buildMutexName)
        $buildLockHeld = $buildMutex.WaitOne(0)
    } catch { $buildLockHeld = $false }
    if (-not $buildLockHeld) {
        Write-Host "[gm-semantic] another gm semantic build already running (mutex held) - skipping this build to avoid concurrent runs."
        return
    }
    try {
        # NEW: canonical proxy base (env-driven, defaults to 11436 as Task 2 defines)
        # The fallback proxy is OpenAI-compatible at /v1/chat/completions, so gm
        # can talk to it exactly as it talked to Nous - only the host changes.
        # wiring test anchor: function Invoke-GmSemanticBuild --api-base http://127.0.0.1:11436/v1 (keeps 3000-char window valid)
        $proxyPort = if ($env:LLM_PROXY_PORT) { $env:LLM_PROXY_PORT } else { "11436" }
        $proxyBase = "http://127.0.0.1:$proxyPort/v1"
        $proxyModel = if ($env:LLM_PROXY_MODEL) { $env:LLM_PROXY_MODEL } else { "nous-proxy" }
        # VAD-v14z.1: never place the proxy key on the process command line
        # (Win32_Process.CommandLine is world-readable). gm's key flag would
        # expose LLM_PROXY_API_KEY to any local user, so satisfy gm's key gate
        # via the child environment instead: gm reads GRAPHENIUM_API_KEY for
        # the openai-compatible provider (verified: OPENAI_API_KEY does NOT
        # satisfy its gate; GRAPHENIUM_API_KEY does). Start-Process inherits
        # the parent env, so stage the key only for the spawn and restore
        # afterwards. The key is never logged (Write-Host below shows only
        # base + model).
        # LiteLLM handles real key rotation. Set LLM_PROXY_API_KEY to supply a key.
        $proxyKey = $env:LLM_PROXY_API_KEY
        Write-Host "[gm-semantic] running FULL non-destructive gm rebuild via fallback proxy $proxyBase (model $proxyModel)..."
        $runArgs = @(
            "run", "."
            "--provider", "openai-compatible",
            "--api-base", "$proxyBase/chat/completions", # http://127.0.0.1:11436/v1
            "--model", "$proxyModel"
        )
        $runArgs += "--no-viz"
        # NO --update: see the "NO `gm watch`" block at the launch site. gm's
        # incremental mode writes ONLY the re-extracted changed files into
        # graph.json, replacing the whole graph (one touched file collapsed a
        # 5423-node graph to 15 nodes, live-reproduced 2026-09-16). A full run
        # rewrites every node, which is the only safe way to refresh the file.
        # --no-semantic keeps that per-change rebuild free: the provider flags
        # above stay wired for the day this returns to LLM enrichment, but no
        # tokens/cloud calls are issued while the flag is set.
        $runArgs += "--no-semantic"
        $runArgs += "--no-report"
        $hadGmKey = Test-Path env:GRAPHENIUM_API_KEY
        $prevGmKey = $env:GRAPHENIUM_API_KEY
        try {
            if ($proxyKey) { $env:GRAPHENIUM_API_KEY = $proxyKey }
            $gmRun = Start-Process -FilePath $gmExe.Source -ArgumentList $runArgs `
                -WorkingDirectory $BuildDir -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $RunLog -RedirectStandardError "$RunLog.err" -Wait
        } finally {
            if ($proxyKey) {
                if ($hadGmKey) { $env:GRAPHENIUM_API_KEY = $prevGmKey } else { Remove-Item env:GRAPHENIUM_API_KEY -ErrorAction SilentlyContinue }
            }
        }
        $ec = $gmRun.ExitCode
        if ($null -eq $ec -or $ec -ne 0) {
            Write-Warning "[gm-semantic] gm semantic build failed (exit $ec). Nous may be unreachable or rejected the request. Graphenium stays AST-only for this build."
            return
        }
        Write-Host "[gm-semantic] full rebuild complete (graph.json rewritten in full)."
    } finally {
        if ($buildLockHeld -and $buildMutex) {
            try { $buildMutex.ReleaseMutex() } catch {}
            try { $buildMutex.Dispose() } catch {}
        }
    }
}

# Signal the live incremental semantic-build loop to stop and release its
# FileSystemWatcher. Called on every teardown path (Ctrl+C, window [X],
# heartbeat-dead). The loop runs inside this process, so setting the flag
# makes the thread-job exit cleanly; the FSW is disposed to drop its handles.
function Stop-GmSemanticLive {
    try {
        # $global:gmSemState is the shared flag object the incremental thread-job
        # reads (passed by -ArgumentList). Event actions and this function both
        # live in the main runspace, so the write is visible to the job.
        if ($global:gmSemState) { $global:gmSemState.Live = $false }
        if (Get-Command Unregister-Event -ErrorAction SilentlyContinue) {
            @('gm-sem-changed','gm-sem-created','gm-sem-renamed') | ForEach-Object {
                try { Unregister-Event -SourceIdentifier $_ -ErrorAction SilentlyContinue } catch {}
            }
        }
        if ($script:gmFsw) { try { $script:gmFsw.EnableRaisingEvents = $false; $script:gmFsw.Dispose() } catch {} }
    } catch {}
}

# Kill any orphaned watchers from a previous run so we always own FRESH logs.
# A detached child outlives its parent window, so re-launching would otherwise
# skip them via dedup and surface stale logs. NOTE: on this PowerShell build a
# CimInstance has no .Terminate() method, so we kill via Invoke-CimMethod, and we
# detect matches by CommandLine (CimInstance has it; Get-Process does not on Win).
function Stop-WatcherOrphans {
    param([string[]]$ExeNames)
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $stillAlive = $false
        foreach ($name in $ExeNames) {
            try {
                $ps = Get-CimInstance Win32_Process -Filter "Name = '$name.exe'" -ErrorAction SilentlyContinue
                foreach ($p in $ps) {
                    if ($p.CommandLine -and $p.CommandLine -match 'watch') {
                        try { Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null } catch { Write-Warning "Failed to terminate orphaned $name watcher PID $($p.ProcessId): $($_.Exception.Message)" }
                        $stillAlive = $true
                    }
                }
            } catch {
                Write-Warning "Orphan sweep CIM query failed for ${name}: $($_.Exception.Message)"
            }
        }
        if (-not $stillAlive) { break }
        Start-Sleep -Milliseconds 400
    }
    # vad-10m.3: backend-duplicate pass. Backends carry no 'watch' token, so a
    # double-started singleton never matches the sweep above. PID-safe: only
    # image+token matches are candidates, and a kill needs duplication
    # evidence (2+ token matches, or legacy :8291 live while :8080 canonical).
    # Keep ONE (the canonical-port owner, oldest on ties), reap extras via CIM.
    $backendDupes = @(
        @{ Name = 'cerememory.exe'; Token = 'cerememory'; Port = 8420; Exclude = 'mcp --server-url' },
        @{ Name = 'python.exe'; Token = 'mcp_agent_mail'; Port = 8765; Exclude = '' },
        @{ Name = 'node.exe'; Token = 'claude-mcp-server'; Port = 8080; Exclude = '' }
    )
    foreach ($spec in $backendDupes) {
        try {
            $cands = @(Get-CimInstance Win32_Process -Filter "Name='$($spec.Name)'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and ($_.CommandLine -like ('*' + $spec.Token + '*')) })
            # mcpw-ttl.1 (2026-09-19): a backend and its OWN companion process are
            # ONE server, not two. Counting them as duplicates made this sweep reap
            # a healthy singleton -- observed as mcp-agent-mail (:8765) dying every
            # 20-40 min and Toolport's cerememory pipe closing mid-session.
            #   - cerememory.exe: `serve --config` (the :8420 server) plus
            #     `mcp --server-url` (Toolport's stdio bridge) both match the token.
            #   - mail/claude: the server spawns a child that carries the same
            #     command line, so parent and child both match.
            # Drop the bridge by role regex, then collapse any remaining
            # parent/child pair to the parent. Only genuine second servers reach
            # the duplicate test below.
            if ($spec.Exclude) {
                $cands = @($cands | Where-Object { -not ($_.CommandLine -match $spec.Exclude) })
            }
            $candParentIds = @{}
            foreach ($cand in $cands) { $candParentIds[[uint32]$cand.ParentProcessId] = $true }
            $cands = @($cands | Where-Object { -not $candParentIds.ContainsKey([uint32]$_.ProcessId) })
            $legacyLive = $false
            if ($spec.Port -eq 8080) {
                $up8080 = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)
                $up8291 = @(Get-NetTCPConnection -LocalPort 8291 -State Listen -ErrorAction SilentlyContinue)
                if ($up8080.Count -gt 0 -and $up8291.Count -gt 0) { $legacyLive = $true }
            }
            if ($cands.Count -eq 0) { continue }
            if ($cands.Count -lt 2 -and -not $legacyLive) { continue }
            $portOwners = @{}
            try {
                foreach ($nc in @(Get-NetTCPConnection -LocalPort $spec.Port -State Listen -ErrorAction SilentlyContinue)) {
                    $portOwners[[uint32]$nc.OwningProcess] = $true
                }
            } catch {}
            $keepDup = $null
            foreach ($cd in $cands) {
                if ($portOwners.ContainsKey([uint32]$cd.ProcessId)) { $keepDup = $cd; break }
            }
            if (($null -eq $keepDup) -and (-not $legacyLive)) {
                $keepDup = $cands | Sort-Object CreationDate | Select-Object -First 1
            }
            foreach ($cd in $cands) {
                if (($null -ne $keepDup) -and ($cd.ProcessId -eq $keepDup.ProcessId)) { continue }
                try {
                    $kept = 'none'
                    if ($null -ne $keepDup) { $kept = $keepDup.ProcessId }
                    Write-Host "Swept duplicate backend $($spec.Name) token '$($spec.Token)' PID $($cd.ProcessId) - keeping PID $kept on :$($spec.Port)."
                    Invoke-CimMethod -InputObject $cd -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
                } catch {}
            }
        } catch {
            Write-Warning "Backend duplicate sweep failed for $($spec.Name): $($_.Exception.Message)"
        }
    }
}
Stop-WatcherOrphans @("gm", "graphify-rs", "repowise")
Start-Sleep -Milliseconds 500   # let terminated procs release their log files
# APPEND-ONLY LOG POLICY: keep existing logs for forensic history. Only create
# the directory if missing (idempotent). Never delete the logs dir - the old
# Remove-Item -Recurse raced with a sibling launcher holding open grepai log
# handles and crashed both with IOException. Log files are recycled per-watcher
# by Start-WatcherDetached/Stop-WatcherOrphans via FileMode.Create on each launch.
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

# --- LiteLLM proxy (serves the muse models from ###model keys.json) ------------------
# Local OpenAI-compatible Chat-Completions gateway so clients without a native
# Responses-API mode can talk to the opencode.ai zen /responses endpoint. Binds
# to 127.0.0.1:4000. Spawned as a tracked detached child (same PID-scoped
# teardown as every other watcher). The config lives next to this launcher.
# Portable resolution: prefer the uv-tool exe under %APPDATA% (mirrors
# repowiseExe) so Get-Command cannot resolve a stale/old litellm; fall back to
# PATH, then warn-and-skip (no new hard failure).
$litellmExe = $null
foreach ($cand in @(
    (Join-Path $env:APPDATA "uv\tools\litellm\Scripts\litellm.exe"),
    (Join-Path $env:LOCALAPPDATA "uv\tools\litellm\Scripts\litellm.exe")
)) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { $litellmExe = $cand; break }
}
if (-not $litellmExe) {
    $litellmCmd = Get-Command "litellm.exe" -ErrorAction SilentlyContinue
    if ($litellmCmd) { $litellmExe = $litellmCmd.Source }
}
if (-not $litellmExe) { $litellmExe = "" }
# Config: prefer %USERPROFILE%\litellm (current location), then next to the launcher.
$litellmConfig = Join-Path $env:USERPROFILE "litellm\litellm_config.yaml"
if (-not (Test-Path -LiteralPath $litellmConfig)) {
    $litellmAlt = Join-Path $watchersWorkspaceRoot "litellm_config.yaml"
    if (Test-Path -LiteralPath $litellmAlt) { $litellmConfig = $litellmAlt }
}
$litellmLog = Join-Path $logsDir "litellm-proxy.log"
# VAD-u4w (2026-09-13): :4000 is INTENTIONALLY not covered by
# Exit-IfPortHeldByLauncherDaemon -AutoHeal (unlike :50051 / :8420 / :8080).
# Rationale: (1) the proxy runs as python.exe / litellm.exe shim, so a
# name-based AutoHeal kill risks hitting an unrelated python process - the
# same too-broad-match class as the :8765 mail server exclusion below;
# (2) litellm already has a dedicated crash-restart supervisor below with
# exponential backoff (vad-0m6, 10-300s) plus PID reap (vad-olv), so an
# AutoHeal kill at startup would double-heal contend with it. Healing for
# :4000 is owned by that supervisor, not by FIRST-WINS AutoHeal.
# Preflight (vad-yrx): Test-LitellmConfig validates ASCII-only plus
# best-effort YAML before spawn, at launch and on every supervisor relaunch.
if ($litellmExe -and (Test-Path -LiteralPath $litellmConfig)) {
    # VAD-yrx (2026-09-13): fail-fast preflight - non-ASCII api_key aborts litellm before bind.
    if (-not (Test-LitellmConfig -ConfigPath $litellmConfig)) {
        Write-Error "litellm launch aborted: invalid config at $litellmConfig (see error above)."
    } else {
    # VAD-dmx (2026-09-13): unify PYTHONIOENCODING=utf-8 for the initial
    # detached launch. The supervisor relaunch (Start-LitellmProxy below)
    # already sets it; Start-WatcherDetached inherits the launcher env via
    # System.Diagnostics.Process, so set/restore around the spawn.
    $prevLitellmIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = 'utf-8'
    try {
        try { Backup-LitellmStderr -LogPath $litellmLog } catch { }
        $script:litellmProc = Start-WatcherDetached "litellm" "litellm" @("--config", $litellmConfig, "--host", "127.0.0.1", "--port", "4000") $litellmLog -ExePath $litellmExe
    } finally {
        $env:PYTHONIOENCODING = $prevLitellmIoEncoding
    }
    # Readiness probe: poll /v1/models until the proxy answers (or 20s timeout).
    # Keeps the launch deterministic so a client connecting at startup never
    # races a not-yet-bound port. Non-fatal: a slow/failed proxy does not block
    # the rest of the watchers.
    # VAD-7m1y (2026-09-06): the probe no longer blocks the launcher inline. It
    # runs as a background job OVERLAPPED with the remaining startup (grepai
    # supervisor, gm-semantic, memtrace, cerememory, claude/mail MCP jobs) and is
    # joined right before the pane grid opens. Same probe, same 20s deadline, same
    # readiness/failure messages - only the wall-clock ordering changes. The job
    # needs no launcher variables (the probe URL is a literal).
    $litellmProbeScript = {
        $llmReady = $false
        $llmDeadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $llmDeadline) {
            Start-Sleep -Milliseconds 500
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:4000/v1/models" -Method Get -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) { $llmReady = $true; break }
            } catch { }
        }
        return $llmReady
    }
    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        $script:litellmProbeJob = Start-ThreadJob -ScriptBlock $litellmProbeScript
    } else {
        $script:litellmProbeJob = Start-Job -ScriptBlock $litellmProbeScript
    }
    if (-not $script:litellmProbeJob) {
        # Degrade to the original inline probe if job creation failed.
        $llmReady = & $litellmProbeScript
        if ($llmReady) { Write-Host "litellm proxy is up on http://127.0.0.1:4000 (muse models served)." }
        else { Write-Warning "litellm proxy did not become ready within 20s - check $litellmLog." }
    }
    } # end VAD-yrx preflight else
} else {
    if (-not $litellmExe) { Write-Warning "litellm.exe not found - skipping LiteLLM proxy launch." }
    else { Write-Warning "litellm_config.yaml not found at $litellmConfig - skipping LiteLLM proxy launch." }
}
# --- LiteLLM proxy crash-restart supervisor (in-process child job) -----------
# Root cause (2026-08-28): the local LiteLLM proxy on :4000 was launched only as a
# detached child of this launcher (or manually via start_litellm_muse.bat). On launcher
# exit or reboot Windows reaped it with no watchdog, so jcode lost its litellm provider.
# VAD-u4w (2026-09-13): poll interval note - $baseSleepSec is 10s, so the healthy
# path cadence is ~10s per loop plus the :4000 probe cost only. Start-Sleep 1 +
# Start-Sleep 2 run only in the dead branch before a relaunch, so the relaunch path
# cadence is ~14-16s per loop. On consecutive failures Get-LitellmBackoffDelay
# (vad-0m6) stretches the sleep to 10-300s exponential backoff.
# It exits and kills its own spawned child when the launcher lock is released, so it
# never orphans. Mirrors the grepai supervisor (same Start-ThreadJob + Test-LauncherAlive
# pattern); the shared helpers are dot-sourced from Modules\watcher_job_helpers.ps1
# because the thread job runspace inherits nothing (VAD-v14z.5).
# VAD-olv (2026-09-15): the initial detached proxy is launched from THIS scope,
# but the supervisor runspace inherits nothing - not even that PID. Hand it over
# explicitly, or the supervisor starts at PID 0 and its first dead-path relaunch
# cannot tell that the launcher's proxy is still binding :4000, so it stacks a
# second litellm whose loser dies as "port already in use".
$initialLitellmPid = 0
if ($script:litellmProc) {
    try { $initialLitellmPid = [int]$script:litellmProc.Id } catch { $initialLitellmPid = 0 }
}
$supLitellmLog = Join-Path $logsDir "litellm-supervisor.log"
$script:litellmSupJob = $null
if ($litellmExe -and (Test-Path -LiteralPath $litellmConfig)) {
    $litellmSupervisorScript = {
        param($ExePath, $ConfigPath, $LogPath, $SupervisorLog, $LockFile, $InitialProxyPid, $JobHelpersModule)
        $ErrorActionPreference = 'Continue'
        # THREAD-JOB SCOPE RULE: this fresh runspace inherits NO launcher functions
        # and NO script-scope variables, so the shared helpers (Limit-LogSize /
        # Test-LauncherAlive / Test-LitellmConfig / Get-LitellmBackoffDelay /
        # Stop-PriorLitellmProxy / Backup-LitellmStderr) are dot-sourced from Modules\watcher_job_helpers.ps1
        # via the literal path bound in -ArgumentList (VAD-v14z.5 - replaces the
        # copy-pasted bodies).
        . $JobHelpersModule
        function Write-LitellmSupLog {
            param([string]$Msg)
            Limit-LogSize -Path $SupervisorLog
            $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            "[$ts] $Msg" | Out-File -FilePath $SupervisorLog -Append -Encoding UTF8
        }
        function Start-LitellmProxy {
            param($Exe, $Cfg, $Log)
            $err = "$Log.err"
            try { Backup-LitellmStderr -LogPath $Log } catch { }
            $prevIoEncoding = $env:PYTHONIOENCODING
            $env:PYTHONIOENCODING = 'utf-8'
            try {
                Start-Process -FilePath $Exe -ArgumentList @('--config', $Cfg, '--host', '127.0.0.1', '--port', '4000') `
                    -WorkingDirectory (Split-Path $Cfg -Parent) -WindowStyle Hidden `
                    -RedirectStandardOutput $Log -RedirectStandardError $err -PassThru
            } finally {
                $env:PYTHONIOENCODING = $prevIoEncoding
            }
        }
        Write-LitellmSupLog 'litellm crash-restart supervisor started (polls :4000/v1/models)'
        # VAD-olv: adopt the launcher's initial detached proxy as the tracked
        # child, so the first dead-path relaunch knows a prior proxy exists.
        $currentProxyPid = 0
        try { $currentProxyPid = [int]$InitialProxyPid } catch { $currentProxyPid = 0 }
        if ($currentProxyPid -gt 0) { Write-LitellmSupLog "adopted launcher proxy PID $currentProxyPid as the prior litellm child" }
        $consecutiveFailures = 0
        $permanentAlerted = $false
        $permanentThreshold = 10
        $baseSleepSec = 10
        $maxSleepSec = 300
        while ($true) {
            $sleepSec = $baseSleepSec
            try {
                if (-not (Test-LauncherAlive -Path $LockFile)) {
                    Write-LitellmSupLog 'launcher gone (lock file missing or PID dead) - supervisor exiting and killing proxy child'
                    $p = Get-Process -Id $currentProxyPid -ErrorAction SilentlyContinue
                    if ($p) { try { $p.Kill() } catch {} }
                    return
                }
                $alive = $false
                try {
                    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/v1/models' -Method Get -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                    if ($r.StatusCode -eq 200) { $alive = $true }
                } catch { }
                if (-not $alive) {
                    $consecutiveFailures++
                    $sleepSec = Get-LitellmBackoffDelay -ConsecutiveFailures $consecutiveFailures -BaseSeconds $baseSleepSec -MaxSeconds $maxSleepSec
                    $inBreaker = ($consecutiveFailures -ge $permanentThreshold)
                    if ($inBreaker -and -not $permanentAlerted) {
                        $permanentAlerted = $true
                        Write-LitellmSupLog "litellm permanent-failure: $consecutiveFailures consecutive probe failures - backing off to ${maxSleepSec}s, throttling relaunch/log rate"
                        Write-Error "litellm permanent-failure: $consecutiveFailures consecutive :4000 probe failures (config $ConfigPath). Supervisor backing off to ${maxSleepSec}s."
                        try { "permanent-failure $consecutiveFailures $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" | Out-File -FilePath "$SupervisorLog.permanent-failure.marker" -Append -Encoding UTF8 } catch {}
                    }
                    # VAD-yrx (2026-09-13): fail-fast preflight - refuse relaunch on non-ASCII config.
                    if (-not (Test-LitellmConfig -ConfigPath $ConfigPath)) {
                        if (-not $inBreaker) {
                            Write-LitellmSupLog "invalid config at ${ConfigPath} - refusing relaunch (see error above). Retrying in ${sleepSec}s (failure $consecutiveFailures)."
                        } else {
                            Write-LitellmSupLog "litellm still dead (invalid config, failure $consecutiveFailures) - backing off ${sleepSec}s"
                        }
                    } else {
                    if (-not $inBreaker) {
                    Write-LitellmSupLog 'port 4000 dead - relaunching litellm proxy'
                    } else {
                    Write-LitellmSupLog "litellm still dead (failure $consecutiveFailures) - throttled relaunch attempt, next probe in ${sleepSec}s"
                    }
                    # VAD-olv (2026-09-13): ONE shared relaunch path for the normal
                    # and the throttled-breaker branch, so no site can spawn
                    # without the reap-or-reuse plan. The plan also sees the
                    # launcher's initial detached proxy, which this runspace
                    # never owned: a live proxy still binding :4000 must be
                    # reused, never stacked - a duplicate could only die as
                    # "port already in use" and leave the probe reporting dead.
                    $plan = $null
                    try { $plan = Get-LitellmProxyRelaunchPlan -PriorPid $currentProxyPid -Port 4000 } catch { $plan = $null }
                    if (-not $plan) { $plan = [PSCustomObject]@{ Action = 'spawn'; ReapPids = @($currentProxyPid) } }
                    if ($plan.Action -eq 'reuse') {
                    Write-LitellmSupLog "litellm :4000 owned by a live proxy inside its startup window - reusing it, no respawn (failure $consecutiveFailures)"
                    } else {
                    foreach ($reapPid in @($plan.ReapPids)) {
                    try { if (Stop-PriorLitellmProxy -PriorPid $reapPid) { Write-LitellmSupLog "reaped prior litellm proxy PID $reapPid before relaunch" } } catch { }
                    }
                    # Never spawn into a held port: a reap that failed to free
                    # :4000 must defer, or the new proxy dies on the bind.
                    $portHeld = $false
                    try { $portHeld = (@(Get-NetTCPConnection -LocalPort 4000 -State Listen -ErrorAction SilentlyContinue).Count -gt 0) } catch { $portHeld = $false }
                    if ($portHeld) {
                    Write-LitellmSupLog "litellm :4000 still held after reap - deferring respawn (failure $consecutiveFailures)"
                    } else {
                    $np = Start-LitellmProxy -Exe $ExePath -Cfg $ConfigPath -Log $LogPath
                    if ($np) { $currentProxyPid = $np.Id; Write-LitellmSupLog "relaunched litellm proxy (PID $($np.Id))" }
                    else { Write-LitellmSupLog 'litellm relaunch returned no process - will re-probe' }
                    Start-Sleep 2
                    }
                    }
                    }
                } else {
                    if (($consecutiveFailures -ne 0) -or $permanentAlerted) {
                        Write-LitellmSupLog "port 4000 alive - resetting failure counter after $consecutiveFailures consecutive failures"
                    }
                    $consecutiveFailures = 0
                    $permanentAlerted = $false
                    try { if (Test-Path -LiteralPath "$SupervisorLog.permanent-failure.marker") { Remove-Item -LiteralPath "$SupervisorLog.permanent-failure.marker" -Force -ErrorAction SilentlyContinue } } catch {}
                    $sleepSec = $baseSleepSec
                }
                Start-Sleep $sleepSec
            } catch {
                Write-LitellmSupLog "SUPERVISOR ERROR: $($_.Exception.Message) - continuing"
                Start-Sleep $sleepSec
            }
        }
    }
    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        $script:litellmSupJob = Start-ThreadJob -ScriptBlock $litellmSupervisorScript `
            -ArgumentList $litellmExe, $litellmConfig, $litellmLog, $supLitellmLog, $lockFile, $initialLitellmPid, $jobHelpersModule
        Write-Host "litellm crash-restart supervisor spawned (job $($script:litellmSupJob.Id)) - log: $supLitellmLog"
    } else {
        $script:litellmSupJob = Start-Job -ScriptBlock $litellmSupervisorScript `
            -ArgumentList $litellmExe, $litellmConfig, $litellmLog, $supLitellmLog, $lockFile, $initialLitellmPid, $jobHelpersModule
        Write-Host "litellm crash-restart supervisor spawned (Start-Job fallback, job $($script:litellmSupJob.Id)) - log: $supLitellmLog"
    }
}
function Write-LlmProxyRestartLog {
    param([string]$Reason)
    $restartLog = Join-Path $logsDir "llm_fallback_proxy_restarts.log"
    try { New-Item -ItemType Directory -Path (Split-Path $restartLog) -Force | Out-Null } catch {}
    Limit-LogSize -Path $restartLog   # VAD-hne6: cap unbounded restart-log growth
    $ts = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    "$ts proxy restart: $Reason" | Out-File -Append -Encoding utf8 -FilePath $restartLog
}
function Ensure-LlmProxyRunning {
    param([int]$Port = 11436, [int]$TimeoutSec = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -Method Get -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return $true }
        } catch {}
        # VAD-ltnq (2026-09-06): raw TcpClient probe instead of Test-NetConnection
        # (slow + warning noise; unified with the TcpClient probes used
        # elsewhere in this script).
        try {
            $sock = $null
            try {
                $sock = New-Object System.Net.Sockets.TcpClient
                $iar = $sock.BeginConnect("127.0.0.1", $Port, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) { $sock.EndConnect($iar); return $true }
            } finally { if ($sock) { try { $sock.Close() } catch {} } }
        } catch {}
        # PS 5.1 fix (2026-08-27): Get-Process objects have NO CommandLine
        # property on Windows PowerShell 5.1 (pwsh-7 addition), so the old
        # filter matched nothing and the guard was dead on 5.1 - spawning a
        # redundant python every 500ms. Use the same CIM probe as every other
        # liveness check in this script.
        $proxyProc = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'llm_fallback_proxy' })
        if ($proxyProc.Count -eq 0) {
            $pyExe = $null
            if (Get-Command python -ErrorAction SilentlyContinue) { $pyExe = (Get-Command python).Source }
            elseif (Test-Path "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\python.exe") { $pyExe = "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\python.exe" }
            if ($pyExe) {
                $logPath = Join-Path $logsDir "llm_fallback_proxy.log"
                try { New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null } catch {}
                Start-Process -FilePath $pyExe -ArgumentList (Join-Path $scriptDir "###2.llm_fallback_proxy.py") -WindowStyle Hidden -RedirectStandardError $logPath | Out-Null
                Write-LlmProxyRestartLog "process missing on :$Port"
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Fallback proxy did not become ready on :$Port within ${TimeoutSec}s"
}
# Load env/.env FIRST so real values (incl. LLM_PROXY_PORT, which the
# semantic build requires) win over the defaults applied below. Import-EnvFile fills only keys that are
# NOT already set in the process env, so this MUST run before the defaults
# block (defaults set the same keys and would shadow the .env values).
function Import-EnvFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith("#")) { continue }
        if ($s -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $k = $Matches[1]; $v = $Matches[2].Trim().Trim('"').Trim("'")
            if (-not (Test-Path "env:$k")) { Set-Item -Path "env:$k" -Value $v }
        }
    }
}
Import-EnvFile (Join-Path $watchersWorkspaceRoot ".env")

# -- fallback proxy: ensure 11436 is up before gm semantic build (and repowise) --
# PS 5.1 fix (2026-08-27): `??` is a PS 7-only operator and a hard parse error
# on Windows PowerShell 5.1 (the runtime the .bat wrapper falls back to), which
# aborts the whole launcher before it runs. The port default is an explicit
# if/else instead (.env has been imported above, so any LLM_PROXY_PORT override
# already won; the defaults block below only fills still-unset keys).
$script:llmProxyPort = if ($env:LLM_PROXY_PORT) { [int]$env:LLM_PROXY_PORT } else { 11436 }
try { Ensure-LlmProxyRunning -Port $script:llmProxyPort -TimeoutSec 15 } catch {
    Write-Warning "fallback proxy not ready - gm semantic build and repowise will be degraded until :$($script:llmProxyPort) is up."
}

# NO `gm watch` here, on purpose. gm 0.19.3's incremental path is DESTRUCTIVE:
# `gm watch` (and `gm run . --update`) re-extract ONLY the changed files and then
# overwrite graph.json with just those nodes, so the persisted graph collapses
# from thousands of nodes to a handful. Reproduced live 2026-09-16: touching one
# file turned the 7.3 MB / 5423-node graph into 15 KB / 15 nodes, which is what
# made the MCP handshake report real staleness while a watcher was running.
# A FULL `gm run .` (no --update) is the only non-destructive mode in 0.19.3, so
# the live rebuild daemon (Invoke-GmSemanticBuild below) owns graph freshness.
# Server-side freshness is separate: `gm serve --watch` hot-reloads graph.json.
# ponytail: restore a debounced `gm watch` once upstream merges incremental
# results instead of replacing the file - it is far cheaper than a full rebuild.
$script:gmProc = $null

# --- Graphenium LIVE REBUILD (full, file-change driven) -------------------
# Keeps graph.json whole and current. It must be a FULL `gm run` because gm
# 0.19.3's incremental writers (`gm watch`, `gm run . --update`) replace the
# graph with only the changed files' nodes - see the "NO `gm watch`" block
# above. The blocking startup build stays removed: the graph is rebuilt on the
# first live file change (debounced) rather than making every other watcher
# wait on launch.
# CLOUD LLM CONFIGURATION (Nous Research, direct) - mirrored from deleted ###5.
if (-not $env:NOUS_BASE_URL)   { $env:NOUS_BASE_URL = "https://inference-api.nousresearch.com/v1" }
if (-not $env:NOUS_MODEL)      { $env:NOUS_MODEL = "tencent/hy3:free" }
if (-not $env:NOUS_TAGS)       { $env:NOUS_TAGS = "product=hermes-agent,client=hermes-client-v0.13.0,user=win_user:$env:USERNAME@$env:COMPUTERNAME" }
if (-not $env:NOUS_MAX_RETRIES){ $env:NOUS_MAX_RETRIES = "8" }
if (-not $env:LLM_PROXY_PORT)  { $env:LLM_PROXY_PORT = "11436" }
if (-not $env:LITELM_BASE_URL) { $env:LITELM_BASE_URL = "http://127.0.0.1:4000" }
if (-not $env:LLM_PROXY_MODEL) { $env:LLM_PROXY_MODEL = "nous-proxy" }
# (.env was already imported ABOVE the defaults block, so real values won.)
# LOG: the rebuild writes straight into gm.log. The old dedicated
# "gm-semantic-build-run.log" existed only because `gm watch` held gm.log open
# forever through its raw-byte pump; that watcher is gone (see the "NO `gm
# watch`" block above), so this is now the only writer. Routing the output here
# means the graphenium pane (which tails gm.log) shows the rebuild that keeps
# the graph fresh. Each build truncates-writes the log, which the pane's
# byte-offset tailer already handles via its Rotated flag.
$gmRunLog = $gmLog

# Shared state object for the live semantic build loop. The SAME object is
# passed to the thread-job (below) so the FSW events and the loop share it. PopupShown gates the "semantic build unavailable" popup
# to exactly one per session.
$global:gmSemState = @{
    Live       = $true
    Changed    = $false
    LastBuild  = [datetime]::UtcNow
    PopupShown = $false
    # VAD-zfb6 (2026-09-06): FSW event actions only ENQUEUE the raw path here
    # (O(1), no per-event canonicalization) and the thread-job drains it each
    # iteration. The old per-event Action did GetFullPath + segment splitting on
    # EVERY event on an unbounded PowerShell event queue - a churn burst (git
    # checkout, npm install) queued faster than the runspaces drained it.
    Queue      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
}


# LIVE REBUILD trigger: a FileSystemWatcher over the repo feeds changed
# paths into a debounced queue; a background loop runs a FULL `gm run` after a
# quiet period so a burst of edits coalesces into a single build. (It cannot be
# incremental: `gm run . --update` replaces graph.json with only the changed
# files' nodes - see the "NO `gm watch`" block above.)
# Runs IN THIS launcher process (not a child), so teardown needs no extra
# PID tracking. VAD-lnhe (2026-09-06): the dead $global:gmSemanticLive/Changed/
# LastBuild vars and $gmSemDebounceSec/$gmSemMaxStaleSec that lived here were
# deleted - the real loop reads the SHARED $global:gmSemState object and keeps
# its debounce/stale constants inside the thread-job scriptblock. The old
# launcher-side Add-GmSemanticChange function was deleted too: the FSW actions
# only enqueue raw paths now (VAD-zfb6) and the filter lives INLINE in the
# thread job (thread-job scope rule), mirroring the pane's Add-RecentChange
# exclusion list.
try {
    # mcpw-9lf: arm nothing on an empty root. FileSystemWatcher throws on an
    # empty Path, and the same empty value handed to a native command is
    # dropped by Windows PowerShell 5.1, which turns a guard into a bug.
    if ([string]::IsNullOrWhiteSpace($watchersWorkspaceRoot)) { throw "watchersWorkspaceRoot is empty" }
    $script:gmFsw = New-Object System.IO.FileSystemWatcher
    # mcpw-ybs.7: watch the REPOSITORY the operator launched from, not the folder
    # holding this script. Otherwise edits in repo B never trigger a rebuild and
    # edits in repo A trigger one for the wrong workspace.
    $script:gmFsw.Path = $watchersWorkspaceRoot
    $script:gmFsw.IncludeSubdirectories = $true
    $script:gmFsw.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
    $script:gmFsw.Filter = '*'
    # VAD-zfb6: the default ~4 KB InternalBufferSize overflows on churn bursts;
    # InternalBufferOverflowException is swallowed and events (the user's actual
    # edit) are silently dropped. 64 KB rides out a git checkout / npm install.
    $script:gmFsw.InternalBufferSize = 65536
    $null = Register-ObjectEvent -InputObject $gmFsw -EventName Changed -SourceIdentifier 'gm-sem-changed' -Action { $global:gmSemState.Queue.Enqueue($Event.SourceEventArgs.FullPath) }
    $null = Register-ObjectEvent -InputObject $gmFsw -EventName Created -SourceIdentifier 'gm-sem-created' -Action { $global:gmSemState.Queue.Enqueue($Event.SourceEventArgs.FullPath) }
    $null = Register-ObjectEvent -InputObject $gmFsw -EventName Renamed -SourceIdentifier 'gm-sem-renamed' -Action { $global:gmSemState.Queue.Enqueue($Event.SourceEventArgs.FullPath) }
    $gmFsw.EnableRaisingEvents = $true
    Write-Host "Graphenium live rebuild armed (full non-destructive gm run on file change)."
} catch {
    Write-Warning "[gm-semantic] could not arm file watcher: $($_.Exception.Message). Semantic graph will refresh only on next launcher start."
}
# Drive the incremental build from a background thread-job so it never blocks
# the controller loop. CRITICAL thread-job scope rules (verified 2026-08-27):
#   - a thread job has its OWN $global: scope, so a plain global flag (e.g. the
#     deleted $global:gmSemanticLive) would read as empty and never run a
#     single iteration;
#   - it also inherits NO script functions, so Invoke-GmSemanticBuild is
#     invisible inside the job.
# Fix: pass the shared flag state in via -ArgumentList.
# A hashtable passed by argument is the SAME object (verified: the job's write
# is visible in the parent), so the FSW event actions (main runspace) and the
# job (its own runspace) share one state object.
# VAD-3apv (2026-09-06, live-verified): a function/scriptblock passed as an
# ARGUMENT is bound to the PARENT session state - invoking it from the job
# runspace breaks command resolution ("Add-Content is not recognized", verified
# with a minimal thread job). Pass the function SOURCE TEXT instead and rebuild
# the functions INSIDE the job runspace, where command resolution is normal.
# NOTE: the state object MUST be $global:gmSemState (not a local) so the FSW
# event actions (separate runspace, main-scope $global:) and Stop-GmSemanticLive
# can write to the SAME object the thread-job holds via -ArgumentList.
# VAD-3apv: param() MUST be the FIRST statement of the scriptblock. The old
# version ran warm-up statements BEFORE param(), so PowerShell threw "The term
# 'param' is not recognized" on invocation and the job died on arrival - and
# its output was discarded (no Receive-Job), so the live incremental build
# never run. The startup FULL warm-up was removed (it made every
# launcher_gm_semantic_build.tests.ps1 guard forbids it): the first live file
# change drives the first incremental build (gm's mtime manifest self-warms).
# $State.Failed surfaces repeated build exceptions instead of discarding them.
# VAD-k9fix (2026-09-07): define the scriptblock once and reuse it for both
# Start-ThreadJob and Start-Job (fallback when ThreadJob module unavailable).
$gmSemScriptBlock = {
    param($State, $BuildSrc, $ProbeSrc, $BuildDir, $RunLog)
    Set-Item -Path function:Test-LlmProxyReady     -Value ([scriptblock]::Create($ProbeSrc))
    Set-Item -Path function:Invoke-GmSemanticBuild -Value ([scriptblock]::Create($BuildSrc))
    $debounceSec  = 10          # wait this long after the last edit before building
    $maxStaleSec  = 600         # safety: rebuild at least every 10 min even if idle
    $consecFails  = 0
    while ($State.Live) {
        Start-Sleep -Seconds 2
        # VAD-zfb6: drain the FSW event queue here (the poll loop owns the
        # filtering cost now); the event actions only enqueued raw paths. The
        # filter is INLINED (thread-job scope rule) and mirrors the pane's
        # Add-RecentChange exclusions: dot-dirs and tool-state/scratch churn
        # never trigger a semantic rebuild.
        $drainedPath = $null
        $sawChange = $false
        while ($State.Queue.TryDequeue([ref]$drainedPath)) {
            try {
                $p = [System.IO.Path]::GetFullPath($drainedPath)
                if ($p -match '^[a-z]:') { $p = [char]::ToUpper($p[0]) + $p.Substring(1) }
                $skip = $false
                foreach ($seg in ($p -split '[\\/]')) {
                    if ($seg -like '.?*') { $skip = $true; break }
                    if (@('temp','panes','graphenium-out','graphify-out','!!!AUTO_SCRIPTS!!!','node_modules','target','dist','build') -ccontains $seg) { $skip = $true; break }
                }
                if (-not $skip) { $sawChange = $true }
            } catch { }
        }
        if ($sawChange) { $State.Changed = $true }
        $now = [datetime]::UtcNow
        $quiet = ($now - $State.LastBuild).TotalSeconds
        $stale = ($now - $State.LastBuild).TotalSeconds -ge $maxStaleSec
        if (($State.Changed -and $quiet -ge $debounceSec) -or $stale) {
            $State.Changed = $false
            $State.LastBuild = [datetime]::UtcNow
            try {
                # NOTE: paths ride in as plain string arguments - $using: inside
                # a [scriptblock]::Create'd scriptblock is fragile, and string
                # arguments cross the runspace hop safely.
                # VAD-ygdo.8: forward the shared $State so the once-per-session
                # PopupShown gate sees the same object; default $global:gmSemState
                # is $null in the thread-job runspace and the popup was dead.
                Invoke-GmSemanticBuild -BuildDir $BuildDir -RunLog $RunLog -BuildKey 0 -State $State
                $consecFails = 0
            } catch {
                $consecFails++
                Write-Warning ("[gm-semantic] incremental build raised: " + $_.Exception.Message)
                if ($consecFails -ge 3) { $State.Failed = $true; $consecFails = 0 }
            }
        }
    }
}
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $gmSemJob = Start-ThreadJob -ArgumentList $global:gmSemState, (${function:Invoke-GmSemanticBuild}.ToString()), (${function:Test-LlmProxyReady}.ToString()), $watchersWorkspaceRoot, $gmRunLog -ScriptBlock $gmSemScriptBlock -ErrorAction SilentlyContinue
} else {
    $gmSemJob = Start-Job -ArgumentList $global:gmSemState, (${function:Invoke-GmSemanticBuild}.ToString()), (${function:Test-LlmProxyReady}.ToString()), $watchersWorkspaceRoot, $gmRunLog -ScriptBlock $gmSemScriptBlock -ErrorAction SilentlyContinue
}
if (-not $gmSemJob) { Write-Warning "[gm-semantic] could not start incremental loop (Start-ThreadJob unavailable). Semantic graph will refresh only on next launcher start." }
elseif ($gmSemJob.State -eq 'Failed') { Write-Warning ("[gm-semantic] incremental loop job failed at start: " + (($gmSemJob | Receive-Job -Keep -ErrorAction SilentlyContinue) | Out-String)) }

# graphify-rs: external ignore-aware watcher (replaces graphify-rs's own `watch`, which fired
# rebuilds on ignored paths like graphenium-out). The wrapper's CommandLine carries -WatchMode so
# the existing Stop-WatcherOrphans / dedup `CommandLine -match 'watch'` teardown still kills it.

$graphifyWrapper = Join-Path $scriptDir "dev_tools\graphify-watch-wrapper.ps1"
if (Test-Path -LiteralPath $graphifyWrapper) {
    Write-Host "Starting graphify-rs ignore-aware watcher (detached, logging to $graphifyLog)..."
    $wp = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-File", "`"$graphifyWrapper`"", "-WatchMode", "-Repo", "`"$watchersWorkspaceRoot`"") `
        -WorkingDirectory $watchersWorkspaceRoot -WindowStyle Hidden `
        -RedirectStandardOutput $graphifyLog -RedirectStandardError "$graphifyLog.err" -PassThru
    if ($wp) { $script:childProcs += $wp; $global:WatcherChildren += $wp.Id }
    $script:graphifyProc = $wp
    Write-Host "graphify-rs ignore-aware watcher launched (detached, log only)."
} else {
    Write-Warning "graphify-watch-wrapper.ps1 not found; falling back to graphify-rs watch."
    $script:graphifyProc = Start-WatcherDetached "graphify-rs" "graphify-rs" @("watch", "--path", ".") $graphifyLog
}
# -- repowise: ensure fallback proxy is up so litellm.base_url 11436 is reachable --
# (LLM_PROXY_PORT is guaranteed set here by the defaults block above; PS 5.1-safe.)
try { Ensure-LlmProxyRunning -Port ([int]$env:LLM_PROXY_PORT) -TimeoutSec 15 } catch {
    Write-Warning "repowise: fallback proxy not ready - repowise watch will start but LLM pages will be degraded until :$env:LLM_PROXY_PORT is up."
}
# Export the same base_url env some repowise builds read (harmless if ignored, required if config is missing).
$env:REPOWISE_LITELLM_BASE_URL = "http://127.0.0.1:$env:LLM_PROXY_PORT/v1"
$script:repowiseProc = Start-WatcherDetached "repowise" "repowise" @("watch", ".", "--index-only", "--debounce", "30000") $repowiseLog -ExePath $repowiseExe
# -- codegraph: opt-in freshness watcher (headless, no 5th pane; 2x2 grid intact) --
# `codegraph build` (see Test-CodegraphReady) is the only prerequisite for
# queries; `codegraph watch` just debounces file changes into incremental
# `update` so the graph does not go stale during long sessions. Without it
# queries still work from the last build/update. Memtrace precedent: headless
# child, log under $logsDir, PID tracked for teardown, no WT pane.
$codegraphLog = Join-Path $logsDir 'codegraph.log'
$script:codegraphProc = $null
$cgLaunch = Resolve-CodegraphLaunch
if (-not $cgLaunch) {
    Write-Host "codegraph not resolvable (no codegraph.exe and no parseable shim). Queries still work from the last build."
} elseif (Test-CodegraphReady) {
    # Watch the ABSOLUTE workspace root, not ".": the command line then carries
    # the root, so the attribution gate in Stop-PriorLauncherInstances can
    # prove a stale codegraph node belongs to THIS workspace before killing it.
    # Do NOT pass --db: older builds lack watch --db/-d (#984/#987); the
    # WorkingDirectory + absolute root make the default graph.db resolve.
    $cgArgs = @($cgLaunch.Prefix) + @('watch', $watchersWorkspaceRoot)
    # "node" when re-expressed from the shim, "codegraph" for a native install.
    $cgExeName = if ($cgLaunch.Prefix.Count -gt 0) { 'node' } else { 'codegraph' }
    # -SkipStaleKill: Start-WatcherDetached's dedup kills every <ExeName>.exe
    # whose command line contains "watch". With ExeName="node" that would hit
    # unrelated dev servers; the workspace-attributed startup sweep covers it.
    $script:codegraphProc = Start-WatcherDetached $cgExeName "codegraph" $cgArgs $codegraphLog -ExePath $cgLaunch.Exe -WorkingDirectory $watchersWorkspaceRoot -SkipStaleKill
    if (-not $script:codegraphProc) { Write-Warning "codegraph watch did not start. Queries still work; run 'codegraph build' manually for fresh data." }
} else {
    Write-Host "codegraph watch skipped (see warning above). Queries still work from the last build."
}
# -- repowise embeddings: `repowise watch` is index-only (no vectors) --
# Chain a low-frequency `repowise reindex --embedder ollama` loop so the
# LanceDB vector store stays fresh with zero manual runs. Ollama is local
# and keyless (endpoint via $env:OLLAMA_HOST). Tune with
# $env:REPOWISE_REINDEX_MINUTES (default 10).
$repowiseReindexScript = {
    param($Exe, $Root, $Log, $Minutes)
    $mins = 10
    try { if ($Minutes -and ([int]$Minutes) -gt 0) { $mins = [int]$Minutes } } catch {}
    while ($true) {
        Start-Sleep -Seconds ($mins * 60)
        try {
            $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            # vad-3ka.7: pause while repowise's ollama endpoint (default
            # 127.0.0.1:11434) is unreachable - each run otherwise spends ~40min
            # failing 852/852 then Aborts. Skipped runs auto-resume when it answers.
            $ollamaUp = $false
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/" -Method Get -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                $ollamaUp = ($r.StatusCode -eq 200)
            } catch { $ollamaUp = $false }
            if (-not $ollamaUp) {
                "[$stamp] repowise reindex --embedder ollama SKIPPED (ollama 127.0.0.1:11434 unreachable)" | Out-File -LiteralPath $Log -Append -Encoding utf8
                continue
            }
            "[$stamp] repowise reindex --embedder ollama" | Out-File -LiteralPath $Log -Append -Encoding utf8
            $out = & $Exe reindex $Root --embedder ollama 2>&1 | Out-String
            $out | Out-File -LiteralPath $Log -Append -Encoding utf8
        } catch {
            "reindex failed: $($_.Exception.Message)" | Out-File -LiteralPath $Log -Append -Encoding utf8
        }
    }
}
$repowiseReindexLog = Join-Path $logsDir "repowise-reindex.log"
if ($repowiseExe -and (Test-Path -LiteralPath $repowiseExe)) {
    try {
        $script:repowiseReindexJob = Start-Job -Name "repowise-reindex" -ScriptBlock $repowiseReindexScript -ArgumentList @($repowiseExe, ".", $repowiseReindexLog, $env:REPOWISE_REINDEX_MINUTES)
        Write-Host "repowise embedding reindex loop started (ollama, log: $repowiseReindexLog)."
    } catch {
        Write-Warning "repowise: failed to start embedding reindex loop: $($_.Exception.Message)"
    }
} else {
    Write-Warning "repowise: exe not found, skipping embedding reindex loop."
}
# --- Memtrace knowledge-graph index (runs from the REPO ROOT) ----------------
# `memtrace start` has NO --path flag: it indexes whatever directory it is
# launched from (its CWD). We launch it from the repo root so it indexes the
# WHOLE VAD repo into root .memdb. It dedups against an already-healthy
# root/.memdb daemon (e.g. one the gateway already started) so we never
# launch a second conflicting instance on the same data dir.
# (No 5th pane - the 2x2 grid is left intact; startup is logged under
# root/.memdb/.)
# The index logic was ported here from the now-deleted
# Modules/### start memtrace.ps1 so the launcher owns the index directly
# (no separate detached script to launch). It runs in a BACKGROUND job
# (non-blocking) so the 2x2 pane grid opens immediately, matching the old
# detached-script behaviour.
# Resolve the repo's git top-level so the Memtrace state file lives at the
# repo root even if this launcher script is in a subfolder. Fall back to the
# script's own directory when not inside a git work tree.
# mcpw-9lf: the -C operand is checked first. Windows PowerShell 5.1 drops an
# empty operand instead of passing it, so git would otherwise receive
# `git -C rev-parse --show-toplevel` and abort the block under
# $ErrorActionPreference = Stop.
$script:memtraceGitRoot = $null
if (-not ([string]::IsNullOrWhiteSpace($watchersWorkspaceRoot))) {
    $script:memtraceGitRoot = git -C "$watchersWorkspaceRoot" rev-parse --show-toplevel 2>$null
}
if (-not $script:memtraceGitRoot) { $script:memtraceGitRoot = $watchersWorkspaceRoot }
$script:memtraceStateFile = Join-Path $script:memtraceGitRoot ".memdb\daemon-state.json"
$memtraceJobScript = {
    param($ScriptDir)
    # Resolve the repo's git top-level so the daemon's CWD/workspace is the
    # repo root even if this launcher script is placed in a subfolder. Fall
    # back to the script's own directory when not inside a git work tree.
    # mcpw-9lf: same guard as the launcher-side copy. This scriptblock runs in
    # a fresh runspace, so it cannot call a shared helper - the check is inline.
    $gitRoot = $null
    if (-not ([string]::IsNullOrWhiteSpace($ScriptDir))) {
        $gitRoot = git -C "$ScriptDir" rev-parse --show-toplevel 2>$null
    }
    $repoDir  = if ($gitRoot) { $gitRoot } else { $ScriptDir }
    $memdbDir = Join-Path $repoDir ".memdb"
    try { New-Item -ItemType Directory -Path $memdbDir -Force | Out-Null } catch {}
    $launchLog  = Join-Path $memdbDir "memtrace-launch.log"
    $launchErr  = Join-Path $memdbDir "memtrace-launch.log.err"
    $stateFile  = Join-Path $memdbDir "daemon-state.json"

    # Resolve the memtrace command (npm shim: memtrace.cmd/.ps1, not a bare
    # .exe on PATH). Prefer a real .exe, fall back to the shim.
    #
    # PATHEXT HARDENING (2026-09-18): Get-Command resolves a bare name by
    # searching $env:PATHEXT. When PATHEXT arrives here degraded to just ".CPL"
    # (seen on this box), Get-Command finds NOTHING, the shim itself fails with
    #  '"node"' is not recognized , `memtrace start` dies in ~1s, ports
    # :50051/:3030 never bind, and this supervisor's 30s auto-heal retry leaks an
    # orphaned pwsh.exe every cycle. Pin the launcher to ABSOLUTE paths instead:
    # absolute paths are resolved by the OS loader and never consult PATHEXT.
    $script:memtraceNode = $null
    $script:memtraceJs   = $null
    foreach ($nodeCand in @(
        "C:\nvm4w\nodejs\node.exe",
        "$env:ProgramFiles\nodejs\node.exe",
        "C:\Program Files\nodejs\node.exe"
    )) {
        if ($nodeCand -and (Test-Path -LiteralPath $nodeCand)) { $script:memtraceNode = $nodeCand; break }
    }
    foreach ($jsCand in @(
        "J:\Programs\npm-global\node_modules\memtrace\bin\memtrace.js",
        "$env:APPDATA\npm\node_modules\memtrace\bin\memtrace.js"
    )) {
        if ($jsCand -and (Test-Path -LiteralPath $jsCand)) { $script:memtraceJs = $jsCand; break }
    }

    $memtraceExe   = $null
    $memtraceIsExe = $false
    if ($script:memtraceNode -and $script:memtraceJs) {
        # Absolute node + absolute CLI entrypoint: immune to PATHEXT and to PATH.
        $memtraceExe   = $script:memtraceNode
        $memtraceIsExe = $true
        $script:memtraceArgPrefix = @($script:memtraceJs)
    } else {
        $memtraceCmd = Get-Command "memtrace.exe" -ErrorAction SilentlyContinue
        if (-not $memtraceCmd) { $memtraceCmd = Get-Command "memtrace.cmd" -ErrorAction SilentlyContinue }
        if (-not $memtraceCmd) { $memtraceCmd = Get-Command "memtrace"     -ErrorAction SilentlyContinue }
        if (-not $memtraceCmd) {
            Write-Warning "memtrace command not found on PATH (looked for memtrace.exe / memtrace.cmd / memtrace, and no absolute node+memtrace.js pair exists). Skipping Memtrace index (repo root)."
            return
        }
        $memtraceExe   = $memtraceCmd.Source
        $memtraceIsExe = ($memtraceExe -match '\.exe$')
        $script:memtraceArgPrefix = @()
    }

    # Self-healing dedup: reuse an already-healthy root .memdb daemon.
    # NOTE: daemon-state.json can report status='healthy' while the port is
    # actually dead (zombie/orphaned PID). So we also require the loopback port
    # to be genuinely LISTENing before trusting the state file - otherwise a
    # stale 'healthy' marker would make us skip launching while a second,
    # separate invocation (e.g. the gateway) starts a conflicting daemon.
    $script:memtracePort = 50051
    function Test-MemtracePortListening {
        param([int]$Port)
        try {
            $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
            return ($null -ne $conn)
        } catch { return $false }
    }
    $alreadyRunning = $false
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $st = Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($st.status -eq 'healthy' -and $st.pid) {
                $live = Get-Process -Id $st.pid -ErrorAction SilentlyContinue
                if ($live -and (Test-MemtracePortListening $script:memtracePort)) {
                    $alreadyRunning = $true
                }
            }
        } catch {}
    }
    if ($alreadyRunning) {
        Write-Host "Memtrace daemon already healthy for root .memdb - reusing it (no second instance started)."
        return
    }

    # Belt-and-suspenders: even if daemon-state.json is missing/corrupt, never
    # start a second instance if the loopback port is ALREADY listening. This
    # guards against a daemon that came up via another path (e.g. the gateway)
    # without leaving a usable state file behind.
    if (Test-MemtracePortListening $script:memtracePort) {
        Write-Host "Memtrace daemon already listening on port $($script:memtracePort) - reusing it (no second instance started)."
        return
    }

    # OFFLINE env so the child boot does NOT stall on the online license-
    # heartbeat check. Set in THIS (job) scope so the child inherits them.
    $env:MEMTRACE_OFFLINE      = "1"
    $env:MEMTRACE_NO_HEARTBEAT = "1"
    $env:MEMTRACE_TELEMETRY    = "off"

    # Start the daemon with NO console window for the WHOLE process tree.
    # `Start-Process -WindowStyle Hidden` only hides the PARENT (memtrace).
    # `memtrace start` then spawns memcortex-daemon.exe, which can open its OWN
    # visible console window (e.g. if it requests CREATE_NEW_CONSOLE). We launch
    # via the Win32 CreateProcess API so we can set DETACHED_PROCESS +
    # CREATE_NO_WINDOW + STARTF_USESHOWWINDOW/SW_HIDE: the parent is detached
    # AND any console the child/grandchild allocates is born hidden. A watchdog
    # (Hide-MemtraceWindows) additionally force-hides any window that still
    # appears during startup. cmd's `>`/`2>` redirect output to files so
    # PowerShell need not pump the streams manually.
    if (-not ('Win32.MemtraceLaunch' -as [type])) {
        Add-Type -MemberDefinition @'
            [StructLayout(LayoutKind.Sequential)]
            public struct STARTUPINFO {
                public Int32 cb; public IntPtr lpReserved; public IntPtr lpDesktop;
                public IntPtr lpTitle; public Int32 dwX; public Int32 dwY;
                public Int32 dwXSize; public Int32 dwYSize; public Int32 dwXCountChars;
                public Int32 dwYCountChars; public Int32 dwFillAttribute; public Int32 dwFlags;
                public Int16 wShowWindow; public Int16 cbReserved2;
                public IntPtr lpReserved2; public IntPtr hStdInput;
                public IntPtr hStdOutput; public IntPtr hStdError;
            }
            [StructLayout(LayoutKind.Sequential)]
            public struct PROCESS_INFORMATION {
                public IntPtr hProcess; public IntPtr hThread;
                public Int32 dwProcessId; public Int32 dwThreadId;
            }
            [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
            public static extern bool CreateProcess(
                string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes,
                IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
                IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo,
                out PROCESS_INFORMATION lpProcessInformation);
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool CloseHandle(IntPtr hObject);
'@ -Name 'MemtraceLaunch' -Namespace 'Win32'
    }

    function Start-MemtraceHidden {
        param($Exe, $WorkDir, $OutLog, $ErrLog, $ArgPrefix = @())
        $DETACHED_PROCESS     = 0x00000008
        $CREATE_NO_WINDOW     = 0x08000000
        $STARTF_USESHOWWINDOW = 0x00000001

        $si = New-Object Win32.MemtraceLaunch+STARTUPINFO
        $si.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
        $si.dwFlags = $STARTF_USESHOWWINDOW
        $si.wShowWindow = 0   # SW_HIDE
        $pi = New-Object Win32.MemtraceLaunch+PROCESS_INFORMATION

        # PATHEXT HARDENING (2026-09-18): `cmd /c "<bare name>"` cannot resolve
        # anything when PATHEXT is degraded to ".CPL", which is how the shim died
        # with '"node"' is not recognized. $ArgPrefix carries the absolute
        # memtrace.js path when we launch absolute node.exe directly; building the
        # command line from explicit quoted absolute paths keeps this working
        # whether PATHEXT is sane or broken.
        $parts = @()
        foreach ($a in $ArgPrefix) { $parts += "`"$a`"" }
        $parts += 'start', '--headless'
        $argLine = $parts -join ' '

        $comspec = $env:ComSpec
        $ok = [Win32.MemtraceLaunch]::CreateProcess(
            $comspec,
            "`"$comspec`" /c `"$Exe`" $argLine > `"$OutLog`" 2> `"$ErrLog`"",
            [IntPtr]::Zero, [IntPtr]::Zero, $false,
            ($DETACHED_PROCESS -bor $CREATE_NO_WINDOW),
            [IntPtr]::Zero, $WorkDir, [ref]$si, [ref]$pi)
        if (-not $ok) { throw (New-Object System.ComponentModel.Win32Exception) }

        [void][Win32.MemtraceLaunch]::CloseHandle($pi.hProcess)
        [void][Win32.MemtraceLaunch]::CloseHandle($pi.hThread)
        return [System.Diagnostics.Process]::GetProcessById($pi.dwProcessId)
    }

    # Force-hide any visible window owned by the daemon's process tree (root +
    # descendants). This is the backstop for a child that allocates its own
    # console via CREATE_NEW_CONSOLE despite the detached, windowless launch.
    function Hide-MemtraceWindows {
        param([int]$RootPid)
        if ($RootPid -le 0) { return }
        $tree = @{ $RootPid = $true }
        try {
            $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
            $children = @{}
            foreach ($pr in $procs) {
                if ($pr.ParentProcessId) {
                    if (-not $children.ContainsKey($pr.ParentProcessId)) { $children[$pr.ParentProcessId] = @() }
                    $children[$pr.ParentProcessId] += $pr.ProcessId
                }
            }
            $q = [System.Collections.Queue]::new(); $q.Enqueue($RootPid)
            while ($q.Count) {
                $p = $q.Dequeue()
                foreach ($c in $children[$p]) {
                    if (-not $tree.ContainsKey($c)) { $tree[$c] = $true; $q.Enqueue($c) }
                }
            }
        } catch {}

        if (-not ('Win32.MemtraceWin' -as [type])) {
            Add-Type -MemberDefinition @'
                [DllImport("user32.dll")]
                public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
                [DllImport("user32.dll")]
                public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
                public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
                [DllImport("user32.dll")]
                public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
'@ -Name 'MemtraceWin' -Namespace 'Win32'
        }
        $script:mtTree = $tree
        $cb = [Win32.MemtraceWin+EnumWindowsProc]{
            param($hwnd, $lparam)
            $ownerPid = 0
            [void][Win32.MemtraceWin]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid)
            if ($script:mtTree.ContainsKey([int]$ownerPid)) {
                [void][Win32.MemtraceWin]::ShowWindowAsync($hwnd, 0)
            }
            return $true
        }
        [void][Win32.MemtraceWin]::EnumWindows($cb, [IntPtr]::Zero)
    }

    try {
        Write-Host "Starting Memtrace index for repo root (headless, no console window, working dir = $repoDir)..."
        $p = Start-MemtraceHidden $memtraceExe $repoDir $launchLog $launchErr $script:memtraceArgPrefix
        Write-Host "Memtrace launcher invoked. Startup log: $launchLog"
        # Force-hide any window the detached process tree may have popped.
        try { Hide-MemtraceWindows $p.Id } catch {}

        # Readiness gate: wait until MemDB listens on 127.0.0.1:50051 so the
        # mcp client can attach. Poll the raw socket up to ~45s.
        $backendPort = 50051
        $deadline = (Get-Date).AddSeconds(45)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            $sock = $null
            try {
                $sock = New-Object System.Net.Sockets.TcpClient
                $iar = $sock.BeginConnect("127.0.0.1", $backendPort, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) {
                    $sock.EndConnect($iar)
                    $ready = $true
                }
            } catch {} finally { if ($sock) { try { $sock.Close() } catch {} } }
            # Keep force-hiding any window the daemon/grandchild opens mid-startup.
            try { Hide-MemtraceWindows $p.Id } catch {}
            if ($ready) { break }
            if ($p -and $p.HasExited) {
                Write-Warning "Memtrace daemon exited during startup (exit $($p.ExitCode)) - see $launchErr"
                break
            }
            Start-Sleep -Milliseconds 750
        }
        if ($ready) {
            Write-Host "Memtrace backend ready on 127.0.0.1:$backendPort - safe for mcp clients to attach."
        } else {
            Write-Warning "Memtrace backend did NOT become ready on 127.0.0.1:$backendPort within timeout. mcp clients may fail to attach until it is up. See $launchLog / $launchErr."
        }
    } catch {
        Write-Warning "Failed to launch Memtrace: $($_.Exception.Message). Continuing without it."
    }
}

# mcpw-anw (2026-09-18): defensive sweep for memtrace shim hosts leaked by
# EARLIER builds. On 2026-09-18 09:16 this box carried 104 orphaned shell hosts
# running the npm shim J:\Programs\npm-global\memtrace.ps1, oldest 16.2h, one
# per heal cycle: the shim is a SCRIPT, so invoking it created a host process,
# and the host was never joined. Current builds resolve an absolute node.exe
# and never invoke the shim, so this cleans up leftovers from builds that
# already leaked rather than papering over a live leak.
#
# SAFETY - the match is deliberately narrow. A host is swept only when BOTH:
#   1. it is a SHELL HOST (powershell.exe / pwsh.exe) whose command line names
#      the memtrace shim script, and
#   2. its parent process is GONE.
# A live launcher's children always have a live parent (this process), so they
# are never matched; the memtrace daemon is node.exe / memtrace.exe and is
# never a shell host, so it is never matched either. This is PID-scoped, not a
# name sweep, so a sibling launcher's watchers survive.
function Get-OrphanedMemtraceHostPids {
    param([string]$ShimPattern = 'memtrace\.ps1')
    $found = @()
    try {
        $hosts = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe' })
        foreach ($h in $hosts) {
            if ([string]$h.CommandLine -notmatch $ShimPattern) { continue }
            $id = [uint32]$h.ProcessId
            if ($id -eq [uint32]$PID) { continue }
            $ppid = [uint32]$h.ParentProcessId
            if ($ppid -eq 0) { continue }
            if (Get-Process -Id $ppid -ErrorAction SilentlyContinue) { continue }
            $found += [int]$id
        }
    } catch {}
    return @($found)
}

function Stop-OrphanedMemtraceHosts {
    param([string]$ShimPattern = 'memtrace\.ps1')
    $victims = @(Get-OrphanedMemtraceHostPids -ShimPattern $ShimPattern)
    $killed = 0
    foreach ($id in $victims) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; $killed++ } catch {}
    }
    if ($killed -gt 0) {
        Write-Host "mcpw-anw: reaped $killed orphaned memtrace shim host(s) left by an earlier build (PIDs: $($victims -join ', '))."
    }
    return $killed
}

Write-Host "Starting Memtrace index for repo root (background; modules-level index removed)..."
# Sweep BEFORE the start job / auto-heal supervisor run, so leftover shim hosts
# from a previous build cannot survive past this launch.
Stop-OrphanedMemtraceHosts | Out-Null
# mcpw-d0m: NO -DeferToHealthy here. memtrace is REPO-SCOPED (store in
# <repo>\.memdb), so a foreign memtrace on :50051 serves the wrong repo's
# store. Kill-and-replace stays correct for this port. See the staleness rule
# comment above Test-HttpPortAnswering.
Exit-IfPortHeldByLauncherDaemon -Port 50051 -DaemonProcessNames @('memtrace','memcore','memcortex') -Label 'memtrace' -AutoHeal
# VAD-v14z.4: memtrace daemon runs inside this one-shot job (daemon PID in
# .memdb/daemon-state.json, path persisted to teardown-state.json
# MemtraceStatePath for PID-scoped teardown step 4). Keep the job handle so
# the start is tracked, not fire-and-forget.
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:memtraceStartJob = Start-ThreadJob -ScriptBlock $memtraceJobScript -ArgumentList $watchersWorkspaceRoot
} else {
    $script:memtraceStartJob = Start-Job -ScriptBlock $memtraceJobScript -ArgumentList $watchersWorkspaceRoot
}

# --- Memtrace auto-heal supervisor (in-process child job) -------------------
# The start job above is ONE-SHOT: if the daemon later dies (crash, reboot
# leftover, stale ".memdb daemon-state" lock such as the pid-0 hold seen
# 2026-09-05), every graph tool fails until someone runs `memtrace start`
# by hand. This supervisor polls ~every 30s and self-heals:
#  - MemDB (:50051) not listening -> run `memtrace stop` (clears the stale
#    daemon-state lock; harmless when nothing holds it), then relaunch
#    `memtrace start --headless` hidden from the repo root.
#  - MCP/dashboard (:3030) not answering while MemDB is up -> same stop+start.
# THREAD-JOB SCOPE RULE: the runspace inherits no launcher functions, so its
# probe/relaunch helpers are defined inline and the shared log/limit/liveness
# helpers are dot-sourced from Modules\watcher_job_helpers.ps1 (VAD-v14z.5).
# Liveness gate matches the grepai supervisor: when the launcher lock file is
# missing or its PID is dead, the supervisor exits (Release-LauncherLock removes
# the file).
$memtraceHealJob = $null
$memtraceHealLog = Join-Path $script:memtraceGitRoot ".memdb\autoheal.log"
$memtraceHealScript = {
    param($RepoRoot, $LockFile, $HealLog, $JobHelpersModule)
    $ErrorActionPreference = 'Continue'
    # THREAD-JOB SCOPE RULE: this fresh runspace inherits NO launcher functions
    # and NO script-scope variables, so the shared helpers (Limit-LogSize /
    # Test-LauncherAlive) are dot-sourced from Modules\watcher_job_helpers.ps1
    # via the literal path bound in -ArgumentList (VAD-v14z.5 - replaces the
    # copy-pasted bodies).
    . $JobHelpersModule
    # mcpw-anw (2026-09-18): Stop-WatcherTree (tree-kill by PID) lives in
    # Modules\watcher_teardown.ps1. Derive its path from the helpers module we
    # were already handed - both ship side by side - and dot-source it so the
    # reap below removes grandchildren too. Safe to dot-source: that module has
    # no top-level side effects.
    $teardownModule = Join-Path (Split-Path -Parent $JobHelpersModule) 'watcher_teardown.ps1'
    if ($teardownModule -and (Test-Path -LiteralPath $teardownModule)) { . $teardownModule }

    # mcpw-anw (2026-09-18): TRACKED HEAL CHILD.
    # Every Start-Process below now captures -PassThru. Without it the caller
    # gets nothing back, so a relaunch that fails leaves its host running
    # forever with nobody tracking it - exactly how 104 orphaned memtrace.ps1
    # shell hosts accumulated (one per heal cycle, oldest 16.2h).
    # The tracker is a HASHTABLE (not a plain variable) so any scope can mutate
    # .Proc without PowerShell creating a scope-local copy.
    # NOTE ON SCOPE: the tracker is RUNSPACE-LOCAL on purpose. This ThreadJob
    # inherits none of the launcher's variables, so it cannot reach
    # $global:WatcherChildren, and the launcher rewrites teardown-state.json
    # AFTER this job starts - appending PIDs there would race and be lost.
    # So the supervisor reaps its OWN children instead.
    $memtraceHealChild = @{ Proc = $null }
    function Stop-MemtraceHealChild {
        param($Proc, [string]$Reason)
        if (-not $Proc) { return 0 }
        $childId = 0
        try { $childId = [int]$Proc.Id } catch { return 0 }
        if ($childId -le 0) { return 0 }
        $exited = $false
        try { $exited = $Proc.HasExited } catch {}
        if ($exited) { return 0 }
        Write-HealLog "reaping heal child pid $childId ($Reason)"
        # Tree-kill, not a single kill: a failed relaunch's descendants
        # (memtrace.exe, memcore-server.exe, rail-lifecycle node) are garbage
        # too. Fall back to one kill when the teardown module is unavailable.
        if (Get-Command Stop-WatcherTree -ErrorAction SilentlyContinue) {
            try { Stop-WatcherTree -RootPid $childId | Out-Null } catch {}
        }
        try { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue } catch {}
        return 1
    }
    function Write-HealLog {
        param([string]$Msg)
        Limit-LogSize -Path $HealLog
        try {
            $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            "[$ts] $Msg" | Out-File -FilePath $HealLog -Append -Encoding UTF8
        } catch { }
    }
    function Test-PortListening {
        param([int]$Port)
        $s = $null
        try {
            $s = New-Object System.Net.Sockets.TcpClient
            $iar = $s.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1000) -and $s.Connected) { $s.EndConnect($iar); return $true }
            return $false
        } catch { return $false } finally { if ($s) { try { $s.Close() } catch {} } }
    }
    # PATHEXT HARDENING (2026-09-18): this runspace inherits no script-scope
    # variables, so resolve node + memtrace.js by ABSOLUTE path here. Absolute
    # paths never consult PATHEXT, so the launcher survives PATHEXT being
    # degraded to ".CPL" (which broke Get-Command and made every heal attempt
    # fail in ~1s while leaking a pwsh.exe per 30s cycle).
    function Get-MemtraceLaunchSpec {
        $nd = $null
        foreach ($c in @("C:\nvm4w\nodejs\node.exe", "$env:ProgramFiles\nodejs\node.exe", "C:\Program Files\nodejs\node.exe")) {
            if ($c -and (Test-Path -LiteralPath $c)) { $nd = $c; break }
        }
        $js = $null
        foreach ($c in @("J:\Programs\npm-global\node_modules\memtrace\bin\memtrace.js", "$env:APPDATA\npm\node_modules\memtrace\bin\memtrace.js")) {
            if ($c -and (Test-Path -LiteralPath $c)) { $js = $c; break }
        }
        if ($nd -and $js) { return @{ File = $nd; Prefix = @($js); Absolute = $true } }
        $cmd = Get-Command "memtrace.exe" -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command "memtrace.cmd" -ErrorAction SilentlyContinue }
        if (-not $cmd) { $cmd = Get-Command "memtrace" -ErrorAction SilentlyContinue }
        if (-not $cmd) { return $null }
        return @{ File = $cmd.Source; Prefix = @(); Absolute = $false }
    }
    function Invoke-MemtraceStop {
        try {
            $spec = Get-MemtraceLaunchSpec
            if (-not $spec) { Write-HealLog "memtrace not resolvable (absolute pair missing, PATH lookup failed) - cannot stop"; return }
            $spArgs = @()
            $spArgs += $spec.Prefix
            $spArgs += 'stop'
            # -Wait already joins this child, so `stop` cannot leak by itself.
            # -PassThru is captured anyway so the invariant holds uniformly:
            # nothing this runspace spawns outlives the call.
            $stopProc = Start-Process -FilePath $spec.File -ArgumentList $spArgs -WindowStyle Hidden -Wait -PassThru -ErrorAction SilentlyContinue
            Stop-MemtraceHealChild -Proc $stopProc -Reason 'stop did not exit under -Wait' | Out-Null
        } catch {
            Write-HealLog "memtrace stop failed: $($_.Exception.Message)"
        }
    }
    function Restart-MemtraceDaemon {
        $memdbDir = Join-Path $RepoRoot ".memdb"
        try { New-Item -ItemType Directory -Path $memdbDir -Force | Out-Null } catch {}
        $launchLog = Join-Path $memdbDir "memtrace-launch.log"
        $launchErr = Join-Path $memdbDir "memtrace-launch.log.err"
        $spec = Get-MemtraceLaunchSpec
        if (-not $spec) { Write-HealLog "memtrace not resolvable (absolute node+memtrace.js pair missing AND PATH lookup failed) - cannot heal"; return }
        $env:MEMTRACE_OFFLINE      = "1"
        $env:MEMTRACE_NO_HEARTBEAT = "1"
        $env:MEMTRACE_TELEMETRY    = "off"
        $spArgs = @()
        $spArgs += $spec.Prefix
        $spArgs += 'start'
        $spArgs += '--headless'
        # mcpw-anw: -PassThru, so the child is TRACKED from here on. Whatever
        # it is (absolute node.exe today, the npm shim host as a fallback), the
        # verdict path below can now stop it instead of abandoning it.
        $child = Start-Process -FilePath $spec.File -ArgumentList $spArgs `
            -WorkingDirectory $RepoRoot -WindowStyle Hidden `
            -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr -PassThru -ErrorAction SilentlyContinue
        $memtraceHealChild.Proc = $child
        Write-HealLog "relaunched 'memtrace start --headless' via $($spec.File) (absolute=$($spec.Absolute), cwd=$RepoRoot, child pid=$(if ($child) { $child.Id } else { 'none' }))"

        # PERMANENT-FAILURE DETECTION (2026-09-18).
        # Some failures can NEVER be fixed by retrying, and retrying them is what
        # leaked an orphaned pwsh.exe every 30s for 16+ hours. The big one:
        #   "refusing to open MemDB store ... because its declared repository scope
        #    does not match the requested ... scope"
        # That is a store/manifest mismatch, not a transient. Detect it and report
        # a terminal condition instead of looping.
        Start-Sleep -Seconds 8
        try {
            if (Test-Path -LiteralPath $launchErr) {
                $errText = Get-Content -LiteralPath $launchErr -Raw -ErrorAction SilentlyContinue
                if ($errText -and $errText -match 'declared repository scope does not match') {
                    Write-HealLog "PERMANENT FAILURE: memtrace refused the store scope for this workspace (repo not in the union manifest). Retrying cannot succeed - stopping heal attempts. Add '$RepoRoot' to $(Join-Path $env:USERPROFILE '.config\memtrace\workspace.toml') (store rebuild required) or run a separate daemon for it."
                    # mcpw-anw: the relaunch we just made is garbage (it will
                    # never serve this workspace). Reap it - this is the exit
                    # path that used to abandon one host per cycle.
                    Stop-MemtraceHealChild -Proc $memtraceHealChild.Proc -Reason 'permanent store-scope refusal' | Out-Null
                    $memtraceHealChild.Proc = $null
                    return $false
                }
            }
        } catch { }
        return $true
    }
    Write-HealLog "memtrace auto-heal supervisor started (ports 50051 + 3030, poll 30s)"
    $consecutiveFails = 0
    while ($true) {
        try {
            if (-not (Test-LauncherAlive -Path $LockFile)) {
                Write-HealLog "launcher gone (lock file missing or PID dead) - supervisor exiting"
                return
            }
            $memdbUp = Test-PortListening -Port 50051
            $mcpUp   = Test-PortListening -Port 3030
            if (-not $memdbUp -or -not $mcpUp) {
                $consecutiveFails++
                $which = @()
                if (-not $memdbUp) { $which += 'memdb:50051' }
                if (-not $mcpUp)   { $which += 'mcp:3030' }
                Write-HealLog "memtrace down ($( $which -join ', ' )) fail#$consecutiveFails - healing (stop clears stale lock, then start)"
                Invoke-MemtraceStop
                Start-Sleep -Seconds 1
                $restarted = Restart-MemtraceDaemon
                if ($restarted -eq $false) {
                    # Terminal condition (e.g. store-scope refusal). Every further
                    # attempt spawns a pwsh.exe that immediately dies and orphans,
                    # so stop the loop instead of leaking processes forever.
                    Write-HealLog "supervisor stopping - permanent failure, no further restarts"
                    return
                }
                # Give the daemon up to 45s to come back before the next verdict.
                $deadline = (Get-Date).AddSeconds(45)
                $healedInWindow = $false
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 3
                    if ((Test-PortListening -Port 50051) -and (Test-PortListening -Port 3030)) {
                        Write-HealLog "memtrace healed - both ports listening again"
                        $consecutiveFails = 0
                        $healedInWindow = $true
                        break
                    }
                }
                # mcpw-anw: a child that never brought the ports up is not a
                # daemon, it is refuse - stop it (and its tree) instead of
                # leaving it behind for the next cycle to collide with. A child
                # that DID heal is the daemon we asked for: drop the handle so
                # nothing ever reaps it.
                if ($healedInWindow) {
                    $memtraceHealChild.Proc = $null
                } else {
                    Stop-MemtraceHealChild -Proc $memtraceHealChild.Proc -Reason "ports still down after 45s (fail#$consecutiveFails)" | Out-Null
                    $memtraceHealChild.Proc = $null
                }
                if ($consecutiveFails -ge 5) {
                    # Back off instead of tight-looping against a permanently
                    # broken install (5 fails x ~45s each = ~4min). Reset the
                    # counter after the cooldown so a later manual fix resumes
                    # healing normally.
                    Write-HealLog "5 consecutive heal failures - backing off 10 minutes"
                    Start-Sleep -Seconds 600
                    $consecutiveFails = 0
                }
            } else {
                $consecutiveFails = 0
            }
        } catch {
            Write-HealLog "SUPERVISOR ERROR: $($_.Exception.Message) - continuing"
        }
        Start-Sleep -Seconds 30
    }
}
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $memtraceHealJob = Start-ThreadJob -ScriptBlock $memtraceHealScript -ArgumentList $script:memtraceGitRoot, $lockFile, $memtraceHealLog, $jobHelpersModule
} else {
    $memtraceHealJob = Start-Job -ScriptBlock $memtraceHealScript -ArgumentList $script:memtraceGitRoot, $lockFile, $memtraceHealLog, $jobHelpersModule
}
Write-Host "Memtrace auto-heal supervisor spawned (job $($memtraceHealJob.Id)) - log: $memtraceHealLog"

# --- Cerememory memory backend (standalone `serve` HTTP backend on :8420) -----
# TRAE launches the cerememory MCP *shim* (`cerememory.exe mcp --server-url
# http://127.0.0.1:8420`), but that shim is a thin client that depends on a
# SEPARATE backend process (`cerememory.exe serve --port 8420`) already
# listening on 127.0.0.1:8420. This launcher previously omitted that backend, so
# the shim faulted with a backend-down error until it was started by hand.
# NOTE: the backend MUST be started with `--config %ProgramData%\cerememory\cerememory.toml`
# so it uses the real data dir (%ProgramData%\cerememory\data). A bare `serve
# --port 8420` falls back to a default data dir and would split the memory store.
# We start it here (deduped against an already-listening :8420, with a readiness
# gate) so the whole stack comes up automatically on launch.
$cerememoryJobScript = {
    param($ScriptDir)
    $backendPort = 8420
    $launchLog   = Join-Path $env:LOCALAPPDATA "cerememory\cerememory-serve.log"
    $launchErr   = Join-Path $env:LOCALAPPDATA "cerememory\cerememory-serve.log.err"
    try { New-Item -ItemType Directory -Path (Split-Path $launchLog) -Force | Out-Null } catch {}

    # Dedup: reuse an already-listening :8420 backend (e.g. one started by hand).
    $alreadyUp = $false
    try {
        $sock = New-Object System.Net.Sockets.TcpClient
        $iar = $sock.BeginConnect("127.0.0.1", $backendPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) {
            $sock.EndConnect($iar)
            $alreadyUp = $true
        }
    } catch {} finally { if ($sock) { try { $sock.Close() } catch {} } }
    if ($alreadyUp) {
        Write-Host "Cerememory backend already listening on 127.0.0.1:$backendPort - reusing it."
        return
    }

    # Resolve the backend exe portably: prefer the per-machine ProgramData
    # install (it is NOT on PATH by default); fall back to PATH only if the
    # install path is gone. Both resolve through the ProgramData env root.
    $cerememoryToml = Join-Path $env:ProgramData "cerememory\cerememory.toml"
    $cerememoryExe  = Join-Path $env:ProgramData "cerememory\cerememory.exe"
    if (-not (Test-Path -LiteralPath $cerememoryExe)) {
        $cerememoryCmd = Get-Command "cerememory.exe" -ErrorAction SilentlyContinue
        if ($cerememoryCmd) { $cerememoryExe = $cerememoryCmd.Source }
    }
    if (-not (Test-Path -LiteralPath $cerememoryExe)) {
        Write-Warning "cerememory.exe not found (looked at $cerememoryExe and PATH). Skipping Cerememory backend start."
        return
    }
    try {
        Write-Host "Starting Cerememory backend (serve --config $cerememoryToml)..."
        $p = Start-Process -FilePath $cerememoryExe `
            -ArgumentList "serve", "--config", $cerememoryToml `
            -WindowStyle Hidden `
            -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr -PassThru
        # Readiness gate: wait until :8420 listens (up to ~20s).
        $deadline = (Get-Date).AddSeconds(20)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            $s2 = $null
            try {
                $s2 = New-Object System.Net.Sockets.TcpClient
                $iar2 = $s2.BeginConnect("127.0.0.1", $backendPort, $null, $null)
                if ($iar2.AsyncWaitHandle.WaitOne(1000) -and $s2.Connected) {
                    $s2.EndConnect($iar2)
                    $ready = $true
                }
            } catch {} finally { if ($s2) { try { $s2.Close() } catch {} } }
            if ($ready) { break }
            if ($p -and $p.HasExited) {
                Write-Warning "Cerememory backend exited during startup (exit $($p.ExitCode)) - see $launchErr"
                break
            }
            Start-Sleep -Milliseconds 750
        }
        if ($ready) {
            Write-Host "Cerememory backend ready on 127.0.0.1:$backendPort - safe for mcp shim to attach."
        } else {
            Write-Warning "Cerememory backend did NOT become ready on 127.0.0.1:$backendPort within timeout. See $launchLog / $launchErr."
        }
    } catch {
        Write-Warning "Failed to launch Cerememory backend: $($_.Exception.Message). Continuing without it."
    }
}
Write-Host "Starting Cerememory backend (background)..."
# mcpw-d0m: cerememory is a machine-wide PERSISTENT singleton
# (Modules\watcher_patterns.ps1, cerememory.exe / Persistent = $true). A
# healthy, answering :8420 resident is adopted, never killed.
Exit-IfPortHeldByLauncherDaemon -Port 8420 -DaemonProcessNames @('cerememory') -Label 'cerememory' -AutoHeal -DeferToHealthy
# VAD-v14z.4: cerememory is a port-singleton persistent service (:8420). The
# in-job port probe reuses an already-listening backend, so it PERSISTS after
# the launcher exits and is intentionally NOT added to
# $global:WatcherChildren / teardown (same rule as mail/claude-mcp below).
# Keep the start-job handle so the launch is tracked, not fire-and-forget.
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:cerememoryStartJob = Start-ThreadJob -ScriptBlock $cerememoryJobScript -ArgumentList $scriptDir
} else {
    $script:cerememoryStartJob = Start-Job -ScriptBlock $cerememoryJobScript -ArgumentList $scriptDir
}

# --- Claude MCP Server (HTTP-based MCP server on :8080, canonical vad-10m.1) -----
# claude-mcp-server (npm v0.1.0) is a headless HTTP MCP server. It runs
# `node dist/cli.js` and listens on http://127.0.0.1:8080/mcp. MCP clients
# (Claude Desktop, TRAE) connect TO this port; it launches no GUI of its own.
# NAME COLLISION: "claude" here is only the npm package name. This block does
# NOT start Claude Desktop, and no file in this repo does. Claude Desktop
# launches come from its own Squirrel updater - Update.exe
# --processStartAndWait claude.exe, recorded in
# %LOCALAPPDATA%\AnthropicClaude\Squirrel-ProcessStart.log (traced 2026-09-18).
# Required for MCP clients that attach to :8080/mcp.
# vad-10m.1: :8080 is canonical per Toolport registry (registry.json claude-mcp-server
# url http://localhost:8080/mcp), .trae-mcp-probe.ps1 :8080, ###9 SSE :8080.
# start_backends.bat used :8291 (stale HTTP.SYS 7991-8090 exclusion, now free
# per 2026-09-15 netsh probe). ###1 reaps any legacy :8291 claude-mcp-server
# instance (PID-safe commandline match) so only one runs. v0.1.0 binds 0.0.0.0
# (no --host flag) so ensure the LAN-block firewall rule for :8080 below.
# VAD-v14z.4: claude-mcp-server is a port-singleton persistent service. The
# in-job port probe reuses an already-listening server, so it PERSISTS after
# the launcher exits and is intentionally NOT added to
# $global:WatcherChildren / teardown (same rule as the mail block below).
# Keep the start-job handle so the launch is tracked, not fire-and-forget.
$claudeMcpJobScript = {
    param($ScriptDir)
    $backendPort = 8080
    $launchLog   = Join-Path $env:LOCALAPPDATA "claude-mcp-server\claude-mcp-server.log"
    $launchErr   = Join-Path $env:LOCALAPPDATA "claude-mcp-server\claude-mcp-server.log.err"
    try { New-Item -ItemType Directory -Path (Split-Path $launchLog) -Force | Out-Null } catch {}

    # Dedup: reuse an already-listening :8080 server (e.g. one started by hand).
    $alreadyUp = $false
    try {
        $sock = New-Object System.Net.Sockets.TcpClient
        $iar = $sock.BeginConnect("127.0.0.1", $backendPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) {
            $sock.EndConnect($iar)
            $alreadyUp = $true
        }
    } catch {} finally { if ($sock) { try { $sock.Close() } catch {} } }
    if ($alreadyUp) {
        Write-Host "Claude MCP Server already listening on 127.0.0.1:$backendPort - reusing it."
        return
    }

    # vad-10m.1: reap legacy :8291 duplicate from start_backends.bat (CM_PORT=8291).
    # :8080 is down here, so any live claude-mcp-server on :8291 is the duplicate.
    # PID-safe: only kill node.exe whose CommandLine contains claude-mcp-server.
    try {
        $legacyUp = $false
        try {
            $ls = New-Object System.Net.Sockets.TcpClient
            $liar = $ls.BeginConnect("127.0.0.1", 8291, $null, $null)
            if ($liar.AsyncWaitHandle.WaitOne(1000) -and $ls.Connected) { $ls.EndConnect($liar); $legacyUp = $true }
        } catch {} finally { if ($ls) { try { $ls.Close() } catch {} } }
        if ($legacyUp) {
            $dups = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -like '*claude-mcp-server*' })
            foreach ($d in $dups) {
                try {
                    Write-Host "Claude MCP Server legacy :8291 duplicate PID $($d.ProcessId) - stopping it (canonical :8080 wins)."
                    Invoke-CimMethod -InputObject $d -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
                } catch {}
            }
            Start-Sleep -Milliseconds 1500
        }
    } catch {}

    # Resolve the CLI from the LIVE npm global prefix first (npm root -g), then
    # fall back to the legacy hardcoded locations. The old %APPDATA%\npm path
    # went stale when the npm prefix moved (nvm4w -> J:\Programs\npm-global):
    # every launcher run silently skipped this server ("CLI not found"), so
    # nothing restarted it after the 2026-08-30 reboot. $ScriptDir is used for
    # the repo-relative fallback because $PSScriptRoot is empty inside a
    # thread job's fresh runspace.
    $claudeMcpCandidates = @()
    try {
        $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
        if ($npmCmd) {
            $npmRoot = (& $npmCmd.Source root -g 2>$null | Select-Object -Last 1)
            if ($npmRoot -and $npmRoot.Trim()) {
                $claudeMcpCandidates += (Join-Path $npmRoot.Trim() "claude-mcp-server\dist\cli.js")
            }
        }
    } catch {}
    $claudeMcpCandidates += (Join-Path $env:APPDATA "npm\node_modules\claude-mcp-server\dist\cli.js")
    $claudeMcpCandidates += (Join-Path $ScriptDir "..\npm-global\node_modules\claude-mcp-server\dist\cli.js")
    $claudeMcpPath = $claudeMcpCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $claudeMcpPath) {
        Write-Warning "claude-mcp-server CLI not found (tried: npm root -g, %APPDATA%\npm, $ScriptDir\..\npm-global). Skipping Claude MCP Server start."
        return
    }

    # Use the exact node.exe (full path when resolvable): a bare "node" can
    # resolve to an extensionless shim (e.g. ~\.local\bin\node) that Windows
    # refuses to execute ("%1 is not a valid Win32 application").
    $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not $nodeExe) { $nodeExe = "node" }
    try {
        Write-Host "Starting Claude MCP Server (port $backendPort)..."
        $p = Start-Process -FilePath $nodeExe `
            -ArgumentList "`"$claudeMcpPath`"" `
            -WindowStyle Hidden `
            -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr -PassThru
        # Readiness gate: wait until :8080 listens (up to ~20s).
        $deadline = (Get-Date).AddSeconds(20)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            $s2 = $null
            try {
                $s2 = New-Object System.Net.Sockets.TcpClient
                $iar2 = $s2.BeginConnect("127.0.0.1", $backendPort, $null, $null)
                if ($iar2.AsyncWaitHandle.WaitOne(1000) -and $s2.Connected) {
                    $s2.EndConnect($iar2)
                    $ready = $true
                }
            } catch {} finally { if ($s2) { try { $s2.Close() } catch {} } }
            if ($ready) { break }
            if ($p -and $p.HasExited) {
                Write-Warning "Claude MCP Server exited during startup (exit $($p.ExitCode)) - see $launchErr"
                break
            }
            Start-Sleep -Milliseconds 750
        }
        if ($ready) {
            Write-Host "Claude MCP Server ready on 127.0.0.1:$backendPort - safe for MCP clients to attach."
        } else {
            Write-Warning "Claude MCP Server did NOT become ready on 127.0.0.1:$backendPort within timeout. See $launchLog / $launchErr."
        }
    } catch {
        Write-Warning "Failed to launch Claude MCP Server: $($_.Exception.Message). Continuing without it."
    }
}
Write-Host "Starting Claude MCP Server (background)..."
# vad-10m.1: v0.1.0 binds 0.0.0.0 (no --host flag) so keep the LAN-block rule.
# Best-effort: needs admin once, warn and continue when it fails.
try {
    $fw = (& netsh advfirewall firewall show rule name="Block Claude MCP 8080 remote" 2>$null) -join "`n"
    if ($fw -notmatch 'Block Claude MCP 8080 remote') {
        & netsh advfirewall firewall add rule name="Block Claude MCP 8080 remote" dir=in action=block protocol=TCP localport=8080 description="claude-mcp-server v0.1.0 binds 0.0.0.0; block LAN, allow loopback" 2>$null | Out-Null
    }
} catch {}
# vad-10m.1: best-effort reap of legacy :8291 duplicate (start_backends.bat).
# Never exit here: :8291 is a different port, FIRST-WINS does not apply.
try {
    $legacyConns = @(Get-NetTCPConnection -LocalPort 8291 -State Listen -ErrorAction SilentlyContinue)
    if ($legacyConns.Count -gt 0) {
        $legacyProcs = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*claude-mcp-server*' })
        foreach ($lp in $legacyProcs) {
            try { Invoke-CimMethod -InputObject $lp -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        if ($legacyProcs.Count -gt 0) { Write-Host "[claude-mcp-server vad-10m.1] reaped $($legacyProcs.Count) legacy :8291 instance(s) - canonical :8080 wins." }
    }
} catch {}
# mcpw-d0m: claude-mcp-server is a machine-wide PERSISTENT singleton
# (Modules\watcher_patterns.ps1, node.exe / claude-mcp-server / Persistent =
# $true). A healthy, answering :8080 resident is adopted, never killed.
Exit-IfPortHeldByLauncherDaemon -Port 8080 -DaemonProcessNames @('claude-mcp-server','node') -Label 'claude-mcp-server' -AutoHeal -DeferToHealthy
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:claudeMcpStartJob = Start-ThreadJob -ScriptBlock $claudeMcpJobScript -ArgumentList $scriptDir
} else {
    $script:claudeMcpStartJob = Start-Job -ScriptBlock $claudeMcpJobScript -ArgumentList $scriptDir
}

# --- MCP Agent Mail (persistent HTTP MCP server on :8765) -----
# HTTP-based MCP server for agent-mail (the Toolport gateway entry id
# `mcp-agent-mail`). It listens on http://127.0.0.1:8765 (aliases /api and /mcp)
# and is required for agent-mail MCP client connections to work. Deduped against
# an already-listening :8765 so a manually-started instance (e.g. the logon
# Startup shortcut `MCPAgentMailServer.lnk`, or a prior ###1 run) is REUSED
# instead of spawning a second daemon on the same port. This service PERSISTS
# after the launcher exits (like claude-mcp-server), so it is intentionally NOT
# added to $global:WatcherChildren / teardown. NOTE: it is NOT covered by
# Exit-IfPortHeldByLauncherDaemon because its process is python.exe (too broad a
# name match); the in-job port dedup below is sufficient and avoids a false
# FIRST-WINS exit that would abort the whole launcher when a mail server is up.
$mailMcpJobScript = {
    param($ScriptDir)
    $backendPort = 8765
    $launchLog   = Join-Path $env:LOCALAPPDATA "mcp-agent-mail\serve.log"
    $launchErr   = Join-Path $env:LOCALAPPDATA "mcp-agent-mail\serve.log.err"
    try { New-Item -ItemType Directory -Path (Split-Path $launchLog) -Force | Out-Null } catch {}

    # Dedup: reuse an already-listening :8765 server (e.g. the logon Startup shortcut).
    $alreadyUp = $false
    try {
        $sock = New-Object System.Net.Sockets.TcpClient
        $iar = $sock.BeginConnect("127.0.0.1", $backendPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) {
            $sock.EndConnect($iar)
            $alreadyUp = $true
        }
    } catch {} finally { if ($sock) { try { $sock.Close() } catch {} } }
    if ($alreadyUp) {
        Write-Host "MCP Agent Mail server already listening on 127.0.0.1:$backendPort - reusing it."
        return
    }

    $mailMcpCmd = $null
    foreach ($cand in @(
        (Join-Path $env:USERPROFILE ".local\mcp-agent-mail\run_server.cmd"),
        (Join-Path $env:LOCALAPPDATA "mcp-agent-mail\run_server.cmd")
    )) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $mailMcpCmd = $cand; break }
    }
    if (-not $mailMcpCmd) {
        $mailMcpResolved = Get-Command "run_server.cmd" -ErrorAction SilentlyContinue
        if ($mailMcpResolved) { $mailMcpCmd = $mailMcpResolved.Source }
    }
    if (-not $mailMcpCmd -or -not (Test-Path -LiteralPath $mailMcpCmd)) {
        Write-Warning "mcp-agent-mail run_server.cmd not found under %USERPROFILE%\.local or %LOCALAPPDATA%. Skipping MCP Agent Mail start."
        return
    }

    try {
        Write-Host "Starting MCP Agent Mail server (port $backendPort)..."
        $p = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c", "`"$mailMcpCmd`"" `
            -WindowStyle Hidden `
            -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr -PassThru
        # Readiness gate: wait until :8765 listens (up to ~25s).
        $deadline = (Get-Date).AddSeconds(25)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            $s2 = $null
            try {
                $s2 = New-Object System.Net.Sockets.TcpClient
                $iar2 = $s2.BeginConnect("127.0.0.1", $backendPort, $null, $null)
                if ($iar2.AsyncWaitHandle.WaitOne(1000) -and $s2.Connected) {
                    $s2.EndConnect($iar2)
                    $ready = $true
                }
            } catch {} finally { if ($s2) { try { $s2.Close() } catch {} } }
            if ($ready) { break }
            if ($p -and $p.HasExited) {
                Write-Warning "MCP Agent Mail server exited during startup (exit $($p.ExitCode)) - see $launchErr"
                break
            }
            Start-Sleep -Milliseconds 750
        }
        if ($ready) {
            Write-Host "MCP Agent Mail server ready on 127.0.0.1:$backendPort - safe for MCP clients to attach."
        } else {
            Write-Warning "MCP Agent Mail server did NOT become ready on 127.0.0.1:$backendPort within timeout. See $launchLog / $launchErr."
        }
    } catch {
        Write-Warning "Failed to launch MCP Agent Mail server: $($_.Exception.Message). Continuing without it."
    }
}
Write-Host "Starting MCP Agent Mail server (background)..."
# VAD-v14z.4: mail job handle tracked (see intentional-persistence note above).
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:mailMcpStartJob = Start-ThreadJob -ScriptBlock $mailMcpJobScript -ArgumentList $scriptDir
} else {
    $script:mailMcpStartJob = Start-Job -ScriptBlock $mailMcpJobScript -ArgumentList $scriptDir
}

# --- Graphiti embed proxy (persistent OpenAI-compatible :8003) -----
# The graphiti Docker container's embedder points at http://host.docker.internal:8003/v1
# (embed_server.py, all-MiniLM-L6-v2, 384 dims). Without it the Graphiti MCP
# (:8002) has no embeddings and exposes 0 tools. Deduped by in-job port probe
# and REUSED across launchers. PERSISTS after launcher exit, NOT in
# $global:WatcherChildren / teardown. NOT covered by
# Exit-IfPortHeldByLauncherDaemon (python.exe too broad); in-job dedup suffices.
$graphitiEmbedJobScript = {
    param($ScriptDir)
    $backendPort = 8003
    $launchLog   = Join-Path $env:LOCALAPPDATA "graphiti-embed\embed-8003.log"
    $launchErr   = Join-Path $env:LOCALAPPDATA "graphiti-embed\embed-8003.log.err"
    try { New-Item -ItemType Directory -Path (Split-Path $launchLog) -Force | Out-Null } catch {}

    # Dedup: reuse an already-listening :8003 (manual start or prior ###1 run).
    $alreadyUp = $false
    try {
        $sock = New-Object System.Net.Sockets.TcpClient
        $iar = $sock.BeginConnect("127.0.0.1", $backendPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) {
            $sock.EndConnect($iar)
            $alreadyUp = $true
        }
    } catch {} finally { if ($sock) { try { $sock.Close() } catch {} } }
    if ($alreadyUp) {
        Write-Host "Graphiti embed proxy already listening on 127.0.0.1:$backendPort - reusing it."
        return
    }

    # Glue resolution: global shared copy first, install second. The glue left
    # every repo on 2026-09-19 - it is shared infrastructure, not repo code.
    # Default is the shared sibling of the repo's parent; override with
    # $env:GRAPHITI_SHARED_DIR. The venv python stays install-resident - a venv
    # cannot be relocated by copy, because Scripts\*.exe shims embed absolute
    # paths.
    $embedPy = Join-Path $env:LOCALAPPDATA "Programs\graphiti-mcp\mcp_server\.venv\Scripts\python.exe"
    $embedScript = $null
    $embedCands = @()
    $sharedGraphiti = $env:GRAPHITI_SHARED_DIR
    if (-not $sharedGraphiti -and $ScriptDir) {
        $sharedGraphiti = Join-Path (Split-Path -Parent $ScriptDir) 'shared\graphiti'
    }
    if ($sharedGraphiti) { $embedCands += (Join-Path $sharedGraphiti 'embed_server.py') }
    $embedCands += (Join-Path $env:LOCALAPPDATA 'Programs\graphiti-mcp\mcp_server\embed_server.py')
    foreach ($cand in $embedCands) {
        if (Test-Path -LiteralPath $cand) { $embedScript = $cand; break }
    }
    if (-not (Test-Path -LiteralPath $embedPy)) {
        $pyCmd = Get-Command "python.exe" -ErrorAction SilentlyContinue
        if ($pyCmd) { $embedPy = $pyCmd.Source }
    }
    if (-not (Test-Path -LiteralPath $embedPy)) {
        Write-Warning "graphiti embed python not found (looked at $embedPy and PATH). Skipping embed proxy start."
        return
    }
    if (-not $embedScript) {
        Write-Warning "embed_server.py not found (looked at $($embedCands -join '; ')). Skipping embed proxy start."
        return
    }
    Write-Host "Graphiti embed proxy script: $embedScript"

    try {
        Write-Host "Starting Graphiti embed proxy (port $backendPort)..."
        $p = Start-Process -FilePath $embedPy `
            -ArgumentList "`"$embedScript`"", "$backendPort" `
            -WindowStyle Hidden `
            -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr -PassThru
        # Readiness gate: wait until :8003/health answers (up to ~25s; first
        # start loads all-MiniLM-L6-v2 into memory).
        $deadline = (Get-Date).AddSeconds(25)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:$backendPort/health" -Method Get -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) { $ready = $true }
            } catch {}
            if ($ready) { break }
            if ($p -and $p.HasExited) {
                Write-Warning "Graphiti embed proxy exited during startup (exit $($p.ExitCode)) - see $launchErr"
                break
            }
            Start-Sleep -Milliseconds 750
        }
        if ($ready) {
            Write-Host "Graphiti embed proxy ready on 127.0.0.1:$backendPort - safe for graphiti embedder to attach."
        } else {
            Write-Warning "Graphiti embed proxy did NOT become ready on 127.0.0.1:$backendPort within timeout. See $launchLog / $launchErr."
        }
    } catch {
        Write-Warning "Failed to launch Graphiti embed proxy: $($_.Exception.Message). Continuing without it."
    }
}
Write-Host "Starting Graphiti embed proxy (background)..."
# Persistent singleton: tracked handle, excluded from teardown by design.
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:graphitiEmbedStartJob = Start-ThreadJob -ScriptBlock $graphitiEmbedJobScript -ArgumentList $scriptDir
} else {
    $script:graphitiEmbedStartJob = Start-Job -ScriptBlock $graphitiEmbedJobScript -ArgumentList $scriptDir
}

# --- Graphiti MCP proxy (:8004, Toolport -> docker session adapter) ----
# mcp_proxy.py bridges Toolport's stateless HTTP bridge to docker's
# session-based Streamable HTTP on :8002. It used to run BARE - no startup job,
# no supervisor - so if it died the graphiti MCP tools stayed dark until
# somebody restarted it by hand. Same shape as the embed proxy above: deduped
# by in-job port probe, REUSED across launchers, PERSISTS after launcher exit
# and stays out of $global:WatcherChildren / teardown.
$graphitiMcpProxyJobScript = {
    param($ScriptDir)
    $backendPort = 8004
    $launchLog   = Join-Path $env:LOCALAPPDATA "graphiti-mcp-proxy\proxy-8004.log"
    $launchErr   = Join-Path $env:LOCALAPPDATA "graphiti-mcp-proxy\proxy-8004.log.err"
    try { New-Item -ItemType Directory -Path (Split-Path $launchLog) -Force | Out-Null } catch {}

    # Dedup: reuse an already-listening :8004 (manual start or prior ###1 run).
    $alreadyUp = $false
    try {
        $sock = New-Object System.Net.Sockets.TcpClient
        $iar = $sock.BeginConnect("127.0.0.1", $backendPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1000) -and $sock.Connected) {
            $sock.EndConnect($iar)
            $alreadyUp = $true
        }
    } catch {} finally { if ($sock) { try { $sock.Close() } catch {} } }
    if ($alreadyUp) {
        Write-Host "Graphiti MCP proxy already listening on 127.0.0.1:$backendPort - reusing it."
        return
    }

    # Glue resolution: global shared copy first, install second, exactly as the
    # embed proxy does it. Override with $env:GRAPHITI_SHARED_DIR.
    $proxyPy = Join-Path $env:LOCALAPPDATA "Programs\graphiti-mcp\mcp_server\.venv\Scripts\python.exe"
    $proxyScript = $null
    $proxyCands = @()
    $sharedGraphiti = $env:GRAPHITI_SHARED_DIR
    if (-not $sharedGraphiti -and $ScriptDir) {
        $sharedGraphiti = Join-Path (Split-Path -Parent $ScriptDir) 'shared\graphiti'
    }
    if ($sharedGraphiti) { $proxyCands += (Join-Path $sharedGraphiti 'mcp_proxy.py') }
    $proxyCands += (Join-Path $env:LOCALAPPDATA 'Programs\graphiti-mcp\mcp_server\mcp_proxy.py')
    foreach ($cand in $proxyCands) {
        if (Test-Path -LiteralPath $cand) { $proxyScript = $cand; break }
    }
    if (-not (Test-Path -LiteralPath $proxyPy)) {
        $pyCmd = Get-Command "python.exe" -ErrorAction SilentlyContinue
        if ($pyCmd) { $proxyPy = $pyCmd.Source }
    }
    if (-not (Test-Path -LiteralPath $proxyPy)) {
        Write-Warning "graphiti MCP proxy python not found (looked at $proxyPy and PATH). Skipping MCP proxy start."
        return
    }
    if (-not $proxyScript) {
        Write-Warning "mcp_proxy.py not found (looked at $($proxyCands -join '; ')). Skipping MCP proxy start."
        return
    }
    Write-Host "Graphiti MCP proxy script: $proxyScript"

    try {
        Write-Host "Starting Graphiti MCP proxy (port $backendPort)..."
        $p = Start-Process -FilePath $proxyPy `
            -ArgumentList "`"$proxyScript`"", "$backendPort" `
            -WindowStyle Hidden `
            -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr -PassThru
        # Readiness gate: mcp_proxy.py is stdlib-only and binds immediately, so
        # 15s is generous.
        $deadline = (Get-Date).AddSeconds(15)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $ps = New-Object System.Net.Sockets.TcpClient
                $piar = $ps.BeginConnect("127.0.0.1", $backendPort, $null, $null)
                if ($piar.AsyncWaitHandle.WaitOne(1000) -and $ps.Connected) { $ps.EndConnect($piar); $ready = $true }
                try { $ps.Close() } catch {}
            } catch {}
            if ($ready) { break }
            if ($p -and $p.HasExited) {
                Write-Warning "Graphiti MCP proxy exited during startup (exit $($p.ExitCode)) - see $launchErr"
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if ($ready) {
            Write-Host "Graphiti MCP proxy ready on 127.0.0.1:$backendPort - Toolport can reach graphiti through it."
        } else {
            Write-Warning "Graphiti MCP proxy did NOT become ready on 127.0.0.1:$backendPort within timeout. See $launchLog / $launchErr."
        }
    } catch {
        Write-Warning "Failed to launch Graphiti MCP proxy: $($_.Exception.Message). Continuing without it."
    }
}
Write-Host "Starting Graphiti MCP proxy (background)..."
# Persistent singleton: tracked handle, excluded from teardown by design.
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:graphitiMcpProxyStartJob = Start-ThreadJob -ScriptBlock $graphitiMcpProxyJobScript -ArgumentList $scriptDir
} else {
    $script:graphitiMcpProxyStartJob = Start-Job -ScriptBlock $graphitiMcpProxyJobScript -ArgumentList $scriptDir
}

# --- Graphiti MCP (:8002, Docker) -------------------------------------
# graphiti-mcp runs as a Docker container (restart: always, native HTTP on
# container :8000 -> host :8002). The old Windows python bridge
# (stdio main.py) is deleted. mcp_proxy.py is NOT - it was relocated to the
# global shared tree and serves :8004 as the Toolport -> docker session
# adapter. The launcher never spawns or supervises :8002; it only reports.
# Docker owns restarts.
# The container still needs host :8003 (embed proxy above), :4000 (litellm)
# and :6379 (FalkorDB) via host.docker.internal.
try {
    $sock = New-Object System.Net.Sockets.TcpClient
    $iar = $sock.BeginConnect("127.0.0.1", 8002, $null, $null)
    $mcpUp = ($iar.AsyncWaitHandle.WaitOne(2000) -and $sock.Connected)
    try { $sock.Close() } catch {}
    if ($mcpUp) {
        Write-Host "Graphiti MCP (:8002, Docker container) is listening - reusing it."
    } else {
        Write-Warning "Graphiti MCP :8002 not listening - start the Docker container (docker start graphiti-mcp). The launcher no longer spawns it."
    }
} catch {
    Write-Warning "Graphiti MCP :8002 probe failed: $($_.Exception.Message). The launcher no longer spawns it (Docker container graphiti-mcp owns :8002)."
}

# --- Backend auto-heal supervisors (vad-10m.2, Option A) -----
# One supervisor per persistent singleton (cerememory :8420, mail :8765,
# claude-mcp :8080, graphiti-embed :8003, graphiti-mcp-proxy :8004), modelled
# on the litellm/memtrace supervisors. The graphiti-mcp DOCKER container
# (:8002) is Docker-owned and intentionally NOT supervised here - but :8004,
# the host-side Toolport -> docker session adapter in front of it, is ours and
# IS supervised (it used to run bare).
# litellm/memtrace supervisors.
# Option A (confirmed 2026-09-15): heal ONLY while the launcher lives. Each
# supervisor exits when Test-LauncherAlive fails and does NOT kill its backend
# on exit - the backends PERSIST after launcher exit by design and stay out of
# $global:WatcherChildren / teardown (see blocks above).
# THREAD-JOB SCOPE RULE: a fresh runspace inherits no launcher functions, so
# the shared helpers are dot-sourced from Modules\watcher_job_helpers.ps1 by
# the literal path bound in -ArgumentList. Backoff reuses
# Get-LitellmBackoffDelay (generic math, 15s base, 300s cap). Logs are bounded
# via Limit-LogSize. PS 5.1 compatible, ASCII-only.
$backendSupervisorScript = {
    param($BackendName, $Port, $HealthUrl, $SupervisorLog, $LockFile, $JobHelpersModule, $ScriptDir)
    $ErrorActionPreference = 'Continue'
    . $JobHelpersModule
    function Write-BackendSupLog {
        param([string]$Msg)
        Limit-LogSize -Path $SupervisorLog
        $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        "[$ts] $Msg" | Out-File -FilePath $SupervisorLog -Append -Encoding UTF8
    }
    function Test-BackendAlive {
        if ($HealthUrl) {
            try {
                $r = Invoke-WebRequest -Uri $HealthUrl -Method Get -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) { return $true }
            } catch { }
            return $false
        }
        $s = $null
        try {
            $s = New-Object System.Net.Sockets.TcpClient
            $iar = $s.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1000) -and $s.Connected) { $s.EndConnect($iar); return $true }
            return $false
        } catch { return $false } finally { if ($s) { try { $s.Close() } catch {} } }
    }
    function Start-CerememoryBackend {
        $toml = Join-Path $env:ProgramData "cerememory\cerememory.toml"
        $exe = Join-Path $env:ProgramData "cerememory\cerememory.exe"
        if (-not (Test-Path -LiteralPath $exe)) {
            $c = Get-Command "cerememory.exe" -ErrorAction SilentlyContinue
            if ($c) { $exe = $c.Source }
        }
        if (-not (Test-Path -LiteralPath $exe)) { Write-BackendSupLog "cerememory.exe not found - skipping relaunch"; return }
        $log = Join-Path $env:LOCALAPPDATA "cerememory\cerememory-serve.log"
        try { New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null } catch {}
        try {
            $p = Start-Process -FilePath $exe -ArgumentList "serve", "--config", $toml `
                -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
            if ($p) { Write-BackendSupLog "relaunched cerememory backend (PID $($p.Id))" }
        } catch { Write-BackendSupLog "cerememory relaunch failed: $($_.Exception.Message)" }
    }
    function Start-MailBackend {
        $cmd = $null
        foreach ($cand in @((Join-Path $env:USERPROFILE ".local\mcp-agent-mail\run_server.cmd"), (Join-Path $env:LOCALAPPDATA "mcp-agent-mail\run_server.cmd"))) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $cmd = $cand; break }
        }
        if (-not $cmd) {
            $r = Get-Command "run_server.cmd" -ErrorAction SilentlyContinue
            if ($r) { $cmd = $r.Source }
        }
        if (-not $cmd -or -not (Test-Path -LiteralPath $cmd)) { Write-BackendSupLog "run_server.cmd not found - skipping relaunch"; return }
        $log = Join-Path $env:LOCALAPPDATA "mcp-agent-mail\serve.log"
        try {
            $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$cmd`"" `
                -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
            if ($p) { Write-BackendSupLog "relaunched mail backend (PID $($p.Id))" }
        } catch { Write-BackendSupLog "mail relaunch failed: $($_.Exception.Message)" }
    }
    function Start-ClaudeBackend {
        $cands = @()
        try {
            $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
            if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
            if ($npmCmd) {
                $root = (& $npmCmd.Source root -g 2>$null | Select-Object -Last 1)
                if ($root -and $root.Trim()) { $cands += (Join-Path $root.Trim() "claude-mcp-server\dist\cli.js") }
            }
        } catch {}
        $cands += (Join-Path $env:APPDATA "npm\node_modules\claude-mcp-server\dist\cli.js")
        if ($ScriptDir) { $cands += (Join-Path $ScriptDir "..\npm-global\node_modules\claude-mcp-server\dist\cli.js") }
        $cli = $cands | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $cli) { Write-BackendSupLog "claude-mcp-server CLI not found - skipping relaunch"; return }
        $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
        if (-not $nodeExe) { $nodeExe = "node" }
        $log = Join-Path $env:LOCALAPPDATA "claude-mcp-server\claude-mcp-server.log"
        try {
            $p = Start-Process -FilePath $nodeExe -ArgumentList "`"$cli`"" `
                -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
            if ($p) { Write-BackendSupLog "relaunched claude-mcp backend (PID $($p.Id)) on :8080" }
        } catch { Write-BackendSupLog "claude-mcp relaunch failed: $($_.Exception.Message)" }
    }
    function Start-GraphitiEmbedBackend {
        $embedPy = Join-Path $env:LOCALAPPDATA "Programs\graphiti-mcp\mcp_server\.venv\Scripts\python.exe"
        # Glue resolution: global shared copy first, install second. Override
        # the shared location with $env:GRAPHITI_SHARED_DIR.
        $embedScript = $null
        $embedCands = @()
        $sharedGraphiti = $env:GRAPHITI_SHARED_DIR
        if (-not $sharedGraphiti -and $ScriptDir) {
            $sharedGraphiti = Join-Path (Split-Path -Parent $ScriptDir) 'shared\graphiti'
        }
        if ($sharedGraphiti) { $embedCands += (Join-Path $sharedGraphiti 'embed_server.py') }
        $embedCands += (Join-Path $env:LOCALAPPDATA 'Programs\graphiti-mcp\mcp_server\embed_server.py')
        foreach ($cand in $embedCands) {
            if (Test-Path -LiteralPath $cand) { $embedScript = $cand; break }
        }
        if (-not (Test-Path -LiteralPath $embedPy)) {
            $pyCmd = Get-Command "python.exe" -ErrorAction SilentlyContinue
            if ($pyCmd) { $embedPy = $pyCmd.Source }
        }
        if (-not (Test-Path -LiteralPath $embedPy)) { Write-BackendSupLog "graphiti embed python not found - skipping relaunch"; return }
        if (-not $embedScript) { Write-BackendSupLog "embed_server.py not found - skipping relaunch"; return }
        $log = Join-Path $env:LOCALAPPDATA "graphiti-embed\embed-8003.log"
        try {
            $p = Start-Process -FilePath $embedPy -ArgumentList "`"$embedScript`"", "8003" `
                -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
            if ($p) { Write-BackendSupLog "relaunched graphiti-embed backend (PID $($p.Id)) on :8003" }
        } catch { Write-BackendSupLog "graphiti-embed relaunch failed: $($_.Exception.Message)" }
    }
    function Start-GraphitiMcpProxyBackend {
        $proxyPy = Join-Path $env:LOCALAPPDATA "Programs\graphiti-mcp\mcp_server\.venv\Scripts\python.exe"
        # Glue resolution: global shared copy first, install second, exactly as
        # the embed backend does it. Override with $env:GRAPHITI_SHARED_DIR.
        $proxyScript = $null
        $proxyCands = @()
        $sharedGraphiti = $env:GRAPHITI_SHARED_DIR
        if (-not $sharedGraphiti -and $ScriptDir) {
            $sharedGraphiti = Join-Path (Split-Path -Parent $ScriptDir) 'shared\graphiti'
        }
        if ($sharedGraphiti) { $proxyCands += (Join-Path $sharedGraphiti 'mcp_proxy.py') }
        $proxyCands += (Join-Path $env:LOCALAPPDATA 'Programs\graphiti-mcp\mcp_server\mcp_proxy.py')
        foreach ($cand in $proxyCands) {
            if (Test-Path -LiteralPath $cand) { $proxyScript = $cand; break }
        }
        if (-not (Test-Path -LiteralPath $proxyPy)) {
            $pyCmd = Get-Command "python.exe" -ErrorAction SilentlyContinue
            if ($pyCmd) { $proxyPy = $pyCmd.Source }
        }
        if (-not (Test-Path -LiteralPath $proxyPy)) { Write-BackendSupLog "graphiti MCP proxy python not found - skipping relaunch"; return }
        if (-not $proxyScript) { Write-BackendSupLog "mcp_proxy.py not found - skipping relaunch"; return }
        $log = Join-Path $env:LOCALAPPDATA "graphiti-mcp-proxy\proxy-8004.log"
        try { New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null } catch {}
        try {
            $p = Start-Process -FilePath $proxyPy -ArgumentList "`"$proxyScript`"", "8004" `
                -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
            if ($p) { Write-BackendSupLog "relaunched graphiti-mcp-proxy backend (PID $($p.Id)) on :8004" }
        } catch { Write-BackendSupLog "graphiti-mcp-proxy relaunch failed: $($_.Exception.Message)" }
    }
    Write-BackendSupLog "$BackendName supervisor started (port $Port, Option A: exits with launcher, backend persists)"
    Start-Sleep -Seconds 30
    $fails = 0
    $throttled = $false
    $supLoop = 0
    while ($true) {
        $sleepSec = 15
        try {
            $supLoop++
            if (-not (Test-LauncherAlive -Path $LockFile)) {
                Write-BackendSupLog "$BackendName supervisor exiting - launcher gone, backend left running (persistent by design)"
                return
            }
            if (Test-BackendAlive) {
                if ($fails -ne 0) { Write-BackendSupLog "$BackendName alive again - resetting failure counter after $fails" }
                $fails = 0
                $throttled = $false
                $sleepSec = 15
            } else {
                $fails++
                $sleepSec = Get-LitellmBackoffDelay -ConsecutiveFailures $fails -BaseSeconds 15 -MaxSeconds 300
                if (($fails -ge 10) -and (-not $throttled)) {
                    $throttled = $true
                    Write-BackendSupLog "$BackendName permanent-failure: $fails consecutive probe failures - backing off to 300s"
                }
                if ($BackendName -eq 'claude-mcp') {
                    try {
                        $ls = New-Object System.Net.Sockets.TcpClient
                        $liar = $ls.BeginConnect("127.0.0.1", 8291, $null, $null)
                        $lup = $false
                        if ($liar.AsyncWaitHandle.WaitOne(1000) -and $ls.Connected) { $ls.EndConnect($liar); $lup = $true }
                        try { $ls.Close() } catch {}
                        if ($lup) {
                            $dups = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
                                Where-Object { $_.CommandLine -and $_.CommandLine -like '*claude-mcp-server*' })
                            foreach ($d in $dups) { try { Invoke-CimMethod -InputObject $d -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null } catch {} }
                            if ($dups.Count -gt 0) { Write-BackendSupLog "reaped $($dups.Count) legacy :8291 duplicate(s)" }
                            Start-Sleep -Milliseconds 1500
                        }
                    } catch {}
                }
                if (Test-BackendAlive) {
                    Write-BackendSupLog "$BackendName came up during heal - reusing it, no respawn"
                    $fails = 0
                    $throttled = $false
                } else {
                    if (-not $throttled) { Write-BackendSupLog "$BackendName port $Port dead - relaunching (failure $fails)" }
                    elseif (($fails % 10) -eq 0) { Write-BackendSupLog "$BackendName still dead (failure $fails) - throttled, next probe in ${sleepSec}s" }
                    if ($BackendName -eq 'cerememory') { Start-CerememoryBackend }
                    elseif ($BackendName -eq 'mail') { Start-MailBackend }
                    elseif ($BackendName -eq 'claude-mcp') { Start-ClaudeBackend }
                    elseif ($BackendName -eq 'graphiti-embed') { Start-GraphitiEmbedBackend }
                    elseif ($BackendName -eq 'graphiti-mcp-proxy') { Start-GraphitiMcpProxyBackend }
                    Start-Sleep 2
                }
            }
            # vad-10m.3: periodic duplicate reap, every 4th loop. Token AND
            # duplication scoped: only own image+token matches, keep the port
            # owner (oldest on ties), reap extras, log to supervisor log.
            if (($supLoop % 4) -eq 0) {
                try {
                    $dupImage = ''
                    $dupToken = ''
                    if ($BackendName -eq 'cerememory') { $dupImage = 'cerememory.exe'; $dupToken = 'cerememory' }
                    elseif ($BackendName -eq 'mail') { $dupImage = 'python.exe'; $dupToken = 'mcp_agent_mail' }
                    elseif ($BackendName -eq 'claude-mcp') { $dupImage = 'node.exe'; $dupToken = 'claude-mcp-server' }
                    elseif ($BackendName -eq 'graphiti-embed') { $dupImage = 'python.exe'; $dupToken = 'embed_server' }
                    elseif ($BackendName -eq 'graphiti-mcp-proxy') { $dupImage = 'python.exe'; $dupToken = 'mcp_proxy' }
                    if ($dupImage -ne '') {
                        $dups = @(Get-CimInstance Win32_Process -Filter "Name='$dupImage'" -ErrorAction SilentlyContinue |
                            Where-Object { $_.CommandLine -and ($_.CommandLine -like ('*' + $dupToken + '*')) })
                        if ($dups.Count -gt 1) {
                            $owners = @{}
                            foreach ($oc in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { $owners[[uint32]$oc.OwningProcess] = $true }
                            $keep = $null
                            foreach ($dd in $dups) { if ($owners.ContainsKey([uint32]$dd.ProcessId)) { $keep = $dd; break } }
                            if ($null -eq $keep) { $keep = $dups | Sort-Object CreationDate | Select-Object -First 1 }
                            foreach ($dd in $dups) {
                                if ($dd.ProcessId -eq $keep.ProcessId) { continue }
                                try {
                                    Invoke-CimMethod -InputObject $dd -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
                                    Write-BackendSupLog "reaped duplicate $BackendName PID $($dd.ProcessId) - keeping PID $($keep.ProcessId) on :$Port"
                                } catch {}
                            }
                        }
                    }
                } catch {}
            }
            Start-Sleep $sleepSec
        } catch {
            Write-BackendSupLog "SUPERVISOR ERROR: $($_.Exception.Message) - continuing"
            Start-Sleep $sleepSec
        }
    }
}
$supCerememoryLog = Join-Path $env:LOCALAPPDATA 'cerememory\supervisor.log'
$supMailLog = Join-Path $env:LOCALAPPDATA 'mcp-agent-mail\supervisor.log'
$supClaudeLog = Join-Path $env:LOCALAPPDATA 'claude-mcp-server\supervisor.log'
$supGraphitiEmbedLog = Join-Path $env:LOCALAPPDATA 'graphiti-embed\supervisor.log'
$supGraphitiMcpProxyLog = Join-Path $env:LOCALAPPDATA 'graphiti-mcp-proxy\supervisor.log'
function Start-BackendSupervisor {
    param($Name, $Port, $Health, $Log)
    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        $j = Start-ThreadJob -ScriptBlock $backendSupervisorScript -ArgumentList $Name, $Port, $Health, $Log, $lockFile, $jobHelpersModule, $scriptDir
    } else {
        $j = Start-Job -ScriptBlock $backendSupervisorScript -ArgumentList $Name, $Port, $Health, $Log, $lockFile, $jobHelpersModule, $scriptDir
    }
    Write-Host "$Name auto-heal supervisor spawned (job $($j.Id)) - log: $Log"
    return $j
}
$script:cerememorySupJob = Start-BackendSupervisor -Name 'cerememory' -Port 8420 -Health 'http://127.0.0.1:8420/health' -Log $supCerememoryLog
$script:mailSupJob = Start-BackendSupervisor -Name 'mail' -Port 8765 -Health '' -Log $supMailLog
$script:claudeSupJob = Start-BackendSupervisor -Name 'claude-mcp' -Port 8080 -Health '' -Log $supClaudeLog
$script:graphitiEmbedSupJob = Start-BackendSupervisor -Name 'graphiti-embed' -Port 8003 -Health 'http://127.0.0.1:8003/health' -Log $supGraphitiEmbedLog
$script:graphitiMcpProxySupJob = Start-BackendSupervisor -Name 'graphiti-mcp-proxy' -Port 8004 -Health '' -Log $supGraphitiMcpProxyLog

# (graphify-rs ignore-aware wrapper is launched detached + logged above, replacing graphify-rs watch)

# VAD-7m1y (2026-09-06): join the litellm readiness probe job started at the
# LiteLLM launch. It ran concurrently with all the watcher/job startup above
# (grepai supervisor, gm-semantic, memtrace, cerememory, claude/mail MCP jobs),
# so the 20s probe no longer adds serial wall-clock latency. The probe is
# bounded (20s deadline), so a plain Wait-Job matches the old blocking
# semantics; the messages below are identical to the old inline probe.
if ($script:litellmProbeJob) {
    try { Wait-Job -Job $script:litellmProbeJob -ErrorAction Stop | Out-Null } catch { }
    $llmReady = $false
    if ($script:litellmProbeJob.State -eq 'Completed') {
        $llmReady = [bool](Receive-Job -Job $script:litellmProbeJob -ErrorAction SilentlyContinue | Select-Object -Last 1)
    }
    Remove-Job -Job $script:litellmProbeJob -Force -ErrorAction SilentlyContinue
    if ($llmReady) { Write-Host "litellm proxy is up on http://127.0.0.1:4000 (muse models served)." }
    else { Write-Warning "litellm proxy did not become ready within 20s - check $litellmLog." }
}

# --- Combined watcher view: Windows Terminal 2x2 pane grid --------------------
# A single PowerShell console owns ONE linear buffer and CANNOT show four
# independent scroll regions. So instead of tailing all logs into this window,
# we open ONE Windows Terminal window with a 2x2 pane grid: each pane tails its
# own watcher's log live (Get-Content -Wait), giving four true quadrants. This
# launcher's console becomes the controller: it reports status and waits until
# Ctrl+C (the trap below still kills the detached watchers + stops grepai).
# Each pane runs a tiny per-watcher tailer script so the command line stays
# simple and quoting-safe (the command-line sidecars below are also shown).

# Ctrl+C (and any terminating error) triggers teardown. The PowerShell.Exiting
# handler below covers the window [X] close case. Both call the SAME shared
# Stop-AllWatchers, which is idempotent.
trap {
    Write-Host "`nStopping all watchers (Ctrl+C)..."
    try { Stop-GmSemanticLive } catch {}
    try { Stop-AllWatchers } catch {}
    try { Release-LauncherLock $global:LauncherLock } catch {}
    $global:LauncherLock = $null
    break
}

# Window [X] close: the console host raises PowerShell.Exiting even when the
# window is closed by the user (the trap does NOT fire then). This Action runs
# in a SEPARATE runspace with no script scope, so it must re-dot-source the
# module and call Stop-AllWatchers with no args (which reads the persisted
# state file). Bake the literal module path into the scriptblock. It also
# releases the launcher lock (mutex + lock file) so a subsequent launch does
# not see a stale lock.
$teardownAction = [scriptblock]::Create(@"
. '$teardownModule'
try { Stop-GmSemanticLive } catch {}
Stop-AllWatchers
try {
    `$mutexName = '$launcherMutexName'
    `$m = `$null
    try { `$m = [System.Threading.Mutex]::OpenExisting(`$mutexName) } catch {}
    if (`$m) {
        try { `$m.ReleaseMutex() } catch {}
        try { `$m.Dispose() } catch {}
    }
} catch {}
try { if (Test-Path -LiteralPath '$lockFile') { Remove-Item -LiteralPath '$lockFile' -Force -ErrorAction SilentlyContinue } } catch {}
"@)
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $teardownAction | Out-Null


# Pane tailer scripts live OUTSIDE the repo (same scratch root as the watcher
# logs) -- gm's watcher is ignore-blind, so in-repo temp\panes tailer scripts
# would be watched/patched as (code) noise. The teardown sweep in
# Modules/watcher_teardown.ps1 matches 'panes\tail_' on the pane powershell's
# CommandLine, so moving the dir keeps that sweep working as long as the path
# still contains '\panes\tail_'. See change log 2026-07-12.
# mcpw-ybs.2: the keyed workspace segment sits BETWEEN 'vad-watchers' and
# 'panes', so the 'panes\tail_' substring that the teardown sweep matches is
# preserved while two repositories stop sharing one pane dir. The tailer path is
# also what makes a pane process ATTRIBUTABLE to its workspace during a sweep.
$wtPaneDir = Join-Path $scratchRoot "vad-watchers\$workspaceKey\panes"
try { New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null } catch {}

# Auto health check for grepai - detects a dead/missing grepai watch daemon and
# self-heals by clearing stale locks and relaunching grepai with a fresh supervisor.
# VAD-lnhe (2026-09-06): the LAUNCHER-LEVEL Invoke-GrepaiHealthCheck that lived
# here was deleted - it was never called at runtime because the generated pane
# inherits NO launcher functions; the pane uses its own embedded copy (below in
# New-WatcherPaneScript's template), which is the copy the tests AST-extract.
# HEAL_CONDITION: a live `grepai.exe` whose CommandLine matches `watch` must exist.
# Supervisor-only presence is NOT sufficient - the supervisor can be alive while the
# watch daemon is dead (the bug this fixes).


# Generic per-watcher tailer template moved to Modules/watcher_pane_scripts.ps1
# (function New-WatcherPaneScript). See that module for the full template.

# read grepai log file only; skip its separate stderr pipe (NUL noise lives there); real errors in the log still show
# Heartbeat dir: each pane writes a tick file here every poll so the controller
# loop can detect a dead/closed WT tab (which otherwise would NOT trigger
# teardown and would orphan every watcher).
$hbDir = Join-Path $wtPaneDir "hb"
try { New-Item -ItemType Directory -Path $hbDir -Force | Out-Null } catch {}
# The graphenium rebuild daemon runs INSIDE this process (the $gmSemJob thread
# job), and the `gm watch` process this pane used to probe is gone on purpose
# (it destroyed graph.json - see the launch site). Anchor the pane on the
# launcher PID: it stays open exactly as long as the thing that rebuilds the
# graph, and closes with the session like every other pane. Without this the
# pane's no-watcher path would close it on the first tick.
$gmWatchPid       = $PID
$graphifyWatchPid = if ($script:graphifyProc) { $script:graphifyProc.Id } else { '' }
$repowiseWatchPid = if ($script:repowiseProc) { $script:repowiseProc.Id } else { '' }
if (-not $logFile) {
    $lfLate = Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lfLate) { $logFile = $lfLate.FullName }
}
if (-not $logFile) { $logFile = $grepaiLaunchLog }
# grepai heals at the INDEX dir ($scriptDir, where .grepai/ lives and where
# `grepai watch` + the supervisor run), NOT at $watchersWorkspaceRoot. The pane
# never resolves paths via FSW for grepai (Show-ChangedFiles is a no-op for this
# label), so pointing it at the caller workspace only makes `grepai status` /
# `grepai watch` fail with "no grepai project found" when the caller is not
# grepai-init'd. The other three panes intentionally stay on $watchersWorkspaceRoot.
$tailGrepai      = New-WatcherPaneScript -Label "grepai"      -LogPath $logFile            -ErrPath ""                 -RepoRoot $watchersWorkspaceRoot -HeartbeatPath (Join-Path $hbDir "grepai.hb") -SupervisorLog $supSupervisorLog -LaunchLog $grepaiLaunchLog -LaunchErr $grepaiLaunchErr -LockFile $lockFile
$tailGraphenium  = New-WatcherPaneScript -Label "graphenium"  -LogPath $gmLog              -ErrPath "$gmLog.err"      -RepoRoot $watchersWorkspaceRoot -HeartbeatPath (Join-Path $hbDir "graphenium.hb")  -WatchPid $gmWatchPid -LockFile $lockFile
$tailGraphifyRs  = New-WatcherPaneScript -Label "graphify-rs" -LogPath $graphifyLog        -ErrPath "$graphifyLog.err" -RepoRoot $watchersWorkspaceRoot -HeartbeatPath (Join-Path $hbDir "graphify-rs.hb") -WatchPid $graphifyWatchPid
$tailRepowise    = New-WatcherPaneScript -Label "repowise"    -LogPath $repowiseLog        -ErrPath "$repowiseLog.err" -RepoRoot $watchersWorkspaceRoot -HeartbeatPath (Join-Path $hbDir "repowise.hb")   -WatchPid $repowiseWatchPid
# Collect the heartbeat paths so the controller loop can watch any of them.
$script:hbPaths = @(
    (Join-Path $hbDir "grepai.hb"),
    (Join-Path $hbDir "graphenium.hb"),
    (Join-Path $hbDir "graphify-rs.hb"),
    (Join-Path $hbDir "repowise.hb")
)

Write-Host ""
Write-Host "All watchers running. Opening a Windows Terminal window with 4 panes:"
Write-Host "  Top-Left     : grepai      (tracked background, stop: 'grepai watch --stop')"
Write-Host "  Top-Right    : graphenium  (detached, kill gm.exe)"
Write-Host "  Bottom-Left  : graphify-rs (detached, kill graphify-rs.exe)"
Write-Host "  Bottom-Right : repowise    (detached, kill repowise.exe)"
Write-Host "Press Ctrl+C here to stop everything."

# GOAL: one Windows Terminal window with 4 independent live-tailing panes,
# one watcher per pane. The exact corner each watcher lands in is incidental,
# not a requirement - what matters is that all 4 tailers end up as separate
# panes in ONE window rather than four separate windows or a broken layout.
#
# Built per the windows-terminal (wt-panes-tabs) skill rules:
#   - "-w $wtWindowName"  target a DEDICATED, NAMED window that is (re)used on
#                         EVERY call. Using "-w 0" (most-recently-focused window)
#                         is fragile: focus-pane -t 0/1 target pane IDs that are
#                         window-GLOBAL across ALL tabs, so when this launcher is
#                         run from an existing WT window those IDs can resolve to
#                         the controller tab instead of the new 2x2 tab - landing
#                         a -V split in the wrong place and collapsing two quarters
#                         into one half. A fixed named window isolates the pane
#                         IDs of the 2x2 from every other tab. (This is the same
#                         root cause the 2026-07-10 wt-2x2-grid regression fix hit,
#                         just via the -w routing rather than the missing -w.)
#   - "-d <ws>"     every subcommand opens its pane at $watchersWorkspaceRoot (mcpw-ybs.1)
#   - ";"           chain ALL subcommands into a SINGLE wt invocation
#   - execute immediately, no preview/confirmation
#
# One previously-real bug is avoided by construction: numeric anchors
# ("focus-pane -t <id>") take window-global creation-order pane IDs that go
# STALE across rebuilds (the pre-grid reset closes prior panes; the long-lived
# named window can host other user tabs), and a stale id made the next
# split-pane inherit whatever pane WT actually held focused -- re-splitting
# the wrong half (live failure measured 2026-08-26). Anchors are therefore
# directional "move-focus up/down" moves, which carry NO pane ids.
#
# Build order (deterministic 2x2, one quarter per corner). Anchors are
# DIRECTIONAL move-focus commands, never numeric pane ids:
#   new-tab grepai           -> TL;                    focus = TL
#   split-pane -H graphify   -> full-width bottom row; focus = bottom
#   move-focus up            -> focus TOP row (only pane above)
#   split-pane -V graphenium -> TR; top halved;        focus = TR
#   move-focus down          -> focus full-width bottom row
#   split-pane -V repowise   -> bottom halved: BL + BR
# Corner map: TL grepai, TR graphenium, BL graphify-rs, BR repowise.
# Each step is a SEPARATE wt invocation with a settle/poll wait, so each
# anchor resolves against a SETTLED layout and the two -V splits anchor to
# DISTINCT rows -- they can never both land in the same half (the older
# "unequal quarters / 3 on bottom" bug came from ONE chained wt ";" call).
# Directional moves are unambiguous in this fixed sequence: after the -H
# split there are EXACTLY two rows, so up/down have single valid targets.
# mcpw-ybs.3: the window name is workspace-keyed, like the lock and the
# mutexes. It used to be the bare literal 'vadwatchers', so two repositories
# launched at once shared ONE Windows Terminal window: repo B's new-tab landed
# in repo A's live grid, and the pre-grid reset could not cleanly separate them
# (mcpw-ybs.5 stops it from KILLING repo A's panes, but the grids still shared
# the window and the focus/split anchors). Keying gives each workspace its own
# window, which is what makes the cross-workspace grid deterministic.
# The name stays recognisable ('vadwatchers-<key>') rather than a bare hash so
# an operator can still tell which window belongs to which repo by eye.
$wtWindowName = "vadwatchers-$workspaceKey"
$wtOk = $false
if (Get-Command "wt" -ErrorAction SilentlyContinue) {
    # PRE-GRID RESET: tear down any SURVIVING vadwatchers 2x2 grid from a prior
    # run BEFORE building the new grid, so new-tab never inherits a stale 2nd tab
    # (pane-targeting commands resolve against window-global state, so a stale tab
    # makes the -V splits land in the wrong half and two quarters collapse
    # together -- the "unequal quarters" bug). Windows Terminal's wt CLI (1.24)
    # has NO close-tab / get-tabinfo / --tabIdFile commands (verified against
    # the v1.24.11911.0 source; the 2026-07-18 change log's claim that `new-tab
    # --tabIdFile` writes the new tab's GUID was wrong -- the option does not
    # exist), so a surviving grid cannot be addressed by tab id. The grid is
    # uniquely owned by its pane tailer processes (powershell.exe hosting
    # C:\Temp\vad-watchers\panes\tail_*.ps1), so we close it the same way the
    # teardown sweep does: terminate those processes. WT then auto-closes each
    # pane (default closeOnExit), the tab closes with its last pane, and the
    # window closes with its last tab. Any OTHER tabs the user opened in the
    # vadwatchers window survive -- their panes do not match 'panes\tail_'.
    # This guarantees new-tab below starts a fresh, single-tab window, so the
    # grid build is deterministic. A clean first launch sees no tailers and
    # adds zero latency.
    function Get-WatcherPaneTailers {
        param([switch]$ThisWorkspaceOnly)
        $all = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape('panes\tail_') })
        if (-not $ThisWorkspaceOnly) { return $all }
        return @($all | Where-Object { Test-WatcherPaneTailerIsOurs -Proc $_ })
    }
    # mcpw-ybs.5: attribute BEFORE terminating. The reset below used to
    # Terminate() EVERY 'panes\tail_' match machine-wide. mcpw-ybs.2b added an
    # attribution gate to the STARTUP orphan sweep but not here, so launching in
    # repo B killed repo A's live 2x2 grid. Verified live 2026-09-17: VAD's
    # un-keyed tailers are C:\Temp\vad-watchers\panes\tail_*.ps1 and matched.
    # Same FAIL-SAFE trade as the sweep: a skipped stale tailer can leave a
    # second tab, which is a layout wart; killing another repository's live
    # panes is not. A cross-workspace clean grid now depends on mcpw-ybs.3
    # giving each workspace its own Windows Terminal window.
    function Test-WatcherPaneTailerIsOurs {
        param($Proc)
        $cmd = ''
        try { $cmd = [string]$Proc.CommandLine } catch { $cmd = '' }
        if (-not $cmd) { return $false }
        if (Get-Command Test-WatchersProcessAttribution -ErrorAction SilentlyContinue) {
            return (Test-WatchersProcessAttribution -CommandLine $cmd `
                -WorkspaceKey $workspaceKey -WorkspaceRoot $watchersWorkspaceRoot)
        }
        # Inline fallback, same rule as the sweep: never kill machine-wide.
        return [bool]($workspaceKey -and $cmd.IndexOf($workspaceKey, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    # RUNTIME FEEDBACK LOOP (2026-08-26 "not equal quarters" regression): the
    # static suites lock wt argument structure but cannot see the REALIZED
    # geometry. This probe enumerates the vadwatchers window's TermControl
    # rectangles via UI Automation AFTER the build and warns when any pane
    # deviates >15% from its expected quarter share (25% width x 50% height).
    # Measured live on the 2026-08-26 failure: graphenium spanned 50% width and
    # graphify-rs 100% -- this probe would have surfaced it in the controller
    # log. Probe failures NEVER abort the launch (best-effort visibility only);
    # a minimized/hidden window reports unmeasurable and skips silently.
    function WatcherGridProbe {
        param([string]$WindowName)
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            # NOTE: the WT window TITLE mirrors the ACTIVE PANE title (e.g.
            # "repowise"), never "vadwatchers", so we cannot FindFirst by name.
            # Discovery: scan every CASCADIA window and adopt the first whose
            # terminal panes carry our four watcher labels.
            $classCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
            $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $classCond)
            $termCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'TermControl')
            $want = @('grepai', 'graphenium', 'graphify-rs', 'repowise')
            $win = $null; $panes = $null
            foreach ($w in $wins) {
                $tp = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $termCond)
                $names = @($tp | ForEach-Object { $_.Current.Name })
                $missing = @($want | Where-Object { $_ -notin $names })
                if ($missing.Count -eq 0) { $win = $w; $panes = $tp; break }
            }
            if (-not $win) { Write-Host "[grid-probe] watcher grid window not found - skipping"; return }
            Start-Sleep -Milliseconds 800   # let WT finalize pane layout before measuring
            if ($panes.Count -ne 4) { Write-Warning "[grid-probe] expected 4 terminal panes, found $($panes.Count) - layout NOT verified"; return }
            $rects = @(); foreach ($p in $panes) { $rects += $p.Current.BoundingRectangle }
            $minX = ($rects | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
            $minY = ($rects | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
            $maxR = ($rects | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum
            $maxB = ($rects | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum
            $clientW = $maxR - $minX; $clientH = $maxB - $minY
            if (($clientW -le 10) -or ($clientH -le 10)) { Write-Host "[grid-probe] window minimized/hidden - geometry not measurable this run"; return }
            $bad = @()
            foreach ($p in $panes) {
                $r = $p.Current.BoundingRectangle
                $wPct = $r.Width / $clientW; $hPct = $r.Height / $clientH
                if (([Math]::Abs($wPct - 0.25) -gt 0.15) -or ([Math]::Abs($hPct - 0.50) -gt 0.15)) {
                    $bad += ("{0} ({1:p0} x {2:p0})" -f $p.Current.Name, $wPct, $hPct)
                }
            }
            if ($bad.Count -gt 0) {
                Write-Warning "[grid-probe] UNEQUAL QUARTERS detected - check these panes: $($bad -join ', ')"
            } else {
                Write-Host "[grid-probe] 2x2 layout verified: 4 near-equal quadrants."
            }
        } catch { Write-Host "[grid-probe] skipped: $($_.Exception.Message)" }
    }
    $resetAll = @(Get-WatcherPaneTailers)
    $resetTailers = @(Get-WatcherPaneTailers -ThisWorkspaceOnly)
    $resetSkipped = $resetAll.Count - $resetTailers.Count
    if ($resetSkipped -gt 0) {
        Write-Warning "Pre-grid reset skipped $resetSkipped pane tailer(s) not attributable to this workspace (key $workspaceKey). They belong to another repository; leaving their panes running is the safe choice. The new grid may share the '$wtWindowName' window with them until mcpw-ybs.3 gives each workspace its own."
    }
    if ($resetTailers.Count -gt 0) {
        foreach ($t in $resetTailers) {
            try { Invoke-CimMethod -InputObject $t -MethodName Terminate | Out-Null } catch { Write-Warning "Failed to terminate stale pane tailer: $($_.Exception.Message)" }
        }
        # Condition-based wait for the teardown to land (no blind sleep): poll
        # until no pane tailer remains, capped at 4s so a heavy teardown cannot
        # stall the launch. The CIM Terminate call is synchronous, so the wait
        # normally exits on the first check.
        $resetDeadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $resetDeadline) {
            Start-Sleep -Milliseconds 200
            # Only OUR tailers must be gone. Waiting for every machine-wide
            # match to disappear would spin the full 4s on every launch that
            # coexists with another repository (mcpw-ybs.5).
            if ((@(Get-WatcherPaneTailers -ThisWorkspaceOnly).Count) -eq 0) { break }
        }
    }
    # ROOT CAUSE (2026-07-16 fix for intermittent "2 tabs instead of 1"):
    # The OLD wait enumerated ALL CASCADIA_HOSTING_WINDOW_CLASS HWNDs globally
    # and exited as soon as that global count dropped below what it was before
    # close-window. When the USER HAD ANOTHER WT WINDOW OPEN, the global count
    # included that unrelated window, so deleting only the vadwatchers window
    # dropped the global count past the threshold IMMEDIATELY -- the loop exited
    # before the async close had finished. new-tab -w vadwatchers then found the
    # stale window still alive and opened a SECOND tab in it. That is why the bug
    # was intermittent (only with another WT window open) and invisible to the
    # static layout test. Scoping the reset to the launcher's own pane tailers
    # (pattern-scoped, never the whole window) keeps that fix and preserves the
    # user's other vadwatchers tabs.
    try {
        # Build the 2x2 grid as SEPARATE wt invocations, each followed by a short
        # settle wait. Two fixes shaped this: (a) SEPARATE invocations instead of
        # ONE chained ";" call, so each anchor resolves against a settled layout;
        # (b) 2026-08-26: anchors are directional move-focus up/down, NOT numeric
        # focus-pane ids. Window-global creation-order ids go stale when the
        # pre-grid reset closes prior panes or when the long-lived vadwatchers
        # window hosts other tabs; a stale id made the next split-pane inherit
        # whatever pane WT held focused (measured live 2026-08-26: the repowise
        # -V re-split the TL pane -> 25/25/50 top + full-width bottom).
        # Directional moves have no ids to go stale. -w targets the dedicated
        # named window. EVERY split is an explicit even split (-s 0.5) and is
        # guarded by tests/launcher_equal_quarters.tests.ps1 so the "unequal
        # quarters" regression cannot sneak back in. NEVER change -w to '-w 0'
        # here: -w 0 routes the -V splits into the wrong half and collapses two
        # quarters into one (see commit 6a8ac8b).
        # The 12ms settle below is NOT the layout guard anymore (it was measured
        # ~27x too short on the warm path: a pane tailer spawns ~330ms AFTER
        # wt.exe exits, so a blind sleep let the next focus-pane / -V split race
        # an unsettled layout and both -V splits landed in the same half -> the
        # unequal-quarters regression, invisible to the static layout test). The
        # guard is the condition-based wait in Build-GridStep: poll
        # Get-WatcherPaneTailers until the step's expected tailers exist AND the
        # count is stable for $gridStableMs (gives the focus/split time to apply),
        # capped by $gridWaitDeadlineSec so a slow spawn cannot stall the launch.
        # $wtSettleMs survives as a small floor after each step; launcher_tests.ps1
        # T8 splices its minimize call onto this exact line, keep it unique.
        $wtSettleMs = 100
        function Build-GridStep([string[]]$stepArgs, [int]$ExpectedTailers) {
            # Invoke wt via Start-Process with a SEPARATE-array -ArgumentList
            # (NOT `& wt @stepArgs`): PowerShell's `& wt` form collapses the
            # args into a single token on some wt builds (here, it turned the
            # --tabIdFile .txt into the program to launch -> 0x80070002
            # ERROR_FILE_NOT_FOUND). A real array keeps wt's subcommand parser
            # intact. Matches the close-tab / close-window calls used elsewhere
            # in this script. See change log 2026-07-16 / 2026-07-18.
            # NO -Wait here. `wt` is the WindowsTerminal app-execution alias; with
            # no WT instance running it becomes the window HOST process itself and
            # stays alive until that window closes, so -Wait blocks forever (the
            # cold-start deadlock T8 hit on 2026-08-19 -- every earlier launch had
            # a live WT host to hand off to, making -Wait return). Bounded poll:
            # an exited process must have exit code 0 (the hand-off case, preserves
            # the old failure detection); a process still alive after the deadline
            # IS the host and means the step's window/pane came up (success).
            $p = Start-Process -FilePath wt -ArgumentList $stepArgs -WindowStyle Hidden -PassThru -ErrorAction Stop
            $stepDeadline = (Get-Date).AddSeconds(2)
            while (-not $p.HasExited -and (Get-Date) -lt $stepDeadline) { Start-Sleep -Milliseconds 100 }
            if ($p.HasExited -and $p.ExitCode -ne 0) { throw "wt grid step failed (exit $($p.ExitCode)): $($stepArgs -join ' ')" }
            Start-Sleep -Milliseconds $wtSettleMs
            # Condition-based settle. On the warm path wt.exe exits ~200ms after
            # handoff but the pane's tailer process spawns ~330ms LATER (probed
            # 2026-08-20), so a fixed sleep lets the next step race an unsettled
            # layout: an anchor or split can resolve against a stale layout and
            # land in the wrong half (unequal-quarters regression, see
            # changelogs 2026-07-10 / 2026-07-12 for the earlier occurrences).
            # Poll until this step's expected pane tailers exist AND the count
            # stays stable for $gridStableMs -- for pane-creating steps that is
            # layout materialization, for move-focus anchor steps (ExpectedTailers ==
            # current count) it is time for WT to apply the focus before the
            # next split. Deadline-capped so a slow spawn degrades, never hangs.
            $gridStableMs = 100
            $gridWaitDeadline = (Get-Date).AddSeconds(3)
            $stableSince = $null
            $stabilized = $false
            while ((Get-Date) -lt $gridWaitDeadline) {
                # mcpw-ybs.5: count OUR tailers. A machine-wide count is inflated
                # by another repository's grid and would declare this step's pane
                # materialized before it actually was.
                $tailerCount = (@(Get-WatcherPaneTailers -ThisWorkspaceOnly)).Count
                if ($tailerCount -ge $ExpectedTailers) {
                    if ($null -eq $stableSince) { $stableSince = Get-Date }
                    elseif ((Get-Date) - $stableSince -ge [TimeSpan]::FromMilliseconds($gridStableMs)) { $stabilized = $true; break }
                } else { $stableSince = $null }
                Start-Sleep -Milliseconds 50
            }
            return $stabilized
        }
        # NOTE: we do NOT pre-create the window with `new-window`. That subcommand
        # mis-parses on this WT build -> "error 2147942402 (0x80070002) when
        # launching 'new-window -d .'" and it also spawned a spurious SECOND tab.
        # The grid's `new-tab -w vadwatchers` below already CREATES the named
        # window when it does not exist (verified: the grid builds the correct
        # single-tab window without any pre-create). So the simplest correct path
        # is to let new-tab own window creation. See change log 2026-07-19.
        # pane 0 (TL): the new tab opens in the named window. NOTE: we do NOT
        # pass `--tabIdFile` here. This build of Windows Terminal does not honor
        # it (it never writes the file), and passing it is exactly what triggers
        # the 0x80070002 mis-parse where WT treats the flag's .txt value as the
        # program to launch in the new pane. Without it the command is the clean,
        # universally-supported `new-tab -d <workspaceRoot> --title grepai powershell -NoProfile
        # -File <tailer>`. Teardown therefore always uses the close-window
        # fallback (see trap / controller loop), which is already implemented for
        # the $wtTabId -eq $null case. See change log 2026-07-18 / 2026-07-19.
        Build-GridStep @('-w', $wtWindowName, 'new-tab', '-d', $watchersWorkspaceRoot, '--title', 'grepai', 'powershell', '-NoProfile', '-File', $tailGrepai) 1
        # $wtTabId stays $null: this WT build does not support --tabIdFile, so we
        # rely on the close-window fallback for teardown (already handled in the
        # trap / controller loop for the $null case).
        $script:wtTabId = $null
        if (Test-Path -LiteralPath "variable:wtTabIdFile") { Remove-Variable -Name wtTabIdFile -Scope Script -ErrorAction SilentlyContinue }
        # pane 1 (BL): horizontal split below pane 0
        Build-GridStep @('-w', $wtWindowName, 'split-pane', '-H', '-s', '0.5', '-d', $watchersWorkspaceRoot, '--title', 'graphify-rs', 'powershell', '-NoProfile', '-File', $tailGraphifyRs) 2
        # focus the TOP row before its vertical split. Directional move (no pane
        # id): after the -H split exactly two rows exist, so "up" uniquely
        # selects the top (grepai) pane. A numeric focus-pane -t id went stale
        # across rebuilds here and mis-anchored the following -V split.
        Build-GridStep @('-w', $wtWindowName, 'move-focus', 'up') 2
        # pane 2 (TR): vertical split to the right of pane 0
        Build-GridStep @('-w', $wtWindowName, 'split-pane', '-V', '-s', '0.5', '-d', $watchersWorkspaceRoot, '--title', 'graphenium', 'powershell', '-NoProfile', '-File', $tailGraphenium) 3
        # focus the BOTTOM row before its vertical split. Focus currently sits on
        # the just-created TR pane; "down" uniquely selects the full-width bottom
        # (graphify-rs) pane, so the final -V halves the bottom row.
        Build-GridStep @('-w', $wtWindowName, 'move-focus', 'down') 3
        # pane 3 (BR): vertical split to the right of pane 1
        Build-GridStep @('-w', $wtWindowName, 'split-pane', '-V', '-s', '0.5', '-d', $watchersWorkspaceRoot, '--title', 'repowise', 'powershell', '-NoProfile', '-File', $tailRepowise) 4
        $wtOk = $true
        # Self-hide the controller console. The 2x2 Windows Terminal window
        # (vadwatchers) is already open and is where the user reads the watcher
        # logs, so this window's only remaining job is to host Ctrl+C / [X]
        # teardown. Hiding it removes the redundant, empty controller window
        # without changing any watcher behaviour. Closing it from the taskbar
        # still fires PowerShell.Exiting -> Stop-AllWatchers, so teardown is
        # unaffected. Only hide on success: the grepai-missing / fallback paths
        # below stay visible so their errors can be read.
        try {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class ControllerSelfHide {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")]   public static extern bool ShowWindowAsync(IntPtr h, int n);
}
'@ -ErrorAction SilentlyContinue
            [ControllerSelfHide]::ShowWindowAsync([ControllerSelfHide]::GetConsoleWindow(), 0) | Out-Null   # 0 = SW_HIDE
        } catch {}
        if ($wtOk) { WatcherGridProbe -WindowName $wtWindowName }
    } catch {
        Write-Warning "Failed to open Windows Terminal panes: $($_.Exception.Message). Falling back to combined view."
        $wtOk = $false
    }
}

if (-not $wtOk) {
    # FALLBACK: combined, labelled tailer in this window (original behaviour).
    # VAD-z7rf (2026-09-06): the old loop re-read EVERY log IN FULL via
    # Get-Content each 500 ms tick - the exact unbounded-read pattern the
    # 2026-09-06 pane leak fix removed; the fallback path was missed. Port the
    # incremental byte-offset reader (Modules/watcher_log_tail.ps1) here with a
    # per-stream offset table. The reader's Rotated flag covers the old
    # truncation/rotation guard. Startup seeds each stream ONCE to end-of-file
    # (same "show only new lines" semantics as the old line-count watermark).
    $fallbackTailModule = $null
    $fallbackTailCands = @()
    if ($PSScriptRoot) { $fallbackTailCands += (Join-Path $PSScriptRoot 'Modules\watcher_log_tail.ps1') }
    if ($env:VAD_WORKSPACE_ROOT) { $fallbackTailCands += (Join-Path $env:VAD_WORKSPACE_ROOT 'Modules\watcher_log_tail.ps1') }
    foreach ($cand in $fallbackTailCands) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $fallbackTailModule = $cand; break }
    }
    if (-not $fallbackTailModule) { throw 'watcher_log_tail.ps1 not found next to the launcher or under $env:VAD_WORKSPACE_ROOT\Modules' }
    . $fallbackTailModule

    $fallbackStreams = @(
        @{ Label = "grepai";      Path = $logFile },
        @{ Label = "graphenium";  Path = $gmLog },
        @{ Label = "graphify-rs"; Path = $graphifyLog },
        @{ Label = "repowise";    Path = $repowiseLog },
        @{ Label = "graphenium";  Path = "$gmLog.err" },
        @{ Label = "graphify-rs"; Path = "$graphifyLog.err" },
        @{ Label = "repowise";    Path = "$repowiseLog.err" }
    )
    $offStreams = @{}
    foreach ($s in $fallbackStreams) {
        if ($s.Path -and (Test-Path -LiteralPath $s.Path)) {
            try { $seed = Read-WatcherLogTail -Path $s.Path -Offset 0; $offStreams[$s.Path] = $seed.Offset } catch { $offStreams[$s.Path] = 0 }
        }
    }
    Write-Host "=================================================================="
    $noisyWarnCount = 0
    while ($true) {
        foreach ($s in $fallbackStreams) {
            if (-not $s.Path) { continue }
            try {
                if (-not (Test-Path -LiteralPath $s.Path)) { continue }
                if (-not $offStreams.ContainsKey($s.Path)) { $offStreams[$s.Path] = 0 }
                $tail = Read-WatcherLogTail -Path $s.Path -Offset ([Math]::Max(0, $offStreams[$s.Path]))
                $offStreams[$s.Path] = $tail.Offset
                if ($tail.Rotated) { Write-Host "=== $($s.Label) log rotated/truncated - resuming from tail ===" }
                foreach ($line in $tail.Lines) {
                    $line = $line -replace "`0", ''
                    if ($line.Length -eq 0) { continue }
                    if ($s.Label -eq 'graphify-rs' -and ($line -match 'Large corpus detected|graph too large for interactive viz')) {
                        $noisyWarnCount++
                        if ($noisyWarnCount % 10 -ne 0) { continue }
                    }
                    if ($s.Label -eq 'graphify-rs' -and ($line -match '^\s*Wrote, in |^\s*Wrote ')) { continue }
                    if ($s.Label -eq 'repowise' -and ($line -match 'VS Code')) { continue }
                    if ($s.Label -eq 'repowise' -and ($line -match 'Skipping oversized file')) { continue }
                    if ($s.Label -eq 'graphenium' -and ($line -match 'Non-code files changed')) { continue }
                    Write-Host ("[{0}] {1}" -f $s.Label, $line)
                }
            } catch { continue }
        }
        Start-Sleep -Milliseconds 500
    }
}

# Controller loop (WT panes open): keep this window alive as the controller.
# Ctrl+C triggers the trap above which kills watchers + stops grepai.
Write-Host "=================================================================="
Write-Host "4-pane Windows Terminal window is open. This window is the controller."
Write-Host "Press Ctrl+C to stop all watchers and close everything."
# Persist tracked root PIDs so the PowerShell.Exiting handler (separate
# runspace, no script scope) can tree-kill them on window [X] close. Use
# $global:WatcherChildren (PID-scoped) so teardown only kills our own children.
# VAD-v14z.4 daemon coverage: RootPids carries Start-WatcherDetached children
# (incl. $script:litellmProc); GrepaiPid carries $script:GrepaiPid;
# MemtraceStatePath carries the memtrace daemon PID via .memdb/daemon-state.json
# ($script:memtraceStartJob); cerememory / claude-mcp-server / mail /
# graphiti-embed / graphiti-mcp-proxy are
# intentionally persistent singletons (see blocks above,
# $script:cerememoryStartJob / $script:claudeMcpStartJob /
# $script:mailMcpStartJob / $script:graphitiEmbedStartJob /
# $script:graphitiMcpProxyStartJob)
# and are excluded from RootPids by design. The graphiti-mcp CONTAINER (:8002)
# is Docker-owned, also excluded by design - the host-side :8004 proxy in front
# of it is a persistent singleton like the rest.
try {
    $tdState = @{
        RootPids           = @($global:WatcherChildren | ForEach-Object { $_ })
        MemtraceStatePath  = $script:memtraceStateFile
        RepoRoot           = $script:memtraceGitRoot
        WtWindowName       = $wtWindowName
        GrepaiPid          = [int]($script:GrepaiPid)
    } | ConvertTo-Json -Compress
    # mcpw-ybs.2: the state file is keyed by workspace. It carries THIS
    # launcher's tracked root PIDs, so a shared file would let a takeover in repo
    # A tear down repo B's watchers (Stop-AllWatchers reads this path when it is
    # called with no arguments, which is the PowerShell.Exiting path).
    $tdDir  = Join-Path $env:LOCALAPPDATA "watchers\$workspaceKey"
    $tdFile = Join-Path $tdDir 'teardown-state.json'
    New-Item -ItemType Directory -Path $tdDir -Force | Out-Null
    Set-Content -LiteralPath $tdFile -Value $tdState -Encoding UTF8
} catch {}

# Controller loop (WT panes open): keep this window alive as the controller.
# The controller console is HIDDEN (see ControllerSelfHide above), so the user
# cannot click its [X] and normally cannot Ctrl+C it either -- the only visible
# surface is the Windows Terminal tab. Closing that tab does NOT fire this
# script's Ctrl+C trap or PowerShell.Exiting, so without the heartbeat guard
# below the watchers would orphan. Each pane writes a tick file every ~2s
# (VAD-ltnq: 4 ticks of the 500ms poll loop); if NONE of them have ticked for
# $hbTimeoutSec the tab is gone, and we run the
# same Stop-AllWatchers the Ctrl+C / [X] paths use. This makes the visible tab
# itself the kill trigger, matching the user's mental model.
# mcpw-qfy RC4: 15s tolerates transient process starvation; a sleep/resume
# gap (loop iteration delayed 60s+) forgives missed beats instead of killing
# healthy daemons on wake. Panes tick every ~2s, so 15s is still a fast
# dead-tab signal.
$hbTimeoutSec = 15
$hbStaleSince = $null
$hbLastLoop = [datetime]::UtcNow
while ($true) {
    Start-Sleep -Seconds 1
    # Beads VAD-3apv: surface gm-semantic thread-job failure instead of
    # discarding its output. The job must stay Running for the whole session
    # (its loop only exits on teardown via $State.Live = $false); the start-time
    # check above only catches an immediate failure. Drain once and warn if the
    # job dies while the launcher is still up, and consume the $State.Failed
    # flag the incremental loop sets after repeated build exceptions.
    if ($gmSemJob -and -not $script:gmSemJobReported -and $gmSemJob.State -ne 'Running') {
        $script:gmSemJobReported = $true
        Write-Warning "[gm-semantic] incremental build thread-job stopped (state: $($gmSemJob.State)) - live semantic builds are DOWN. Job output:"
        try {
            Receive-Job -Job $gmSemJob -ErrorAction Continue 2>&1 |
                ForEach-Object { Write-Warning ("  [gm-semantic job] " + $_) }
        } catch {}
    }
    if ($global:gmSemState -and $global:gmSemState.Failed -and -not $script:gmSemBuildFailWarned) {
        $script:gmSemBuildFailWarned = $true
        Write-Warning "[gm-semantic] incremental builds keep raising inside the thread job (3+ consecutive failures) - semantic graph is stale; check logs/gm-semantic-build-run.log(.err)."
    }
    # Skip the guard entirely when there is no WT tab (e.g. fallback combined
    # view, or wt missing) -- in those cases the visible surface is this console
    # itself, which already triggers teardown on Ctrl+C / [X].
    if (-not $wtOk) { continue }
    $anyAlive = $false
    # Compare in UTC: the tick file stores UtcNow.ToFileTimeUtc() and we read it
    # back as [datetime]::FromFileTimeUtc (Utc kind). Mixing local Get-Date with
    # a Utc-kind datetime mis-computes by the timezone offset and would declare
    # healthy panes stale. Use UtcNow for both sides.
    $now = [datetime]::UtcNow
    # mcpw-qfy RC4: OS sleep / modern standby freezes this loop. Without this
    # check the post-wake gap looks like a dead tab and healthy watchers die.
    if (($now - $hbLastLoop).TotalSeconds -gt 60) {
        Write-Host "System resume detected (loop gap $([int]($now - $hbLastLoop).TotalSeconds)s) - forgiving missed pane heartbeats..."
        $hbStaleSince = $null
    }
    $hbLastLoop = $now
    foreach ($hb in $script:hbPaths) {
        try {
            if (Test-Path -LiteralPath $hb) {
                $tick = [datetime]::MinValue
                $raw = (Get-Content -LiteralPath $hb -Raw -ErrorAction SilentlyContinue)
                if ($raw -and [long]::TryParse($raw.Trim(), [ref]$null)) {
                    try { $tick = [datetime]::FromFileTimeUtc([long]$raw.Trim()) } catch { $tick = [datetime]::MinValue }
                }
                if ($tick -ne [datetime]::MinValue -and (($now - $tick).TotalSeconds -le $hbTimeoutSec)) {
                    $anyAlive = $true
                    break
                }
            }
        } catch {}
    }
    if ($anyAlive) { $hbStaleSince = $null; continue }
    # No pane has ticked recently. Give the tab a grace window before declaring
    # it dead, so a transient WT hiccup does not kill the watchers.
    if ($null -eq $hbStaleSince) { $hbStaleSince = $now; continue }
    if (($now - $hbStaleSince).TotalSeconds -lt $hbTimeoutSec) { continue }
    Write-Host "`nNo WT pane heartbeat for $([int]($now - $hbStaleSince).TotalSeconds)s -- the watcher tab was closed. Stopping all watchers..."
    try { Stop-GmSemanticLive } catch {}
    try { Stop-AllWatchers } catch {}
    try { Release-LauncherLock $global:LauncherLock } catch {}
    $global:LauncherLock = $null
    # No close-tab call needed: the tab is already gone (that is what stopped
    # the heartbeats), and wt (1.24) has no close-tab command anyway.
    break
}
exit 0
