# modules/watcher_teardown.ps1
# Shared watcher teardown. Dot-sourced by:
#   - ###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
#   - tests/launcher_watcher_teardown.tests.ps1
#   - tests/launcher_memtrace_heal.tests.ps1 (defines the orphan sweep here)
#   - tests/launcher_memtrace_orphan_sweep.tests.ps1 (mcpw-ajy regression)
# SAFE TO DOT-SOURCE: no top-level side effects (no launches, no writes).
#
# The launcher persists tracked root PIDs to a state file so the
# PowerShell.Exiting engine event (which runs in a separate runspace
# without the launcher's script scope) can call Stop-AllWatchers with no
# arguments and still reach the real processes.

$watcherPatterns = Join-Path $PSScriptRoot 'watcher_patterns.ps1'
if (Test-Path -LiteralPath $watcherPatterns) { . $watcherPatterns }

# Kill a process tree by root PID using a CIM parent/child walk.
# Returns the number of processes terminated (for test assertions).
function Stop-WatcherTree {
    # NOTE: `$Pid` (automatic, read-only) cannot be a param name, and aliasing
    # a param to `Pid` makes PowerShell attempt to overwrite the read-only
    # automatic `$Pid` ("Cannot overwrite variable Pid") and crash the caller.
    # So the public parameter is `-RootPid` (callers pass `-RootPid`, NOT `-Pid`).
    param(
        [int]$RootPid
    )
    # CIM Win32_Process returns ParentProcessId/ProcessId as [uint32]. The
    # [int] $RootPid (e.g. from $proc.Id) will NOT match a [uint32] hashtable
    # key, which silently breaks the parent/child walk. Normalize everything
    # to [uint32] so the walk actually traverses descendants.
    $root = [uint32]$RootPid
    $killed = 0
    try {
        $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        $byParent = @{}
        foreach ($p in $all) {
            $ppid = [uint32]$p.ParentProcessId
            if (-not $byParent.ContainsKey($ppid)) {
                $byParent[$ppid] = @()
            }
            $byParent[$ppid] += $p
        }
        # Use a real Queue for BFS. NOTE: the naive `$queue = $queue[1..($queue.Count-1)]`
        # idiom is a latent PowerShell trap: when the queue holds a single element,
        # `1..0` yields indices @(1,0), which re-enqueues the same item and hangs in an
        # infinite loop. System.Collections.Queue.Dequeue() avoids that entirely.
        $seen = @{}
        $q = New-Object System.Collections.Queue
        $q.Enqueue($root)
        while ($q.Count -gt 0) {
            $cur = [uint32]$q.Dequeue()
            if ($seen.ContainsKey($cur)) { continue }
            $seen[$cur] = $true
            if ($byParent.ContainsKey($cur)) {
                foreach ($child in $byParent[$cur]) {
                    $q.Enqueue([uint32]$child.ProcessId)
                }
            }
        }
        # $seen holds root + every descendant.
        foreach ($id in $seen.Keys) {
            $pr = $null
            try { $pr = Get-Process -Id $id -ErrorAction SilentlyContinue } catch {}
            if ($pr) {
                try { $pr.Kill(); $killed++ } catch {}
            }
        }
    } catch {}
    return $killed
}

# Build the set of a root PID and all its descendants (by CIM parent/child walk).
# Returns a hashtable keyed by [uint32] PID. Used to scope teardown so we only
# touch processes launched by THIS launcher.
function Get-DescendantPidSet {
    param([int[]]$RootPids)
    $result = @{}
    try {
        $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        $byParent = @{}
        foreach ($p in $all) {
            $pp = [uint32]$p.ParentProcessId
            if (-not $byParent.ContainsKey($pp)) { $byParent[$pp] = @() }
            $byParent[$pp] += $p
        }
        $q = New-Object System.Collections.Queue
        foreach ($rp in $RootPids) { if ($rp -gt 0) { $q.Enqueue([uint32]$rp) } }
        while ($q.Count -gt 0) {
            $cur = [uint32]$q.Dequeue()
            if ($result.ContainsKey($cur)) { continue }
            $result[$cur] = $true
            if ($byParent.ContainsKey($cur)) {
                foreach ($child in $byParent[$cur]) { $q.Enqueue([uint32]$child.ProcessId) }
            }
        }
    } catch { }
    return $result
}

