# mcpw-ozm - the grepai cross-instance SPAWN RACE, and the lock gate that stops
# the spawn path retrying against a lock it cannot clear.
#
# THE BUG: 92 "grepai (PID n) exited immediately after restart" flaps. The
# freshly spawned watcher is not crashing - grepai's own single-instance guard
# refuses it:
#
#     Error: watcher is already running (PID 65534)
#
# naming a PID the supervisor never spawned (it spawned 6228, then 86624). The
# lock dir is MACHINE-GLOBAL, so a sibling launcher or a stray grepai wins the
# lock and our child exits at once; the supervisor then retried 2 s later,
# forever, 196 exits + 94 retries.
#
# WHAT THESE TESTS PIN
#
#   1. The live/stale distinction is TWO signals, not one. Liveness alone
#      misclassifies a RECYCLED PID - a .pid file naming a live process that is
#      not a grepai watcher. That is the one lock grepai can never clear itself
#      (IsProcessRunning says "alive") and that Clear-StaleLocks can never clear
#      either (Get-Process -Id succeeds too). It wedges the watcher forever.
#   2. A live watcher's lock is NEVER deleted - including a sibling
#      repository's. That is the mcpw-eud bug class.
#   3. A genuinely crashed grepai (dead PID) still yields 'spawn'. Healing is
#      not disabled - the whole point of the stale branch.
#   4. A live FOREIGN holder yields 'backoff' with a growing delay, never a
#      respawn that grepai will refuse.
#   5. *.lock files are never touched: the lock is the OS lock on the open
#      handle, not the file's existence.
#
# HOW THESE TESTS AVOID THE LIVE SYSTEM: every process question goes through the
# injectable -ProcessProbe, so no real PID is consulted and no process is
# spawned or killed. Every filesystem question goes through an explicit -LogDir
# in a temp directory, so the real machine-global
# %LOCALAPPDATA%\grepai\logs is never read, written, or swept. Do NOT add a test
# that calls these functions without -LogDir: that is the live lock dir.
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

BeforeAll {
    $script:Helpers = Join-Path $PSScriptRoot '..\Modules\watcher_job_helpers.ps1'
    if (Test-Path -LiteralPath $script:Helpers) { . $script:Helpers }

    $script:ProbeDir = Join-Path ([System.IO.Path]::GetTempPath()) "mcpw-ozm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:ProbeDir -Force | Out-Null

    $script:Mine     = 'J:\audio\MCP-Watchers'
    $script:Sibling  = 'J:\audio\VAD'

    # PIDs that exist only inside the fake process table below. Distinct values
    # so a failure message names which identity rule misfired.
    $script:LiveWatcher   = 4001   # grepai.exe ... watch        (a real holder)
    $script:LiveMcpServe  = 4002   # grepai.exe mcp-serve        (NOT a watcher)
    $script:LiveStranger  = 4003   # something.exe               (recycled PID)
    $script:DeadPid       = 4004   # absent from the table = dead

    # A process probe backed by a hashtable. .GetNewClosure() is required: a
    # bare scriptblock would resolve $Table in the CALLER's scope, where it does
    # not exist, and every lookup would silently report "dead".
    function New-FakeProbe {
        param([hashtable]$Table)
        $sb = {
            param([int]$ProcessId)
            if ($Table.ContainsKey($ProcessId)) { return [PSCustomObject]$Table[$ProcessId] }
            return $null
        }
        return $sb.GetNewClosure()
    }

    function New-LiveTable {
        return @{
            $script:LiveWatcher  = [PSCustomObject]@{ Name = 'grepai.exe'; CommandLine = '"C:\Users\yuni\AppData\Local\Programs\grepai\grepai.exe" watch' }
            $script:LiveMcpServe = [PSCustomObject]@{ Name = 'grepai.exe'; CommandLine = '"C:\Users\yuni\AppData\Local\Programs\grepai\grepai.exe" mcp-serve' }
            $script:LiveStranger = [PSCustomObject]@{ Name = 'notepad.exe'; CommandLine = 'notepad.exe C:\Temp\notes.txt' }
        }
    }

    # A probe where NOTHING is alive - every PID file is stale.
    function New-EmptyProbe {
        return (New-FakeProbe -Table @{})
    }

    function New-PidFile {
        param([string]$Name, [int]$OwnerPid)
        $p = Join-Path $script:ProbeDir $Name
        Set-Content -LiteralPath $p -Value "$OwnerPid" -Encoding ASCII
        return $p
    }

    # A worktree lock plus the sibling log that is its only ownership evidence.
    function New-WorktreeLock {
        param([string]$Id, [int]$OwnerPid, [string]$ProjectInLog = $null, [bool]$WithLog = $true)
        $pidFile = New-PidFile -Name "grepai-worktree-$Id.pid" -OwnerPid $OwnerPid
        if ($WithLog) {
            $logFile = Join-Path $script:ProbeDir "grepai-worktree-$Id.log"
            Set-Content -LiteralPath $logFile -Value "Starting grepai watch in $ProjectInLog" -Encoding ASCII
        }
        return $pidFile
    }
}

