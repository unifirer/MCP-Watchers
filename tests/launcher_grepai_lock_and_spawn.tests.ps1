# mcpw-0zj — regression tests for the mcpw-eud / mcpw-0on fixes.
#
# Both fixes landed in commit 3bc8309 with no test coverage at all: a grep across
# tests/ found zero references to either function. This suite proves the two
# behaviours those commits claim, so they cannot silently regress.
#
#   mcpw-eud  Test-GrepaiLockStale  gates Clear-StaleLocks. %LOCALAPPDATA%\grepai\logs
#             is MACHINE-GLOBAL: every repo on this box writes there. The old
#             sweep deleted every match, so a heal in repo A destroyed repo B's
#             LIVE lock. The critical case below is the sibling-repo one.
#   mcpw-0on  Get-GrepaiSpawnLogPair gives every respawn attempt its own
#             redirect pair, so no two grepai children ever share a target.
#
# WHY Clear-StaleLocks ITSELF IS NOT CALLED HERE: it sweeps the real, machine-global
# %LOCALAPPDATA%\grepai\logs. Invoking it from a test would delete the LIVE locks of
# whichever watchers are running on this box - i.e. reproduce the very outage this
# suite exists to prevent. Test-GrepaiLockStale is the gate that decides removal, so
# testing the gate proves the sweep cannot over-delete.
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

