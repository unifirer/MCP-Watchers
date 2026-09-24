# tests/mcpw_p83_sibling_log_writers.tests.ps1
# Pester 6 idiom (Should -Be / Should -Match). Bead mcpw-p83 - the follow-up to
# mcpw-hzh.
#
# THE BUG (same class as mcpw-hzh, measured 2026-09-24). Out-File -Append
# creates the FILE but never the parent DIRECTORY, so a log writer whose target
# directory does not exist yet throws "Could not find a part of the path" on its
# first write. Under the default $ErrorActionPreference = 'Continue' that throw
# takes down whatever job is doing the writing - silently (no log, no pane, no
# console hint). mcpw-hzh hardened Write-BackendSupLog inline; the SIBLING
# writers in the launcher still had the unguarded shape:
#   grepai Write-SupLog / Write-WatchersLog, litellm Write-LitellmSupLog,
#   the repowise reindex job, and Write-HealLog.
#
# THE FIX under test: ONE shared helper, New-LogParentDir, in
# Modules\watcher_job_helpers.ps1 (the single source of truth every job
# runspace dot-sources). Each sibling writer calls it immediately before its
# append, so the guard is written once instead of eleven times.
# Write-BackendSupLog keeps its own inline guard on purpose - the mcpw-hzh suite
# pins the guard INSIDE that function's body, so this suite does not touch it.
#
# HOW THESE TESTS AVOID THE LIVE SYSTEM: New-LogParentDir and the real writer
# are AST-extracted and pointed at a throwaway temp path, so nothing is written
# under %LOCALAPPDATA% or C:\Temp\vad-watchers.
#
# TWO PESTER-6 CONSTRAINTS THIS FILE IS SHAPED AROUND (same as
# tests/mcpw_hzh_backend_sup_log_dir.tests.ps1):
#
#   1. NOTHING DEFINED AT FILE SCOPE IS VISIBLE INSIDE AN It BLOCK - not a
#      variable, not a function, not a dot-sourced .ps1. Only $PSScriptRoot and
#      $PSCommandPath survive. So every It re-derives the paths and re-extracts
#      what it needs. Do not "tidy" that into a file-scope helper - it will
#      silently stop working.
#
#   2. This file must NOT import the Pester module itself, because
#      dev_tools/run_pester_suite.py's sniff is a plain substring test. Run it
#      as: Invoke-Pester -Path tests/mcpw_p83_sibling_log_writers.tests.ps1
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

