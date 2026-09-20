# Resolve script directory to ensure we run inside the correct project/repository
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ($scriptDir) {
    Set-Location -LiteralPath $scriptDir
}

# grepai is launched by this script as a long-running watcher. The launcher does NOT
# exit immediately after spawning it - it waits until grepai confirms it is running
# (via process liveness + worktree log artifacts) and only then opens the live tail,
# leaving grepai's own process running for real-time indexing. If grepai is missing
# or fails to start, the launcher holds the console ("Press Enter to exit") so the
# error is visible instead of the window vanishing.
#
# VAD-vxr (2026-09-13): this launcher no longer uses --background and no longer
# trusts --status, matching the ###1 watcher launcher's documented contract:
#  - --background carries a HARD-CODED 30s internal "become ready" probe. This
#    ~38k-file repo cannot finish its initial scan in 30s, so every --background
#    launch self-kills mid-scan and crash-loops ("tick 1" forever, index stuck at 0).
#  - --status reports "Status: not running" even while a tracked watcher is alive
#    and serving, so it is unusable as a truth source here.
# The fix is the same as ###1: launch FOREGROUND `grepai watch` detached + hidden
# (no internal gate, finishes the scan at its own pace), then judge readiness by
# CIM process liveness + the fresh grepai-worktree-* log/ready artifacts.

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

# --- Parent-death wiring for the grepai WE spawn (vad-r0i) --------------------
# This launcher spawns `grepai watch` DETACHED + hidden, so the child inherits
# nothing that can end it: when this console is closed / Ctrl+C'd / crashed /
# hard-killed, grepai (and the index workers it spawns) used to survive as an
# orphan holding ~2 GB RAM and the Ollama embedding model lock (observed
# 2026-09-15: two orphaned grepai.exe with no launcher alive). Two layers now
# cover every exit path, both PID-scoped to the grepai WE spawn - a grepai that
# was already running before this launcher is never touched:
#   1) HARD death (kill / crash - no handler can run): a Windows Job Object with
#      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. grepai is assigned at spawn, so the
#      kernel reaps it and every worker it spawns the moment this launcher
#      process dies.
#   2) GRACEFUL exit (Ctrl+C trap + PowerShell.Exiting engine event): stop our
#      grepai first (index flush / Ollama model release), then run the shared
#      PID-scoped teardown - the same module + trap + engine-event shape as the
#      ###1 watcher launcher's watcher-job teardown.
# The job helpers are shared with ###1 through Modules\watcher_job_helpers.ps1;
# the teardown lives in Modules\watcher_teardown.ps1.
$jobHelpersModule = $null
$jobHelpersCands = @()
if ($scriptDir) { $jobHelpersCands += (Join-Path $scriptDir 'Modules\watcher_job_helpers.ps1') }
if ($env:VAD_WORKSPACE_ROOT) { $jobHelpersCands += (Join-Path $env:VAD_WORKSPACE_ROOT 'Modules\watcher_job_helpers.ps1') }
foreach ($cand in $jobHelpersCands) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { $jobHelpersModule = $cand; break }
}
if ($jobHelpersModule) { . $jobHelpersModule }
else { Write-Warning 'Modules\watcher_job_helpers.ps1 not found - grepai parent-death job unavailable.' }

$teardownModule = $null
$teardownCands = @()
if ($scriptDir) { $teardownCands += (Join-Path $scriptDir 'Modules\watcher_teardown.ps1') }
if ($env:VAD_WORKSPACE_ROOT) { $teardownCands += (Join-Path $env:VAD_WORKSPACE_ROOT 'Modules\watcher_teardown.ps1') }
foreach ($cand in $teardownCands) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { $teardownModule = $cand; break }
}
if ($teardownModule) { . $teardownModule }
else { Write-Warning 'Modules\watcher_teardown.ps1 not found - graceful watcher teardown unavailable.' }

# The grepai watch PID THIS launcher spawned. Stays 0 when an already-running
# watcher was reused - teardown is then a no-op, so a sibling launcher's grepai
# is never stopped from here.
$script:GrepaiPid = 0
$script:DeathJob = [IntPtr]::Zero