# Main teardown. Idempotent: unknown/dead PIDs are no-ops.
#
# PID-SCOPED: only stops processes launched by THIS launcher. Child PIDs are
# tracked in $global:WatcherChildren by the launcher. We tree-kill those roots
# (and their descendants) and DO NOT perform a global sweep by process name — a
# global sweep would kill a sibling launcher's watchers if two launchers ran
# close together. This is the core fix for the multi-launcher race.
function Stop-AllWatchers {
    param(
        [int[]]$RootPids = @(),
        [string]$MemtraceStatePath = '',
        [string]$RepoRoot = '',
        [int]$GrepaiPid = 0
    )
    # Backing state file written by the launcher (covers the Exiting-event
    # call path that has no script scope).
    # mcpw-ybs.2: the file is keyed by WORKSPACE so two repositories never share
    # one teardown record. VAD_WATCHERS_WORKSPACE_KEY is exported by the launcher,
    # so it is present on the Exiting path and in every child process. When the
    # variable is absent - an older launcher, or a consumer that never sourced
    # Modules\watcher_workspace.ps1 - fall back to the legacy un-keyed path rather
    # than guessing a key, because a WRONG key reads a nonexistent file and would
    # silently disable teardown instead of failing loudly.
    $wsKey = $env:VAD_WATCHERS_WORKSPACE_KEY
    if ($wsKey) {
        $stateFile = Join-Path $env:LOCALAPPDATA "watchers\$wsKey\teardown-state.json"
    } else {
        $stateFile = Join-Path $env:LOCALAPPDATA 'watchers\teardown-state.json'
    }
    if (($RootPids.Count -eq 0) -and (Test-Path -LiteralPath $stateFile)) {
        try {
            $st = Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($st.RootPids)           { $RootPids = @($st.RootPids) }
            if ($st.MemtraceStatePath)   { $MemtraceStatePath = $st.MemtraceStatePath }
            if ($st.RepoRoot)           { $RepoRoot = $st.RepoRoot }
            if ($st.GrepaiPid)          { $GrepaiPid = [int]$st.GrepaiPid }
        } catch {}
    }

    # Build the PID scope: our tracked roots and ALL their descendants. Every
    # kill below is gated on membership in this set so a sibling launcher's
    # watchers are never touched.
    $ourPids = Get-DescendantPidSet -RootPids $RootPids

    # 1) Tree-kill every tracked root (PID-scoped). This catches grandchildren
    #    such as an in-flight `graphify-rs` rebuild spawned by the wrapper powershell.
    #    Only PIDs our own launcher launched are in $RootPids, so a sibling
    #    launcher's watchers are never touched.
    # NOTE: the loop variable cannot be named `$pid` (automatic read-only var).
    foreach ($rootPid in $RootPids) {
        if ($rootPid -and $rootPid -gt 0) { Stop-WatcherTree -RootPid $rootPid | Out-Null }
    }

    # 1b) Tree-kill wrapper HOSTS by PID FIRST (before the sweep), so an
    #    in-flight graphify-rs.exe rebuild child dies WITH its host even when the
    #    host was found only by its CommandLine (not in $RootPids). The pattern
    #    sweep below also reaps rebuild children by match-all (their command line
    #    has no 'watch' token), but killing hosts first removes the race where a
    #    rebuild child survives because its host died between the snapshot and the
    #    host's own Terminate. Hosts are only tree-killed if they are in our PID
    #    scope (PID-scoped).
    if ($ourPids.Count -gt 0) {
        $wrapperHosts = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape('graphify-watch-wrapper') })
        foreach ($wh in $wrapperHosts) {
            if ($ourPids.ContainsKey([uint32]$wh.ProcessId)) {
                Stop-WatcherTree -RootPid $wh.ProcessId | Out-Null
            }
        }
    }

    # 2) Pattern sweep for any watcher binary still alive. PID-SCOPED: only
    #    match processes that are in our PID scope. This avoids killing a
    #    sibling launcher's watcher processes.
    if ($ourPids.Count -gt 0) {
        $sweeps = $script:WatcherSweepPatterns
        foreach ($s in $sweeps) {
            try {
                $ps = Get-CimInstance Win32_Process -Filter "Name = '$($s.Name)'" -ErrorAction SilentlyContinue
                foreach ($p in $ps) {
                    if (-not $ourPids.ContainsKey([uint32]$p.ProcessId)) { continue }
                    if (Test-WatcherSweepMatch -CommandLine $p.CommandLine -Pattern $s.Pattern) {
                        try { Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null } catch {}
                    }
                }
            } catch {}
        }
    }

    # 3) grepai tracked stop (best-effort; PID-SCOPED).
    # VAD-49om: do NOT call a bare `grepai watch --stop` unconditionally -- that
    # signals the grepai daemon to stop the GLOBAL watch, which would also kill a
    # SIBLING launcher's grepai watcher (two launchers racing for the same repo).
    # Only stop grepai when THIS launcher recorded its own grepai PID in the
    # teardown state and that PID is still alive and within our PID scope. The
    # name-sweep in step 2 already covers our grepai.exe via 'watch' membership,
    # so this is the authoritative graceful stop for our own grepai only.
    if ($GrepaiPid -and $GrepaiPid -gt 0) {
        $gAlive = $false
        try {
            $gp = Get-Process -Id $GrepaiPid -ErrorAction SilentlyContinue
            if ($gp) { $gAlive = $true }
        } catch {}
        if ($gAlive -and $ourPids.ContainsKey([uint32]$GrepaiPid)) {
            try { & grepai watch --stop | Out-Null } catch {}
        }
    }

    # 4) Memtrace daemon by recorded pid (scoped to root .memdb; modules-level
    #    index was removed on 2026-07-12, so the only memtrace daemon is the
    #    repo-root one launched by the watchers launcher).
    try {
        $mtState = if ($MemtraceStatePath) {
            $MemtraceStatePath
        } else {
            if ($RepoRoot) { Join-Path $RepoRoot '.memdb\daemon-state.json' } else { '' }
        }
        if ($mtState -and (Test-Path -LiteralPath $mtState)) {
            $mst = Get-Content -LiteralPath $mtState -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($mst.status -eq 'healthy' -and $mst.pid) {
                $mp = $null
                try { $mp = Get-Process -Id $mst.pid -ErrorAction SilentlyContinue } catch {}
                if ($mp) { try { $mp.Kill() } catch {} }
            }
        }
    } catch {}
}

