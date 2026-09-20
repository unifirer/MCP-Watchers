param(
    [Parameter(Mandatory = $true)]  [string] $RepoRoot,
    [Parameter(Mandatory = $true)]  [int]    $DummyPid,
    [Parameter(Mandatory = $true)]  [string] $OutPath,
    [int] $GrepaiPid = 0
)
# Faithful reproduction of the teardown-state.json writer embedded in ###1
# (lines ~3888-3900): same 5 keys, same ConvertTo-Json -Compress, same UTF8.
# The 5 keys are: RootPids, MemtraceStatePath, RepoRoot, WtWindowName, GrepaiPid.
# GrepaiPid is required by Modules/watcher_teardown.ps1 (lines ~110, 121, 183-189).
# (TabId was removed on 2026-08-11: wt has no --tabIdFile/close-tab, so no tab
# GUID is ever captured.)
$ErrorActionPreference = 'Stop'
$tdState = @{
    RootPids          = @($DummyPid)
    MemtraceStatePath = Join-Path $RepoRoot ".memdb\daemon-state.json"
    RepoRoot          = $RepoRoot
    WtWindowName      = "vadwatchers"
    GrepaiPid         = [int]$GrepaiPid
} | ConvertTo-Json -Compress
$dir = Split-Path -Parent $OutPath
if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Set-Content -LiteralPath $OutPath -Value $tdState -Encoding UTF8
