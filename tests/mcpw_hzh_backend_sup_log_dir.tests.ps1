# tests/mcpw_hzh_backend_sup_log_dir.tests.ps1
# Pester 6 idiom (Should -Be / Should -Match). Bead mcpw-hzh - a backend
# supervisor whose log directory does not exist yet died SILENTLY.
#
# THE BUG (measured 2026-09-23). Five of the six backend supervisors started;
# neo4j did not, and left no trace at all. $supNeo4jLog points at
# %LOCALAPPDATA%\neo4j-atlas\supervisor.log and that directory did not exist.
# Write-BackendSupLog called Limit-LogSize (guarded by Test-Path + try/catch,
# so a missing file was harmless) and then Out-File, which is NOT guarded:
# Out-File creates the FILE but never the parent DIRECTORY, so it threw
# "Could not find a part of the path". The supervisor threadjob died on its very
# first write - before it could emit its "supervisor started" line - so there
# was no log, no pane output and no console hint. The five that worked all had
# pre-existing directories under %LOCALAPPDATA%.
#
# THE FIX under test (option (b) from the bead): Write-BackendSupLog itself
# creates the parent directory before writing, so EVERY backend supervisor is
# immune, not just the one whose directory happens to be missing today.
#
# HOW THESE TESTS AVOID THE LIVE SYSTEM: Write-BackendSupLog is AST-extracted
# from the launcher and pointed at a throwaway temp path, so nothing is written
# under %LOCALAPPDATA% - in particular this suite never creates
# C:\Users\yuni\AppData\Local\neo4j-atlas, which would mask the bug it locks.
#
# TWO PESTER-6 CONSTRAINTS THIS FILE IS SHAPED AROUND (same as
# tests/mcpw_rkg4_grepai_first_scan.tests.ps1):
#
#   1. NOTHING DEFINED AT FILE SCOPE IS VISIBLE INSIDE AN It BLOCK - not a
#      variable, not a function, not a dot-sourced .ps1. Only $PSScriptRoot and
#      $PSCommandPath survive. So every It re-derives the launcher path from
#      $PSScriptRoot and extracts the function itself. Do not "tidy" that into a
#      file-scope helper - it will silently stop working.
#
#   2. This file must NOT import the Pester module itself, because
#      dev_tools/run_pester_suite.py's sniff is a plain substring test. Run it
#      as: Invoke-Pester -Path tests/mcpw_hzh_backend_sup_log_dir.tests.ps1
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

Describe 'mcpw-hzh: a backend supervisor log dir that does not exist yet' {

    It 'creates the missing parent directory instead of dying on the first write' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        Test-Path -LiteralPath $launcher | Should -BeTrue

        # AST extraction, not brace counting: the function lives INSIDE the
        # backend supervisor scriptblock. A parse error would make Find return
        # nothing, so the error count is asserted first.
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0 -Because 'the launcher must parse before anything else is asserted'
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Write-BackendSupLog' }, $true)
        $fn | Should -Not -BeNullOrEmpty -Because 'every backend supervisor logs through one writer'

        # The real helper module: Limit-LogSize is what the production runspace
        # dot-sources, and this test must not credit a stub for the real thing.
        . (Join-Path $repo 'Modules\watcher_job_helpers.ps1')
        Invoke-Expression $fn.Extent.Text

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('hzhsuplog_' + [guid]::NewGuid().ToString('N'))
        $dir = Join-Path $root 'neo4j-atlas'
        $log = Join-Path $dir 'supervisor.log'
        try {
            # The case under test IS the missing directory - if the dir somehow
            # pre-exists the test proves nothing.
            Test-Path -LiteralPath $dir | Should -BeFalse

            $SupervisorLog = $log
            # Stop, so a NON-terminating Out-File error is caught too: the
            # production scriptblock runs with Continue, which is exactly why
            # this death was silent instead of visible.
            $ErrorActionPreference = 'Stop'
            $threw = ''
            try { Write-BackendSupLog 'neo4j supervisor started' } catch { $threw = $_.Exception.Message }

            $threw | Should -Be '' -Because 'the first write must not take the supervisor down'
            Test-Path -LiteralPath $dir | Should -BeTrue
            Test-Path -LiteralPath $log | Should -BeTrue
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'neo4j supervisor started'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still writes and appends when the directory already exists' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Write-BackendSupLog' }, $true)
        . (Join-Path $repo 'Modules\watcher_job_helpers.ps1')
        Invoke-Expression $fn.Extent.Text

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('hzhsuplog_' + [guid]::NewGuid().ToString('N'))
        $dir = Join-Path $root 'mcp-agent-mail'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $log = Join-Path $dir 'supervisor.log'
        try {
            $SupervisorLog = $log
            $ErrorActionPreference = 'Stop'
            $threw = ''
            try {
                Write-BackendSupLog 'mail first line'
                Write-BackendSupLog 'mail second line'
            } catch { $threw = $_.Exception.Message }

            $threw | Should -Be ''
            @(Get-Content -LiteralPath $log).Count | Should -Be 2
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'mail first line'
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'mail second line'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the guard inside Write-BackendSupLog (option b), not a one-off at the $sup*Log assignments' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Write-BackendSupLog' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $body = $fn.Extent.Text

        # The dir is derived from the log path this call was given, so the guard
        # covers every backend, not just the one named in the bead.
        $body | Should -Match ([regex]::Escape('Split-Path -Parent $SupervisorLog'))
        $body | Should -Match 'New-Item -ItemType Directory'
        $body | Should -Match 'Test-Path -LiteralPath'

        # ...and it must come BEFORE the write it protects, or it is decoration.
        # Needle is the full write expression: a bare 'Out-File' also matches the
        # comment above it, which sits before the guard and would invert this.
        # IndexOf is a LITERAL search, so no [regex]::Escape here (that would
        # look for the backslashes, not the pipeline bar).
        $writeIdx = $body.IndexOf('| Out-File -FilePath $SupervisorLog')
        $writeIdx | Should -BeGreaterThan -1
        $body.IndexOf('New-Item -ItemType Directory') | Should -BeLessThan $writeIdx

        # Option (a) - a one-off New-Item next to $supNeo4jLog - must NOT be how
        # this is fixed: it leaves every future backend one missing dir away from
        # the same silent death.
        $src = Get-Content -LiteralPath $launcher -Raw
        $src | Should -Not -Match 'neo4jLogDir'
    }
}
