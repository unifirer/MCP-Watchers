Import-Module Pester -ErrorAction Stop

# Regression guard for the 4x2 watcher grid in ###1.
# Prevents the recurring "unequal quarters" bug by locking the wt-arg structure.
# Comments are stripped before assertions so the documented "-w 0 is bad" note
# in the comment block does not trip the "never -w 0" guard.
#
# mcpw-0sp: the grid went 2x2 (4 panes) -> 3x2 (6 panes: 5 watchers + 1 reserved
# empty cell). mcpw-qxj.8 gave the reserved cell to heimdall. mcpw-cnc.4 grows
# to 4x2 (8 panes: 6 watchers + atlas + blocker). Equal quarters via sequential
# splits on the newest pane: -s 0.75 (1/4 + 3/4) then -s 0.6667 (1/4 + 1/2)
# then -s 0.5 (halve the 1/2 into quarters). Keeps the 0.6667/0.5 thirds
# arithmetic. Every split still carries an explicit -s; none is left to default.
# Counts below derive from the grid builder (mcpw-i15 precedent): the pane-step
# count follows Build-GridStep lines carrying a pane (-File), anchors carry none.

$launcher = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

function Get-LauncherCode {
    (Get-Content -LiteralPath $launcher) |
        Where-Object { $_.TrimStart().StartsWith('#') -eq $false }
}