AfterAll {
    if ($script:ProbeDir -and (Test-Path -LiteralPath $script:ProbeDir)) {
        Remove-Item -LiteralPath $script:ProbeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-GrepaiPidFileStale (mcpw-ozm)' {

    It 'keeps a global PID file naming a live grepai watcher' {
        $f = New-PidFile -Name 'grepai-watch.pid' -OwnerPid $script:LiveWatcher
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-FakeProbe -Table (New-LiveTable)) | Should -BeFalse
    }

    It 'clears a global PID file naming a live NON-watcher process - the recycled PID' {
        # The crux. IsProcessRunning() only proves SOME process owns the PID.
        # Windows recycles PIDs, so grepai sees "alive" and refuses forever, and
        # Clear-StaleLocks' Get-Process -Id check also succeeds - nothing but an
        # identity check can ever clear this lock.
        $f = New-PidFile -Name 'grepai-watch.pid' -OwnerPid $script:LiveStranger
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-FakeProbe -Table (New-LiveTable)) | Should -BeTrue
    }

    It 'clears a global PID file naming a live grepai mcp-serve (not a watcher)' {
        # grepai.exe mcp-serve is a live grepai process that is NOT the watcher,
        # so it cannot be the holder of the watch lock.
        $f = New-PidFile -Name 'grepai-watch.pid' -OwnerPid $script:LiveMcpServe
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-FakeProbe -Table (New-LiveTable)) | Should -BeTrue
    }

    It 'clears a global PID file naming a dead PID - a genuinely crashed grepai' {
        $f = New-PidFile -Name 'grepai-watch.pid' -OwnerPid $script:DeadPid
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-EmptyProbe) | Should -BeTrue
    }

    It 'keeps a worktree PID file naming a live grepai watcher' {
        $f = New-WorktreeLock -Id 'ozm001' -OwnerPid $script:LiveWatcher -ProjectInLog $script:Sibling
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-FakeProbe -Table (New-LiveTable)) | Should -BeFalse
    }

    It 'clears a worktree PID file naming a dead PID' {
        $f = New-WorktreeLock -Id 'ozm002' -OwnerPid $script:DeadPid -ProjectInLog $script:Mine
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-EmptyProbe) | Should -BeTrue
    }

    It 'clears an empty PID file' {
        $f = Join-Path $script:ProbeDir 'grepai-watch.pid'
        Set-Content -LiteralPath $f -Value '' -Encoding ASCII
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-EmptyProbe) | Should -BeTrue
    }

    It 'clears an unparseable PID file' {
        $f = Join-Path $script:ProbeDir 'grepai-watch.pid'
        Set-Content -LiteralPath $f -Value 'not-a-pid' -Encoding ASCII
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-EmptyProbe) | Should -BeTrue
    }

    It 'clears a leftover .pid.tmp from an interrupted atomic write' {
        $f = Join-Path $script:ProbeDir 'grepai-worktree-ozm003.pid.tmp'
        Set-Content -LiteralPath $f -Value "$script:LiveWatcher" -Encoding ASCII
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-FakeProbe -Table (New-LiveTable)) | Should -BeTrue
    }

    It 'NEVER touches a .pid.lock - the lock is the OS lock, not the file' {
        # Deleting a .lock file achieves nothing (grepai recreates it) and
        # deleting one a live watcher holds is pure risk.
        $f = Join-Path $script:ProbeDir 'grepai-watch.pid.lock'
        Set-Content -LiteralPath $f -Value '' -Encoding ASCII
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-EmptyProbe) | Should -BeFalse

        $w = Join-Path $script:ProbeDir 'grepai-worktree-ozm004.pid.lock'
        Set-Content -LiteralPath $w -Value '' -Encoding ASCII
        Test-GrepaiPidFileStale -PidFile $w -ProcessProbe (New-EmptyProbe) | Should -BeFalse
    }

    It 'never touches an unrecognised name' {
        $f = Join-Path $script:ProbeDir 'grepai-workspace-anything.pid'
        Set-Content -LiteralPath $f -Value '1' -Encoding ASCII
        Test-GrepaiPidFileStale -PidFile $f -ProcessProbe (New-EmptyProbe) | Should -BeFalse
    }
}