# ===========================================================================
# mcpw-ajy (2026-09-20): orphaned memtrace host sweep
# ===========================================================================
# The mcpw-anw sweep (originally inline in the launcher) matched ONLY shell
# hosts whose command line named the npm SHIM script (memtrace.ps1). Current
# builds never invoke that shim - they launch an ABSOLUTE node.exe with
# memtrace.js - so that leak shape is invisible to it: ~46
# `node.exe ... memtrace.js start --headless --bless-workspace` orphans piled up
# one per 5-minute tick from 2026-09-19 23:19 and had to be removed by hand.
#
# The match is extended to node.exe hosts naming memtrace.js. Two conditions
# still gate every kill, and the second is a SAFETY requirement, not a nicety:
# the shared union daemon (memcore-server.exe on :50051, data dir
# C:\Users\yuni\.config\memtrace\.memdb) is a union store shared by 8
# workspaces, and killing it takes memtrace down everywhere.
#
#   1. the host's PARENT IS GONE, with a PID-reuse guard (a "parent" whose
#      creation time is LATER than the child's is a reused PID, not a parent);
#   2. the host is NOT part of a LIVE daemon tree.
#
# Condition 2 is load-bearing, and it was measured rather than assumed. On
# 2026-09-20 four `node.exe memtrace.js start --headless --workspace <manifest>`
# processes had DEAD parents yet were live members of the union daemon family
# (their parent PIDs 34376/37864/61784/66016 were all gone). A parent-gone-only
# rule would have killed all four. A daemon-tree ANCHOR is therefore:
#   * a daemon binary (memcore-server.exe / memcortex-daemon.exe / memtrace.exe),
#     or
#   * a node.exe naming memtrace.js AND carrying a real `--workspace` token -
#     the canonical union form. The leaked legacy form is `--bless-workspace`,
#     which does NOT contain the token `--workspace` (the two dashes are
#     interrupted by 'bless'), so the two forms stay distinguishable.
# A candidate is excluded when it IS an anchor, when its live parent IS an
# anchor (a daemon ancestor is necessarily that live parent), or when ANY
# descendant is an anchor: an orphaned node.exe that still owns a live daemon
# subtree IS the live daemon, and killing it is the outage this guard exists to
# prevent.
#
# All matching is done by Test-OrphanedMemtraceHostProcess, a pure function over
# a process snapshot, so it is unit-testable without spawning anything. The
# entry point additionally protects the :50051 owner (best-effort) so the
# documented invariant is enforced even if a daemon binary is renamed.