Describe '###1 4x2 pane grid enforces EQUAL cells' {

    It 'routes through a dedicated NAMED window, never -w 0 (which collapses two cells into one)' {
        $code = Get-LauncherCode | Out-String
        $code.Contains("'-w', `$wtWindowName") | Should -Be $true
        $code | Should -Not -Match '\-w[\s,]+0\b'
    }

    It 'splits the rows in half and the columns in quarters: 3 x -s 0.5 plus 2 x -s 0.6667 plus 2 x -s 0.75, and no split without an explicit -s' {
        $code = Get-LauncherCode | Out-String
        # Rows: one -H 0.5 (two equal rows). Columns per row: -V 0.75 (1/4 + 3/4)
        # then -V 0.6667 (1/4 + 1/2) then -V 0.5 (halve the 1/2 into quarters).
        # mcpw-cnc.4 keeps the 0.6667/0.5 thirds arithmetic. Pane steps derive
        # from the builder (mcpw-i15): splits = panes - 1 (new-tab is not a split).
        $paneSteps = @((Get-LauncherCode) | Where-Object { $_ -match 'Build-GridStep @\(' -and $_ -match "'-File'" })
        $halves   = [regex]::Matches($code, "'split-pane',\s*'-[HV]',\s*'-s',\s*'0\.5'")
        $thirds   = [regex]::Matches($code, "'split-pane',\s*'-[HV]',\s*'-s',\s*'0\.6667'")
        $quarters = [regex]::Matches($code, "'split-pane',\s*'-[HV]',\s*'-s',\s*'0\.75'")
        $halves.Count | Should -Be 3
        $thirds.Count | Should -Be 2
        $quarters.Count | Should -Be 2
        # Guard: no split is left to wt's default size.
        $allSplits = [regex]::Matches($code, "'split-pane',\s*'-[HV]'")
        $sized     = [regex]::Matches($code, "'split-pane',\s*'-[HV]',\s*'-s',\s*'0\.\d+'")
        $allSplits.Count | Should -Be ($paneSteps.Count - 1)
        $sized.Count     | Should -Be ($paneSteps.Count - 1)
    }

    It 'builds the 4x2 as SEPARATE wt invocations with DIRECTIONAL move-focus anchors BETWEEN the row splits (no numeric pane ids): new-tab; split -H; move-focus up; split -V; split -V; split -V; move-focus down; split -V; split -V; split -V' {
        $code = Get-LauncherCode | Out-String
        # Every grid step targets the named window so pane targeting stays scoped
        # to the single 4x2 tab. Step count derives from the builder (mcpw-i15):
        # pane steps (carry -File) plus exactly 2 anchor steps (no pane, no -File).
        $paneSteps = @((Get-LauncherCode) | Where-Object { $_ -match 'Build-GridStep @\(' -and $_ -match "'-File'" })
        $namedWin = [regex]::Matches($code, "Build-GridStep @\('-w', [$]wtWindowName")
        $namedWin.Count | Should -Be ($paneSteps.Count + 2)
        # Exactly two DIRECTIONAL anchors (top then bottom row), each its OWN
        # invocation so it resolves against a settled layout. Numeric
        # "focus-pane -t <id>" anchors are BANNED: they carry window-global
        # creation-order ids that go STALE across rebuilds (the pre-grid reset
        # closes prior panes; the long-lived named window can host user tabs).
        # A stale id mis-anchored the final -V split on 2026-08-26 (live failure:
        # top row 25/25/50, bottom full width). Directional moves have no ids.
        $upCount   = [regex]::Matches($code, "'move-focus', 'up'").Count
        $downCount = [regex]::Matches($code, "'move-focus', 'down'").Count
        $upCount   | Should -Be 1
        $downCount | Should -Be 1
        $code | Should -Not -Match "'focus-pane'"
        # Canonical 4x2 order: new-tab -> split -H -> move up -> 3 x split -V ->
        # move down -> 3 x split -V
        $iNewTab = $code.IndexOf("'new-tab'")
        $iH      = $code.IndexOf("'split-pane', '-H'")
        $iUp     = $code.IndexOf("'move-focus', 'up'")
        $iV1     = $code.IndexOf("'split-pane', '-V'")
        $iDown   = $code.IndexOf("'move-focus', 'down'")
        $iV2     = $code.IndexOf("'split-pane', '-V'", $iV1 + 1)
        # 4x2: the three row-1 column splits all precede the single move-focus
        # down, then the three row-2 column splits follow it.
        $iV3     = $code.IndexOf("'split-pane', '-V'", $iV2 + 1)
        $iV4     = $code.IndexOf("'split-pane', '-V'", $iV3 + 1)
        $iV5     = $code.IndexOf("'split-pane', '-V'", $iV4 + 1)
        $iV6     = $code.IndexOf("'split-pane', '-V'", $iV5 + 1)
        @($iNewTab, $iH, $iUp, $iV1, $iV2, $iV3, $iDown, $iV4, $iV5, $iV6) | ForEach-Object { $_ | Should -BeGreaterThan -1 }
        $iNewTab -lt $iH    | Should -Be $true
        $iH      -lt $iUp   | Should -Be $true
        $iUp     -lt $iV1   | Should -Be $true
        $iV1     -lt $iV2   | Should -Be $true
        $iV2     -lt $iV3   | Should -Be $true
        $iV3     -lt $iDown | Should -Be $true
        $iDown   -lt $iV4   | Should -Be $true
        $iV4     -lt $iV5   | Should -Be $true
        $iV5     -lt $iV6   | Should -Be $true
        # A settle wait must follow every step (the race was in-chained focus/split;
        # serializing + waiting is what makes each anchor resolve deterministically).
        $code | Should -Match 'Start-Sleep -Milliseconds'
    }

    It 'targets exactly 8 panes (6 watchers + atlas + blocker) each with a --title' {
        $code = Get-LauncherCode | Out-String
        # Pane count derives from the builder (mcpw-i15): one titled pane step
        # per -File tailer. The 4x2 contract is 8 titled steps.
        $paneSteps = @((Get-LauncherCode) | Where-Object { $_ -match 'Build-GridStep @\(' -and $_ -match "'-File'" })
        $paneSteps.Count | Should -Be 8
        $titles = [regex]::Matches($code, "'--title', '(grepai|graphenium|graphify-rs|repowise|codegraph|heimdall|atlas|blocker)'")
        $titles.Count | Should -Be $paneSteps.Count
        # Every one of the eight cells is titled exactly once.
        foreach ($lbl in @('grepai', 'graphenium', 'graphify-rs', 'repowise', 'codegraph', 'heimdall', 'atlas', 'blocker')) {
            [regex]::Matches($code, "'--title', '$lbl'").Count | Should -Be 1
        }
    }

    It 'resets any SURVIVING vadwatchers pane grid BEFORE building the grid (a pre-grid pane-tailer kill between the window-name assignment and new-tab), so new-tab never inherits a stale 2nd tab that makes focus-pane -t mis-resolve and collapse two cells into one -- and so teardown only closes the tab(s) it opened, not the whole window' {
        $code = Get-LauncherCode | Out-String
        # Prefix, no closing quote: mcpw-ybs.3 keys the name per workspace
        # ('vadwatchers-<key>'), so the old full literal no longer exists and
        # IndexOf would return -1 for a window name that IS defined.
        $winNameIdx = $code.IndexOf('$wtWindowName = "vadwatchers')
        $newTabIdx  = $code.IndexOf("'new-tab'")
        $winNameIdx -gt -1      | Should -Be $true
        $newTabIdx  -gt -1      | Should -Be $true
        # Good: a pre-grid reset that kills the launcher's OWN pane tailer
        # processes (powershell.exe matched by 'panes\tail_' in its command
        # line -- the same pattern the teardown sweep uses). wt (1.24) has NO
        # close-tab / --tabIdFile, so a process-kill reset is the only working
        # tab-scoped close; WT then closes the panes/tab/window by itself while
        # the user's other tabs in the window survive.
        $resetKillIdx = $code.IndexOf("'panes\tail_'")
        $resetKillIdx -gt -1        | Should -Be $true
        $resetKillIdx -ge $winNameIdx | Should -Be $true
        $resetKillIdx -le $newTabIdx   | Should -Be $true
        # The reset must actually terminate those processes.
        $code | Should -Match 'Terminate \| Out-Null'
    }

    It 'waits for the prior vadwatchers GRID to be gone by polling for its pane tailer processes (never the old global CASCADIA_HOSTING_WINDOW_CLASS count), so a surviving second tab cannot be inherited when the user has another WT window open (the intermittent "2 tabs" regression)' {
        $code = Get-LauncherCode | Out-String
        # Good: the reset polls the launcher's OWN pane tailer processes
        # (pattern-scoped -- independent of any OTHER tabs/windows the user has
        # open, so it never gives a false "ready"). wt -w get-tabinfo does not
        # exist in wt 1.24, so a process poll is the only scoped probe.
        $code | Should -Match 'Get-WatcherPaneTailers'
        # Bad: the old buggy global-count wait that enumerated every WT window.
        $badGlobal = [regex]::Matches($code, "WtHostWin::Get\(\)\s*-ge\s*[$]wtBefore")
        $badGlobal.Count | Should -Be 0
        $code | Should -Not -Match 'public class WtHostWin'
    }

    It 'tears down the grid tab on Ctrl+C by killing its pane tailers through the Stop-AllWatchers sweep -- wt (1.24) has no close-tab command, and a tab whose panes all exited closes by itself (the whole window is never nuked; the user''s other vadwatchers tabs survive)' {
        $code = Get-LauncherCode | Out-String
        $trapIdx = $code.IndexOf('trap {')
        $trapIdx | Should -BeGreaterThan -1
        # The trap's teardown path is Stop-AllWatchers (whose sweep terminates
        # powershell.exe processes matching 'panes\tail_'; see
        # Modules/watcher_teardown.ps1).
        $trapBlock = $code.Substring($trapIdx)
        $trapBlock -match 'Stop-AllWatchers' | Should -Be $true
        # guard: no `& wt 'close-tab ...'` whole-string form AND no close-tab
        # anywhere -- the subcommand does not exist in wt 1.24.
        ($code -match '&\s*wt\s+[''\"]close-tab') | Should -Be $false
        $code | Should -Not -Match 'close-tab'
    }
}