# --- Scratch log paths (outside the watched tree; same scheme as ###1) --------
# Launch stdout/stderr redirect to a scratch log dir off the watched tree; the
# grepai-native worktree artifacts (log/.ready) live under %LOCALAPPDATA%\grepai\logs.
$scratchRoot = $null
if (Test-Path -LiteralPath "C:\Temp") { $scratchRoot = "C:\Temp" }
else { $scratchRoot = Join-Path $env:TEMP "vad-watchers" }
$logsDir = Join-Path $scratchRoot "vad-watchers\watchers"
try { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null } catch {}
$grepaiLaunchLog = Join-Path $logsDir "grepai-launch.log"
$grepaiLaunchErr = Join-Path $logsDir "grepai-launch.log.err"
$grepaiLogsDir = Join-Path $env:LOCALAPPDATA 'grepai\logs'

# Liveness probe: only a grepai.exe whose command line carries 'watch' counts as
# the WATCHER. A bare process count was too broad - a one-off `grepai search` or
# an `mcp-serve` server is a live grepai.exe that is NOT the watcher. This is the
# same watch-CommandLine probe the ###1 launcher uses for readiness.
function Test-GrepaiWatchAlive {
    return @(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' }).Count -gt 0
}

# Check if a grepai watch is already running WITHOUT --status (unreliable in this
# environment - it reports "not running" even while a tracked watcher is alive).
# If it is already running, do NOT exit: this script's whole purpose is a visible,
# persistent watcher view, so we capture the newest worktree log and fall through
# to the live tail below.
$watchRunning = Test-GrepaiWatchAlive
$logFile = $null
$watchWaited = 0
if ($watchRunning) {
    Write-Host "grepai watch already running (live watch process detected). Reusing it for the tail view."
    $lf = Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lf) { $logFile = $lf.FullName }
}