# Best-effort set of PIDs that must never be swept: every daemon binary plus the
# process currently LISTENing on the union daemon port.
function Get-MemtraceDaemonProtectedPids {
    param(
        [string[]]$DaemonNames = @('memcore-server.exe','memcortex-daemon.exe','memtrace.exe'),
        [int[]]$Ports = @(50051)
    )
    $set = @{}
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            if ($DaemonNames -contains [string]$p.Name) { $set[[int]$p.ProcessId] = $true }
        }
    } catch {}
    foreach ($port in $Ports) {
        try {
            foreach ($c in @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
                if ($c.OwningProcess) { $set[[int]$c.OwningProcess] = $true }
            }
        } catch {}
    }
    return @($set.Keys)
}

# Is this one process a member (or the root) of the shared memtrace daemon tree?
function Test-MemtraceDaemonAnchor {
    param(
        [string]$Name,
        [string]$CommandLine,
        [string[]]$DaemonNames = @('memcore-server.exe','memcortex-daemon.exe','memtrace.exe')
    )
    if ($Name -and ($DaemonNames -contains $Name)) { return $true }
    if ($Name -eq 'node.exe' -and $CommandLine -and
        ($CommandLine -match 'memtrace\.js') -and
        ($CommandLine -match '(^|\s)--workspace(\s|=|-|$)')) { return $true }
    return $false
}

# Pure matcher. Returns $true only for a host that is (1) of a host image,
# (2) whose command line names a memtrace host script, (3) whose parent is GONE
# (PID-reuse aware), and (4) that is not inside a LIVE daemon tree.
function Test-OrphanedMemtraceHostProcess {
    param(
        [Parameter(Mandatory=$true)] $Candidate,
        [object[]]$AllProcesses = @(),
        [string[]]$HostNames = @('powershell.exe','pwsh.exe','node.exe'),
        [string[]]$ShimPatterns = @('memtrace\.ps1','memtrace\.js'),
        [string[]]$DaemonNames = @('memcore-server.exe','memcortex-daemon.exe','memtrace.exe'),
        [int[]]$ProtectedPids = @(),
        [int]$SelfPid = 0
    )
    if ($null -eq $Candidate) { return $false }

    $name = [string]$Candidate.Name
    if (-not ($HostNames -contains $name)) { return $false }

    $cmd = ''
    try { $cmd = [string]$Candidate.CommandLine } catch { $cmd = '' }
    $token = $false
    foreach ($pat in $ShimPatterns) {
        if ($cmd -and ($cmd -match $pat)) { $token = $true; break }
    }
    if (-not $token) { return $false }

    $id = [int]$Candidate.ProcessId
    if ($SelfPid -gt 0 -and $id -eq $SelfPid) { return $false }
    if ($ProtectedPids -contains $id) { return $false }

    $byPid = @{}
    foreach ($p in $AllProcesses) {
        if ($null -eq $p) { continue }
        $byPid[[int]$p.ProcessId] = $p
    }

    # (4a) the candidate itself must not be a daemon-tree member.
    if (Test-MemtraceDaemonAnchor -Name $name -CommandLine $cmd -DaemonNames $DaemonNames) { return $false }

    # (1) Orphanhood is decided by the IMMEDIATE parent, with a PID-reuse guard:
    # a "parent" whose creation time is LATER than the child's is a reused PID,
    # not a parent. A live real parent also proves the candidate is not in a
    # daemon tree (a daemon ancestor would BE that live parent), so this single
    # check carries both conditions on the way up. Anything we cannot prove dead
    # fails SAFE - not an orphan, so not killed. In particular a chain that
    # breaks HIGHER up is not orphanhood: every process tree ends somewhere
    # (services.exe's parent is PID 0), and reading that as orphanhood is what
    # made an earlier revision of this function match a live launcher child.
    $ppid = [int]$Candidate.ParentProcessId
    if ($ppid -le 0) { return $false }
    if (-not $byPid.ContainsKey($ppid)) {
        $orphan = $true
    } else {
        $par = $byPid[$ppid]
        if ($ProtectedPids -contains [int]$par.ProcessId) { return $false }
        $reused = $false
        try {
            $pc = $par.CreationDate
            $cc = $Candidate.CreationDate
            if ($pc -and $cc -and ([datetime]$pc -gt [datetime]$cc)) { $reused = $true }
        } catch { $reused = $false }
        if (-not $reused) { return $false }
        $orphan = $true
    }
    if (-not $orphan) { return $false }

    # (4c) no LIVE descendant may be a daemon-tree member. This is the case that
    # protects an orphaned node.exe which is itself the daemon root.
    $childMap = @{}
    foreach ($p in $AllProcesses) {
        if ($null -eq $p) { continue }
        $pp = [int]$p.ParentProcessId
        if (-not $childMap.ContainsKey($pp)) { $childMap[$pp] = New-Object System.Collections.ArrayList }
        [void]$childMap[$pp].Add($p)
    }
    $seen = @{}
    $q = New-Object System.Collections.Queue
    $q.Enqueue($id)
    while ($q.Count -gt 0) {
        $curId = [int]$q.Dequeue()
        if ($seen.ContainsKey($curId)) { continue }
        $seen[$curId] = $true
        if (-not $childMap.ContainsKey($curId)) { continue }
        foreach ($ch in $childMap[$curId]) {
            $chId = [int]$ch.ProcessId
            if ($seen.ContainsKey($chId)) { continue }
            if ($ProtectedPids -contains $chId) { return $false }
            $chCmd = ''
            try { $chCmd = [string]$ch.CommandLine } catch { $chCmd = '' }
            if (Test-MemtraceDaemonAnchor -Name ([string]$ch.Name) -CommandLine $chCmd -DaemonNames $DaemonNames) { return $false }
            $q.Enqueue($chId)
        }
    }
    return $true
}

