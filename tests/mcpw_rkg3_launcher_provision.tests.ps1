# tests/mcpw_rkg3_launcher_provision.tests.ps1
# Pester 6 idiom (Should -Be / Should -Match). Bead mcpw-rkg.3 - wire the
# committed provision module (Modules/watcher_mcp_provision.ps1, bead
# mcpw-rkg.2) into the ###1 launcher.
#
# RUN IT WITH THE SUITE RUNNER:
#     python dev_tools/run_pester_suite.py tests/mcpw_rkg3_launcher_provision.tests.ps1
# Never trust the exit code - count the [-] lines (Pester 6.0.x dies in discovery
# yet exits 0). Report "N of M tests passed", never a bare pair.
#
# WHAT IS PINNED, and why each one is a real failure mode rather than a style
# preference:
#
#   1. The module is dot-sourced with the file's GUARDED pattern
#      (`if (Test-Path -LiteralPath $m) { . $m }`). An unguarded dot-source
#      aborts the whole launch when the module is absent, and the launcher's job
#      is to open its pane grid regardless.
#   2. The load sits AFTER $watchersWorkspaceRoot is resolved, so the module
#      sees the caller's repository and not $scriptDir.
#   3. The CALL is ordered before the FIRST watcher spawn. This is the entire
#      point of the bead: a watcher that starts against an uninitialized repo
#      reports "no graph / no index / no agent entry" and the operator cannot
#      tell that from a real failure.
#   4. The call is repo-agnostic ($watchersWorkspaceRoot), never an absolute
#      J:\audio\... literal - the mcpw-ybs.1/.2 rule.
#   5. A provision failure cannot abort the launch: guarded by Get-Command,
#      wrapped in try/catch, and no exit/throw inside the block.
#   6. The function the launcher calls is really exported by the module, so a
#      rename on either side fails HERE instead of at runtime.
#
# TWO PESTER-6 CONSTRAINTS THIS FILE IS SHAPED AROUND (same as
# tests/launcher_mcp_provision.tests.ps1):
#
#   1. NOTHING DEFINED AT FILE SCOPE IS VISIBLE INSIDE AN It BLOCK - not a
#      variable, not a function, not a dot-sourced .ps1. Only $PSScriptRoot and
#      $PSCommandPath survive. So every It re-derives the paths from
#      $PSScriptRoot. Do not "tidy" that into a file-scope helper.
#
#   2. This file must NOT import the Pester module itself - not even inside a
#      comment - because run_pester_suite.py's sniff is a plain substring test.
#      A false positive makes the runner execute the file DIRECTLY instead of
#      wrapping it, turning a Should--Be suite into a discovery-failure loop.
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