Describe 'Get-GrepaiSpawnDecision (mcpw-ozm)' {

    It 'spawns when the lock dir holds no live watcher' {
        $d = Join-Path $script:ProbeDir 'empty'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-EmptyProbe)
        $dec.Action | Should -Be 'spawn'
        $dec.DelaySeconds | Should -Be 0
        $dec.BlockerPid | Should -Be 0
    }

    It 'spawns when the only lock is a stale PID file - a crashed grepai still heals' {
        # The conservative requirement: do not disable healing.
        $d = Join-Path $script:ProbeDir 'stale'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'grepai-worktree-ozm010.pid') -Value "$script:DeadPid" -Encoding ASCII
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-EmptyProbe)
        $dec.Action | Should -Be 'spawn'
    }

    It 'BACKS OFF instead of spawning when a live foreign watcher holds the global lock' {
        # The 92-flap case: our worktree PID file is absent, so runWatch falls
        # back to the machine-global grepai-watch.pid, finds a live watcher from
        # a DIFFERENT repository, and refuses with a PID we never spawned.
        $d = Join-Path $script:ProbeDir 'foreignglobal'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'grepai-watch.pid') -Value "$script:LiveWatcher" -Encoding ASCII
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-FakeProbe -Table (New-LiveTable))
        $dec.Action | Should -Be 'backoff'
        $dec.BlockerPid | Should -Be $script:LiveWatcher
        $dec.DelaySeconds | Should -BeGreaterThan 0
    }

    It 'BACKS OFF rather than adopting a foreign worktree watcher' {
        # Adoption is deliberately withheld: tracking a foreign PID would make
        # this supervisor reap someone else's watcher on teardown.
        $d = Join-Path $script:ProbeDir 'foreignworktree'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'grepai-worktree-ozm011.pid') -Value "$script:LiveWatcher" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $d 'grepai-worktree-ozm011.log') -Value "Starting grepai watch in $script:Sibling" -Encoding ASCII
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-FakeProbe -Table (New-LiveTable))
        $dec.Action | Should -Be 'backoff'
    }

    It 'BACKS OFF when the live holder cannot be attributed at all' {
        # A worktree PID file with no sibling log carries no ownership evidence,
        # so it is neither ours to adopt nor safe to delete.
        $d = Join-Path $script:ProbeDir 'unattributable'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'grepai-worktree-ozm012.pid') -Value "$script:LiveWatcher" -Encoding ASCII
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-FakeProbe -Table (New-LiveTable))
        $dec.Action | Should -Be 'backoff'
    }

    It 'ADOPTS a live watcher holding OUR worktree lock' {
        $d = Join-Path $script:ProbeDir 'ours'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'grepai-worktree-ozm013.pid') -Value "$script:LiveWatcher" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $d 'grepai-worktree-ozm013.log') -Value "Starting grepai watch in $script:Mine" -Encoding ASCII
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-FakeProbe -Table (New-LiveTable))
        $dec.Action | Should -Be 'adopt'
        $dec.BlockerPid | Should -Be $script:LiveWatcher
        $dec.DelaySeconds | Should -Be 0
    }

    It 'reports the HOLDER PID, never a PID the caller would have spawned' {
        # The evidence: the supervisor spawned 6228 then 86624, and grepai named
        # 65534. The decision must surface the blocker, not the attempt.
        $d = Join-Path $script:ProbeDir 'blockerpid'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'grepai-watch.pid') -Value '65534' -Encoding ASCII
        $table = New-LiveTable
        $table[65534] = [PSCustomObject]@{ Name = 'grepai.exe'; CommandLine = '"C:\Users\yuni\AppData\Local\Programs\grepai\grepai.exe" watch' }
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-FakeProbe -Table $table)
        $dec.Action | Should -Be 'backoff'
        $dec.BlockerPid | Should -Be 65534
        $dec.BlockerPath | Should -Match 'grepai-watch\.pid$'
    }

    It 'spawns when the log dir does not exist' {
        $d = Join-Path $script:ProbeDir 'no-such-dir-ozm'
        $dec = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-EmptyProbe)
        $dec.Action | Should -Be 'spawn'
    }

    It 'is pure - it never deletes a lock' {
        $d = Join-Path $script:ProbeDir 'pure'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $f = Join-Path $d 'grepai-watch.pid'
        Set-Content -LiteralPath $f -Value "$script:DeadPid" -Encoding ASCII
        $null = Get-GrepaiSpawnDecision -LogDir $d -ProjectRoot $script:Mine -ProcessProbe (New-EmptyProbe)
        Test-Path -LiteralPath $f | Should -BeTrue
    }
}

