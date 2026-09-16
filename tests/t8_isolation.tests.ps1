# tests/t8_isolation.tests.ps1
# Regression guard for the T8 flake: proves T8's pane block is fully isolated
# from the user's live ###1 window (unique name + unique dir + scoped matcher)
# so it can neither kill ###1's panes nor flake on PID-delta scoping.
# Run: powershell -NoProfile -File tests/t8_isolation.tests.ps1
#
# Pester 6.0.1/6.1.0 WORKAROUND (github.com/pester/Pester/issues/2669 + two-phase
# discovery): the discovery walker (a) throws "break/continue escaped" on files
# with >1 Describe or >1 It, and (b) nulls file-scope function/variable defs
# inside It blocks. Keep this file to EXACTLY ONE Describe and ONE It, and put
# ALL logic (including the helper and $repoRoot) INSIDE the It. Backslash
# literals are built from [char]92 so '\p' never appears raw in source.
Describe 'T8 pane block is fully isolated from the user''s ###1 window' {
    It 'rewrites window name + pane dir + scopes the reset matcher to a unique t8 sandbox (RED: still shared)' {
        $repoRoot = "J:\audio\VAD"
        $BS = [char]92
        $vadPanes   = 'vad-watchers' + $BS + 'panes'
        $tailMarker = 'panes' + $BS + 'tail_'

        # Bind to the REAL implementation under test. Dot-sourced INSIDE the It
        # because Pester 6's two-phase discovery nulls file-scope definitions
        # inside It blocks (this replaces Task 1's RED inline placeholder).
        . (Join-Path $repoRoot 'tests\watcher_pane_helpers.ps1')
        function Extract-LauncherPaneBlock([string]$RRoot) {
            $launcher = Join-Path $RRoot '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
            $s = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8
            $a = $s.IndexOf('$wtPaneDir = Join-Path $scratchRoot "vad-watchers\panes"')
            $b = $s.IndexOf('# Controller loop (WT panes open)')
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
        $hasSharedName = $isolated.Contains('$wtWindowName = "vadwatchers"')
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
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($vadPanes + $BS + 'tail_') } |
            Select-Object -ExpandProperty CommandLine)
        $null = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('t8_' + $guid)) -Force -ErrorAction SilentlyContinue
        try { Invoke-Expression $isolated } catch { }
        Start-Sleep -Seconds 2
        $after = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($vadPanes + $BS + 'tail_') } |
            Select-Object -ExpandProperty CommandLine)
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape(('t8_' + $guid + $BS + 'panes' + $BS + 'tail_')) } |
            ForEach-Object { try { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null } catch { } }
        $after.Count | Should -Be $before.Count
        foreach ($bb in $before) { $after | Should -Contain $bb }
    }
}
