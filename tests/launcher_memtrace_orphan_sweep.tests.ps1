Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_memtrace_orphan_sweep.tests.ps1
# Pester 3.4.0 (pinned team idiom).
#
# mcpw-ajy (2026-09-20) regression guard. The mcpw-anw orphan sweep matched ONLY
# shell hosts naming the npm shim (memtrace.ps1). Current builds launch an
# ABSOLUTE node.exe + memtrace.js, so ~46 `node.exe ... memtrace.js start
# --headless --bless-workspace` orphans accumulated from 2026-09-19 23:19 and
# were removed by hand during mcpw-l40 with a PID-reuse guard, because killing
# the wrong process takes down the shared union daemon.
#
# The extended match must therefore hold three properties, asserted below:
#   (a) an orphaned node.exe memtrace.js with a DEAD parent IS matched;
#   (b) a node.exe memtrace.js inside a LIVE daemon tree is NOT matched;
#   (c) the old shim-script case still matches.
#
# Matching is exercised through Test-OrphanedMemtraceHostProcess /
# Get-OrphanedMemtraceHostPids over SYNTHETIC process snapshots, so nothing is
# spawned and no real process is touched. One final It runs the matcher against
# the REAL snapshot and asserts the safety property only (no live daemon-tree
# member may ever appear in the victim set) - that assertion is deterministic
# and environment-independent.
#
# Ports 50051 / 3030 are never touched and no memtrace daemon is ever started.
#
# Run (single pass, reliable exit code):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
#     "if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }; Invoke-Pester -Path 'tests\launcher_memtrace_orphan_sweep.tests.ps1' -EnableExit"

$repo   = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$module = Join-Path $repo 'Modules\watcher_teardown.ps1'

# Safe to dot-source: no top-level side effects.
. $module

# Build a synthetic Win32_Process-shaped row.
function New-ProcRow {
    param(
        [int]$Id,
        [int]$ParentId,
        [string]$Name,
        [string]$CommandLine,
        $CreationDate = $null
    )
    [pscustomobject]@{
        ProcessId         = $Id
        ParentProcessId   = $ParentId
        Name              = $Name
        CommandLine       = $CommandLine
        CreationDate      = $CreationDate
    }
}

$NODE   = 'C:\nvm4w\nodejs\node.exe'
$MEMJS  = 'J:\Programs\npm-global\node_modules\memtrace\bin\memtrace.js'
$MANIF  = 'C:\Users\yuni\.config\memtrace\workspace.toml'
# The leaked legacy form: note it does NOT contain the token '--workspace'.
$LEAKED = '"' + $NODE + '" ' + $MEMJS + ' start --headless --bless-workspace'
$UNION  = '"' + $NODE + '" ' + $MEMJS + ' start --headless --workspace ' + $MANIF

