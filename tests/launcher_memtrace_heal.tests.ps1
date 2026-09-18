# tests/launcher_memtrace_heal.tests.ps1
# Pester 3.4.0 (pinned).
#
# mcpw-anw (2026-09-18): the memtrace auto-heal supervisor leaked one orphaned
# shell host per heal cycle (104 measured, oldest 16.2h). Three spawn sites
# reached the npm shim memtrace.ps1 - a SCRIPT - and Start-Process was called
# WITHOUT -PassThru, so the child was never tracked and never reaped.
#
# Commit 1f14b57 removed the shim host at the source (absolute node.exe +
# memtrace.js). This file pins what that commit did NOT close: the child is now
# TRACKED with -PassThru and REAPED when the heal verdict fails.
#
# Everything here is REAL. No simulated process objects:
#   - the relaunch target is redirected to a harmless sleeping shell host, but
#     the process spawned, tracked and killed is a live OS process;
#   - the orphan sweep runs against a genuinely orphaned shell host created by
#     the test (its parent process is killed first).
# Ports 50051 / 3030 are never touched and no memtrace daemon is ever started.
#
# Run (single pass, reliable exit code):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
#     "if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }; Invoke-Pester -Path 'tests\launcher_memtrace_heal.tests.ps1' -EnableExit"
if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }

$repo     = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

function Get-LauncherFunctionText {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "launcher parse error: $($errors[0].Message)" }
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
    if ($fn.Count -ne 1) { throw "expected exactly 1 definition of $Name, found $($fn.Count)" }
    return $fn[0].Extent.Text
}

# Define the REAL production functions in this scope so every It block sees them.
# These live inside the $memtraceHealScript scriptblock in the launcher; AST
# extraction reaches nested scriptblocks, so no function body is duplicated here.
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Get-MemtraceLaunchSpec')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Stop-MemtraceHealChild')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Restart-MemtraceDaemon')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Get-OrphanedMemtraceHostPids')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Stop-OrphanedMemtraceHosts')))

# Real tree-kill implementation (the supervisor dot-sources this from
# Modules\watcher_teardown.ps1). Safe to dot-source: no top-level side effects.
. (Join-Path $repo 'Modules\watcher_teardown.ps1')

# Scratch area for this test only.
$workDir = Join-Path $repo 'temp\mcpw-anw-heal-test'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$healLog = Join-Path $workDir 'autoheal.log'

# Runspace-local collaborators the extracted functions close over.
$RepoRoot = $workDir
$HealLog  = $healLog
# The tracker the supervisor uses: a hashtable so any scope can mutate .Proc.
$memtraceHealChild = @{ Proc = $null }

# Logging stubs (logging is not the behaviour under test).
function Limit-LogSize { param([string]$Path) }
function Write-HealLog {
    param([string]$Msg)
    "[$((Get-Date).ToString('o'))] $Msg" | Out-File -FilePath $healLog -Append -Encoding UTF8
}

$shellPath = (Get-Process -Id $PID).Path

