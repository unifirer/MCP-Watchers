# tests/mcpw_rkg4_grepai_first_scan.tests.ps1
# Pester 6 idiom (Should -Be / Should -Match). Bead mcpw-rkg.4 - the grepai FIRST
# SCAN must survive the supervisor's idle-TTL reap.
#
# RUN IT WITH THE SUITE RUNNER:
#     python dev_tools/run_pester_suite.py tests/mcpw_rkg4_grepai_first_scan.tests.ps1
# Never trust the exit code - count the [-] lines (Pester 6.0.x dies in discovery
# yet exits 0). Report "N of M tests passed", never a bare pair.
#
# THE BUG. The idle TTL (watch.idle_timeout_minutes, default 20) exists to free
# the embedding model (~1.9 GB measured) once the index goes quiet. Its clocks -
# watch.last_index_time in .grepai/config.yaml and the newest
# grepai-worktree-*.log - are written at scan/CHECKPOINT boundaries, not per
# write. A first scan of a large repository has a stretch longer than the TTL in
# which neither clock moves while grepai is in fact busy writing chunks, so the
# supervisor reaped a LIVE scanning watcher, the scan restarted from zero, and it
# could never complete. Measured on this box 2026-09-20: `grepai status` reported
# "Files indexed: 0 / Total chunks: 714" - chunks going UP (the write path was
# alive) while the file counter never left zero.
#
# THE FIX under test. Test-GrepaiFirstScanInProgress, defined inside the grepai
# supervisor scriptblock of the ###1 launcher, gates the reap: while the watcher
# running NOW has not finished its first scan, the reap is DEFERRED.
#
# THE COMPLETION EVENT (measured on this box 2026-09-20, live watcher PID 35460):
#   <worktree>.ready  mtime 20:01:52.628
#   log line          "Initial scan complete: 160 files indexed, 1249 chunks
#                      created, 0 files removed, 0 skipped (took 4m34.08s)"
#                     at 20:01:47.487
#   process start     19:56:23.819   (so .ready is 5 s AFTER the scan, and is
#                                     NOT a daemon-start marker)
#   .ready content    "ready" then the watcher PID on the next line
# So a .ready naming the tracked PID is the completion event; a .ready left by a
# previous instance names a different PID and cannot lift the hold (the same
# freshness rule mcpw-3si applies to last_index_time).
#
# HOW THESE TESTS AVOID THE LIVE SYSTEM: the predicate takes an explicit -LogDir
# and an explicit -WatcherPid, so every test builds synthetic markers in a temp
# directory and never reads, writes, or sweeps the real machine-global
# %LOCALAPPDATA%\grepai\logs. This mirrors tests/mcpw-ozm.tests.ps1.
#
# TWO PESTER-6 CONSTRAINTS THIS FILE IS SHAPED AROUND (same as
# tests/launcher_mcp_bootstrap.tests.ps1):
#
#   1. NOTHING DEFINED AT FILE SCOPE IS VISIBLE INSIDE AN It BLOCK - not a
#      variable, not a function, not a dot-sourced .ps1. Only $PSScriptRoot and
#      $PSCommandPath survive. So every It re-derives the launcher path from
#      $PSScriptRoot and extracts the function itself. Do not "tidy" that into a
#      file-scope helper - it will silently stop working.
#
#   2. This file must NOT import the Pester module itself - not even inside a
#      comment - because run_pester_suite.py's sniff is a plain substring test.
#      A false positive makes the runner execute the file DIRECTLY instead of
#      wrapping it, turning a Should--Be suite into a discovery-failure loop.
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

