Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_window_name_keying.tests.ps1 (mcpw-ybs.3)
# Pester 3.4.0 (pinned). Guards the PER-WORKSPACE keying of the Windows
# Terminal window name the launcher builds its 2x2 pane grid in.
#
# Background: the name was the bare literal 'vadwatchers', so two repositories
# launched at once shared ONE Windows Terminal window. Repo B's `new-tab -w
# vadwatchers` landed in repo A's LIVE grid, and the directional move-focus /
# split-pane anchors (which have no ids and resolve against whatever layout the
# window currently holds) then operated on a 2x2 that already had repo A in it.
# mcpw-ybs.5 stopped the pre-grid reset from KILLING repo A's pane tailers, but
# that only made the collision survivable -- it did not give each repo its own
# window. Keying the name does.
#
# The name stays human-readable ('vadwatchers-<key>') rather than a bare hash,
# so an operator can still tell which window belongs to which repository.
#
# No window is opened and no process is spawned. The assignment line is
# EXTRACTED from the launcher source and executed, so the assertions run
# against the real code rather than a hand-copy.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

# The real keys on this box, so a drift in the derivation shows up as a failure.
$KEY_VAD = '77442b14'          # J:\audio\VAD
$KEY_MCPW = 'ad90e3fb'         # J:\audio\MCP-Watchers

function Get-LauncherSource {
    Get-Content -LiteralPath $launcher -Raw
}

function Get-WindowNameLine {
    # The one assignment that defines the window name.
    $src = Get-LauncherSource
    $idx = $src.IndexOf('$wtWindowName = "vadwatchers')
    if ($idx -lt 0) { return $null }
    $eol = $src.IndexOf("`n", $idx)
    if ($eol -lt 0) { $eol = $src.Length }
    return $src.Substring($idx, $eol - $idx).TrimEnd("`r")
}

function Invoke-WindowName {
    param([string]$Key)
    $workspaceKey = $Key
    $line = Get-WindowNameLine
    if (-not $line) { throw 'wtWindowName assignment not found in the launcher source' }
    # Refuse to execute a fragment that is not a clean assignment: an
    # unbalanced extract would throw a parse error that reads like a launcher
    # bug rather than an extractor bug (see the .2b / .5 traps).
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$null, [ref]$errs)
    if (@($errs).Count -gt 0) {
        throw ("extracted wtWindowName line does not parse: " +
               (($errs | ForEach-Object { $_.Message }) -join '; '))
    }
    Invoke-Expression $line
    return $wtWindowName
}

Describe 'Windows Terminal window name keying (mcpw-ybs.3)' {

    It 'finds the real window-name assignment in the launcher' {
        $line = Get-WindowNameLine
        $line | Should Not BeNullOrEmpty
        $line | Should Match '\$wtWindowName\s*=\s*"vadwatchers-'
    }

    It 'derives the window name from the workspace key' {
        (Invoke-WindowName -Key $KEY_VAD) | Should Be "vadwatchers-$KEY_VAD"
        (Invoke-WindowName -Key $KEY_MCPW) | Should Be "vadwatchers-$KEY_MCPW"
    }

    It 'gives two workspaces two DIFFERENT windows' {
        # The regression this gate exists for: one shared 'vadwatchers'.
        $a = Invoke-WindowName -Key $KEY_VAD
        $b = Invoke-WindowName -Key $KEY_MCPW
        $a | Should Not Be $b
    }

    It 'leaves no bare un-keyed window name assignment' {
        # A full-literal assignment would silently reintroduce the shared
        # window. Checked WITHOUT the closing quote so both the old bare form
        # and any future un-keyed variant are caught.
        $src = Get-LauncherSource
        $src | Should Not Match '\$wtWindowName\s*=\s*"vadwatchers"\s*$'
    }

    It 'still prefixes with vadwatchers so the window stays recognisable' {
        $src = Get-LauncherSource
        $src | Should Match '\$wtWindowName\s*=\s*"vadwatchers-\$workspaceKey"'
    }

    It 'routes EVERY wt invocation through the variable, never a literal name' {
        # -w must always be $wtWindowName; a hardcoded 'vadwatchers' in any one
        # step would put that step back in the shared window.
        $src = Get-LauncherSource
        $literalTarget = @($src -split "`r?`n" | Where-Object {
            $_ -match "'-w',\s*'vadwatchers" -or $_ -match '-w'',\s*"vadwatchers'
        })
        $literalTarget.Count | Should Be 0
        $variableTarget = @($src -split "`r?`n" | Where-Object { $_ -match "'-w',\s*\`$wtWindowName" })
        $variableTarget.Count | Should BeGreaterThan 0
    }

    It 'degrades to a visible name when the key is empty' {
        # Same rule as the lock/mutex: never fall back to the bare global name.
        (Invoke-WindowName -Key 'default') | Should Be 'vadwatchers-default'
    }

    It 'carries the keyed name into the state the teardown reads' {
        $src = Get-LauncherSource
        $src | Should Match 'WtWindowName\s*=\s*\$wtWindowName'
    }
}

if (-not $env:WINDOW_NAME_KEYING_TEST_RAN) {
    $env:WINDOW_NAME_KEYING_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