Describe 'Get-GrepaiSpawnBackoffSeconds (mcpw-ozm)' {

    It 'waits the base delay on the first block' {
        Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 1 | Should -Be 15
    }

    It 'grows the delay for consecutive blocks' {
        # Retrying every few seconds cannot clear a lock a live process holds -
        # that churn is the bug. The wait has to become real.
        $d2 = Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 2
        $d3 = Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 3
        $d4 = Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 4
        $d2 | Should -Be 30
        $d3 | Should -Be 60
        $d4 | Should -Be 120
        $d2 | Should -BeGreaterThan (Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 1)
        $d3 | Should -BeGreaterThan $d2
    }

    It 'caps the delay so healing stays responsive when the holder exits' {
        Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 20 -MaxSeconds 600 | Should -Be 600
    }

    It 'clamps nonsense input instead of returning a zero wait' {
        Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 0 | Should -Be 15
        Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 3 -BaseSeconds 0 | Should -Be 60
        Get-GrepaiSpawnBackoffSeconds -ConsecutiveBlocked 9 -BaseSeconds 30 -MaxSeconds 10 | Should -Be 30
    }
}

Describe 'Clear-StaleGrepaiSpawnLocks (mcpw-ozm)' {

    It 'removes the stale locks and leaves the live ones' {
        $d = Join-Path $script:ProbeDir 'sweep'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $staleGlobal = Join-Path $d 'grepai-watch.pid'
        Set-Content -LiteralPath $staleGlobal -Value "$script:DeadPid" -Encoding ASCII
        $recycled = Join-Path $d 'grepai-worktree-ozm020.pid'
        Set-Content -LiteralPath $recycled -Value "$script:LiveStranger" -Encoding ASCII
        $live = Join-Path $d 'grepai-worktree-ozm021.pid'
        Set-Content -LiteralPath $live -Value "$script:LiveWatcher" -Encoding ASCII

        $removed = @(Clear-StaleGrepaiSpawnLocks -LogDir $d -ProcessProbe (New-FakeProbe -Table (New-LiveTable)))

        Test-Path -LiteralPath $staleGlobal | Should -BeFalse
        Test-Path -LiteralPath $recycled    | Should -BeFalse
        Test-Path -LiteralPath $live        | Should -BeTrue
        $removed.Count | Should -Be 2
    }

    It 'never deletes a .pid.lock or an unrecognised marker' {
        $d = Join-Path $script:ProbeDir 'sweep-lock'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $lock = Join-Path $d 'grepai-watch.pid.lock'
        Set-Content -LiteralPath $lock -Value '' -Encoding ASCII
        $stop = Join-Path $d "grepai-stop-$script:DeadPid"
        Set-Content -LiteralPath $stop -Value "$script:DeadPid" -Encoding ASCII

        $null = Clear-StaleGrepaiSpawnLocks -LogDir $d -ProcessProbe (New-EmptyProbe)

        Test-Path -LiteralPath $lock | Should -BeTrue
        Test-Path -LiteralPath $stop | Should -BeTrue
    }

    It 'removes a leftover .pid.tmp' {
        $d = Join-Path $script:ProbeDir 'sweep-tmp'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $tmp = Join-Path $d 'grepai-worktree-ozm022.pid.tmp'
        Set-Content -LiteralPath $tmp -Value "$script:LiveWatcher" -Encoding ASCII
        $null = Clear-StaleGrepaiSpawnLocks -LogDir $d -ProcessProbe (New-FakeProbe -Table (New-LiveTable))
        Test-Path -LiteralPath $tmp | Should -BeFalse
    }

    It 'returns nothing for a missing log dir' {
        $removed = @(Clear-StaleGrepaiSpawnLocks -LogDir (Join-Path $script:ProbeDir 'no-such-dir-ozm2') -ProcessProbe (New-EmptyProbe))
        $removed.Count | Should -Be 0
    }
}

Describe 'Get-GrepaiLogDir (mcpw-ozm)' {

    It 'honours an explicit dir so tests never touch the machine-global one' {
        Get-GrepaiLogDir -LogDir 'C:\Temp\somewhere' | Should -Be 'C:\Temp\somewhere'
    }

    It 'defaults to the machine-global grepai log dir' {
        Get-GrepaiLogDir | Should -Be (Join-Path $env:LOCALAPPDATA 'grepai\logs')
    }
}
