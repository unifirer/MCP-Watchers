#Requires -Version 5.1
<#
.SYNOPSIS
    Preview what MCP provisioning would do, without doing it.

.DESCRIPTION
    Wraps Invoke-McpProvisionForRepo -ReportOnly (bead mcpw-0zo.6) so the
    operator can ask "will this launch cost me a memtrace index and a grepai
    first scan?" without spending them.

    It runs the six detection probes and reports, per MCP:
        stamped  already provisioned - nothing would run
        skipped  no runnable tool, or an optional step's opt-in file is missing
        planned  this step WOULD execute its command

    No provisioning command runs and no stamp is written, so it is safe to point
    at a repository you do not own. It reads the probes rather than the stamp, so
    a step whose stamp says done but whose artifact is gone is reported 'planned'
    - the false-stamp case the stamp gate cannot see.

    It is not free. A probe whose artifact already exists shells out to CONFIRM
    it (grepai status, repowise doctor), measured at ~40s on this repo. A probe
    whose artifact is absent short-circuits without spawning anything. That is
    still far cheaper than a real run.

.PARAMETER Path
    Repository to report on. Defaults to the current directory.

.EXAMPLE
    .\dev_tools\mcp_provision_report.ps1
    .\dev_tools\mcp_provision_report.ps1 -Path J:\audio\VAD

.NOTES
    Double-click safe: when launched from Explorer it pauses before closing so
    the report can be read. Run from a console and it just prints.
#>
[CmdletBinding()]
param(
    [string]$Path
)

$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$launcherRoot = Split-Path -Parent $scriptDir

if (-not $Path) {
    $Path = (Get-Location).ProviderPath
    if (-not $Path) { $Path = $launcherRoot }
}

$detectModule   = Join-Path $launcherRoot 'Modules\watcher_mcp_detect.ps1'
$provisionModule = Join-Path $launcherRoot 'Modules\watcher_mcp_provision.ps1'

foreach ($m in @($detectModule, $provisionModule)) {
    if (-not (Test-Path -LiteralPath $m -PathType Leaf)) {
        Write-Error "module not found: $m"
        exit 1
    }
}

# Dot-sourced, not imported: the modules are plain .ps1 files with no manifest.
. $detectModule
. $provisionModule

if (-not (Get-Command Invoke-McpProvisionForRepo -ErrorAction SilentlyContinue)) {
    Write-Error 'Invoke-McpProvisionForRepo did not load - aborting.'
    exit 1
}

Write-Host ''
Write-Host ('MCP provisioning report for {0}' -f $Path) -ForegroundColor Cyan
Write-Host 'read-only: no provisioning command will run and no stamp will be written' -ForegroundColor DarkGray
Write-Host ''

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$report = Invoke-McpProvisionForRepo -Path $Path -ReportOnly
$sw.Stop()

# Out-String, not Out-Host: the formatted table arrives without a trailing
# newline, which makes the next Write-Host land on the same line as the last
# row (measured). Out-String ends the block cleanly.
$table = $report.Results |
    Select-Object Mcp, Phase, Status, Reason |
    Format-Table -AutoSize -Wrap |
    Out-String
Write-Host $table.TrimEnd()

Write-Host ''
Write-Host ('{0} step(s): {1} stamped, {2} planned, {3} skipped  ({4:N1}s)' -f `
    $report.Total, $report.Stamped, $report.Planned, $report.Skipped, $sw.Elapsed.TotalSeconds)

$planned = @($report.Results | Where-Object { $_.Status -eq 'planned' })
if ($planned.Count -gt 0) {
    Write-Host ''
    Write-Host ('a real launch would run: {0}' -f (($planned | ForEach-Object { $_.Mcp }) -join ', ')) -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host 'a real launch would run nothing - every step is already provisioned' -ForegroundColor Green
}

# Double-click support (AGENTS.md script-usability rule): Explorer is the parent
# process, so the window would otherwise vanish before the report is read.
$parent = $null
try {
    $parent = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction SilentlyContinue).ParentProcessId
    if ($parent) {
        $pname = (Get-Process -Id $parent -ErrorAction SilentlyContinue).ProcessName
        if ($pname -eq 'explorer') {
            Write-Host ''
            Read-Host 'press Enter to close'
        }
    }
} catch { }
