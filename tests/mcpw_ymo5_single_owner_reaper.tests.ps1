# tests/mcpw_ymo5_single_owner_reaper.tests.ps1
# Bead mcpw-ymo.5 (parent epic mcpw-ymo): regression test - a single healthy
# mail backend must never be reaped.
#
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/mcpw_ymo5_single_owner_reaper.tests.ps1
#
# WHY THIS EXISTS. Between 2026-09-15 and 09-22 the :8765 mail backend logged
# 9,657 relaunches / 4,624 'reaped duplicate mail PID' events because TWO
# starters coexisted. The periodic duplicate reaper in
# $backendSupervisorScript is the last-resort safety net for that class of bug.
# The invariant it must never violate (###1...ps1, SINGLE-OWNER INVARIANT
# block, ~:5115) is:
#
#   "the periodic duplicate reaper ... must never terminate a process it
#    cannot PROVE is redundant (one that is not the confirmed :Port listener).
#    An unidentified owner means SKIP, never guess."
#
# This suite locks that with three facts:
#   * a single healthy :8765 listener is never reaped;
#   * an unidentifiable owner is SKIPPED, not killed;
#   * a genuine duplicate IS still reaped (so the suite cannot pass by turning
#     the reaper into a no-op).
#
# HOW IT TESTS WITHOUT TOUCHING A REAL PROCESS. The reaper is inline inside the
# backend supervisor scriptblock, so this suite extracts its source text
# VERBATIM from the launcher (anchored between `$backendSupervisorScript = {`
# and `$script:mailSupJob`) and runs it in a child powershell.exe where the only
# I/O it touches is stubbed:
#   Get-CimInstance / Get-NetTCPConnection  -> a synthetic process table
#   Invoke-CimMethod (Terminate)            -> records the PID, kills nothing
# No real python.exe / node.exe is enumerated or terminated. The child never
# binds :8765 and never starts a second mail backend.
#
# Pester 3.4.0 pinned (v3 positional `Should Match` / `Should Be` idiom). A
# *.tests.ps1 that itself calls Invoke-Pester loops forever under Pester 3.x
# rediscovery, so the run at the bottom is guarded by *_TEST_RAN.

Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
# MCPW_YMO5_LAUNCHER exists only so a scratch COPY of the launcher can be run
# through this suite to prove the suite is not vacuous (a deliberately broken
# reaper must make the relevant It fail). Normal runs use the real launcher.
$launcher = if ($env:MCPW_YMO5_LAUNCHER) {
    $env:MCPW_YMO5_LAUNCHER
} else {
    Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
}
$launcherSrc = Get-Content -LiteralPath $launcher -Raw

# ---------------------------------------------------------------------------
# Extract the reap block VERBATIM. Anchors mirror tests/backend_sweep_safety
# .tests.ps1 (the supervisor block is delimited by its assignment and the first
# Start-BackendSupervisor call); the reap pass itself is the `$supLoop % 4`
# guard, which ends where the loop's next statement (`Start-Sleep $sleepSec`)
# begins. Returns '' when an anchor is missing so the suite fails per-test with
# a readable diagnostic instead of aborting at load time.
# ---------------------------------------------------------------------------
function Get-ReapBlock([string]$src) {
    $bStart = $src.IndexOf('$backendSupervisorScript = {')
    if ($bStart -lt 0) { return '' }
    $bEnd = $src.IndexOf('$script:mailSupJob', $bStart)
    if ($bEnd -le $bStart) { return '' }
    $sup = $src.Substring($bStart, $bEnd - $bStart)
    $rStart = $sup.IndexOf('if (($supLoop % 4) -eq 0) {')
    if ($rStart -lt 0) { return '' }
    $rEnd = $sup.IndexOf('Start-Sleep $sleepSec', $rStart)
    if ($rEnd -le $rStart) { return '' }
    return $sup.Substring($rStart, $rEnd - $rStart)
}
$reapBlock = Get-ReapBlock $launcherSrc

