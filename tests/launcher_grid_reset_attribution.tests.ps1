Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_grid_reset_attribution.tests.ps1 (mcpw-ybs.5)
# Pester 3.4.0 (pinned). Guards the PRE-GRID pane-tailer reset in ###1, the
# step that tears down a surviving 2x2 grid before the new one is built.
#
# Background: that reset matched 'panes\tail_' on CommandLine and terminated
# EVERY match machine-wide. mcpw-ybs.2b put an attribution gate on the STARTUP
# orphan sweep but not here, so launching the launcher in repo B killed repo A's
# LIVE pane grid. Verified live 2026-09-17: VAD's Tier A launcher (no keying)
# runs 4 tailers at the un-keyed C:\Temp\vad-watchers\panes\tail_*.ps1 and every
# one of them matched.
#
# The reset now terminates a match ONLY when the tailer is attributable to THIS
# workspace, and SKIPS it otherwise. Same FAIL-SAFE trade as the sweep: a
# skipped stale tailer can leave an extra tab, which is a layout wart, whereas
# killing another repository's live panes is not.
#
# No process is spawned or terminated. Get-CimInstance and Invoke-CimMethod are
# stubbed and the reset block is EXTRACTED from the launcher source, so the
# assertions run the real branch logic rather than a hand-copy.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$workspaceModule = Join-Path $repo 'Modules\watcher_workspace.ps1'

# The real key on this box for J:\audio\VAD; the other is a sibling repository.
$KEY_THIS = '77442b14'
$KEY_OTHER = 'ad90e3fb'
$ROOT_THIS = 'J:\audio\VAD'
$PS = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Get-LauncherSource {
    Get-Content -LiteralPath $launcher -Raw
}

function Get-ResetBlock {
    # The reset + its two helpers, straight out of the launcher. Anchored so a
    # deleted gate fails loudly.
    #
    # SLICED, NOT SPANNED. The span from Get-WatcherPaneTailers to the ROOT
    # CAUSE anchor also contains WatcherGridProbe, a ~45-line UI Automation
    # function. Spanning it and then filtering out lines matching 'GridProbe'
    # removed the `function ... {` line but LEFT THE BODY, so the fragment kept
    # WatcherGridProbe's closing brace with nothing to close and
    # Invoke-Expression threw "Unexpected token '}'". Every behavioural test
    # below then asserted nothing while the run still looked green -- the same
    # trap that made the .2b suite report a false pass. Three balanced slices
    # instead, and a parse assertion in the suite to catch any future drift.
    $src = Get-LauncherSource
    $lines = @($src -split "`r?`n")
    $slices = @(
        @{
            A = '    function Get-WatcherPaneTailers {'
            B = '    # mcpw-ybs.5: attribute BEFORE terminating.'
        },
        @{
            A = '    function Test-WatcherPaneTailerIsOurs {'
            B = '    # RUNTIME FEEDBACK LOOP'
        },
        @{
            A = '    $resetAll = @(Get-WatcherPaneTailers)'
            B = '    # ROOT CAUSE (2026-07-16 fix for intermittent "2 tabs instead of 1")'
        }
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $slices) {
        $ia = -1; $ib = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($ia -lt 0) {
                if ($lines[$i] -ceq $s.A) { $ia = $i }
            } elseif ($lines[$i].StartsWith($s.B)) { $ib = $i; break }
        }
        if ($ia -lt 0 -or $ib -le $ia) { return $null }
        for ($i = $ia; $i -lt $ib; $i++) { [void]$out.Add($lines[$i]) }
    }
    return ($out -join "`n")
}