# Read the Ollama endpoint grepai is configured to use, from .grepai/config.yaml
# (embedder.ollama.endpoint). Falls back to grepai's documented default 11434.
# Same pattern as Get-GrepaiOllamaTarget in the ###1 watcher launcher, so this
# launcher probes the endpoint grepai actually embeds against (not a stale
# hardcoded port).
function Get-GrepaiOllamaTarget {
    $ghCfg = Join-Path $scriptDir '.grepai\config.yaml'
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

# Prerequisites Check: Ollama service.
# Probe the CONFIG-DRIVEN endpoint first (matches what grepai embeds against),
# then the documented legacy 12134 fallback - same probe order as the ###1
# launcher, so the two launchers never disagree about "is Ollama up".
$ollamaTarget = Get-GrepaiOllamaTarget
$ollamaLegacyPort = 12134                       # documented fallback (pre-relocation default)
$ollamaUrls = @("http://$ollamaTarget/", "http://127.0.0.1:$ollamaLegacyPort/")
$ollamaUrl = $ollamaUrls[0]
$ollamaRunning = $false

try {
    foreach ($u in $ollamaUrls) {
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
            # `serve` accepts no --host flag on this Ollama build. OLLAMA_HOST
            # (process env, inherited by the child) tells it which port to
            # bind, mirroring the ###1 launcher's port-fix mechanism.
            if ($ollamaTarget -ne '127.0.0.1:11434') { $env:OLLAMA_HOST = $ollamaTarget }
            Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden

            # Wait up to 20 seconds for Ollama to become ready
            $waitLimit = 20
            $waited = 0
            $ollamaRunning = $false
            while ($waited -lt $waitLimit) {
                Start-Sleep -Seconds 1
                $waited++
                foreach ($u in $ollamaUrls) {
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
        Write-Warning "Ollama service is not running on $($ollamaUrls -join ' or ') and could not be started. Skipping Ollama-dependent startup."
    }
} catch {
    Write-Warning "Ollama prerequisite check failed: $($_.Exception.Message). Continuing without Ollama."
}

# Layer2: Validate .grepai/ state in the MAIN repo and linked worktrees before starting grepai.
# NOTE: the main repo's own index.gob was previously NOT covered (the scan filtered out
# $gitRoot), which is exactly how the 2026-07-16 corrupt-377-byte-index EOF recurred. We now
# include $gitRoot in the scan set so the primary repo's index is validated/self-healed too.
try {
    $gitRoot = git -C $scriptDir rev-parse --show-toplevel 2>$null
    if ($gitRoot) {
        $worktreeDirs = @($gitRoot) + @(
            (git -C $gitRoot worktree list --porcelain 2>$null |
                Where-Object { $_ -match '^worktree ' } |
                ForEach-Object { ($_ -split ' ', 2)[1] } |
                Where-Object { $_ -ne $gitRoot })
        )
        foreach ($wt in $worktreeDirs) {
            $idx = Join-Path $wt '.grepai\index.gob'
            $cfg = Join-Path $wt '.grepai\config.yaml'
            if ((Test-Path $idx) -and -not (Test-Path $cfg)) {
                Write-Host "Removing stale .grepai/index.gob in linked worktree: $wt"
                Remove-Item $idx -Force
            }
        }
    }
} catch {
    Write-Warning "Worktree .grepai validation failed: $($_.Exception.Message)"
}

# Layer 1: Prune fully-merged stale worktrees to prevent grepai auto-discovery
try {
    $gitRoot = git -C $scriptDir rev-parse --show-toplevel 2>$null
    if ($gitRoot) {
        $mainHead = git -C $gitRoot rev-parse HEAD 2>$null
        $worktreeDirs = git -C $gitRoot worktree list --porcelain 2>$null |
            Where-Object { $_ -match '^worktree ' } |
            ForEach-Object { ($_ -split ' ', 2)[1] } |
            Where-Object { $_ -ne $gitRoot }
        foreach ($wt in $worktreeDirs) {
            $wtHead = git -C $wt rev-parse HEAD 2>$null
            if ($wtHead -and $wtHead -eq $mainHead) {
                # Never --force-remove a worktree holding uncommitted changes.
                $dirty = @(git -C $wt status --porcelain 2>$null)
                if ($dirty.Count -gt 0) {
                    Write-Warning "Skipping worktree '$wt': HEAD matches main but uncommitted changes exist."
                    continue
                }
                $branch = git -C $wt rev-parse --abbrev-ref HEAD 2>$null
                Write-Host "Pruning stale worktree '$wt' (HEAD matches main, branch: $branch)..."
                git -C $gitRoot worktree remove $wt --force 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to remove worktree: $wt"
                }
            }
        }
        git -C $gitRoot worktree prune 2>$null
    }
} catch {
    Write-Warning "Worktree pruning failed: $($_.Exception.Message)"
}

# Only launch + wait when grepai is not already running. The already-running case
# was handled above (it captured the log path and falls through to the live tail).
if (-not $watchRunning) {
    # Build the kill-on-close job BEFORE the spawn so the fresh grepai can be
    # assigned immediately - workers grepai spawns afterwards inherit the job.
    if (Get-Command New-WatcherParentDeathJob -ErrorAction SilentlyContinue) {
        $script:DeathJob = New-WatcherParentDeathJob
        if ($script:DeathJob -eq [IntPtr]::Zero) {
            Write-Warning "grepai parent-death job could not be created - relying on the graceful teardown only."
        }
    }
    # Start grepai watch in FOREGROUND mode, detached + hidden. Foreground watch has
    # NO internal 30s readiness gate, so it finishes the initial scan at its own pace
    # instead of self-killing mid-scan like --background does on this ~38k-file repo.
    Write-Host "Starting grepai watch (foreground, detached + hidden)..."
    try {
        $gp = Start-Process -FilePath (Get-Command "grepai.exe").Source -ArgumentList "watch" `
            -WorkingDirectory $scriptDir -WindowStyle Hidden `
            -RedirectStandardOutput $grepaiLaunchLog -RedirectStandardError $grepaiLaunchErr -PassThru
        # Parent-death: this is the grepai WE own, so it goes into the job (and
        # takes every worker it spawns from here on with it).
        $script:GrepaiPid = $gp.Id
        $assigned = Add-ProcessToWatcherDeathJob -Job $script:DeathJob -ProcessId $gp.Id
        if (-not $assigned) { Write-Warning "grepai parent-death assign failed for PID $($gp.Id) - job Zero or already-in-job; relying on graceful teardown only." }
        # FOREGROUND watch should stay up. Wait ~10s: if it exits on its own within
        # that window it is a genuine launch failure (missing exe, immediate crash).
        # A blank or 0 exit = daemonized / refused with a recoverable lock; only a
        # real numeric non-zero exit is a hard failure (###1 contract).
        $exited = $gp.WaitForExit(10000)
        if ($exited -and ($gp.ExitCode -is [int]) -and $gp.ExitCode -ne 0) {
            throw "grepai watch exited with code $($gp.ExitCode)"
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
                    -WorkingDirectory $scriptDir -WindowStyle Hidden `
                    -RedirectStandardOutput $grepaiLaunchLog -RedirectStandardError $grepaiLaunchErr -PassThru
                # Parent-death: track + assign the retried spawn too (the failed
                # first attempt never became our watcher).
                $script:GrepaiPid = $gp2.Id
                $assigned = Add-ProcessToWatcherDeathJob -Job $script:DeathJob -ProcessId $gp2.Id
                if (-not $assigned) { Write-Warning "grepai parent-death assign failed for PID $($gp2.Id) - job Zero or already-in-job; relying on graceful teardown only." }
                $gp2.WaitForExit(35000) | Out-Null
            } catch { Write-Warning "grepai relaunch failed: $($_.Exception.Message)" }
        } else {
            Write-Warning "grepai launch error: $($_.Exception.Message)"
        }
    }

    # Readiness: wait for a live watch process or a FRESH worktree log/ready
    # artifact, max 30s. Never --status (unreliable in this environment - it
    # reports "not running" even while a tracked watcher is alive and serving).
    $watchWaitLimit = 30
    $ready = $false
    while ($watchWaited -lt $watchWaitLimit) {
        Start-Sleep -Seconds 1
        $watchWaited++
        $fresh = Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } | Select-Object -First 1
        if ($fresh) { $ready = $true; break }
        if (Test-GrepaiWatchAlive) { $ready = $true; break }
    }
    $lf = Get-ChildItem -Path $grepaiLogsDir -Filter 'grepai-worktree-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lf) { $logFile = $lf.FullName }

    if ($ready) {
        $watchRunning = $true
    } else {
        Write-Error "grepai watch did not become ready within $watchWaitLimit s. It may have crashed on launch. Check the grepai launch log: $grepaiLaunchErr"
        Write-Host "Press Enter to exit..."
        $null = Read-Host
        exit 1
    }
}

# --- Parent-death teardown: graceful exit (vad-r0i) ---------------------------
# Both graceful exit paths stop the grepai THIS launcher spawned: the Ctrl+C /
# terminating-error trap, and the window [X] close, which raises
# PowerShell.Exiting in a SEPARATE runspace with no script scope (so the handler
# re-dot-sources the teardown module and uses the PID baked into its
# scriptblock - the same shape as the ###1 launcher's teardown action).
# $script:GrepaiPid is 0 when this launcher only reused a watcher someone else
# started, and both paths are no-ops then. The kernel-level Job Object
# (KILL_ON_JOB_CLOSE, assigned at spawn) remains the backstop for a kill/crash
# where neither handler can run.
$grepaiTeardownPid = [int]$script:GrepaiPid
trap {
    Write-Host "`nStopping the grepai watcher this launcher started (parent-death teardown)..."
    if ($script:GrepaiPid -gt 0) {
        try { & grepai watch --stop | Out-Null } catch {}
        try { Stop-AllWatchers -RootPids @($script:GrepaiPid) -GrepaiPid $script:GrepaiPid | Out-Null } catch {}
    }
    break
}
$teardownAction = [scriptblock]::Create(@"
if ('$teardownModule' -and (Test-Path -LiteralPath '$teardownModule')) { . '$teardownModule' }
if ($grepaiTeardownPid -gt 0) {
    try { & grepai watch --stop | Out-Null } catch {}
    try { Stop-AllWatchers -RootPids @($grepaiTeardownPid) -GrepaiPid $grepaiTeardownPid | Out-Null } catch {}
}
"@)
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $teardownAction | Out-Null

# --- Visible, persistent watcher view -----------------------------------------
# grepai runs detached in the background; this console now mirrors its live log so
# the user gets a visible, real-time watcher. Stays open until Ctrl+C.
Write-Host ""
Write-Host "grepai watch is RUNNING (confirmed after $watchWaited s)."
Write-Host "This window shows grepai's live index log. Press Ctrl+C to stop watching."
if ($script:GrepaiPid -gt 0) {
    Write-Host "(This launcher started that watcher, so closing this window stops it -"
    Write-Host " the parent-death teardown ends grepai and the workers it spawned.)"
} else {
    Write-Host "(That watcher was already running before this launcher, so closing"
    Write-Host " this window leaves it running. Use 'grepai watch --stop' to stop it.)"
}
Write-Host "=================================================================="

if ($logFile -and (Test-Path $logFile)) {
    try {
        Get-Content -LiteralPath $logFile -Wait -Tail 20
    } catch {
        Write-Host "Live tail unavailable: $($_.Exception.Message)"
        Write-Host "Press Enter to exit..."
        $null = Read-Host
    }
} else {
    Write-Host "Could not locate grepai log file for live tail."
    Write-Host "Press Enter to exit..."
    $null = Read-Host
}
exit 0