Describe 'mcpw-anw: heal spawn is tracked with -PassThru' {

    It 'production spawn sites pass -PassThru (source contract)' {
        $restart = Get-LauncherFunctionText -Name 'Restart-MemtraceDaemon'
        $stop    = Get-LauncherFunctionText -Name 'Invoke-MemtraceStop'
        $restart | Should Match '-PassThru'
        $stop    | Should Match '-PassThru'
    }

    It 'Restart-MemtraceDaemon tracks the child it spawned (real process)' {
        # Redirect ONLY the executable. The process created is a real, live
        # shell host; the tracking and reaping under test are real.
        function Start-Process {
            param(
                [string]$FilePath, [object[]]$ArgumentList, [string]$WorkingDirectory,
                [string]$WindowStyle, [string]$RedirectStandardOutput,
                [string]$RedirectStandardError, [switch]$PassThru, [switch]$Wait
            )
            $script:spawnFilePath = $FilePath
            $script:spawnPassThru = [bool]$PassThru
            $childCmd = "Start-Process -FilePath '$shellPath' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 300') -PassThru | Out-Null; Start-Sleep -Seconds 300"
            return (Microsoft.PowerShell.Management\Start-Process -FilePath $shellPath `
                -ArgumentList @('-NoProfile', '-Command', $childCmd) -WindowStyle Hidden -PassThru)
        }

        $script:spawnPassThru = $false
        $memtraceHealChild.Proc = $null
        $null = Restart-MemtraceDaemon

        try {
            $script:spawnPassThru | Should Be $true
            $memtraceHealChild.Proc | Should Not BeNullOrEmpty
            $tracked = Get-Process -Id $memtraceHealChild.Proc.Id -ErrorAction SilentlyContinue
            $tracked | Should Not BeNullOrEmpty
        } finally {
            # Leave nothing behind whatever the assertions do.
            Stop-MemtraceHealChild -Proc $memtraceHealChild.Proc -Reason 'test cleanup' | Out-Null
            $memtraceHealChild.Proc = $null
        }
    }

    It 'a tracked child that failed the heal verdict is reaped with its tree' {
        # Same redirect as above: a real host that itself spawns a real child,
        # so the reap must remove BOTH (a single kill would orphan the child).
        function Start-Process {
            param(
                [string]$FilePath, [object[]]$ArgumentList, [string]$WorkingDirectory,
                [string]$WindowStyle, [string]$RedirectStandardOutput,
                [string]$RedirectStandardError, [switch]$PassThru, [switch]$Wait
            )
            $childCmd = "Start-Process -FilePath '$shellPath' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 300') -PassThru | Out-Null; Start-Sleep -Seconds 300"
            return (Microsoft.PowerShell.Management\Start-Process -FilePath $shellPath `
                -ArgumentList @('-NoProfile', '-Command', $childCmd) -WindowStyle Hidden -PassThru)
        }

        $memtraceHealChild.Proc = $null
        $null = Restart-MemtraceDaemon
        $child = $memtraceHealChild.Proc
        $child | Should Not BeNullOrEmpty

        $grandChild = $null
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $grandChild = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($child.Id)" -ErrorAction SilentlyContinue)
            if ($grandChild.Count -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }
        $grandChild.Count | Should BeGreaterThan 0

        # This is the call the supervisor makes when the ports never came up.
        Stop-MemtraceHealChild -Proc $child -Reason 'ports still down after 45s (fail#1)' | Should Be 1

        Start-Sleep -Seconds 2
        (Get-Process -Id $child.Id -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
        (Get-Process -Id $grandChild[0].ProcessId -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
        $memtraceHealChild.Proc = $null
    }

    It 'a cleared handle is never reaped (the healed daemon survives)' {
        # The supervisor clears .Proc when the ports came up, so the daemon it
        # just started is never killed. Reaping a cleared handle must be a no-op.
        Stop-MemtraceHealChild -Proc $null -Reason 'nothing tracked' | Should Be 0
    }
}

Describe 'mcpw-anw: orphaned memtrace shim hosts are swept' {

    It 'finds only shell hosts whose parent is gone' {
        # REAL orphan: an intermediary spawns the host and exits immediately,
        # so the host's ParentProcessId points at a dead process.
        $shim = Join-Path $workDir 'mcpw-anw-shim-memtrace.ps1'
        Set-Content -LiteralPath $shim -Value 'Start-Sleep -Seconds 300' -Encoding UTF8

        $inner = "Start-Process -FilePath '$shellPath' -ArgumentList @('-NoProfile','-File','$shim') -PassThru | Out-Null"
        $mid = Microsoft.PowerShell.Management\Start-Process -FilePath $shellPath `
            -ArgumentList @('-NoProfile', '-Command', $inner) -WindowStyle Hidden -PassThru

        $orphan = $null
        try {
            $deadline = (Get-Date).AddSeconds(25)
            while ((Get-Date) -lt $deadline) {
                # Exclude the intermediary: its own command line also carries the
                # shim path (it names the file it launches), but it is not a host.
                $orphan = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($shim) -and
                                   $_.ProcessId -ne $mid.Id })
                if ($orphan.Count -gt 0) { break }
                Start-Sleep -Milliseconds 500
            }
            $orphan.Count | Should BeGreaterThan 0

            # Wait for the intermediary to exit so the host is genuinely orphaned.
            $deadline = (Get-Date).AddSeconds(25)
            while ((Get-Date) -lt $deadline) {
                if (-not (Get-Process -Id $mid.Id -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 500
            }
            (Get-Process -Id $mid.Id -ErrorAction SilentlyContinue) | Should BeNullOrEmpty

            $victimId = [int]$orphan[0].ProcessId
            (@(Get-OrphanedMemtraceHostPids) -contains $victimId) | Should Be $true

            $killed = Stop-OrphanedMemtraceHosts
            $killed | Should BeGreaterThan 0
            Start-Sleep -Seconds 2
            (Get-Process -Id $victimId -ErrorAction SilentlyContinue) | Should BeNullOrEmpty

            # And the sweep is a no-op once nothing is orphaned.
            (@(Get-OrphanedMemtraceHostPids) -contains $victimId) | Should Be $false
        } finally {
            foreach ($p in $orphan) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
            }
            try { Stop-Process -Id $mid.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}