function Invoke-Reset {
    param(
        [object[]]$Processes,
        [string]$Key,
        [string]$Root
    )
    $script:ResetProcs = @($Processes)
    $script:ResetKilled = @()

    function Get-CimInstance {
        param($Class, $Filter, $ErrorAction)
        # A terminated process stops showing up, exactly as it would for real.
        # Without this the reset's condition-based wait would spin its full 4s
        # deadline on every single test.
        $live = @($script:ResetProcs | Where-Object { $script:ResetKilled -notcontains [int]$_.ProcessId })
        # Honour the image-name filter exactly as the real cmdlet would.
        if ($Filter -and $Filter -match "^Name='([^']+)'") {
            $wanted = $Matches[1]
            return @($live | Where-Object { $_.Name -eq $wanted })
        }
        return $live
    }
    function Invoke-CimMethod {
        param($InputObject, $MethodName, $ErrorAction)
        if ($MethodName -eq 'Terminate') { $script:ResetKilled += [int]$InputObject.ProcessId }
        return $null
    }

    $workspaceKey = $Key
    $watchersWorkspaceRoot = $Root
    $wtWindowName = 'vadwatchers'
    $WarningPreference = 'SilentlyContinue'

    $block = Get-ResetBlock
    if (-not $block) { throw 'pre-grid reset block not found in the launcher source' }
    # Refuse to run an unbalanced extract. Invoke-Expression would throw
    # "Unexpected token '}'", which Pester reports as a test failure but which
    # reads like a bug in the launcher rather than in this extractor. Say which.
    $parseErrs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($block, [ref]$null, [ref]$parseErrs)
    if (@($parseErrs).Count -gt 0) {
        throw ("extracted reset block does not parse -- fix Get-ResetBlock: " +
               (($parseErrs | ForEach-Object { $_.Message }) -join '; '))
    }
    Invoke-Expression $block

    return [PSCustomObject]@{
        Killed  = @($script:ResetKilled)
        Skipped = [int]$resetSkipped
    }
}