# ---------------------------------------------------------------------------
# Behavioural harness. Runs the verbatim reap block against a synthetic world
# and returns the PIDs it terminated (as int[]). Every process table, port
# owner and relaunch parameter is supplied here; the block's own CIM/TCP calls
# are shadowed by stub functions, so nothing on the real machine is read or
# killed.
#
# FIXTURE RULE: every synthetic process carries a NON-ZERO ParentProcessId
# (1000 - a shared, unrelated parent, i.e. the two matches are siblings). A
# Parent of 0 is a trap: when the keeper is unresolved the block computes
# `[uint32]$null.ProcessId` = 0, and any candidate whose Parent is also 0 would
# be misread as kin of the keeper and silently skipped. Real processes have a
# non-zero parent, so 0 is never a faithful fixture.
# ---------------------------------------------------------------------------
function Invoke-ReapCase {
    param(
        [object[]]$Processes,        # @{ Id; Parent; AgeSec }
        [int[]]  $OwnerPids,         # PIDs confirmed LISTENING on :8765
        [int]    $RelaunchPid = 0,   # the PID the supervisor just started (0 = none)
        [int]    $RelaunchAgeSec = -1
    )
    $rows = @()
    foreach ($p in $Processes) {
        $rows += ('    @{ ProcessId = ' + [int]$p.Id + '; ParentProcessId = ' + [int]$p.Parent + '; AgeSec = ' + [int]$p.AgeSec + ' }')
    }
    $procTable = ($rows -join ",`r`n")
    $owners = ($OwnerPids -join ', ')
    if ($RelaunchPid -gt 0) { $relaunchAt = ('$now.AddSeconds(-1 * ' + [int]$RelaunchAgeSec + ')') }
    else { $relaunchAt = '[datetime]::MinValue' }

    $tmp = Join-Path $env:TEMP ('ymo5_reap_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $resultFile = Join-Path $tmp 'result.txt'

    $harness = @'
$ErrorActionPreference = 'Stop'
$now = Get-Date
$procTable = @(
__PROCTABLE__
)
$ownerPids = @(__OWNERS__)

$script:terminated = New-Object System.Collections.ArrayList
function Write-BackendSupLog { param([string]$Msg) }
function Get-CimInstance {
    [CmdletBinding()]
    param($ClassName, $Filter)
    $all = @()
    foreach ($p in $procTable) {
        $all += [pscustomobject]@{
            ProcessId       = [uint32]$p.ProcessId
            ParentProcessId = [uint32]$p.ParentProcessId
            CommandLine     = 'C:\Python311\python.exe -m mcp_agent_mail.cli --port 8765'
            CreationDate    = $now.AddSeconds(-1 * [double]$p.AgeSec)
        }
    }
    return $all
}
function Get-NetTCPConnection {
    [CmdletBinding()]
    param($LocalPort, $State)
    $r = @()
    foreach ($op in $ownerPids) { $r += [pscustomobject]@{ OwningProcess = [uint32]$op } }
    return $r
}
function Invoke-CimMethod {
    [CmdletBinding()]
    param($InputObject, $MethodName)
    [void]$script:terminated.Add([int]$InputObject.ProcessId)
    return [pscustomobject]@{ ReturnValue = 0 }
}

$BackendName     = 'mail'
$Port            = 8765
$supLoop         = 4
$startupGraceSec = 90
$relaunchPid     = __RELAUNCHPID__
$relaunchAt      = __RELAUNCHAT__

# ---- PRODUCTION REAP BLOCK (verbatim from the launcher) ----
__REAPBLOCK__

($script:terminated -join ',') | Set-Content -LiteralPath '__RESULT__' -Encoding ASCII
'@
    $harness = $harness.Replace('__PROCTABLE__', $procTable)
    $harness = $harness.Replace('__OWNERS__', $owners)
    $harness = $harness.Replace('__RELAUNCHPID__', [string]$RelaunchPid)
    $harness = $harness.Replace('__RELAUNCHAT__', $relaunchAt)
    $harness = $harness.Replace('__REAPBLOCK__', $reapBlock)
    $harness = $harness.Replace('__RESULT__', $resultFile)

    $hScript = Join-Path $tmp 'case.ps1'
    Set-Content -LiteralPath $hScript -Value $harness -Encoding utf8
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hScript) `
            -WindowStyle Hidden -Wait -PassThru `
            -RedirectStandardOutput ($hScript + '.out') -RedirectStandardError ($hScript + '.err') | Out-Null
        if (-not (Test-Path -LiteralPath $resultFile)) {
            $err = (Get-Content -LiteralPath ($hScript + '.err') -Raw -ErrorAction SilentlyContinue)
            return @('HARNESS-DIED: ' + [string]$err)
        }
        $raw = (Get-Content -LiteralPath $resultFile -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw.Trim() -split ',' | ForEach-Object { [int]$_ })
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'mcpw-ymo.5: the periodic duplicate reaper never reaps a healthy mail backend' {

    # --- the invariant is still wired where the tests look for it ----------
    It 'launcher still carries the SINGLE-OWNER INVARIANT and the owner-identified SKIP guard' {
        $launcherSrc | Should Match 'SINGLE-OWNER INVARIANT'
        $launcherSrc | Should Match ([regex]::Escape('An unidentified owner means SKIP, never guess'))
        # The keeper must be the confirmed :Port listener; with no such match the
        # pass logs a SKIP and terminates nothing.
        $launcherSrc | Should Match ([regex]::Escape('reap SKIPPED - owner identified: no'))
        $launcherSrc | Should Match ([regex]::Escape('$dups.Count -gt 1'))
    }

    # --- extraction integrity: an empty block must never look like a pass ---
    It 'the extracted reap block is the real decision, not an empty string' {
        ($reapBlock.Length -gt 0) | Should Be $true
        $reapBlock | Should Match 'Invoke-CimMethod'
        $reapBlock | Should Match 'reap SKIPPED - owner identified: no'
        $reapBlock | Should Match 'owner of :\$Port'
    }

    # --- CORE ASSERTION: one healthy backend, never reaped -----------------
    It 'a single healthy :8765 listener (one token match owning the port) is never reaped' {
        # One python.exe matching 'mcp_agent_mail', and it owns :8765.
        $killed = Invoke-ReapCase -Processes @(
            @{ Id = 4101; Parent = 1000; AgeSec = 600 }
        ) -OwnerPids @(4101)
        @($killed).Count | Should Be 0
    }

    # --- the mcpw-ymo.3 flap scenario: owner + a fresh relaunch in grace ----
    It 'a confirmed owner plus a fresh relaunch inside the grace window reaps nothing' {
        # Owner on :8765 (old), plus a 5s-old relaunch that has not bound yet.
        $killed = Invoke-ReapCase -Processes @(
            @{ Id = 4201; Parent = 1000; AgeSec = 3600 },
            @{ Id = 4202; Parent = 1000; AgeSec = 5 }
        ) -OwnerPids @(4201)
        @($killed).Count | Should Be 0
    }

    # --- unidentifiable owner: SKIP, never guess ---------------------------
    It 'no confirmed :8765 owner => SKIP, nothing reaped' {
        # Two token matches, but the listener PID (9999) is neither of them, so
        # redundancy is UNPROVEN. The old 'oldest wins' fallback killed here.
        $killed = Invoke-ReapCase -Processes @(
            @{ Id = 4301; Parent = 1000; AgeSec = 3600 },
            @{ Id = 4302; Parent = 1000; AgeSec = 3600 }
        ) -OwnerPids @(9999)
        @($killed).Count | Should Be 0
    }

    # --- anti-no-op: a genuine duplicate IS still reaped -------------------
    It 'a genuine duplicate outside the grace window IS reaped (exactly one, the non-owner)' {
        # Owner 4401 holds :8765; 4402 is an unrelated long-lived sibling (not a
        # child of the owner, so not kin) and is the only reapable candidate.
        $killed = Invoke-ReapCase -Processes @(
            @{ Id = 4401; Parent = 1000; AgeSec = 3600 },
            @{ Id = 4402; Parent = 1000; AgeSec = 3600 }
        ) -OwnerPids @(4401)
        @($killed).Count | Should Be 1
        ($killed -join ',') | Should Be '4402'
    }

    # --- the relaunch-PID exemption, isolated from the age exemption -------
    It 'our own just-relaunched PID is spared while its relaunch is inside the grace window' {
        # The candidate's process age is OUTSIDE the grace window on purpose, so
        # only the explicit $relaunchPid exemption can spare it.
        $killed = Invoke-ReapCase -Processes @(
            @{ Id = 4501; Parent = 1000; AgeSec = 3600 },
            @{ Id = 4502; Parent = 1000; AgeSec = 3600 }
        ) -OwnerPids @(4501) -RelaunchPid 4502 -RelaunchAgeSec 5
        @($killed).Count | Should Be 0
    }

    # --- and once that relaunch is stale, it is reapable again ------------
    It 'the same relaunch PID is reaped once its relaunch leaves the grace window' {
        $killed = Invoke-ReapCase -Processes @(
            @{ Id = 4601; Parent = 1000; AgeSec = 3600 },
            @{ Id = 4602; Parent = 1000; AgeSec = 3600 }
        ) -OwnerPids @(4601) -RelaunchPid 4602 -RelaunchAgeSec 3600
        @($killed).Count | Should Be 1
        ($killed -join ',') | Should Be '4602'
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard with
# an env var so the rediscovery child skips the second Invoke-Pester. -Path keeps
# the run scoped to THIS file (no cross-file contamination).
if (-not $env:MCPW_YMO5_REAPER_TEST_RAN) {
    $env:MCPW_YMO5_REAPER_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