Describe '###1 4x2 grid survives a COLD START (WT not already running)' {

    It 'builds each grid step through a named GridStep helper that does bounded polling (not a blind fixed sleep)' {
        $code = Get-LauncherCode | Out-String
        $code | Should -Match 'function Build-GridStep'
        # Every grid step is invoked through the helper (bounded poll), not a
        # bare `& wt` followed by a fixed sleep.
        $helperCalls = [regex]::Matches($code, 'Build-GridStep').Count
        $helperCalls | Should -BeGreaterThan 0
    }

    It 'sets a bounded settle delay after each grid step' {
        $code = Get-LauncherCode | Out-String
        # The launcher uses a short, bounded $wtSettleMs (not 400, not absent).
        $m = [regex]::Match($code, '\$wtSettleMs\s*=\s*(\d+)')
        $m.Success | Should -Be $true
        [int]$m.Groups[1].Value | Should -BeGreaterThan 0
        # Guard: no stale 400ms floor reference.
        $code | Should -Not -Match '\$wtSettleMs\s*=\s*400'
        # Guard: no non-existent $wtReadyTimeoutMs reference.
        $code | Should -Not -Match '\$wtReadyTimeoutMs'
    }

    It 'waits for each grid step to MATERIALIZE (condition wait on pane-tailer count, not a blind 12ms sleep) -- guards the warm-path race where a pane spawns ~330ms AFTER wt.exe exits, so focus-pane/-V splits raced an unsettled layout and both -V splits landed in the same half (unequal quarters, invisible to the static test)' {
        $code = Get-LauncherCode | Out-String
        # Scoped to the Build-GridStep body (the pre-grid RESET also calls
        # Get-WatcherPaneTailers, so a whole-file match would false-pass).
        $fnIdx = $code.IndexOf('function Build-GridStep')
        $fnIdx | Should -BeGreaterThan -1
        $fnBody = $code.Substring($fnIdx)
        $callIdx = $fnBody.IndexOf('Build-GridStep @(')
        $callIdx | Should -BeGreaterThan -1
        $fnBody = $fnBody.Substring(0, $callIdx)
        # The helper must poll pane-tailer existence for this step's expected
        # count (the race was: blind fixed sleep while the pane had not spawned).
        $fnBody | Should -Match 'Get-WatcherPaneTailers'
        $fnBody | Should -Match '\$ExpectedTailers'
        # ... with a stability window (lets focus-pane apply) and a deadline cap
        # so a slow spawn degrades instead of stalling the launch.
        $fnBody | Should -Match '\$gridStableMs'
        $fnBody | Should -Match '\$gridWaitDeadline'
        # Every grid step must pass its expected tailer count (pane steps + 2
        # anchors, derived from the builder per mcpw-i15), and the counts run
        # 1..8 (one new tailer per pane-creating step, anchors repeat the count).
        $paneSteps = @((Get-LauncherCode) | Where-Object { $_ -match 'Build-GridStep @\(' -and $_ -match "'-File'" })
        $countArgs = [regex]::Matches($code, 'Build-GridStep @\([^)]*\) \d+')
        $countArgs.Count | Should -Be ($paneSteps.Count + 2)
        $counts = @($countArgs | ForEach-Object { [int]([regex]::Match($_.Value, '(\d+)$').Groups[1].Value) })
        ($counts -join ',') | Should -Be '1,2,2,3,4,5,5,6,7,8'
    }

    It 'treats a still-running wt process as success on cold start (the host stays alive) and only fails on a real non-zero exit' {
        $code = Get-LauncherCode | Out-String
        # Build-GridStep must check HasExited AND the exit code, so a cold-start
        # host process (still alive after the deadline) is treated as success --
        # not a hang. A bare `$LASTEXITCODE` check must NOT be the only gate.
        $code | Should -Match 'HasExited'
        $iExit  = $code.IndexOf('$LASTEXITCODE -ne 0')
        $iReady = $code.IndexOf('Build-GridStep')
        $iExit  | Should -BeGreaterThan -1
        $iReady | Should -BeGreaterThan -1
    }

    It 'flags cold-start readiness with $wtOk so teardown only closes tabs the launcher actually opened' {
        $code = Get-LauncherCode | Out-String
        $code | Should -Match '\$wtOk\s*=\s*\$true'
    }

    It 'NEVER passes wt features that do not exist in the installed build (regression guard for the 0x80070002 banner in the grepai pane): no --tabIdFile, no close-tab, no get-tabinfo, no close-window anywhere in the launcher code' {
        $code = Get-LauncherCode | Out-String
        $code | Should -Not -Match '--tabIdFile'
        $code | Should -Not -Match 'close-tab'
        $code | Should -Not -Match 'get-tabinfo'
        $code | Should -Not -Match 'close-window'
    }

    It 'builds the first pane with a PLAIN new-tab command line -- the pane command is passed through as real args (powershell -NoProfile -File <tailer>), never absorbed into a bogus option' {
        $code = Get-LauncherCode | Out-String
        $ntIdx = $code.IndexOf("'new-tab'")
        $ntIdx | Should -BeGreaterThan -1
        $newTabLine = ($code.Substring($ntIdx) -split "`r?`n")[0]
        # The new-tab step carries the real tailer path (no -RunToken token).
        $newTabLine | Should -Match 'tailGrepai'
        $newTabLine | Should -Not -Match 'RunToken'
    }

    It 'tears down the grid on Ctrl+C / window close via Stop-AllWatchers (no wt close-tab/close-window, which do not exist in wt 1.24)' {
        $code = Get-LauncherCode | Out-String
        $trapIdx = $code.IndexOf('trap {')
        $trapIdx | Should -BeGreaterThan -1
        $trapBlock = $code.Substring($trapIdx)
        $trapBlock -match 'Stop-AllWatchers' | Should -Be $true
        # The PowerShell.Exiting engine-event handler (window [X] close path)
        # also routes through Stop-AllWatchers.
        $code | Should -Match 'Register-EngineEvent'
        $code | Should -Not -Match 'close-tab'
        $code | Should -Not -Match 'close-window'
    }
}

if (-not $env:LAUNCHER_EQUAL_QUARTERS_TEST_RAN) {
    $env:LAUNCHER_EQUAL_QUARTERS_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