BeforeAll {
    $script:Helpers = Join-Path $PSScriptRoot '..\Modules\watcher_job_helpers.ps1'
    if (Test-Path -LiteralPath $script:Helpers) { . $script:Helpers }

    $script:ProbeDir = Join-Path ([System.IO.Path]::GetTempPath()) "mcpw-0zj-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:ProbeDir -Force | Out-Null

    $script:Mine     = 'J:\audio\MCP-Watchers'
    $script:Siblings = 'J:\audio\VAD'

    # A worktree lock plus its sibling log. The log's first line is the only
    # ownership evidence a worktree lock carries (they hold no project key).
    function New-WorktreeLock {
        param([string]$Id, [string]$ProjectInLog, [bool]$WithLog = $true)
        $pidFile = Join-Path $script:ProbeDir "grepai-worktree-$Id.pid"
        Set-Content -LiteralPath $pidFile -Value '12345' -Encoding ASCII
        if ($WithLog) {
            $logFile = Join-Path $script:ProbeDir "grepai-worktree-$Id.log"
            Set-Content -LiteralPath $logFile -Value "Starting grepai watch in $ProjectInLog" -Encoding ASCII
        }
        return $pidFile
    }

    # A PID no process on this box can own. Scans down from the top of the PID
    # space rather than spawning a process, so the test needs no child process.
    function Get-UnusedPid {
        $candidate = 999999
        while ($candidate -gt 100000) {
            if (-not (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { return $candidate }
            $candidate--
        }
        return $candidate
    }
}

AfterAll {
    if ($script:ProbeDir -and (Test-Path -LiteralPath $script:ProbeDir)) {
        Remove-Item -LiteralPath $script:ProbeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-GrepaiLockStale (mcpw-eud)' {

    It 'keeps a grepai-stop marker whose owner PID is still alive' {
        # $PID is this PowerShell process - definitely running, so the owner is
        # alive and the marker must survive. Deleting it is the mcpw-eud bug.
        $marker = Join-Path $script:ProbeDir "grepai-stop-$PID"
        Set-Content -LiteralPath $marker -Value "$PID" -Encoding ASCII
        Test-GrepaiLockStale -LockFile $marker -ProjectRoot $script:Mine | Should -BeFalse
    }

    It 'removes a grepai-stop marker whose owner PID is gone' {
        $marker = Join-Path $script:ProbeDir "grepai-stop-$(Get-UnusedPid)"
        Set-Content -LiteralPath $marker -Value '0' -Encoding ASCII
        Test-GrepaiLockStale -LockFile $marker -ProjectRoot $script:Mine | Should -BeTrue
    }

    It 'removes our own worktree lock when its sibling log names this project' {
        $lock = New-WorktreeLock -Id 'mine01' -ProjectInLog $script:Mine
        Test-GrepaiLockStale -LockFile $lock -ProjectRoot $script:Mine | Should -BeTrue
    }

    It 'KEEPS a sibling repository worktree lock - the mcpw-eud bug itself' {
        # The lock dir is shared by every repo. This lock belongs to a DIFFERENT
        # repository with a LIVE watcher. Removing it let that repo be launched a
        # second time against a lock it believed was clear.
        $lock = New-WorktreeLock -Id 'sib01' -ProjectInLog $script:Siblings
        Test-GrepaiLockStale -LockFile $lock -ProjectRoot $script:Mine | Should -BeFalse
    }

    It 'keeps a worktree lock whose sibling log is missing' {
        # No log means no ownership evidence at all - unattributable, so keep it.
        $lock = New-WorktreeLock -Id 'nolog1' -ProjectInLog $script:Mine -WithLog $false
        Test-GrepaiLockStale -LockFile $lock -ProjectRoot $script:Mine | Should -BeFalse
    }

    It 'keeps an unrecognised marker shape' {
        $other = Join-Path $script:ProbeDir 'something-else-99.pid'
        Set-Content -LiteralPath $other -Value '0' -Encoding ASCII
        Test-GrepaiLockStale -LockFile $other -ProjectRoot $script:Mine | Should -BeFalse
    }

    It 'keeps everything when ProjectRoot is empty' {
        # No project root means ownership cannot be established for ANY shape.
        $lock = New-WorktreeLock -Id 'noroot1' -ProjectInLog $script:Mine
        Test-GrepaiLockStale -LockFile $lock -ProjectRoot '' | Should -BeFalse
    }
}

Describe 'Get-GrepaiSpawnLogPair (mcpw-0on)' {

    It 'gives attempt 1 the canonical pair the pane tailer watches' {
        $pair = Get-GrepaiSpawnLogPair -LogPath 'C:\logs\grepai-launch.log' -ErrPath 'C:\logs\grepai-launch.err' -Attempt 1
        $pair.Log | Should -Be 'C:\logs\grepai-launch.log'
        $pair.Err | Should -Be 'C:\logs\grepai-launch.err'
    }

    It 'gives every later attempt its own suffixed pair' {
        $pair = Get-GrepaiSpawnLogPair -LogPath 'C:\logs\grepai-launch.log' -ErrPath 'C:\logs\grepai-launch.err' -Attempt 3
        $pair.Log | Should -Be 'C:\logs\grepai-launch.log.attempt3'
        $pair.Err | Should -Be 'C:\logs\grepai-launch.err.attempt3'
    }

    It 'never lets two attempts share a redirect target' {
        # Start-Process -RedirectStandardOutput truncates its target and holds the
        # handle for the child's lifetime, so a shared target means a sharing
        # violation or two children interleaved into one unreadable log.
        $targets = @()
        foreach ($n in 1..5) {
            $p = Get-GrepaiSpawnLogPair -LogPath 'C:\logs\grepai-launch.log' -ErrPath 'C:\logs\grepai-launch.err' -Attempt $n
            $targets += $p.Log
            $targets += $p.Err
        }
        ($targets | Select-Object -Unique).Count | Should -Be $targets.Count
    }

    It 'treats attempt 0 and negative attempts as attempt 1' {
        # Defensive: a caller that never sets -Attempt must still get the
        # canonical pair, not a ".attempt0" file nothing tails.
        $a = Get-GrepaiSpawnLogPair -LogPath 'C:\logs\l.log' -ErrPath 'C:\logs\l.err' -Attempt 0
        $b = Get-GrepaiSpawnLogPair -LogPath 'C:\logs\l.log' -ErrPath 'C:\logs\l.err' -Attempt -2
        $a.Log | Should -Be 'C:\logs\l.log'
        $b.Log | Should -Be 'C:\logs\l.log'
    }
}

Describe 'Test-GrepaiLockStale drift guard (mcpw-0zj)' {

    It 'the pane-script copy and the shared copy have the same body' {
        # The generated pane script dot-sources nothing by design, so it carries
        # its own copy of this function. Two hand-synced copies drifted once
        # before (VAD-v14z.5: the supervisor's missing copy caused the 2026-08-26
        # crash-restart loop). This asserts the bodies still match, so drift
        # fails a test instead of waiting for an outage.
        $shared = Join-Path $PSScriptRoot '..\Modules\watcher_job_helpers.ps1'
        $pane   = Join-Path $PSScriptRoot '..\Modules\watcher_pane_scripts.ps1'

        function Get-LockStaleBody {
            param([string]$Path)
            $body = @()
            $started = $false
            $depth = 0
            foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
                if (-not $started) {
                    if ($line -match 'function\s+Test-GrepaiLockStale') {
                        $started = $true
                        $depth = 1
                    }
                    continue
                }
                $depth += ([regex]::Matches($line, '\{')).Count
                $depth -= ([regex]::Matches($line, '\}')).Count
                if ($depth -le 0) { break }
                # Normalise: indentation differs (the pane copy is nested) and
                # comments differ by design, so compare code lines only.
                $t = $line.Trim()
                if ($t -and -not $t.StartsWith('#')) { $body += $t }
            }
            return ($body -join "`n")
        }

        $sharedBody = Get-LockStaleBody -Path $shared
        $paneBody   = Get-LockStaleBody -Path $pane

        $sharedBody | Should -Not -BeNullOrEmpty
        $paneBody   | Should -Not -BeNullOrEmpty
        $paneBody   | Should -BeExactly $sharedBody
    }
}
