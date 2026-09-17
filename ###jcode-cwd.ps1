<#
.SYNOPSIS
    Launch jcode in the current working directory as a new tab.

.DESCRIPTION
    Starts the jcode CLI with its working directory set to wherever this
    script is invoked from (the current working directory / cwd). This lets
    you run jcode from any folder without changing the project first.

    Every session opens as a NEW TAB inside one dedicated Windows Terminal
    window named "jcode" ("-w jcode"). Windows Terminal creates that window
    on the first launch and reuses it for every later launch. Tabs never
    appear in unrelated terminal windows.
    When wt.exe is not available, the script falls back to launching jcode
    directly in a fresh console.

    The script resolves the jcode executable from PATH. If jcode is not on
    PATH, set $env:JCODE_BIN to its directory (containing jcode.exe).

.PARAMETER Args
    Optional. Extra arguments to pass through to jcode (e.g. a prompt,
    --model, --help).

.EXAMPLE
    # Run from your project folder, then:
    pwsh C:\Users\yuni\jcode-cwd.ps1

.EXAMPLE
    pwsh C:\Users\yuni\jcode-cwd.ps1 --help

.NOTES
    Uses jcode's -C/--cwd flag so the local client process starts in the cwd.
    Opens via "wt.exe -w jcode new-tab". The named "jcode" window is created
    on first use and receives every later session as a tab, so repeated
    launches stay inside that one window instead of new windows.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Args = @()
)

# Suppress the split-second PowerShell host window that appears when this
# script is launched directly (double-click / Run dialog). A visible pwsh
# console paints, runs the launcher, then Windows Terminal takes over jcode's
# session. Relaunch hidden instead so no window flashes.
#
# CRITICAL: a hidden console keeps a NON-EMPTY WindowTitle, so the title is
# NOT a safe "already hidden" signal — without a guard the hidden child would
# re-launch itself forever and never open the tab. We tag the hidden child
# with the env marker JCODE_CWD_RELAUNCHED so the relaunch happens at most once.
if (-not $env:JCODE_CWD_RELAUNCHED) {
    if ($Host.Name -eq 'ConsoleHost' -and $Host.UI.RawUI.WindowTitle) {
        # Visible console host: re-run ourself hidden and exit this window.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $psi.FileName) { $psi.FileName = 'powershell.exe' }
        $psi.Arguments = "-NoProfile -WindowStyle Hidden -File `"$($MyInvocation.MyCommand.Path)`" $($Args -join ' ')"
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['JCODE_CWD_RELAUNCHED'] = '1'
        $null = [System.Diagnostics.Process]::Start($psi)
        exit 0
    }
}

$ErrorActionPreference = 'Stop'

# Bring a named process's main window to the foreground using Win32 APIs.
# Used after opening the tab so the dedicated "jcode" terminal window pops
# to the front instead of opening behind whatever was last focused.
function Bring-ProcessToForeground {
    param([string]$ProcessName)

    $type = Add-Type -PassThru -Name "Win32Foreground_$([Guid]::NewGuid().ToString('N').Substring(0,8))" -Namespace "Win32" -MemberDefinition @'
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);
'@

    $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    foreach ($proc in $processes) {
        $hwnd = $proc.MainWindowHandle
        if ($hwnd -eq [IntPtr]::Zero) { continue }
        try {
            if ($type::IsIconic($hwnd)) {
                $null = $type::ShowWindow($hwnd, 9)  # SW_RESTORE
            }
            $null = $type::SetForegroundWindow($hwnd)
        } catch {
            # Best-effort: if the API call fails, the tab is still open.
        }
        return
    }
}

# Resolve the jcode executable. Prefer explicit env override, else PATH lookup.
$jcodeExe = $null
if ($env:JCODE_BIN) {
    $candidate = Join-Path $env:JCODE_BIN 'jcode.exe'
    if (Test-Path $candidate) { $jcodeExe = $candidate }
}

if (-not $jcodeExe) {
    $found = Get-Command jcode.exe -ErrorAction SilentlyContinue
    if ($found) { $jcodeExe = $found.Source }
}

if (-not $jcodeExe) {
    Write-Error "jcode.exe not found on PATH. Set `$env:JCODE_BIN to the directory containing jcode.exe."
    exit 1
}

# Use the directory the script was launched from.
$startDir = (Get-Location).Path

# Open as a new tab inside THE dedicated "jcode" Windows Terminal window.
# "-w jcode" targets the window NAMED "jcode": WT adds our session as a tab
# if that window exists, and silently creates it on the very first launch.
# Tabs therefore NEVER appear in unrelated terminal windows.
# "--maximized" opens that window maximized (applies when the window is
# created on first launch; the dedicated jcode window persists between runs).
# History: "--always-new-process" forced a fresh window per run, and "-w 0"
# targeted the most recently used window of ANY kind, so tabs could land in
# non-jcode windows. Both were rejected.
$wtExe = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wtExe) {
    $tabTitle = "jcode: $startDir"
    & $wtExe.Source --maximized -w jcode new-tab --title $tabTitle -- $jcodeExe --cwd $startDir @Args
    # Bring the dedicated "jcode" terminal window to the foreground so the
    # new tab pops in front instead of opening behind the current window.
    Bring-ProcessToForeground 'WindowsTerminal'
    exit $LASTEXITCODE
}

# Fallback: launch jcode directly in a fresh console.
& $jcodeExe --cwd $startDir @Args
exit $LASTEXITCODE