Describe 'pre-grid pane-tailer reset attribution (mcpw-ybs.5)' {

    It 'the workspace module defines the attribution helper' {
        Test-Path -LiteralPath $workspaceModule | Should Be $true
        # Direct statement, not inside the { } handed to Should: that scriptblock
        # has its own scope and the function would be gone by the assertion.
        . $workspaceModule
        (Test-WatchersProcessAttribution -CommandLine 'ps -File C:\Temp\vad-watchers\77442b14\panes\tail_grepai.ps1' `
            -WorkspaceKey $KEY_THIS -WorkspaceRoot '') | Should Be $true
    }

    It 'extracts the real reset block from the launcher source' {
        $block = Get-ResetBlock
        $block | Should Not BeNullOrEmpty
        $block | Should Match 'Test-WatcherPaneTailerIsOurs'
        $block | Should Match 'Invoke-CimMethod -InputObject \$t -MethodName Terminate'
    }

    It 'the extracted block PARSES (a broken extract must fail loudly)' {
        # The whole reason this suite exists as a separate gate: an unbalanced
        # extract makes Invoke-Expression throw, which voids every behavioural
        # test below while the run still LOOKS like a suite that ran. Check the
        # fragment is parseable first so a future anchor drift turns RED here.
        $block = Get-ResetBlock
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($block, [ref]$null, [ref]$errs)
        $msg = ($errs | ForEach-Object { $_.Message }) -join '; '
        @($errs).Count | Should Be 0   # $msg
    }

    It 'excludes the UI Automation probe rather than tearing its body apart' {
        # Slicing by 'GridProbe' lines left an orphaned closing brace. Assert we
        # never carry the probe in at all.
        $block = Get-ResetBlock
        $block | Should Not Match 'WatcherGridProbe'
        $block | Should Not Match 'UIAutomation'
    }

    It 'the reset filters by THIS WORKSPACE before it terminates' {
        # Without -ThisWorkspaceOnly the gate could be deleted and the rest of
        # these tests would still pass.
        $block = Get-ResetBlock
        $block | Should Match 'Get-WatcherPaneTailers -ThisWorkspaceOnly'
        $block | Should Match '\$resetSkipped'
    }

    It 'terminates a stale tailer from THIS workspace' {
        . $workspaceModule
        $r = Invoke-Reset -Key $KEY_THIS -Root $ROOT_THIS -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 5101
                CommandLine = "$PS -NoProfile -File C:\Temp\vad-watchers\$KEY_THIS\panes\tail_grepai.ps1"
            })
        $r.Killed.Count | Should Be 1
        $r.Killed[0] | Should Be 5101
        $r.Skipped | Should Be 0
    }

    It 'SKIPS a live tailer belonging to ANOTHER workspace' {
        # The regression this gate exists for: VAD's un-keyed tailers.
        . $workspaceModule
        $r = Invoke-Reset -Key $KEY_THIS -Root $ROOT_THIS -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 5201
                CommandLine = "$PS -NoProfile -File C:\Temp\vad-watchers\$KEY_OTHER\panes\tail_repowise.ps1"
            })
        $r.Killed.Count | Should Be 0
        $r.Skipped | Should Be 1
    }

    It 'SKIPS a tailer at the legacy UN-KEYED pane dir (VAD Tier A today)' {
        # C:\Temp\vad-watchers\panes\tail_*.ps1 carries no workspace marker at
        # all, so it can never be attributed and must never be terminated.
        . $workspaceModule
        $r = Invoke-Reset -Key $KEY_THIS -Root $ROOT_THIS -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 5301
                CommandLine = "$PS -NoProfile -File C:\Temp\vad-watchers\panes\tail_graphify-rs.ps1"
            })
        $r.Killed.Count | Should Be 0
        $r.Skipped | Should Be 1
    }

    It 'terminates a tailer attributable by the workspace ROOT instead of the key' {
        . $workspaceModule
        $r = Invoke-Reset -Key $KEY_THIS -Root $ROOT_THIS -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 5401
                CommandLine = "$PS -NoProfile -File C:\Temp\vad-watchers\panes\tail_graphenium.ps1 -RepoRoot $ROOT_THIS"
            })
        $r.Killed.Count | Should Be 1
        $r.Killed[0] | Should Be 5401
    }

    It 'counts every skipped tailer so the operator sees the shared window' {
        . $workspaceModule
        $r = Invoke-Reset -Key $KEY_THIS -Root $ROOT_THIS -Processes @(
            [PSCustomObject]@{ Name = 'powershell.exe'; ProcessId = 5501
                CommandLine = "$PS -File C:\Temp\vad-watchers\panes\tail_grepai.ps1" },
            [PSCustomObject]@{ Name = 'powershell.exe'; ProcessId = 5502
                CommandLine = "$PS -File C:\Temp\vad-watchers\$KEY_OTHER\panes\tail_repowise.ps1" },
            [PSCustomObject]@{ Name = 'powershell.exe'; ProcessId = 5503
                CommandLine = "$PS -File C:\Temp\vad-watchers\$KEY_THIS\panes\tail_graphenium.ps1" })
        $r.Killed.Count | Should Be 1
        $r.Killed[0] | Should Be 5503
        $r.Skipped | Should Be 2
    }

    It 'never terminates a tailer whose command line cannot be read' {
        # An unreadable CommandLine is dropped by Get-WatcherPaneTailers
        # ITSELF, before the attribution gate ever sees it, so it is neither
        # killed nor counted as skipped -- fail-safe in the right direction.
        # Paired here with a real attributable tailer so "nothing was killed"
        # cannot be confused with "nothing was found".
        . $workspaceModule
        $r = Invoke-Reset -Key $KEY_THIS -Root $ROOT_THIS -Processes @(
            [PSCustomObject]@{ Name = 'powershell.exe'; ProcessId = 5601; CommandLine = '' },
            [PSCustomObject]@{ Name = 'powershell.exe'; ProcessId = 5602
                CommandLine = "$PS -File C:\Temp\vad-watchers\$KEY_THIS\panes\tail_grepai.ps1" })
        $r.Killed.Count | Should Be 1
        $r.Killed[0] | Should Be 5602
        $r.Skipped | Should Be 0
    }

    It 'waits only for ITS OWN tailers to disappear' {
        # Waiting for every machine-wide match would spin the full 4s on any
        # launch that coexists with another repository.
        $block = Get-ResetBlock
        $block | Should Match '\(@\(Get-WatcherPaneTailers -ThisWorkspaceOnly\)\.Count\) -eq 0'
        $block | Should Not Match 'if \(\(Get-WatcherPaneTailers\)\.Count -eq 0\)'
    }

    It 'the grid-build settle counts OUR tailers, not every match' {
        $src = Get-LauncherSource
        $src | Should Match '\$tailerCount = \(@\(Get-WatcherPaneTailers -ThisWorkspaceOnly\)\)\.Count'
    }
}

if (-not $env:GRID_RESET_ATTRIBUTION_TEST_RAN) {
    $env:GRID_RESET_ATTRIBUTION_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
