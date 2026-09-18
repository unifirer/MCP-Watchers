# tests/t8_isolation.tests.ps1
# Regression guard for the T8 flake: proves T8's pane block is fully isolated
# from the user's live ###1 window (unique name + unique dir + scoped matcher)
# so it can neither kill ###1's panes nor flake on PID-delta scoping.
# Run: powershell -NoProfile -File tests/t8_isolation.tests.ps1
#
# RUN UNDER PESTER 6 (Import-Module Pester -RequiredVersion 6.1.0). This file
# uses the `Should -Be` form; under Pester 3.4.0 every assertion dies with
# "'-Be' is not a valid Should operator", which is a runner mismatch, not a
# failure of the code under test. A sweep that pins 3.4.0 will report this suite
# red for exactly that reason. Pester 6 also dropped -EnableExit: use -PassThru
# and exit on $r.FailedCount.
#
# Pester 6.0.1/6.1.0 WORKAROUND (github.com/pester/Pester/issues/2669 + two-phase
# discovery): the discovery walker (a) throws "break/continue escaped" on files
# with >1 Describe or >1 It, and (b) nulls file-scope function/variable defs
# inside It blocks. Keep this file to EXACTLY ONE Describe and ONE It, and put
# ALL logic (including the helper and $repoRoot) INSIDE the It. Backslash
# literals are built from [char]92 so '\p' never appears raw in source — but
# note that only keeps '\p' out of the SOURCE: the runtime regex still needs a
# DOUBLED backslash (see $BSre below), or -match dies with
# "Malformed \p{X} character escape".
Describe 'T8 pane block is fully isolated from the user''s ###1 window' {
    It 'rewrites window name + pane dir + scopes the reset matcher to a unique t8 sandbox (RED: still shared)' {
        # Repo root is RESOLVED, never hardcoded. This suite was extracted from
        # J:\audio\VAD into the standalone MCP-Watchers repo (2026-09-17); a
        # hardcoded path made it silently assert against the WRONG launcher.
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $BS = [char]92
        # Keyed pane dir (beads mcpw-ybs.2): the launcher writes
        # <scratch>\vad-watchers\<workspaceKey>\panes\tail_<label>.ps1, where the
        # key is an 8-character lowercase hex SHA-256 prefix that differs per
        # repository. The live matcher below is therefore a REGEX, and the shared
        # dir is detected by its literal ASSIGNMENT PREFIX, not by a full path.
        $vadPanes   = 'vad-watchers' + $BS + '[0-9a-f]{8}' + $BS + 'panes'
        $sharedPaneDirLiteral = '$wtPaneDir = Join-Path $scratchRoot "vad-watchers'
        $tailMarker = 'panes' + $BS + 'tail_'
        # REGEX form for the live matcher below. A literal backslash in a .NET
        # pattern is TWO backslashes: a single one makes '\p' the start of a
        # Unicode property escape, and -match dies with
        # "parsing ... Malformed \p{X} character escape". The header's
        # [char]92 trick keeps '\p' out of the SOURCE; this keeps it valid in the
        # runtime pattern.
        $BSre = $BS + $BS
        $vadPanesRe = 'vad-watchers' + $BSre + '[0-9a-f]{8}' + $BSre + 'panes' + $BSre + 'tail_'

        # Bind to the REAL implementation under test. Dot-sourced INSIDE the It
        # because Pester 6's two-phase discovery nulls file-scope definitions
        # inside It blocks (this replaces Task 1's RED inline placeholder).
        . (Join-Path $repoRoot 'tests\watcher_pane_helpers.ps1')
        function Extract-LauncherPaneBlock([string]$RRoot) {
            $launcher = Join-Path $RRoot '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
            $s = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8
            # Anchor on the ASSIGNMENT PREFIX ($sharedPaneDirLiteral), not the
            # old full literal 'vad-watchers\panes'. mcpw-ybs.2 keyed the pane
            # dir, so the full literal no longer exists and IndexOf returned -1
            # -> Substring(-1) threw and this test asserted nothing.
            $a = $s.IndexOf($sharedPaneDirLiteral)
            $b = $s.IndexOf('# Controller loop (WT panes open)')
            if ($a -lt 0 -or $b -le $a) {
                throw "Extract-LauncherPaneBlock: pane block anchors not found (a=$a b=$b). The launcher's wtPaneDir assignment or the controller-loop marker moved."
            }
            return $s.Substring($a, $b - $a)
        }

        # --- static isolation assertions (RED until Task 2 replaces New-IsolatedPaneBlock) ---
        $paneBlock = Extract-LauncherPaneBlock -RRoot $repoRoot
        $guid = [guid]::NewGuid().ToString('N')
        $isolated = New-IsolatedPaneBlock -PaneBlock $paneBlock -Guid $guid
        $scoped = $isolated.Contains('t8_' + $guid + $BS + 'panes')

        # DESIRED end state (achieved by Task 2): block IS isolated.
        # RED (un-scoped block): these are FALSE -> test FAILS.
        # GREEN (after Task 2): these are TRUE -> test PASSES.
        # PREFIX, no closing quote: mcpw-ybs.3 keys the name, so the assignment
        # is 'vadwatchers-<key>'. A full-literal check would be FALSE even when
        # isolation FAILED, i.e. it could never fail. The prefix catches both.
        $hasSharedName = $isolated.Contains('$wtWindowName = "vadwatchers')
        $hasSharedDir  = $isolated.Contains($vadPanes)
        $hasBareMatch  = $isolated.Contains($tailMarker)
        $hasUniqueName = $isolated.Contains('$wtWindowName = "t8_' + $guid + '"')
        $hasUniqueDir  = $isolated.Contains('t8_' + $guid + $BS + 'panes')
        $hasScopedMatch = $isolated.Contains('t8_' + $guid + $BS + 'panes' + $BS + 'tail_')

        ($hasUniqueName -and $hasUniqueDir -and $hasScopedMatch) | Should -Be $true
        ($hasSharedName -and $hasSharedDir -and $hasBareMatch) | Should -Be $false

        # --- guarded live-run (skips unless the block is isolated, so RED is safe) ---
        if (-not $scoped) { return }
        $before = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $vadPanesRe } |
            Select-Object -ExpandProperty CommandLine)
        $null = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('t8_' + $guid)) -Force -ErrorAction SilentlyContinue
        try { Invoke-Expression $isolated } catch { }
        Start-Sleep -Seconds 2
        $after = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $vadPanesRe } |
            Select-Object -ExpandProperty CommandLine)
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape(('t8_' + $guid + $BS + 'panes' + $BS + 'tail_')) } |
            ForEach-Object { try { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null } catch { } }
        $after.Count | Should -Be $before.Count
        foreach ($bb in $before) { $after | Should -Contain $bb }
    }
}
