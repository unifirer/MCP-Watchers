# tests/watcher_patterns.tests.ps1
# Pester 3.4.0 (pinned). Guards the SHARED sweep-pattern list used by BOTH the
# launcher's Stop-PriorLauncherInstances (startup) and the module's
# Stop-AllWatchers (exit). A single list means the two sweeps can never drift.
Import-Module Pester -RequiredVersion 3.4.0 -Force

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$patternsModule = Join-Path $repo 'Modules\watcher_patterns.ps1'

Describe 'watcher_patterns shared sweep list' {
    It 'dot-sources with no side effects' {
        Test-Path -LiteralPath $patternsModule | Should Be $true
        { . $patternsModule } | Should Not Throw
    }

    It 'contains the graphify-watch-wrapper entry as a DEDICATED powershell.exe pattern' {
        . $patternsModule
        $wrapper = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'powershell.exe' -and $_.Pattern -eq 'graphify-watch-wrapper' })
        $wrapper.Count | Should Be 1
    }

    It 'contains the pane-tailer entry (panes\tail_)' {
        . $patternsModule
        $pane = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'powershell.exe' -and $_.Pattern -eq 'panes\tail_' })
        $pane.Count | Should Be 1
    }

    It 'contains a match-all entry for graphify-rs.exe (rebuild child, no watch token)' {
        . $patternsModule
        $gf = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'graphify-rs.exe' -and $_.Pattern -eq '' })
        $gf.Count | Should Be 1
    }

    It 'contains a dedicated entry for the codegraph watch sweep' {
        . $patternsModule
        $cg = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'codegraph.exe' -and $_.Pattern -eq 'watch' })
        $cg.Count | Should Be 1
    }

    It 'contains a dedicated entry for the codegraph npm-shim sweep (node.exe)' {
        . $patternsModule
        # codegraph has no native .exe here: it runs as
        # node.exe <cli.mjs> codegraph watch <root>, so the sweep must match
        # the node image or a stale watcher is never reaped. The token is the
        # TWO-word 'codegraph watch' on purpose: the codegraph MCP backend
        # (`npx @optave/codegraph mcp --multi-repo`) also carries 'codegraph'
        # and must never be swept.
        $cg = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'node.exe' -and $_.Pattern -eq 'codegraph watch' })
        $cg.Count | Should Be 1
        # ...and the bare 'codegraph' token must NOT be a node.exe sweep entry.
        $broad = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'node.exe' -and $_.Pattern -eq 'codegraph' })
        $broad.Count | Should Be 0
    }

    It 'sweeps the codegraph REAL CLI shape but never the MCP backend' {
        . $patternsModule
        # Resolve-CodegraphLaunch re-expresses the npm bin shim (the real CLI,
        # installed by `npm install -g @optave/codegraph`) as
        #   node.exe <...>\@optave\codegraph\dist\cli.js watch <root>
        $real = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'node.exe' -and $_.Pattern -eq 'codegraph\dist\cli.js watch' })
        $real.Count | Should Be 1
        # The watcher shape must match...
        $watcher = 'C:\nvm4w\nodejs\node.exe J:\Programs\npm-global\node_modules\@optave\codegraph\dist\cli.js watch J:\audio\MCP-Watchers'
        Test-WatcherSweepMatch -CommandLine $watcher -Pattern 'codegraph\dist\cli.js watch' | Should Be $true
        # ...and the codegraph MCP backend must NOT: same cli.js, `mcp --multi-repo`
        # instead of `watch`. Shape copied verbatim from temp\proc-snapshot.csv.
        $backend = '"node"   "J:\Programs\npm-global\_npx\3739334a42fe877a\node_modules\.bin\..\@optave\codegraph\dist\cli.js" mcp --multi-repo'
        Test-WatcherSweepMatch -CommandLine $backend -Pattern 'codegraph\dist\cli.js watch' | Should Be $false
        Test-WatcherSweepMatch -CommandLine $backend -Pattern 'codegraph watch' | Should Be $false
    }

    It 'contains a dedicated entry for the heimdall reconciler sweep' {
        . $patternsModule
        # mcpw-qxj.4: the reconciler runs as node.exe <...>\bin\heimdall.js
        # daemon. The verb is part of the token on purpose - Toolport's heimdall
        # MCP server is the SAME heimdall.js, ending in `mcp`.
        $hd = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'node.exe' -and $_.Pattern -eq 'heimdall.js daemon' })
        $hd.Count | Should Be 1
        # ...and the bare file name must NOT be a node.exe sweep entry.
        $broad = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'node.exe' -and $_.Pattern -eq 'heimdall.js' })
        $broad.Count | Should Be 0
    }

    It 'sweeps the heimdall reconciler but never the heimdall MCP backend' {
        . $patternsModule
        $daemon = 'C:\nvm4w\nodejs\node.exe J:\Programs\npm-global\node_modules\@arihantdeva\heimdall\bin\heimdall.js daemon'
        Test-WatcherSweepMatch -CommandLine $daemon -Pattern 'heimdall.js daemon' | Should Be $true
        $mcp = 'C:\nvm4w\nodejs\node.exe J:\Programs\npm-global\node_modules\@arihantdeva\heimdall\bin\heimdall.js mcp'
        Test-WatcherSweepMatch -CommandLine $mcp -Pattern 'heimdall.js daemon' | Should Be $false
    }

    It 'names neither program called graft, so neither can be swept (mcpw-qxj.6)' {
        . $patternsModule
        # mcpw-qxj.6: two UNRELATED programs on this box are called "graft".
        # (a) GRAFT IS HEIMDALL'S BACKEND - /c/Users/yuni/.heimdall/config.json
        #     reads "backend": "graft"; graftd.exe is only its daemon binary.
        # (b) The graft/ directory and the graft MCP in this repo are the npm
        #     graft CLI v0.18.0, a per-repo context graph (build/ask/mcp).
        # Graft is a PREREQUISITE started once and the graft MCP is Toolport's,
        # so neither may appear in a sweep pattern. Asserting on the pattern
        # set (not on sample command lines) is what makes that durable: a match
        # -all entry with an empty pattern matches every command line, so
        # sweeping "does this line match?" would pass by accident.
        $named = @($script:WatcherSweepPatterns | Where-Object { $_.Pattern -match 'graft' })
        $named.Count | Should Be 0
    }

    It 'contains a dedicated entry for the grepai supervisor sweep' {
        . $patternsModule
        $sup = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'pwsh.exe' -and $_.Pattern -eq 'vad-grepai-sup' })
        $sup.Count | Should Be 1
    }

    It 'Test-WatcherSweepMatch uses the exact [regex]::Escape contract' {
        . $patternsModule
        $wrapperCmd = 'powershell.exe -NoProfile -WindowStyle Hidden -File "J:\audio\VAD\dev_tools\graphify-watch-wrapper.ps1" -WatchMode -Repo "J:\audio\VAD"'
        Test-WatcherSweepMatch -CommandLine $wrapperCmd -Pattern 'graphify-watch-wrapper' | Should Be $true
        Test-WatcherSweepMatch -CommandLine $wrapperCmd -Pattern 'panes\tail_' | Should Be $false
        # Match-all pattern ('' = every process of that image name).
        Test-WatcherSweepMatch -CommandLine $wrapperCmd -Pattern '' | Should Be $true
        # Null command line never matches a literal pattern.
        Test-WatcherSweepMatch -CommandLine $null -Pattern 'graphify-watch-wrapper' | Should Be $false
        # Regression: '|'-glued alternation is neutralized by [regex]::Escape.
        Test-WatcherSweepMatch -CommandLine $wrapperCmd -Pattern 'panes\\tail_|graphify-watch-wrapper' | Should Be $false
    }
}

if (-not $env:WATCHER_PATTERNS_TEST_RAN) {
    $env:WATCHER_PATTERNS_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
