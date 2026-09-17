# Modules/watcher_workspace.ps1
# Workspace identity for the watcher launcher (beads mcpw-ybs.2).
#
# The launcher is meant to be started from ANY repository through a shortcut, so
# every MACHINE-GLOBAL resource it owns must be keyed by the CALLER's repository:
#   - the teardown state file      (Stop-AllWatchers must read ITS OWN roots)
#   - the pane + log scratch dirs  (each workspace owns its pane tailers)
#   - the launcher lock + mutexes  (FIRST-WINS per workspace, see mcpw-ybs.4)
#   - the startup orphan sweep     (never kill a sibling repository's watchers)
#
# ONE canonical derivation lives here. A disagreement about a key between the
# launcher, the teardown module and the tests would SILENTLY disable a safety
# gate, so this file is the single source of truth. Do not re-implement it.
#
# Safe to dot-source: function definitions only, no top-level side effects.

function Get-WatchersWorkspaceKey {
    <#
    .SYNOPSIS
        Derive a stable 8-character lowercase hex key for a workspace path.
    .DESCRIPTION
        The path is normalised (absolute, lowercased, no trailing separator) and
        hashed with SHA-256. Eight hex characters give about 4.3e9 values, which
        is ample for the handful of repositories on one machine. The short form
        matters because the key is embedded in Windows Terminal command lines and
        in Windows named-mutex names.
    .PARAMETER Path
        The workspace root. Defaults to the current location.
    #>
    param([string]$Path)

    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    if (-not $Path) { $Path = (Get-Location).Path }
    if (-not $Path) { return 'default' }

    $normalized = $Path.TrimEnd('\', '/').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $hex = [System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', ''
        return $hex.Substring(0, 8).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-WatchersWorkspaceRoot {
    <#
    .SYNOPSIS
        Return the workspace root a launcher was INVOKED from.
    .DESCRIPTION
        Resolution order:
          1. the explicit -Path argument
          2. VAD_WATCHERS_WORKSPACE_ROOT, which the launcher exports to its
             children and which a caller can set to make a path explicit
          3. the current location
        Never returns the launcher's own script folder. That folder is $scriptDir
        and is a SEPARATE concept: it locates the Modules\watcher_*.ps1 siblings
        and must never become the watched workspace.
    .PARAMETER Path
        An explicit workspace root. Wins over the environment.
    #>
    param([string]$Path)

    if ($Path) { return $Path.TrimEnd('\', '/') }
    if ($env:VAD_WATCHERS_WORKSPACE_ROOT) {
        return $env:VAD_WATCHERS_WORKSPACE_ROOT.TrimEnd('\', '/')
    }
    $loc = (Get-Location).ProviderPath
    if (-not $loc) { $loc = (Get-Location).Path }
    if (-not $loc) { return '' }
    return $loc.TrimEnd('\', '/')
}

function Test-WatchersProcessAttribution {
    <#
    .SYNOPSIS
        Decide whether a candidate process belongs to THIS workspace.
    .DESCRIPTION
        Used by the launcher's startup orphan sweep, which is a FALLBACK for
        orphans the PID-scoped Stop-AllWatchers could not reach. The sweep must
        FAIL SAFE: skipping an unattributable process can leave an orphan, which
        is harmless, whereas terminating it can kill a sibling repository's LIVE
        watcher.

        Attribution is by COMMAND LINE only, because Win32_Process exposes no
        working directory. A process whose command line carries no workspace
        marker therefore cannot be attributed, and is never terminated.

        Two markers are accepted:
          1. the 8-character workspace key. The keyed pane dir and log dir put it
             on the command line of everything the launcher spawns with a path.
          2. the absolute workspace root. Catches a process started with the
             workspace as an explicit argument.

        A workspace root shorter than 4 characters is ignored. A drive root such
        as C:\ would otherwise attribute every process on the machine.
    .PARAMETER CommandLine
        The candidate's command line. Empty means unattributable.
    .PARAMETER WorkspaceKey
        The 8-character key of this workspace.
    .PARAMETER WorkspaceRoot
        The absolute root of this workspace.
    #>
    param(
        [string]$CommandLine,
        [string]$WorkspaceKey,
        [string]$WorkspaceRoot
    )

    if (-not $CommandLine) { return $false }

    if ($WorkspaceKey) {
        if ($CommandLine.IndexOf($WorkspaceKey, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    if ($WorkspaceRoot -and $WorkspaceRoot.Length -ge 4) {
        if ($CommandLine.IndexOf($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}