Describe 'mcpw-rkg.4: the grepai first scan survives the idle TTL reap' {

    It 'extracts Test-GrepaiFirstScanInProgress from the launcher and defines it' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        Test-Path -LiteralPath $launcher | Should -BeTrue

        # AST extraction, not brace counting: the function lives INSIDE the
        # supervisor scriptblock, which is what the nested AST search is for (the
        # same reason tests/launcher_watcher_panes.tests.ps1 uses its
        # Extract-FunctionAst). A parse error would make Find return nothing, so
        # the error count is asserted first.
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0 -Because 'the launcher must parse before anything else is asserted'
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-GrepaiFirstScanInProgress' }, $true)
        $fn | Should -Not -BeNullOrEmpty -Because 'the reap gate must exist'

        Invoke-Expression $fn.Extent.Text
        (Get-Command Test-GrepaiFirstScanInProgress -ErrorAction SilentlyContinue) |
            Should -Not -BeNullOrEmpty
    }

    It 'HOLDS the reap while no .ready names the tracked PID (first scan running)' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-GrepaiFirstScanInProgress' }, $true)
        Invoke-Expression $fn.Extent.Text

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rkg4logs_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $me = 35460
            # A .ready left by a PREVIOUS instance: a different PID.
            Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-aaaa1111.ready') `
                -Value ("ready" + [Environment]::NewLine + "99991") -Encoding utf8
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid $me |
                Should -BeTrue -Because 'a stale .ready names a dead instance, not this watcher'

            # A second worktree, also not ours: still a hold.
            Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-bbbb2222.ready') `
                -Value ("ready" + [Environment]::NewLine + "99992") -Encoding utf8
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid $me | Should -BeTrue
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'RELEASES the reap once a .ready names the tracked PID (first scan done)' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-GrepaiFirstScanInProgress' }, $true)
        Invoke-Expression $fn.Extent.Text

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rkg4logs_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $me = 35460
            # The measured on-disk shape: "ready" then the PID on the next line.
            Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-0882dce4c425.ready') `
                -Value ("ready" + [Environment]::NewLine + "$me") -Encoding utf8
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid $me |
                Should -BeFalse -Because 'our own .ready is the first-scan completion event'

            # A space-separated build must answer the same way.
            Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-0882dce4c425.ready') `
                -Value "ready $me" -Encoding utf8
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid $me | Should -BeFalse
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'never matches a PID on a digit boundary (3546 must not answer for 35460)' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-GrepaiFirstScanInProgress' }, $true)
        Invoke-Expression $fn.Extent.Text

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rkg4logs_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-cccc3333.ready') `
                -Value ("ready" + [Environment]::NewLine + "3546") -Encoding utf8
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid 35460 |
                Should -BeTrue -Because 'a substring match would lift the hold for the wrong watcher'
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid 3546 | Should -BeFalse
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'degrades to the pre-bead behavior when there is no .ready to read' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-GrepaiFirstScanInProgress' }, $true)
        Invoke-Expression $fn.Extent.Text

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rkg4logs_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            # (a) no .ready at all: a grepai build that writes none. Must NOT hold,
            # or the memory saving would be disabled on the whole machine.
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid 35460 | Should -BeFalse
            # (b) a missing log dir: unknown evidence, so also no hold.
            Test-GrepaiFirstScanInProgress -LogDir (Join-Path $dir 'does-not-exist') -WatcherPid 35460 |
                Should -BeFalse
            # (c) an EMPTY marker file: a .ready exists but proves nothing, so the
            # first scan counts as still running.
            Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-dddd4444.ready') -Value '' -Encoding utf8
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid 35460 | Should -BeTrue
            # (d) untracked watcher (PID 0): the TTL branch cannot reach this
            # state, and holding there would be meaningless.
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid 0 | Should -BeFalse
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reads the -LogDir it was given, not the machine-global grepai log dir' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-GrepaiFirstScanInProgress' }, $true)
        Invoke-Expression $fn.Extent.Text

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rkg4logs_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            # A PID that cannot be running and therefore cannot own a real marker.
            # If the function ignored -LogDir and scanned the real
            # %LOCALAPPDATA%\grepai\logs it would find no match and return $true;
            # a $false here proves the synthetic dir was the one consulted.
            $unreal = 4321012
            Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-eeee5555.ready') `
                -Value ("ready" + [Environment]::NewLine + "$unreal") -Encoding utf8
            Test-GrepaiFirstScanInProgress -LogDir $dir -WatcherPid $unreal | Should -BeFalse
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'gates the reap on the predicate without keeping the old ungated condition' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        $text | Should -Match '\$firstScanRunning\s*=\s*Test-GrepaiFirstScanInProgress'
        $text | Should -Match 'if \(\(-not \$firstScanRunning\) -and \$idleMin -ge \$idleTtlMin\) \{'
        # Exactly one reap body: the guard replaced the condition, it did not add
        # a second copy of the body.
        ([regex]::Matches($text, 'if \(\$idleMin -ge \$idleTtlMin\) \{')).Count |
            Should -Be 0 -Because 'the old ungated condition must be gone, not kept alongside'
    }

    It 'PRESERVES the mcpw-6re invariant: the deferral writes no .idle and never returns' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        # mcpw-6re decides "deliberately reaped" from .idle being NEWER than .sup,
        # which holds only because the supervisor stamps .sup at the top of a tick
        # and writes .idle later in the SAME tick, then returns. The deferral must
        # therefore write neither file and must not return - otherwise it would
        # leave an orphan .idle while .sup kept ticking, and the pane would read
        # "deliberately reaped" for a watcher that is alive and scanning.
        $m = [regex]::Match($text, '(?s)if \(\$firstScanRunning -and \$idleMin -ge \$idleTtlMin\) \{(?<body>.*?)\r?\n\s*\}\r?\n')
        $m.Success | Should -BeTrue -Because 'the deferral branch must be findable'
        $body = $m.Groups['body'].Value
        $body | Should -Not -Match 'Set-Content' -Because 'the deferral must not write a marker'
        $body | Should -Not -Match '\.idle' -Because 'the deferral must not touch the reap marker'
        $body | Should -Not -Match '\breturn\b' -Because 'the deferral must keep the supervisor ticking'
        $body | Should -Not -Match '\bexit\b'
        $body | Should -Match 'Write-SupLog' -Because 'a deferred reap must still be observable'

        # The relative-order contract itself is untouched: .sup is still stamped
        # at the top of the tick, and the reap still writes .idle AFTER it.
        $supAt = $text.IndexOf('Set-Content -LiteralPath $supStamp')
        $idleAt = $text.IndexOf("Set-Content -LiteralPath ([System.IO.Path]::ChangeExtension(`$LockFile, '.idle'))")
        $supAt | Should -BeGreaterThan 0
        $idleAt | Should -BeGreaterThan $supAt -Because '.idle must still be written after the .sup stamp'
    }

    It 'keeps the idle TTL armed and tunable (the memory saving is not disabled)' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw
        # The gate must be an ADDITIONAL condition on the existing TTL, never a
        # replacement: the TTL knob, its config read, and the PID-scoped reap all
        # have to survive this bead.
        $text | Should -Match 'Get-GrepaiIdleTimeoutMinutes -ConfigPath'
        $text | Should -Match '\$idleTtlMin'
        $text | Should -Match 'Stop-TrackedGrepaiTree -RootPid \$trackedGrepaiPid'
        $text | Should -Match 'grepai idle TTL reached'
    }
}
