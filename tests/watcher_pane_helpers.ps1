# tests/watcher_pane_helpers.ps1
# Shared by T8 (tests/launcher_tests.ps1) and tests/t8_isolation.tests.ps1.
# T8 extracts the launcher's pane block from ###1 and passes it here; this
# function rewrites it into a TEST-ISOLATED copy so T8 can run the REAL
# Build-GridStep spawn without ever touching the user's live ###1 window.
#
# The three isolation transforms. Every search string below is byte-accurate to
# the launcher source (verified: each occurs EXACTLY ONCE in the extracted pane
# block) and carries ONE literal backslash -- PowerShell does not treat "\" as an
# escape in either quoting style, so these must never be doubled.
function New-IsolatedPaneBlock {
    param([string]$PaneBlock, [string]$Guid)
    $block = $PaneBlock
    # 1) window name: vadwatchers -> t8_<guid>  (never collides with ###1)
    $block = $block.Replace('$wtWindowName = "vadwatchers"', '$wtWindowName = "t8_' + $Guid + '"')
    # 2) pane dir: vad-watchers\panes -> t8_<guid>\panes  (unique tailer path)
    #    The search string is single-quoted so its backslash stays literal and
    #    matches the one backslash present in the extracted source text.
    $block = $block.Replace('$wtPaneDir = Join-Path $scratchRoot "vad-watchers\panes"', '$wtPaneDir = Join-Path $scratchRoot "t8_' + $Guid + '\panes"')
    # 3) the PRE-GRID RESET's tailer matcher must be scoped to the unique dir,
    #    else it still matches (and kills) the user's vad-watchers\panes tailers.
    #    Double-quoted search/replace strings: backslash is literal in PSH
    #    double quotes, so '\panes\tail_' matches the one-backslash source text.
    $block = $block.Replace("[regex]::Escape('panes\tail_')", "[regex]::Escape('t8_" + $Guid + "\panes\tail_')")
    # 4) the post-build WatcherGridProbe must NOT run under test. It scans ALL
    #    CASCADIA windows for the four watcher-labelled TermControls, so inside
    #    T8 it could only ever find the USER'S live vadwatchers grid (read-only,
    #    but its failure path raises a blocking MessageBox -> hangs the suite).
    #    Runtime geometry is validated by the manual/agent launch proof instead.
    $block = $block.Replace("if (`$wtOk) { WatcherGridProbe -WindowName `$wtWindowName }", "# [test-isolated] WatcherGridProbe disabled under T8")
    return $block
}

# Enumerate every CASCADIA_HOSTING_WINDOW_CLASS window handle. WT hosts all
# windows in ONE process, so we must identify windows by HWND, never by PID.
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public class Win32Enum {
  public delegate bool EnumWnd(IntPtr h, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWnd cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
}
'@ -ErrorAction SilentlyContinue

function Get-CascadiaHwnds {
    $list = [System.Collections.Generic.List[IntPtr]]::new()
    $cb = { param([IntPtr]$h, [IntPtr]$lp)
        try {
            # MUST be the fully-qualified type: PowerShell has no [StringBuilder]
            # type accelerator, so the short form throws "Unable to find type"
            # inside this try{} and would make every enumeration return ZERO
            # handles silently (verified empirically).
            $sb = [System.Text.StringBuilder]::new(256)
            [void][Win32Enum]::GetClassName($h, $sb, 256)
            if ($sb.ToString() -eq 'CASCADIA_HOSTING_WINDOW_CLASS') { $list.Add($h) }
        } catch {}
        return $true
    }
    [Win32Enum]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list.ToArray()
}

function Get-NewCascadiaHwnds {
    param([IntPtr[]]$Before)
    $beforeSet = [System.Collections.Generic.HashSet[int64]]::new()
    foreach ($h in $Before) { [void]$beforeSet.Add([int64]$h) }
    $after = Get-CascadiaHwnds
    $diff = @()
    foreach ($h in $after) { if (-not $beforeSet.Contains([int64]$h)) { $diff += $h } }
    return $diff
}
