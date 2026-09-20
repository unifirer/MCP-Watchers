# tests/launcher_mcp_provision.tests.ps1
# Pester 6 idiom (Should -Be / Should -Match). Bead mcpw-rkg.2 - the per-MCP
# provision ("make it so") layer in Modules/watcher_mcp_provision.ps1, the write
# side of the detection contract from mcpw-rkg.1.
#
# RUN IT WITH THE SUITE RUNNER:
#     python dev_tools/run_pester_suite.py tests/launcher_mcp_provision.tests.ps1
# Never trust the exit code - count the [-] lines (Pester 6.0.x dies in
# discovery yet exits 0). Report "N of M tests passed", never a bare pair.
#
# TWO PESTER-6 CONSTRAINTS THIS FILE IS SHAPED AROUND (measured on this box,
# Pester 6.1.0 under Windows PowerShell 5.1):
#
#   1. NOTHING DEFINED AT FILE SCOPE IS VISIBLE INSIDE AN It BLOCK - not a
#      variable, not a function, not a dot-sourced .ps1. Only $PSScriptRoot and
#      $PSCommandPath survive. So every It re-derives the module paths from
#      $PSScriptRoot and dot-sources the modules itself. Do not "tidy" that into
#      a file-scope helper - it will silently stop working.
#
#   2. This file must NOT import the Pester module itself - not even inside a
#      comment - because run_pester_suite.py's sniff is a plain substring test.
#      A false positive makes the runner execute the file DIRECTLY instead of
#      wrapping it, turning a Should--Be suite into a discovery-failure loop.
#
# CLEAN-ROOM BY CONSTRUCTION: every test runs against synthetic layouts and FAKE
# TOOLS (small .cmd shims) in a temp dir, so the suite needs NONE of the six
# real CLIs installed and never touches a real repository's tool state.
#
# A FAKE MUST PROVISION, NOT JUST EXIT 0. Since bead mcpw-0zo.1 a stamp is
# written only when the matching Test-<Mcp>Initialized probe confirms the repo
# is initialized AFTER the command ran, so a fake that exits 0 and produces
# nothing is a fake of a FAILED step. Those tests therefore have each fake
# create the artifacts its probe looks for, and put fakeDir on PATH (a probe
# resolves a tool by NAME, and fakeDir alone keeps the real installs out).
#
# WHY EVERY FAKE IS INJECTED VIA -ToolPaths RATHER THAN PUT ON PATH: the module
# resolves a tool by trying <name>.exe FIRST (the detect module's rule, needed
# because `gm` is also a PowerShell alias). A fake can only be a .cmd/.ps1, so
# on a box where the REAL <name>.exe exists a PATH lookup would find the real
# tool before the fake. -ToolPaths is used verbatim and bypasses PATH, which is
# exactly how repowise is pinned in production, so the tests exercise the same
# seam the launcher uses.