Describe 'mcpw-p83: sibling log writers create their parent dir before appending' {

    It 'New-LogParentDir creates a missing parent directory (behavioural)' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $module = Join-Path $repo 'Modules\watcher_job_helpers.ps1'
        Test-Path -LiteralPath $module | Should -BeTrue

        # AST extraction, not brace counting: a parse error would make Find
        # return nothing, so the error count is asserted first.
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0 -Because 'the module must parse before anything else is asserted'
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'New-LogParentDir' }, $true)
        $fn | Should -Not -BeNullOrEmpty -Because 'every sibling writer routes through one shared guard'
        Invoke-Expression $fn.Extent.Text

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('p83guard_' + [guid]::NewGuid().ToString('N'))
        $dir = Join-Path $root 'a\b\c'
        $log = Join-Path $dir 'supervisor.log'
        try {
            # The case under test IS the missing directory - if the dir somehow
            # pre-exists the test proves nothing.
            Test-Path -LiteralPath $dir | Should -BeFalse

            # Stop, so a NON-terminating New-Item/Test-Path error is caught too:
            # the production runspace runs with Continue.
            $ErrorActionPreference = 'Stop'
            $threw = ''
            try {
                New-LogParentDir -Path $log
                New-LogParentDir -Path $log          # idempotent second call
                New-LogParentDir -Path 'bare.log'    # a bare name has no parent to derive
                New-LogParentDir -Path ''            # blank is a no-op
                New-LogParentDir -Path $null
            } catch { $threw = $_.Exception.Message }

            $threw | Should -Be '' -Because 'the guard must never throw'
            Test-Path -LiteralPath $dir | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'every hardened writer calls New-LogParentDir BEFORE its append (routing)' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0 -Because 'the launcher must parse before anything else is asserted'

        $fns = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($name in @('Write-SupLog', 'Write-WatchersLog', 'Write-LitellmSupLog', 'Write-HealLog')) {
            $fn = @($fns | Where-Object { $_.Name -eq $name })
            $fn.Count | Should -Be 1 -Because "exactly one $name is expected"
            $body = $fn[0].Extent.Text

            $body | Should -Match 'New-LogParentDir' -Because "$name must create its log dir"
            $guardIdx = $body.IndexOf('New-LogParentDir')
            # Needle is the full write expression: a bare 'Out-File' would also
            # match a comment. IndexOf is a LITERAL search (no [regex]::Escape).
            $writeIdx = $body.IndexOf('| Out-File -FilePath')
            $writeIdx | Should -BeGreaterThan -1
            $guardIdx | Should -BeGreaterThan -1
            $guardIdx | Should -BeLessThan $writeIdx -Because "$name must guard BEFORE it writes"
        }
    }

    It 'the repowise reindex job routes through the shared module and guards its $Log' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $src = Get-Content -LiteralPath $launcher -Raw

        $start = $src.IndexOf('$repowiseReindexScript = {')
        $start | Should -BeGreaterThan -1
        $end = $src.IndexOf('Start-Job -Name "repowise-reindex"', $start)
        $end | Should -BeGreaterThan $start
        $block = $src.Substring($start, $end - $start)

        # A Start-Job gets a fresh runspace, so the helper is reached only
        # through the module dot-source (the same rule every other job follows).
        $block | Should -Match '\. \$JobHelpersModule'
        $block | Should -Match ([regex]::Escape('New-LogParentDir -Path $Log'))

        $guardIdx = $block.IndexOf('New-LogParentDir -Path $Log')
        $writeIdx = $block.IndexOf('| Out-File -LiteralPath $Log')
        $writeIdx | Should -BeGreaterThan -1
        $guardIdx | Should -BeGreaterThan -1
        $guardIdx | Should -BeLessThan $writeIdx -Because 'the guard must precede the first reindex append'

        # ...and the module path is actually handed to the Start-Job, or the
        # dot-source above would resolve to nothing at runtime.
        $src | Should -Match 'Start-Job -Name "repowise-reindex"[^\r\n]*\$jobHelpersModule'
    }

    It 'the grepai Write-SupLog survives a missing log directory (behavioural)' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Write-SupLog' }, $true)
        $fn | Should -Not -BeNullOrEmpty -Because 'the grepai supervisor logs through this writer'

        # The real helper module: Limit-LogSize is what the production runspace
        # dot-sources, and this test must not credit a stub for the real thing.
        . (Join-Path $repo 'Modules\watcher_job_helpers.ps1')
        Invoke-Expression $fn.Extent.Text

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('p83suplog_' + [guid]::NewGuid().ToString('N'))
        $dir = Join-Path $root 'grepai-supervisor'
        $log = Join-Path $dir 'supervisor.log'
        try {
            Test-Path -LiteralPath $dir | Should -BeFalse

            $SupervisorLog = $log
            # Stop, so a NON-terminating Out-File error is caught too: the
            # production scriptblock runs with Continue, which is exactly why
            # this death was silent instead of visible.
            $ErrorActionPreference = 'Stop'
            $threw = ''
            try { Write-SupLog 'grepai supervisor started' } catch { $threw = $_.Exception.Message }

            $threw | Should -Be '' -Because 'the first write must not take the supervisor down'
            Test-Path -LiteralPath $dir | Should -BeTrue
            Test-Path -LiteralPath $log | Should -BeTrue
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'grepai supervisor started'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