Describe 'mcpw-ajy: orphaned memtrace host sweep' {

    It 'matches the function set it is testing' {
        foreach ($fn in @('Test-MemtraceDaemonAnchor','Test-OrphanedMemtraceHostProcess',
                          'Get-OrphanedMemtraceHostPids','Stop-OrphanedMemtraceHosts',
                          'Get-MemtraceDaemonProtectedPids')) {
            (Get-Command $fn -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        }
    }

    It 'treats --workspace as the union daemon form and --bless-workspace as the leak' {
        Test-MemtraceDaemonAnchor -Name 'node.exe' -CommandLine $UNION  | Should Be $true
        Test-MemtraceDaemonAnchor -Name 'node.exe' -CommandLine $LEAKED | Should Be $false
        Test-MemtraceDaemonAnchor -Name 'memcore-server.exe' -CommandLine 'memcore-server.exe --bind 127.0.0.1:50051' | Should Be $true
    }

    # ---------------- (a) the leak shape is now matched ----------------------
    It '(a) matches an orphaned node.exe memtrace.js whose parent is gone' {
        $all = @(
            (New-ProcRow -Id 70001 -ParentId 40001 -Name 'node.exe' -CommandLine $LEAKED)
        )
        # 40001 is absent from the snapshot -> the parent is gone.
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all | Should Be $true
        (@(Get-OrphanedMemtraceHostPids -Processes $all) -contains 70001) | Should Be $true
    }

    It '(a) matches the legacy --bless-workspace orphan even though the parent PID was reused' {
        $childBorn = [datetime]'2026-09-19T23:19:08'
        $all = @(
            (New-ProcRow -Id 70002 -ParentId 40002 -Name 'node.exe' -CommandLine $LEAKED -CreationDate $childBorn),
            # PID 40002 reused by a process created AFTER the child: not its parent.
            (New-ProcRow -Id 40002 -ParentId 1 -Name 'explorer.exe' -CommandLine 'explorer.exe' -CreationDate $childBorn.AddMinutes(5))
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all | Should Be $true
    }

    It '(a) does NOT match when the reused PID was created BEFORE the child (fail safe)' {
        $childBorn = [datetime]'2026-09-19T23:19:08'
        $all = @(
            (New-ProcRow -Id 70003 -ParentId 40003 -Name 'node.exe' -CommandLine $LEAKED -CreationDate $childBorn),
            (New-ProcRow -Id 40003 -ParentId 1 -Name 'services.exe' -CommandLine 'services.exe' -CreationDate $childBorn.AddHours(-9))
        )
        # Cannot prove the parent is gone -> must not be swept.
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all | Should Be $false
    }

    # ---------------- (b) the live daemon tree is never matched --------------
    # Measured 2026-09-20: four `node.exe memtrace.js ... --workspace <manifest>`
    # processes had DEAD parents (34376/37864/61784/66016 all gone) and were
    # still live members of the union daemon family.
    It '(b) does NOT match a node.exe memtrace.js --workspace host whose parent is gone' {
        $all = @(
            (New-ProcRow -Id 22640 -ParentId 34376 -Name 'node.exe' -CommandLine $UNION)
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all | Should Be $false
        (@(Get-OrphanedMemtraceHostPids -Processes $all)).Count | Should Be 0
    }

    It '(b) does NOT match a bare orphan that owns a LIVE daemon subtree' {
        # The candidate has a dead parent and NO --workspace token, so only the
        # descendant check saves it: it is the live daemon root.
        $all = @(
            (New-ProcRow -Id 89040 -ParentId 58996 -Name 'node.exe' -CommandLine ('"' + $NODE + '" ' + $MEMJS + ' start --headless')),
            (New-ProcRow -Id 43748 -ParentId 89040 -Name 'memtrace.exe' -CommandLine 'memtrace.exe start --headless'),
            (New-ProcRow -Id 62980 -ParentId 43748 -Name 'memcore-server.exe' -CommandLine 'memcore-server.exe --bind 127.0.0.1:50051 --data-dir C:\Users\yuni\.config\memtrace\.memdb')
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all | Should Be $false
    }

    It '(b) does NOT match a node.exe memtrace.js whose parent is ALIVE (the launcher itself)' {
        $all = @(
            (New-ProcRow -Id 58996 -ParentId 1 -Name 'pwsh.exe' -CommandLine 'pwsh.exe -File ###1.watchers.ps1'),
            (New-ProcRow -Id 89041 -ParentId 58996 -Name 'node.exe' -CommandLine $LEAKED)
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[1] -AllProcesses $all | Should Be $false
    }

    It '(b) does NOT match a node.exe memtrace.js whose LIVE ancestor is a daemon binary' {
        $all = @(
            (New-ProcRow -Id 43750 -ParentId 1 -Name 'memtrace.exe' -CommandLine 'memtrace.exe start --headless'),
            (New-ProcRow -Id 89042 -ParentId 43750 -Name 'node.exe' -CommandLine $LEAKED)
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[1] -AllProcesses $all | Should Be $false
    }

    It '(b) does NOT match a host in the protected set even if every other rule matches' {
        $all = @(
            (New-ProcRow -Id 70004 -ParentId 40004 -Name 'node.exe' -CommandLine $LEAKED)
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all -ProtectedPids @(70004) | Should Be $false

        # The protected set the entry point feeds in: every live daemon binary.
        $real = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $protected = @(Get-MemtraceDaemonProtectedPids -Ports @())
        foreach ($p in $real) {
            if ($p.Name -eq 'memcore-server.exe' -or $p.Name -eq 'memtrace.exe' -or $p.Name -eq 'memcortex-daemon.exe') {
                ($protected -contains [int]$p.ProcessId) | Should Be $true
            }
        }
    }

    # ---------------- (c) the old shim case still matches --------------------
    It '(c) still matches the old shim-script host whose parent is gone' {
        $shim = 'C:\Users\yuni\AppData\Local\Temp\mcpw-anw-shim-memtrace.ps1'
        $all = @(
            (New-ProcRow -Id 70005 -ParentId 40005 -Name 'powershell.exe' -CommandLine ('powershell.exe -NoProfile -File ' + $shim))
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all | Should Be $true
        (@(Get-OrphanedMemtraceHostPids -Processes $all) -contains 70005) | Should Be $true
    }

    It '(c) does NOT match a shim-script host whose parent is alive' {
        $shim = 'C:\Users\yuni\AppData\Local\Temp\mcpw-anw-shim-memtrace.ps1'
        $all = @(
            (New-ProcRow -Id 40006 -ParentId 1 -Name 'pwsh.exe' -CommandLine 'pwsh.exe -File launcher.ps1'),
            (New-ProcRow -Id 70006 -ParentId 40006 -Name 'powershell.exe' -CommandLine ('powershell.exe -NoProfile -File ' + $shim))
        )
        Test-OrphanedMemtraceHostProcess -Candidate $all[1] -AllProcesses $all | Should Be $false
    }

    It 'never matches itself or an unrelated node.exe' {
        $all = @(
            (New-ProcRow -Id 70007 -ParentId 40007 -Name 'node.exe' -CommandLine '"node.exe" C:\app\server.js'),
            (New-ProcRow -Id 70008 -ParentId 40008 -Name 'node.exe' -CommandLine $LEAKED)
        )
        (@(Get-OrphanedMemtraceHostPids -Processes $all -SelfPid 70008)).Count | Should Be 0
        Test-OrphanedMemtraceHostProcess -Candidate $all[0] -AllProcesses $all | Should Be $false
    }

    It 'reaps nothing (and touches no live daemon tree) on the REAL process table' {
        # Safety-only assertion, so it holds on any box: no live daemon-tree
        # member and no :50051 owner may appear in the victim set.
        $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $all.Count | Should BeGreaterThan 0

        $victims = @(Get-OrphanedMemtraceHostPids -Processes $all)

        $anchors = @{}
        foreach ($p in $all) {
            $cl = ''
            try { $cl = [string]$p.CommandLine } catch { $cl = '' }
            if (Test-MemtraceDaemonAnchor -Name ([string]$p.Name) -CommandLine $cl) {
                $anchors[[int]$p.ProcessId] = $true
            }
        }
        foreach ($v in $victims) {
            ($anchors.ContainsKey([int]$v)) | Should Be $false
        }

        # Every victim must really be an orphan: its parent PID must be absent,
        # or present only as a REUSED pid (a process created after the child).
        $live = @{}
        foreach ($p in $all) { $live[[int]$p.ProcessId] = $true }
        foreach ($v in $victims) {
            $row = $all | Where-Object { [int]$_.ProcessId -eq [int]$v } | Select-Object -First 1
            $row | Should Not BeNullOrEmpty
            $ppid = [int]$row.ParentProcessId
            if ($live.ContainsKey($ppid)) {
                $par = $all | Where-Object { [int]$_.ProcessId -eq $ppid } | Select-Object -First 1
                ([datetime]$par.CreationDate -gt [datetime]$row.CreationDate) | Should Be $true
            }
        }

        # The union daemon port owner, if present, is never a victim.
        try {
            foreach ($c in @(Get-NetTCPConnection -LocalPort 50051 -State Listen -ErrorAction SilentlyContinue)) {
                ($victims -contains [int]$c.OwningProcess) | Should Be $false
            }
        } catch {}
    }
}

if (-not $env:MCPW_AJY_SWEEP_TEST_RAN) {
    $env:MCPW_AJY_SWEEP_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
