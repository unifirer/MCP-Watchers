#Requires -Version 5.1
<#
.SYNOPSIS
    Flip graphenium's LLM semantic extraction on or off, live, without restarting
    the launcher.

.DESCRIPTION
    Writes the per-repo state file that the ###1 launcher's live rebuild daemon
    polls every 2 seconds:

        <repo>\.mcpw-provision\gm-semantic.mode      containing "on" or "off"

    The launcher picks the change up on its next poll, so no restart is needed.
    Turning semantic ON makes every rebuild call the local LLM fallback proxy
    (LLM_PROXY_PORT, default 11436) - that is the only part of the graphenium
    pipeline that costs tokens and wall-clock. Default is OFF, which costs
    nothing and keeps the graph AST-only.

    WHY THE FILE IS NOT UNDER graphenium-out\: gm cleans that directory on every
    run, so a control file there can be deleted out from under the daemon.
    .mcpw-provision\ is launcher-owned, gitignored, and its dot-directory segment
    is skipped by both watchers, so flipping the switch never triggers a rebuild
    storm.

.PARAMETER Mode
    on | off | toggle | status. Default: status.

.PARAMETER Repo
    Repository root. Default: the parent of this script's directory (dev_tools\..).

.PARAMETER Force
    After switching, run one full gm rebuild immediately, instead of waiting for
    the daemon's next poll. Refuses to start a second build if one is already
    running (same machine-wide mutex the daemon uses).

.EXAMPLE
    .\dev_tools\gm-semantic-toggle.ps1 -Mode on
    .\dev_tools\gm-semantic-toggle.ps1 -Mode status
    .\dev_tools\gm-semantic-toggle.ps1 -Mode on -Force

.NOTES
    Bead: mcpw-b81.3. Windows PowerShell 5.1 compatible (no ternary, no ??).
#>
[CmdletBinding()]
param(
    [ValidateSet('on', 'off', 'toggle', 'status')]
    [string]$Mode = 'status',
    [string]$Repo = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- resolve the repo -------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Repo)) {
    # This script lives in <repo>\dev_tools\, so the repo is one level up.
    $Repo = Split-Path -Parent $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($Repo) -or -not (Test-Path -LiteralPath $Repo)) {
    Write-Error "Repo path not found: '$Repo'. Pass -Repo explicitly."
    exit 2
}

$provDir  = Join-Path $Repo '.mcpw-provision'
$modeFile = Join-Path $provDir 'gm-semantic.mode'

function Test-OnFromText([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text.Trim() -match '^(?i)(1|true|yes|on|enabled)$')
}

# --- read the EFFECTIVE state (same rules as the launcher's reader) ---------
# source is one of: file | env | default
function Get-EffectiveMode {
    $fileText = $null
    if (Test-Path -LiteralPath $modeFile) {
        try { $fileText = (Get-Content -LiteralPath $modeFile -TotalCount 1 -ErrorAction Stop) } catch { $fileText = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$fileText)) {
        return @{ On = (Test-OnFromText ([string]$fileText)); Source = 'file'; Text = ([string]$fileText).Trim() }
    }
    if ($env:MCPW_GM_SEMANTIC -and ($env:MCPW_GM_SEMANTIC -match '^(?i)(1|true|yes|on|enabled)$')) {
        return @{ On = $true; Source = 'env (MCPW_GM_SEMANTIC)'; Text = $env:MCPW_GM_SEMANTIC }
    }
    return @{ On = $false; Source = 'default'; Text = '' }
}