# Snapshot the process table (or use an injected one) and return the PIDs of
# orphaned memtrace hosts. Same public name/signature as the sweep the launcher
# used to define inline, so the launcher can drop its local copy unchanged.
function Get-OrphanedMemtraceHostPids {
    param(
        [string[]]$ShimPatterns = @('memtrace\.ps1','memtrace\.js'),
        [string[]]$HostNames = @('powershell.exe','pwsh.exe','node.exe'),
        [string[]]$DaemonNames = @('memcore-server.exe','memcortex-daemon.exe','memtrace.exe'),
        [int[]]$ProtectedPids = @(),
        [object[]]$Processes = @(),
        [int]$SelfPid = 0
    )
    $all = $Processes
    if (-not $all -or $all.Count -eq 0) {
        try { $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) } catch { $all = @() }
    }
    if (-not $all -or $all.Count -eq 0) { return @() }
    $self = $SelfPid
    if ($self -le 0) { $self = [int]$PID }

    $found = @()
    foreach ($p in $all) {
        if ($null -eq $p) { continue }
        if (Test-OrphanedMemtraceHostProcess -Candidate $p -AllProcesses $all `
                -HostNames $HostNames -ShimPatterns $ShimPatterns -DaemonNames $DaemonNames `
                -ProtectedPids $ProtectedPids -SelfPid $self) {
            $found += [int]$p.ProcessId
        }
    }
    return @($found)
}

# Reap the orphans. Adds the :50051 owner (and every daemon binary) to the
# protected set so the shared union daemon is never a victim.
function Stop-OrphanedMemtraceHosts {
    param(
        [string[]]$ShimPatterns = @('memtrace\.ps1','memtrace\.js'),
        [string[]]$HostNames = @('powershell.exe','pwsh.exe','node.exe'),
        [string[]]$DaemonNames = @('memcore-server.exe','memcortex-daemon.exe','memtrace.exe'),
        [int[]]$ProtectedPids = @(),
        [int[]]$DaemonPorts = @(50051),
        [switch]$NoPortGuard
    )
    $guard = @()
    if ($ProtectedPids) { $guard += $ProtectedPids }
    if (-not $NoPortGuard) {
        $guard += @(Get-MemtraceDaemonProtectedPids -DaemonNames $DaemonNames -Ports $DaemonPorts)
    }

    $victims = @(Get-OrphanedMemtraceHostPids -ShimPatterns $ShimPatterns -HostNames $HostNames `
        -DaemonNames $DaemonNames -ProtectedPids $guard)
    $killed = 0
    foreach ($victimPid in $victims) {
        try { Stop-Process -Id $victimPid -Force -ErrorAction SilentlyContinue; $killed++ } catch {}
    }
    if ($killed -gt 0) {
        Write-Host "mcpw-ajy: reaped $killed orphaned memtrace host(s) left by an earlier build (PIDs: $($victims -join ', '))."
    }
    return $killed
}