Describe 'watcher_mcp_provision: idempotent, non-interactive, degrading init' {

    It 'dot-sources cleanly and exposes the aggregate plus one initializer per MCP' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $module = Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1'
        Test-Path -LiteralPath $module | Should -BeTrue
        # Dot-sourced directly, NOT inside a Should -Not -Throw scriptblock: that
        # scriptblock runs in a child scope, so the functions would be defined
        # there and be invisible to the very next line.
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . $module

        $bad = @()
        foreach ($fn in @(
                'Invoke-McpProvisionForRepo',
                'Initialize-MemtraceForRepo', 'Initialize-GrepaiForRepo',
                'Initialize-GrapheniumForRepo', 'Initialize-GraphifyRsForRepo',
                'Initialize-RepowiseForRepo', 'Initialize-GraftForRepo',
                'Get-McpProvisionPlan', 'Get-McpProvisionArgv',
                'Test-McpProvisionStamp', 'Set-McpProvisionStamp',
                'Get-McpProvisionStateDir', 'Invoke-McpProvisionCommand')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { $bad += $fn }
        }
        ($bad -join ', ') | Should -Be '' -Because 'the provision surface must be complete'
    }

    It 'plans all six MCPs cheap-first: config, then build, then index' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $plan = @(Get-McpProvisionPlan)
        $plan.Count | Should -Be 6
        ($plan | ForEach-Object { $_.Mcp }) -join ',' |
            Should -Be 'graphenium,repowise,graphify-rs,graft,memtrace,grepai'

        # Phase must be non-decreasing across the plan: no expensive index step
        # may run before a cheap config step.
        $rank = @{ 'config' = 1; 'build' = 2; 'index' = 3 }
        $bad = @()
        $prev = 0
        foreach ($s in $plan) {
            $r = $rank[$s.Phase]
            if (-not $r) { $bad += "$($s.Mcp): unknown phase '$($s.Phase)'"; continue }
            if ($r -lt $prev) { $bad += "$($s.Mcp): phase $($s.Phase) runs after a costlier phase" }
            $prev = $r
        }
        ($bad -join '; ') | Should -Be ''

        # graphify-rs is the only optional step (bead mcpw-01g, P3).
        @($plan | Where-Object { $_.Optional } | ForEach-Object { $_.Mcp }) -join ',' | Should -Be 'graphify-rs'
    }

    It 'builds non-interactive command lines and never reads from a prompt' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $root = 'C:\synthetic\repo'
        $bad = @()
        $expect = @{
            # memtrace: the real equivalent of a "build" is `index`, and start/mcp
            # are forbidden here (they break the shared union store).
            'memtrace'    = @('index', '--allow-non-git')
            # grepai has no index verb; the scan belongs to watch.
            'grepai'      = @('watch', '--no-ui')
            'graphenium'  = @('init')
            'graphify-rs' = @('build', '--no-llm')
            'repowise'    = @('agents', 'add', '--target', 'claude-code', '--yes')
            'graft'       = @('build')
        }
        foreach ($mcp in $expect.Keys) {
            $argv = @(Get-McpProvisionArgv -Mcp $mcp -Path $root)
            foreach ($needle in $expect[$mcp]) {
                if ($argv -notcontains $needle) { $bad += "$mcp argv is missing '$needle' (got: $($argv -join ' '))" }
            }
        }
        # Explicit per-MCP suppressions that must NOT be there.
        if (@(Get-McpProvisionArgv -Mcp 'graft' -Path $root) -contains '--deep') { $bad += 'graft must never pass --deep (needs an LLM key)' }
        if (@(Get-McpProvisionArgv -Mcp 'memtrace' -Path $root) -contains 'start') { $bad += 'memtrace start must not be provisioned' }
        if (@(Get-McpProvisionArgv -Mcp 'memtrace' -Path $root) -contains 'mcp') { $bad += 'memtrace mcp must not be provisioned' }
        if (@(Get-McpProvisionArgv -Mcp 'grepai' -Step 'config' -Path $root) -notcontains '--yes') { $bad += 'grepai init must pass --yes' }
        if (@(Get-McpProvisionArgv -Mcp 'grepai' -Step 'status' -Path $root) -notcontains '--no-ui') { $bad += 'grepai status must pass --no-ui' }
        ($bad -join '; ') | Should -Be ''

        # No prompt can be raised by this module at all. Comments are stripped
        # first: this module's header deliberately NAMES the prompt cmdlets it
        # refuses to use, and the rule is about code, not prose.
        $text = Get-Content -LiteralPath (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1') -Raw
        $code = (($text -split "`r?`n") | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"
        foreach ($forbidden in @('Read-Host', 'PromptForChoice', '-Confirm', 'Get-Credential')) {
            $code.Contains($forbidden) | Should -BeFalse -Because "$forbidden would let provision block on input"
        }
    }

    It 'skips (never fails) every initializer when its binary is absent' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $savedPath = $env:Path
        try {
            # An empty directory alone on PATH makes every PATH-resolved tool
            # genuinely absent, exactly as on a clean-room box.
            $env:Path = $sandbox
            $cases = @(
                @{ Mcp = 'memtrace';    Exe = 'memtrace';    Fn = 'Initialize-MemtraceForRepo' }
                @{ Mcp = 'grepai';      Exe = 'grepai';      Fn = 'Initialize-GrepaiForRepo' }
                @{ Mcp = 'graphenium';  Exe = 'gm';          Fn = 'Initialize-GrapheniumForRepo' }
                @{ Mcp = 'graphify-rs'; Exe = 'graphify-rs'; Fn = 'Initialize-GraphifyRsForRepo' }
                @{ Mcp = 'graft';       Exe = 'graft';       Fn = 'Initialize-GraftForRepo' }
            )
            $bad = @()
            foreach ($c in $cases) {
                $row = & $c.Fn -Path $sandbox
                if (-not $row) { $bad += "$($c.Mcp): initializer returned nothing"; continue }
                if ($row.Status -ne 'skipped') { $bad += "$($c.Mcp): expected 'skipped', got '$($row.Status)'" }
                elseif ($row.Reason -notmatch '^binary not found:') { $bad += "$($c.Mcp): reason was '$($row.Reason)'" }
            }
            # repowise is pinned by absolute path, so a missing pin must skip -
            # and must NOT silently fall back to PATH.
            $rowW = Initialize-RepowiseForRepo -Path $sandbox -ToolPath (Join-Path $sandbox 'nope\repowise.exe')
            if ($rowW.Status -ne 'skipped') { $bad += "repowise: expected 'skipped', got '$($rowW.Status)'" }
            elseif ($rowW.Reason -notmatch '^binary not found:') { $bad += "repowise: reason was '$($rowW.Reason)'" }
            ($bad -join '; ') | Should -Be ''
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns a six-row summary that never throws, even for hostile inputs' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $fileAsPath = Join-Path $sandbox 'not-a-directory.txt'
        [System.IO.File]::WriteAllText($fileAsPath, 'x', (New-Object System.Text.UTF8Encoding($false)))
        $savedPath = $env:Path
        try {
            $env:Path = $sandbox
            # repowise is pinned by ABSOLUTE path in production, so emptying PATH
            # does not hide it - on this box the real uv-tool binary exists and
            # would really run. Point the pin at a path that does not exist so
            # this suite stays hermetic.
            $noTools = @{ repowise = (Join-Path $sandbox 'absent\repowise.exe') }
            # Empty repo, absent tools, a path that does not exist, a FILE as the
            # repo path, and a directory handed in as a tool path: none of these
            # may throw and none may abort the other steps.
            $runs = @(
                @{ Label = 'empty repo'; Path = $sandbox; ToolPaths = $noTools }
                @{ Label = 'missing path'; Path = (Join-Path $sandbox 'does-not-exist'); ToolPaths = $noTools }
                @{ Label = 'file as path'; Path = $fileAsPath; ToolPaths = $noTools }
                @{ Label = 'directory as tool'; Path = $sandbox; ToolPaths = @{ repowise = (Join-Path $sandbox 'absent\repowise.exe'); memtrace = $sandbox } }
            )
            $bad = @()
            foreach ($r in $runs) {
                $summary = $null
                try { $summary = Invoke-McpProvisionForRepo -Path $r.Path -ToolPaths $r.ToolPaths }
                catch {
                    $bad += "$($r.Label): Invoke-McpProvisionForRepo threw: $($_.Exception.Message)"
                    continue
                }
                if (-not $summary) { $bad += "$($r.Label): no summary returned"; continue }
                if ($summary.Total -ne 6) { $bad += "$($r.Label): expected 6 rows, got $($summary.Total)" }
                if (@($summary.Results).Count -ne 6) { $bad += "$($r.Label): Results has $((@($summary.Results)).Count) rows" }
                if ($summary.Done -ne 0) { $bad += "$($r.Label): nothing can be 'done' with no tools" }
                if ($summary.Stamped -ne 0) { $bad += "$($r.Label): nothing can be 'stamped' on a fresh repo" }
                $order = @($summary.Results | ForEach-Object { $_.Mcp }) -join ','
                if ($order -ne 'graphenium,repowise,graphify-rs,graft,memtrace,grepai') {
                    $bad += "$($r.Label): results out of plan order ($order)"
                }
                foreach ($row in @($summary.Results)) {
                    if ($row.Status -notin @('done', 'stamped', 'skipped')) { $bad += "$($r.Label)/$($row.Mcp): bad status '$($row.Status)'" }
                    if (-not $row.Reason) { $bad += "$($r.Label)/$($row.Mcp): empty reason" }
                }
            }
            ($bad -join '; ') | Should -Be ''
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is idempotent: the second run re-runs no build and reports the stamp' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $repo = Join-Path $sandbox 'repo'
        $fakeDir = Join-Path $sandbox 'fakes'
        $null = New-Item -ItemType Directory -Path $repo -Force
        $null = New-Item -ItemType Directory -Path $fakeDir -Force
        # graphify-rs is optional and skips without its config file; give it one
        # so all six steps really execute in run 1.
        [System.IO.File]::WriteAllText((Join-Path $repo 'graphify-rs.toml'), "[graph]`n", (New-Object System.Text.UTF8Encoding($false)))

        $log = Join-Path $sandbox 'calls.log'
        $crlf = "`r`n"
        # One fake per MCP. Each records its own argv, PROVISIONS the artifacts
        # its detection probe looks for, and exits 0. Every one is handed to the
        # module through -ToolPaths, so no real install on this box can be picked
        # up by the .exe-first resolver.
        #
        # THE PROVISIONING IS THE POINT. Since bead mcpw-0zo.1 a stamp is written
        # only when the matching probe confirms the repository is really
        # initialized, so a fake that merely exits 0 is a fake of a FAILED step,
        # not of a successful one - which is exactly the bug that bead fixes.
        $names = @{ graphenium = 'gm'; repowise = 'repowise'; 'graphify-rs' = 'graphify-rs'; graft = 'graft'; memtrace = 'memtrace'; grepai = 'grepai' }
        $provision = @{
            graphenium = @(
                'type nul > .grapheniumignore',
                'mkdir graphenium-out 2>nul',
                'echo {}> graphenium-out\graph.json'
            )
            repowise = @(
                'if "%1"=="doctor" goto doc',
                'mkdir .repowise 2>nul',
                'goto :eof',
                ':doc',
                'echo Claude Code MCP entry ^| OK ^| registered'
            )
            'graphify-rs' = @(
                'mkdir graphify-out 2>nul',
                'echo {}> graphify-out\graph.json'
            )
            graft = @(
                'mkdir graft\.graph 2>nul',
                'echo {}> graft\.graph\wiring.json',
                'echo # graph> graft\INDEX.md'
            )
            memtrace = @(
                'set P=%~2',
                'set P=%P:\=/%',
                'mkdir .memdb 2>nul',
                'echo {"version":1,"members":[{"repo_id":"t","path":"%P%"}]}> .memdb\.memtrace-store-scope.json'
            )
            grepai = @(
                'if "%1"=="init" goto cfg',
                'if "%1"=="status" goto st',
                'goto :eof',
                ':cfg',
                'mkdir .grepai 2>nul',
                'echo embedder: test> .grepai\config.yaml',
                'goto :eof',
                ':st',
                'echo Files indexed: 0',
                'echo Total chunks: 5'
            )
        }
        $toolPaths = @{}
        foreach ($mcp in $names.Keys) {
            $file = Join-Path $fakeDir ($names[$mcp] + '.cmd')
            $lines = @('@echo off', ('echo ' + $mcp + ' %* >> "' + $log + '"'))
            $lines += $provision[$mcp]
            $lines += 'exit /b 0'
            [System.IO.File]::WriteAllText($file, (($lines -join $crlf) + $crlf), (New-Object System.Text.ASCIIEncoding))
            $toolPaths[$mcp] = $file
        }

        # A probe resolves a tool by NAME from PATH, so the fakes must be ON PATH
        # for the post-command gate to be able to ask them. PATH made of just
        # fakeDir keeps every real install on this box out of the lookup.
        $savedPath = $env:Path
        try {
            $env:Path = $fakeDir

            # ---- run 1: everything really runs --------------------------------
            $first = Invoke-McpProvisionForRepo -Path $repo -ToolPaths $toolPaths -TimeoutMs 30000 -FirstScanTimeoutMs 30000
            $first.Total | Should -Be 6
            $bad = @($first.Results | Where-Object { $_.Status -ne 'done' } | ForEach-Object { "$($_.Mcp)=$($_.Status) ($($_.Reason))" })
            ($bad -join '; ') | Should -Be '' -Because 'a fake tool that provisions what its probe looks for must complete'
            $first.Done | Should -Be 6
            $first.Stamped | Should -Be 0

            # The stamp is the idempotence mechanism, so assert on the FILE.
            $stampFile = Join-Path $repo '.mcpw-bootstrap\state.json'
            Test-Path -LiteralPath $stampFile -PathType Leaf | Should -BeTrue
            $stampDoc = Get-Content -LiteralPath $stampFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $stampedKeys = @($stampDoc.PSObject.Properties | ForEach-Object { $_.Name })
            ($stampedKeys | Sort-Object) -join ',' | Should -Be 'graft,graphenium,graphify-rs,grepai,memtrace,repowise'
            Test-Path -LiteralPath $log -PathType Leaf | Should -BeTrue
            $callsAfterFirst = @(Get-Content -LiteralPath $log).Count
            ($callsAfterFirst -ge 6) | Should -BeTrue -Because 'every step should have invoked its tool at least once'

            # ---- run 2: stamp short-circuits everything -----------------------
            $second = Invoke-McpProvisionForRepo -Path $repo -ToolPaths $toolPaths -TimeoutMs 30000 -FirstScanTimeoutMs 30000
            $second.Total | Should -Be 6
            $second.Stamped | Should -Be 6
            $second.Done | Should -Be 0
            $bad2 = @($second.Results | Where-Object { $_.Status -ne 'stamped' } | ForEach-Object { "$($_.Mcp)=$($_.Status)" })
            ($bad2 -join '; ') | Should -Be '' -Because 'a stamped repo must not re-run any step'
            foreach ($row in @($second.Results)) {
                $row.Reason | Should -Match 'stamp'
            }
            # THE assertion: not one tool was spawned again.
            (@(Get-Content -LiteralPath $log).Count -eq $callsAfterFirst) | Should -BeTrue -Because 'the second run must spawn nothing'

            # ---- -Force ignores the stamp -------------------------------------
            # The artifacts have to go first. -Force bypasses the STAMP, not the
            # pre-command probe, so with the artifacts still in place every step
            # would report 'stamped' and no tool would be spawned.
            foreach ($d in @('.grapheniumignore', 'graphenium-out', '.repowise', 'graphify-out', 'graft', '.memdb', '.grepai')) {
                Remove-Item -LiteralPath (Join-Path $repo $d) -Recurse -Force -ErrorAction SilentlyContinue
            }
            $forced = Invoke-McpProvisionForRepo -Path $repo -ToolPaths $toolPaths -Force -TimeoutMs 30000 -FirstScanTimeoutMs 30000
            $forced.Done | Should -Be 6
            (@(Get-Content -LiteralPath $log).Count -gt $callsAfterFirst) | Should -BeTrue -Because '-Force must re-run the steps'
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'degrades: a tool that exits non-zero is skipped while the other five run' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $repo = Join-Path $sandbox 'repo'
        $fakeDir = Join-Path $sandbox 'fakes'
        $null = New-Item -ItemType Directory -Path $repo -Force
        $null = New-Item -ItemType Directory -Path $fakeDir -Force
        [System.IO.File]::WriteAllText((Join-Path $repo 'graphify-rs.toml'), "[graph]`n", (New-Object System.Text.UTF8Encoding($false)))

        $log = Join-Path $sandbox 'calls.log'
        $crlf = "`r`n"
        $names = @{ graphenium = 'gm'; repowise = 'repowise'; 'graphify-rs' = 'graphify-rs'; graft = 'graft'; memtrace = 'memtrace'; grepai = 'grepai' }
        # The five non-saboteurs provision what their probes look for (bead
        # mcpw-0zo.1: a stamp now needs a confirmed probe, not just exit 0).
        $provision = @{
            graphenium = @(
                'type nul > .grapheniumignore',
                'mkdir graphenium-out 2>nul',
                'echo {}> graphenium-out\graph.json'
            )
            repowise = @(
                'if "%1"=="doctor" goto doc',
                'mkdir .repowise 2>nul',
                'goto :eof',
                ':doc',
                'echo Claude Code MCP entry ^| OK ^| registered'
            )
            'graphify-rs' = @(
                'mkdir graphify-out 2>nul',
                'echo {}> graphify-out\graph.json'
            )
            graft = @()
            memtrace = @(
                'set P=%~2',
                'set P=%P:\=/%',
                'mkdir .memdb 2>nul',
                'echo {"version":1,"members":[{"repo_id":"t","path":"%P%"}]}> .memdb\.memtrace-store-scope.json'
            )
            grepai = @(
                'if "%1"=="init" goto cfg',
                'if "%1"=="status" goto st',
                'goto :eof',
                ':cfg',
                'mkdir .grepai 2>nul',
                'echo embedder: test> .grepai\config.yaml',
                'goto :eof',
                ':st',
                'echo Files indexed: 0',
                'echo Total chunks: 5'
            )
        }
        $toolPaths = @{}
        foreach ($mcp in $names.Keys) {
            $lines = @('@echo off', ('echo ' + $mcp + ' %* >> "' + $log + '"'))
            # graft is the saboteur: it exits 7, complains on stderr, and
            # deliberately provisions nothing.
            if ($mcp -eq 'graft') {
                $lines += 'echo graft refused to build 1>&2'
                $lines += 'exit /b 7'
            } else {
                $lines += $provision[$mcp]
                $lines += 'exit /b 0'
            }
            $file = Join-Path $fakeDir ($names[$mcp] + '.cmd')
            [System.IO.File]::WriteAllText($file, (($lines -join $crlf) + $crlf), (New-Object System.Text.ASCIIEncoding))
            $toolPaths[$mcp] = $file
        }

        # The probes resolve a tool by NAME from PATH, so the fakes must be there
        # for the post-command gate; fakeDir alone keeps the real installs out.
        $savedPath = $env:Path
        try {
            $env:Path = $fakeDir
            $summary = Invoke-McpProvisionForRepo -Path $repo -ToolPaths $toolPaths -TimeoutMs 30000 -FirstScanTimeoutMs 30000

            $summary.Total | Should -Be 6
            $graft = @($summary.Results | Where-Object { $_.Mcp -eq 'graft' })[0]
            $graft.Status | Should -Be 'skipped'
            $graft.Reason | Should -Match 'exited 7'
            $graft.Reason | Should -Match 'refused to build'
            $summary.Skipped | Should -Be 1
            $others = @($summary.Results | Where-Object { $_.Mcp -ne 'graft' } | Where-Object { $_.Status -ne 'done' } | ForEach-Object { "$($_.Mcp)=$($_.Status)" })
            ($others -join '; ') | Should -Be '' -Because 'one broken MCP must not stop the other five'
            # A skipped step writes no stamp, so a later run retries it.
            (Test-McpProvisionStamp -Path $repo -Mcp 'graft') | Should -BeFalse
            (Test-McpProvisionStamp -Path $repo -Mcp 'memtrace') | Should -BeTrue
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats graphify-rs as optional when graphify-rs.toml is missing' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $repo = Join-Path $sandbox 'repo'
        $fakeDir = Join-Path $sandbox 'fakes'
        $null = New-Item -ItemType Directory -Path $repo -Force
        $null = New-Item -ItemType Directory -Path $fakeDir -Force
        $crlf = "`r`n"
        # A graphify-rs binary IS present - the skip must come from the missing
        # config file, not from a missing binary.
        $fake = Join-Path $fakeDir 'graphify-rs.cmd'
        [System.IO.File]::WriteAllText($fake, '@echo off' + $crlf + 'exit /b 0' + $crlf, (New-Object System.Text.ASCIIEncoding))

        try {
            $row = Initialize-GraphifyRsForRepo -Path $repo -ToolPath $fake
            $row.Mcp | Should -Be 'graphify-rs'
            $row.Status | Should -Be 'skipped'
            $row.Reason | Should -Match 'optional'
            $row.Reason | Should -Match 'graphify-rs\.toml'
            # Optional means optional in the summary too.
            $summary = Invoke-McpProvisionForRepo -Path $repo -Only @('graphify-rs') -ToolPaths @{ 'graphify-rs' = $fake }
            $summary.Total | Should -Be 1
            @($summary.Results)[0].Optional | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keys the stamp per repository, under the repo .mcpw-bootstrap dir by default' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $repoA = Join-Path $sandbox 'repo-a'
        $repoB = Join-Path $sandbox 'repo-b'
        $fakeDir = Join-Path $sandbox 'fakes'
        foreach ($d in @($repoA, $repoB, $fakeDir)) { $null = New-Item -ItemType Directory -Path $d -Force }
        $crlf = "`r`n"
        $names = @{ graphenium = 'gm'; repowise = 'repowise'; 'graphify-rs' = 'graphify-rs'; graft = 'graft'; memtrace = 'memtrace'; grepai = 'grepai' }
        # Each fake provisions what its probe looks for (bead mcpw-0zo.1: a stamp
        # needs a confirmed probe, not just exit 0) and writes into its own cwd,
        # which is the repo the step was given - so repo-a and repo-b get
        # separate artifacts as well as separate stamps.
        $provision = @{
            graphenium = @(
                'type nul > .grapheniumignore',
                'mkdir graphenium-out 2>nul',
                'echo {}> graphenium-out\graph.json'
            )
            repowise = @(
                'if "%1"=="doctor" goto doc',
                'mkdir .repowise 2>nul',
                'goto :eof',
                ':doc',
                'echo Claude Code MCP entry ^| OK ^| registered'
            )
            'graphify-rs' = @(
                'mkdir graphify-out 2>nul',
                'echo {}> graphify-out\graph.json'
            )
            graft = @(
                'mkdir graft\.graph 2>nul',
                'echo {}> graft\.graph\wiring.json',
                'echo # graph> graft\INDEX.md'
            )
            memtrace = @(
                'set P=%~2',
                'set P=%P:\=/%',
                'mkdir .memdb 2>nul',
                'echo {"version":1,"members":[{"repo_id":"t","path":"%P%"}]}> .memdb\.memtrace-store-scope.json'
            )
            grepai = @(
                'if "%1"=="init" goto cfg',
                'if "%1"=="status" goto st',
                'goto :eof',
                ':cfg',
                'mkdir .grepai 2>nul',
                'echo embedder: test> .grepai\config.yaml',
                'goto :eof',
                ':st',
                'echo Files indexed: 0',
                'echo Total chunks: 5'
            )
        }
        $toolPaths = @{}
        foreach ($mcp in $names.Keys) {
            $file = Join-Path $fakeDir ($names[$mcp] + '.cmd')
            $lines = @('@echo off') + $provision[$mcp] + 'exit /b 0'
            [System.IO.File]::WriteAllText($file, (($lines -join $crlf) + $crlf), (New-Object System.Text.ASCIIEncoding))
            $toolPaths[$mcp] = $file
        }

        $savedPath = $env:Path
        try {
            # The probes resolve a tool by NAME from PATH; fakeDir alone keeps the
            # real installs on this box out of the lookup.
            $env:Path = $fakeDir
            # Default state dir roots at -Path, not at the machine or the module.
            (Get-McpProvisionStateDir -Path $repoA) | Should -Be (Join-Path $repoA '.mcpw-bootstrap')
            # An explicit -StateDir wins.
            $alt = Join-Path $sandbox 'alt-state'
            (Get-McpProvisionStateDir -Path $repoA -StateDir $alt) | Should -Be $alt

            $a = Invoke-McpProvisionForRepo -Path $repoA -ToolPaths $toolPaths -TimeoutMs 30000 -FirstScanTimeoutMs 30000
            $a.Stamped | Should -Be 0
            (Test-McpProvisionStamp -Path $repoA -Mcp 'graft') | Should -BeTrue
            # A stamp belongs to ONE repository: repo B is untouched by it.
            (Test-McpProvisionStamp -Path $repoB -Mcp 'graft') | Should -BeFalse
            $b = Invoke-McpProvisionForRepo -Path $repoB -ToolPaths $toolPaths -TimeoutMs 30000 -FirstScanTimeoutMs 30000
            $b.Stamped | Should -Be 0
            ($b.Done -gt 0) | Should -BeTrue
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'roots every path at -Path: no absolute reference to any repository' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $text = Get-Content -LiteralPath (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1') -Raw
        # Built from parts so this assertion cannot itself be the absolute path
        # it is forbidding.
        $drive = [char]74   # 'J'
        foreach ($needle in @(($drive + ':\audio'), ($drive + ':/audio'), 'VAD')) {
            $text.Contains($needle) | Should -BeFalse -Because "the module must be repo-agnostic (found '$needle')"
        }
        # The one machine-global input it does use must be environment-derived.
        $text.Contains('$env:APPDATA') | Should -BeTrue
    }

    It 'writes a readable stamp file and tolerates a corrupt one' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        try {
            (Test-McpProvisionStamp -Path $sandbox -Mcp 'graft') | Should -BeFalse
            (Set-McpProvisionStamp -Path $sandbox -Mcp 'graft' -Detail 'unit' -Tool 'graft.exe') | Should -BeTrue
            (Test-McpProvisionStamp -Path $sandbox -Mcp 'graft') | Should -BeTrue
            (Test-McpProvisionStamp -Path $sandbox -Mcp 'memtrace') | Should -BeFalse
            $doc = Get-Content -LiteralPath (Join-Path $sandbox '.mcpw-bootstrap\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $doc.graft.Detail | Should -Be 'unit'

            # A truncated stamp must read as "not initialized" (so the step runs
            # again) and must never throw.
            [System.IO.File]::WriteAllText((Join-Path $sandbox '.mcpw-bootstrap\state.json'), '{ not json', (New-Object System.Text.UTF8Encoding($false)))
            (Test-McpProvisionStamp -Path $sandbox -Mcp 'graft') | Should -BeFalse
            (Set-McpProvisionStamp -Path $sandbox -Mcp 'graft' -Detail 'repaired' -Tool 'graft.exe') | Should -BeTrue
            (Test-McpProvisionStamp -Path $sandbox -Mcp 'graft') | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'closes stdin, so a tool that would prompt sees EOF instead of blocking' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $crlf = "`r`n"
        $prompter = Join-Path $sandbox 'prompter.cmd'
        $proof = Join-Path $sandbox 'stdin-proof.txt'
        # `set /p` reads a line from stdin. With stdin closed it fails
        # immediately; if stdin were an open pipe this would block until the
        # timeout, and the assertion below would catch it.
        $body = '@echo off' + $crlf +
                'set /p ANSWER="give me input: "' + $crlf +
                'echo EOF=%ERRORLEVEL% ANSWER=[%ANSWER%] >> "' + $proof + '"' + $crlf +
                'exit /b 0' + $crlf
        [System.IO.File]::WriteAllText($prompter, $body, (New-Object System.Text.ASCIIEncoding))
        try {
            $r = Invoke-McpProvisionCommand -FilePath $prompter -WorkingDirectory $sandbox -TimeoutMs 15000
            $r.Launched | Should -BeTrue
            $r.TimedOut | Should -BeFalse -Because 'a closed stdin must not hang the child'
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath $proof -PathType Leaf | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'kills a command that overruns its timeout instead of hanging the launcher' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $crlf = "`r`n"
        $sleeper = Join-Path $sandbox 'sleeper.cmd'
        # ping is used as a portable sleep; the timeout must cut it short.
        $body = '@echo off' + $crlf + 'ping -n 60 127.0.0.1 > nul' + $crlf + 'exit /b 0' + $crlf
        [System.IO.File]::WriteAllText($sleeper, $body, (New-Object System.Text.ASCIIEncoding))
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-McpProvisionCommand -FilePath $sleeper -WorkingDirectory $sandbox -TimeoutMs 2500
            $sw.Stop()
            $r.Launched | Should -BeTrue
            $r.TimedOut | Should -BeTrue
            # Bounded by the timeout, not by the child's 60s nap. Generous upper
            # bound so a loaded box cannot false-fail this.
            ($sw.Elapsed.TotalSeconds -lt 30) | Should -BeTrue -Because 'the runner must not wait for the child'
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses to stamp a step whose command exits 0 without provisioning' {
        # Bead mcpw-0zo.1. The historical false-success shape: every child exits
        # 0 and produces NOTHING the matching probe looks for. Before the fix all
        # six were stamped 'done' on the exit code alone, so the repo was
        # recorded as provisioned forever and every later launch skipped it.
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'Modules\watcher_mcp_detect.ps1')
        . (Join-Path $repoRoot 'Modules\watcher_mcp_provision.ps1')

        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-boot-' + [guid]::NewGuid().ToString('N'))
        $repo = Join-Path $sandbox 'repo'
        $fakeDir = Join-Path $sandbox 'fakes'
        $null = New-Item -ItemType Directory -Path $repo -Force
        $null = New-Item -ItemType Directory -Path $fakeDir -Force
        # Keep the optional step in play: without graphify-rs.toml it would skip
        # as optional BEFORE any command ran, which is not what this asserts.
        [System.IO.File]::WriteAllText((Join-Path $repo 'graphify-rs.toml'), "[graph]`n", (New-Object System.Text.UTF8Encoding($false)))

        $crlf = "`r`n"
        $names = @{ graphenium = 'gm'; repowise = 'repowise'; 'graphify-rs' = 'graphify-rs'; graft = 'graft'; memtrace = 'memtrace'; grepai = 'grepai' }
        $toolPaths = @{}
        foreach ($mcp in $names.Keys) {
            $file = Join-Path $fakeDir ($names[$mcp] + '.cmd')
            [System.IO.File]::WriteAllText($file, '@echo off' + $crlf + 'exit /b 0' + $crlf, (New-Object System.Text.ASCIIEncoding))
            $toolPaths[$mcp] = $file
        }

        $savedPath = $env:Path
        try {
            # PATH holds only the fakes, so every probe can resolve its binary and
            # the verdict is decided by the ARTIFACTS alone.
            $env:Path = $fakeDir

            $summary = Invoke-McpProvisionForRepo -Path $repo -ToolPaths $toolPaths -TimeoutMs 30000 -FirstScanTimeoutMs 30000
            $summary.Total | Should -Be 6
            $summary.Done | Should -Be 0 -Because 'exit 0 is not proof of provisioning'
            $summary.Stamped | Should -Be 0
            $summary.Skipped | Should -Be 6
            $bad = @()
            foreach ($row in @($summary.Results)) {
                if ($row.Status -ne 'skipped') { $bad += "$($row.Mcp)=$($row.Status)"; continue }
                if ($row.Reason -notmatch 'exited 0 but the probe still reports') {
                    $bad += "$($row.Mcp): reason does not carry the probe verdict ('$($row.Reason)')"
                }
            }
            ($bad -join '; ') | Should -Be ''
            # A refused stamp is a refusal to RECORD: nothing on disk...
            Test-Path -LiteralPath (Join-Path $repo '.mcpw-bootstrap\state.json') -PathType Leaf | Should -BeFalse
            # ...so a later run retries the step instead of skipping it forever.
            (Test-McpProvisionStamp -Path $repo -Mcp 'graft') | Should -BeFalse
            (Test-McpProvisionStamp -Path $repo -Mcp 'memtrace') | Should -BeFalse
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