function Write-Mode([string]$value) {
    # Atomic: write a sibling temp file in the SAME directory, then move. An
    # interrupted run can therefore never leave a half-written file behind that
    # the launcher's reader would misparse.
    if (-not (Test-Path -LiteralPath $provDir)) {
        New-Item -ItemType Directory -Path $provDir -Force | Out-Null
    }
    $tmp = Join-Path $provDir ('gm-semantic.mode.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Set-Content -LiteralPath $tmp -Value $value -Encoding ASCII -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $modeFile -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# --- act -------------------------------------------------------------------
$before = Get-EffectiveMode
$target = $null

switch ($Mode) {
    'on'     { $target = 'on' }
    'off'    { $target = 'off' }
    'toggle' { $target = if ($before.On) { 'off' } else { 'on' } }
    'status' { $target = $null }
}

if ($target) {
    try {
        Write-Mode $target
    } catch {
        Write-Error "Failed to write $modeFile : $($_.Exception.Message)"
        exit 3
    }
}

$after = Get-EffectiveMode
$proxyPort = if ($env:LLM_PROXY_PORT) { $env:LLM_PROXY_PORT } else { '11436' }
$proxyModel = if ($env:LLM_PROXY_MODEL) { $env:LLM_PROXY_MODEL } else { 'nous-proxy' }

Write-Host ''
Write-Host 'graphenium semantic mode'
Write-Host ('  repo     : ' + $Repo)
Write-Host ('  file     : ' + $modeFile + $(if (Test-Path -LiteralPath $modeFile) { '' } else { '   (absent)' }))
Write-Host ('  mode     : ' + $(if ($after.On) { 'ON  (LLM enrichment)' } else { 'OFF (AST-only)' }))
Write-Host ('  source   : ' + $after.Source)
if ($target) { Write-Host ('  previous : ' + $(if ($before.On) { 'ON' } else { 'OFF' }) + '  ->  ' + $(if ($after.On) { 'ON' } else { 'OFF' })) }
Write-Host ('  llm proxy: http://127.0.0.1:' + $proxyPort + '/v1  (model ' + $proxyModel + ')')
if ($after.On) {
    Write-Host '  cost     : every rebuild now calls the LLM (tokens + wall-clock).'
} else {
    Write-Host '  cost     : none - rebuilds stay AST-only.'
}
Write-Host ''

if (-not $target) { exit 0 }

# --- -Force: run one build now ---------------------------------------------
if ($Force) {
    $gmExe = Get-Command 'gm.exe' -ErrorAction SilentlyContinue
    if (-not $gmExe) {
        Write-Warning "gm.exe not found on PATH - cannot run a build now. The mode file is written and the daemon will pick it up on its next poll."
        exit 0
    }
    # Same machine-wide, fail-fast mutex the daemon uses: never start a second
    # concurrent build on the same graph.json.
    $mutex = $null
    $held = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\VAD_GmSemanticBuild_0')
        $held = $mutex.WaitOne(0)
    } catch { $held = $false }
    if (-not $held) {
        Write-Host 'A gm rebuild is already running (mutex held) - not starting a second one. The mode file is written; the next build will use it.'
        if ($mutex) { try { $mutex.Dispose() } catch {} }
        exit 0
    }
    try {
        $runArgs = @('run', '.', '--provider', 'openai-compatible',
            '--api-base', "http://127.0.0.1:$proxyPort/v1/chat/completions",
            '--model', $proxyModel, '--no-viz')
        # NEVER --update: gm's incremental mode replaces graph.json with only the
        # changed files' nodes (one touched file collapsed a 5423-node graph to 15).
        if (-not $after.On) { $runArgs += '--no-semantic' }
        $runArgs += '--no-report'
        # The key must never ride on the command line (Win32_Process.CommandLine is
        # world-readable); stage it in the child environment like the daemon does.
        $hadKey = Test-Path env:GRAPHENIUM_API_KEY
        $prevKey = $env:GRAPHENIUM_API_KEY
        try {
            if ($env:LLM_PROXY_API_KEY) { $env:GRAPHENIUM_API_KEY = $env:LLM_PROXY_API_KEY }
            Write-Host ('Running a full gm rebuild now (semantic ' + $(if ($after.On) { 'ON' } else { 'OFF' }) + ')...')
            $p = Start-Process -FilePath $gmExe.Source -ArgumentList $runArgs `
                -WorkingDirectory $Repo -WindowStyle Hidden -PassThru -Wait
        } finally {
            if ($env:LLM_PROXY_API_KEY) {
                if ($hadKey) { $env:GRAPHENIUM_API_KEY = $prevKey }
                else { Remove-Item env:GRAPHENIUM_API_KEY -ErrorAction SilentlyContinue }
            }
        }
        if ($p.ExitCode -ne 0) {
            Write-Warning "gm rebuild exited $($p.ExitCode). Check the graphenium pane / gm.log."
            exit 4
        }
        Write-Host 'Rebuild complete.'
    } finally {
        if ($held -and $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
            try { $mutex.Dispose() } catch {}
        }
    }
}
exit 0