Describe 'mcpw-rkg.3: the launcher provisions the seven MCPs before spawning watchers' {

    It 'dot-sources the provision module with the guarded Test-Path pattern' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        $text | Should -Match '\$watcherMcpProvisionModule = Join-Path \$scriptDir ''Modules\\watcher_mcp_provision\.ps1'''
        $text | Should -Match 'if \(Test-Path -LiteralPath \$watcherMcpProvisionModule\) \{ \. \$watcherMcpProvisionModule \}'

        # Guarded means the ONLY way the module is loaded is inside that guard.
        # A second, unguarded load would abort the launch when it is missing.
        ([regex]::Matches($text, '\. \$watcherMcpProvisionModule')).Count |
            Should -Be 1 -Because 'the module must have exactly one, guarded, dot-source'
    }

    It 'loads the module AFTER $watchersWorkspaceRoot is resolved' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        $rootAt = $text.IndexOf('$watchersWorkspaceRoot = (Get-Location).ProviderPath')
        $loadAt = $text.IndexOf('$watcherMcpProvisionModule = Join-Path')
        $rootAt | Should -BeGreaterThan 0 -Because 'the workspace root assignment must exist'
        $loadAt | Should -BeGreaterThan $rootAt -Because 'the module must see the resolved root'
    }

    It 'CALLS Invoke-McpProvisionForRepo on the caller repository, before the first watcher spawn' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        $text | Should -Match 'Invoke-McpProvisionForRepo -Path \$watchersWorkspaceRoot'

        # Ordering. The first watcher the launcher spawns is the grepai watch
        # (verified by reading the file: the only earlier Start-Process is the
        # `ollama serve` prerequisite, which is not a watcher).
        $callAt = $text.IndexOf('Invoke-McpProvisionForRepo -Path $watchersWorkspaceRoot')
        $spawn = [regex]::Match($text, '(?m)^.*Start-Process.*grepai\.exe.*$')
        $spawn.Success | Should -BeTrue -Because 'the grepai watcher spawn must be findable'
        $spawnAt = $spawn.Index
        $callAt | Should -BeLessThan $spawnAt -Because 'init must complete before any watcher spawns'
    }

    It 'is repo-agnostic: no absolute path anywhere in the provision block' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        $start = $text.IndexOf('# --- MCP provision, BEFORE the first watcher spawns')
        $end = $text.IndexOf("`$grepaiLogsDir = Join-Path `$env:LOCALAPPDATA 'grepai\logs'", $start)
        $start | Should -BeGreaterThan 0
        $end | Should -BeGreaterThan $start -Because 'the provision block must be bounded by the spawn block'
        $block = $text.Substring($start, $end - $start)

        $block | Should -Not -Match '[A-Za-z]:\\' -Because 'a hard-coded drive path would break every other repo'
        $block | Should -Not -Match 'J:\\audio'
        $block | Should -Match '\$watchersWorkspaceRoot'
    }

    It 'cannot abort the launch: Get-Command guard, try/catch, and no exit or throw' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        $start = $text.IndexOf('# --- MCP provision, BEFORE the first watcher spawns')
        $end = $text.IndexOf("`$grepaiLogsDir = Join-Path `$env:LOCALAPPDATA 'grepai\logs'", $start)
        $block = $text.Substring($start, $end - $start)

        # A missing module must degrade, not abort: the call is only reachable
        # when the function is actually defined.
        $block | Should -Match 'if \(Get-Command Invoke-McpProvisionForRepo -ErrorAction SilentlyContinue\) \{'
        $block | Should -Match 'else \{'
        $block | Should -Match 'not loaded - skipping MCP init'
        # A throwing module must degrade too.
        $block | Should -Match 'try \{'
        $block | Should -Match 'catch \{'
        $block | Should -Match 'Write-Warning'
        $block | Should -Match 'Continuing'
        # Neither branch may terminate the launcher.
        $block | Should -Not -Match '\bexit\b'
        $block | Should -Not -Match '\bthrow\b'
    }

    It 'logs the summary in the launcher style, with the counts and each skip reason' {
        $launcher = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $text = Get-Content -LiteralPath $launcher -Raw

        $text | Should -Match '\[provision\]'
        # The aggregate counts the module actually returns.
        $text | Should -Match '\$mcpBoot\.Done'
        $text | Should -Match '\$mcpBoot\.Stamped'
        $text | Should -Match '\$mcpBoot\.Skipped'
        $text | Should -Match '\$mcpBoot\.Total'
        $text | Should -Match '\$mcpBoot\.Results'
        # Skipped rows are the ones an operator must see, with their reason.
        $text | Should -Match "Status -eq 'skipped'"
        $text | Should -Match '\$mcpRow\.Reason'
    }

    It 'calls a function the module really exports (no silent rename on either side)' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repoRoot '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $module = Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1'
        Test-Path -LiteralPath $module | Should -BeTrue -Because 'bead mcpw-rkg.2 commits this module'

        # Read the NAME out of the launcher instead of hard-coding it, so the two
        # sides can only ever agree or fail. Anchored on the assignment, because
        # `Get-WatchersWorkspaceKey -Path $watchersWorkspaceRoot` appears earlier
        # in the file and an unanchored match would pin the wrong function.
        $text = Get-Content -LiteralPath $launcher -Raw
        $m = [regex]::Match($text, '\$mcpBoot = (?<fn>[\w-]+) -Path \$watchersWorkspaceRoot')
        $m.Success | Should -BeTrue
        $called = $m.Groups['fn'].Value

        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0 -Because 'the module must parse'
        $defined = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
        $defined | Should -Contain $called -Because "the launcher calls $called"
        $defined | Should -Contain 'Invoke-McpProvisionForRepo'
        # Exactly one aggregate. (Invoke-McpProvisionCommand is the per-command
        # runner, not a second aggregate, so the match is exact.)
        @($defined | Where-Object { $_ -eq 'Invoke-McpProvisionForRepo' }).Count | Should -Be 1
    }

    It 'keeps the module contract the launcher depends on: never throws, degrades to a row' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $module = Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1'
        $text = Get-Content -LiteralPath $module -Raw
        # The launcher's catch is a backstop, not the plan: the module must
        # isolate every step and record a row instead of propagating.
        $text | Should -Match 'initializer threw:'
        $text | Should -Match "New-McpProvisionRow -Mcp \`$step\.Mcp -Status 'skipped'"
        # Status vocabulary the launcher's tally assumes.
        $text | Should -Match "'done'"
        $text | Should -Match "'stamped'"
        $text | Should -Match "'skipped'"
    }
}
