# tests/launcher_mcp_detect.tests.ps1
# Pester 6 idiom (Should -Be). Bead mcpw-rkg.1 - the per-MCP "is it initialized?"
# detection contract in Modules/watcher_mcp_detect.ps1.
#
# RUN IT WITH THE SUITE RUNNER:
#     python dev_tools/run_pester_suite.py tests/launcher_mcp_detect.tests.ps1
# The runner sniffs `Should -` and wraps this file in Pester 6.1.0. Never trust
# the exit code - count the [-] lines (Pester 6.0.x dies in discovery yet exits 0).
#
# TWO PESTER-6 CONSTRAINTS THIS FILE IS SHAPED AROUND (measured on this box,
# Pester 6.1.0 under Windows PowerShell 5.1):
#
#   1. NOTHING DEFINED AT FILE SCOPE IS VISIBLE INSIDE AN It BLOCK.
#      Verified by direct experiment: file-scope variables (plain, `$script:`
#      qualified, literal and computed) all read back EMPTY, a function defined
#      at file scope is CommandNotFoundException, a function arriving from a
#      dot-sourced .ps1 is CommandNotFoundException, and a scriptblock held in a
#      file-scope variable is "not a valid object". The ONLY things that do
#      survive are the automatic variables: $PSScriptRoot and $PSCommandPath.
#      So every It re-derives the module path from $PSScriptRoot and dot-sources
#      the module itself. Do not "tidy" that into a file-scope helper - it will
#      silently stop working.
#
#   2. This file must NOT import the Pester module itself - not even inside a
#      comment, because run_pester_suite.py's sniff is a plain substring test.
#      A file that appears to pick its own Pester is executed DIRECTLY instead
#      of being wrapped, which for a Should--Be suite produces a
#      discovery-failure retry loop rather than a verdict. Let the runner wrap
#      this file in Pester 6.1.0, which is what the sniffed `Should -` selects.
#
# PORTABILITY: the six CLIs (memtrace, grepai, gm, graphify-rs, repowise, graft)
# are installed on this box, so the layout assertions really exercise the layout
# branch. Each such assertion still branches on whether the tool is on PATH and
# asserts the "binary not found" verdict otherwise, so the suite stays honest on
# a clean-room box instead of silently passing or false-failing.

Describe 'watcher_mcp_detect: one initialization probe per MCP' {

    It 'dot-sources cleanly and exposes one probe per MCP' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        Test-Path -LiteralPath $module | Should -BeTrue
        # Dot-sourced directly, NOT inside a `Should -Not -Throw` scriptblock:
        # that scriptblock runs in a child scope, so the probe functions would be
        # defined there and be invisible to the very next line. A throw here
        # fails the It anyway, which is the assertion.
        . $module

        $bad = @()
        foreach ($fn in @(
                'Test-MemtraceInitialized', 'Test-GrepaiInitialized', 'Test-GrapheniumInitialized',
                'Test-GraphifyRsInitialized', 'Test-RepowiseInitialized', 'Test-GraftInitialized',
                'Get-McpInitializationReport')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { $bad += $fn }
        }
        ($bad -join ', ') | Should -Be '' -Because 'every probe must be exported by the module'
    }

    It 'reports FALSE with a diagnostic reason on an empty directory' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        try {
            $probes = @(
                @{ Mcp = 'memtrace';    Fn = 'Test-MemtraceInitialized' }
                @{ Mcp = 'grepai';      Fn = 'Test-GrepaiInitialized' }
                @{ Mcp = 'graphenium';  Fn = 'Test-GrapheniumInitialized' }
                @{ Mcp = 'graphify-rs'; Fn = 'Test-GraphifyRsInitialized' }
                @{ Mcp = 'repowise';    Fn = 'Test-RepowiseInitialized' }
                @{ Mcp = 'graft';       Fn = 'Test-GraftInitialized' }
            )
            # Vocabulary of every legitimate "not initialized" reason. A bare
            # $false with an empty reason would be useless in the launcher log,
            # so an empty or unrecognised reason is a failure in its own right.
            $vocabulary = 'binary not found|missing|not a member|did not report|no output|unreadable|path not found'
            $bad = @()
            foreach ($p in $probes) {
                $reason = ''
                $ok = [bool](& $p.Fn -Path $sandbox -Reason ([ref]$reason))
                if ($ok) { $bad += "$($p.Mcp): expected FALSE on an empty directory" }
                elseif (-not $reason) { $bad += "$($p.Mcp): FALSE with an EMPTY reason" }
                elseif ($reason -notmatch $vocabulary) { $bad += "$($p.Mcp): unrecognised reason '$reason'" }
            }
            ($bad -join '; ') | Should -Be ''
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports TRUE on a synthetic initialized layout for every MCP' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        try {
            # Synthetic layout - exactly the artifacts each probe looks for, and
            # nothing else. Built under a temp dir so it can never touch a real
            # repository's tool state.
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            foreach ($d in @('.memdb', '.grepai', 'graphenium-out', 'graphify-out', '.repowise', 'graft')) {
                $null = New-Item -ItemType Directory -Path (Join-Path $sandbox $d) -Force
            }
            # memtrace: the repo itself must be a scope member. Forward slashes
            # and the sandbox's own casing, exactly as memtrace writes it.
            $scope = '{"version":1,"members":[{"repo_id":"synthetic","path":"' + ($sandbox -replace '\\', '/') + '"}]}'
            [System.IO.File]::WriteAllText((Join-Path $sandbox '.memdb\.memtrace-store-scope.json'), $scope, $utf8)
            [System.IO.File]::WriteAllText((Join-Path $sandbox '.grepai\config.yaml'), "embedder:`n  provider: ollama`n", $utf8)
            # graphenium: `gm init` writes .grapheniumignore (a FILE) - the
            # workspace marker; no gm subcommand creates a .graphenium/ dir.
            [System.IO.File]::WriteAllText((Join-Path $sandbox '.grapheniumignore'), "target/\n", $utf8)
            [System.IO.File]::WriteAllText((Join-Path $sandbox 'graphenium-out\graph.json'), '{"nodes":[]}', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $sandbox 'graphify-out\graph.json'), '{"nodes":[]}', $utf8)
            # graft: the $0 no-key build writes wiring.json AND INDEX.md (never
            # manifest.json, which is the --deep tier).
            $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'graft\.graph') -Force
            [System.IO.File]::WriteAllText((Join-Path $sandbox 'graft\.graph\wiring.json'), '{"wiring":[]}', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $sandbox 'graft\INDEX.md'), '# graft index', $utf8)

            # Shape copied from the real commands (raw captures are in
            # reports/2026-09-20-mcpw-rkg1-detection-contract.md). Injected so
            # the assertions are deterministic and no live grepai/repowise run
            # is needed.
            $grepaiStatus = "grepai index status`nFiles indexed: 42`nTotal chunks: 892`nWatcher: running"
            $repowiseDoctor = "| Claude Code MCP entry | OK | registered: repowise mcp . --transport stdio |"

            $rM = ''; $okM = [bool](Test-MemtraceInitialized   -Path $sandbox -Reason ([ref]$rM))
            $rG = ''; $okG = [bool](Test-GrepaiInitialized     -Path $sandbox -Reason ([ref]$rG) -ProbeOutput $grepaiStatus)
            $rN = ''; $okN = [bool](Test-GrapheniumInitialized -Path $sandbox -Reason ([ref]$rN))
            $rF = ''; $okF = [bool](Test-GraphifyRsInitialized -Path $sandbox -Reason ([ref]$rF))
            $rW = ''; $okW = [bool](Test-RepowiseInitialized   -Path $sandbox -Reason ([ref]$rW) -ProbeOutput $repowiseDoctor)
            $rT = ''; $okT = [bool](Test-GraftInitialized      -Path $sandbox -Reason ([ref]$rT))

            $cases = @(
                @{ Mcp = 'memtrace';    Exe = 'memtrace';    Ok = $okM; Reason = $rM }
                @{ Mcp = 'grepai';      Exe = 'grepai';      Ok = $okG; Reason = $rG }
                @{ Mcp = 'graphenium';  Exe = 'gm';          Ok = $okN; Reason = $rN }
                @{ Mcp = 'graphify-rs'; Exe = 'graphify-rs'; Ok = $okF; Reason = $rF }
                @{ Mcp = 'repowise';    Exe = 'repowise';    Ok = $okW; Reason = $rW }
                @{ Mcp = 'graft';       Exe = 'graft';       Ok = $okT; Reason = $rT }
            )
            # A probe is TRUE only when its tool is on PATH - that is the
            # contract (binary check first). Assert accordingly, and collect
            # every MCP's verdict so one bad probe does not hide the rest.
            $bad = @()
            foreach ($c in $cases) {
                if (Resolve-McpDetectTool -Name $c.Exe) {
                    if (-not $c.Ok) { $bad += "$($c.Mcp): expected TRUE, got FALSE ($($c.Reason))" }
                } elseif ($c.Ok) {
                    $bad += "$($c.Mcp): tool absent but probe said TRUE"
                } elseif ($c.Reason -notmatch '^binary not found:') {
                    $bad += "$($c.Mcp): tool absent but reason was '$($c.Reason)'"
                }
            }
            ($bad -join '; ') | Should -Be ''
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports FALSE with "binary not found" when the tool is absent from PATH' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        # An empty directory is a valid -Path for this probe; putting it alone
        # on PATH is what makes every tool genuinely absent (verified: emptying
        # $env:Path hides a command PowerShell had already resolved).
        $savedPath = $env:Path
        try {
            $env:Path = $sandbox
            $probes = @(
                @{ Mcp = 'memtrace';    Exe = 'memtrace';    Fn = 'Test-MemtraceInitialized' }
                @{ Mcp = 'grepai';      Exe = 'grepai';      Fn = 'Test-GrepaiInitialized' }
                @{ Mcp = 'graphenium';  Exe = 'gm';          Fn = 'Test-GrapheniumInitialized' }
                @{ Mcp = 'graphify-rs'; Exe = 'graphify-rs'; Fn = 'Test-GraphifyRsInitialized' }
                @{ Mcp = 'repowise';    Exe = 'repowise';    Fn = 'Test-RepowiseInitialized' }
                @{ Mcp = 'graft';       Exe = 'graft';       Fn = 'Test-GraftInitialized' }
            )
            $bad = @()
            foreach ($p in $probes) {
                $reason = ''
                $ok = [bool](& $p.Fn -Path $sandbox -Reason ([ref]$reason))
                if ($ok) { $bad += "$($p.Mcp): expected FALSE, got TRUE" }
                elseif ($reason -ne "binary not found: $($p.Exe)") {
                    $bad += "$($p.Mcp): expected reason 'binary not found: $($p.Exe)', got '$reason'"
                }
            }
            ($bad -join '; ') | Should -Be ''
        } finally {
            $env:Path = $savedPath
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports TRUE for grepai on chunks alone when Files indexed is 0 (the measured qdrant shape)' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $sandbox '.grepai') -Force
        try {
            # CONTRACT CHANGE (bead mcpw-4ci). The old contract keyed on
            # "Files indexed" > 0, which grepai NEVER computes on a qdrant
            # backend (upstream hardcodes TotalFiles: 0) - so the probe was
            # unsatisfiable and the bootstrap first scan re-ran every launch.
            # The measured shape here is a correct config, a fresh clock, 0
            # files, and 892 chunks: that index HAS content and IS initialized.
            [System.IO.File]::WriteAllText((Join-Path $sandbox '.grepai\config.yaml'),
                "embedder:`n  provider: ollama`n  model: nomic-embed-text`n", (New-Object System.Text.UTF8Encoding($false)))
            $status = "grepai index status`nFiles indexed: 0`nTotal chunks: 892`nLast updated: 2026-09-20 14:31:22`nWatcher: not running"

            $reason = ''
            $ok = [bool](Test-GrepaiInitialized -Path $sandbox -Reason ([ref]$reason) -ProbeOutput $status)
            $ok | Should -BeTrue
            if (Resolve-McpDetectTool -Name 'grepai') {
                $reason | Should -Match 'Total chunks: 892'
            } else {
                $reason | Should -Match '^binary not found:'
            }
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports FALSE for grepai when the index is genuinely empty (0 files and 0 chunks)' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $sandbox '.grepai') -Force
        try {
            # Both counters zero is the only genuinely-uninitialized state: no
            # vectors exist, so there is nothing to search. Must be FALSE.
            [System.IO.File]::WriteAllText((Join-Path $sandbox '.grepai\config.yaml'),
                "embedder:`n  provider: ollama`n  model: nomic-embed-text`n", (New-Object System.Text.UTF8Encoding($false)))
            $status = "grepai index status`nFiles indexed: 0`nTotal chunks: 0`nLast updated: 2026-09-20 14:31:22`nWatcher: not running"

            $reason = ''
            $ok = [bool](Test-GrepaiInitialized -Path $sandbox -Reason ([ref]$reason) -ProbeOutput $status)
            $ok | Should -BeFalse
            if (Resolve-McpDetectTool -Name 'grepai') {
                $reason | Should -Match 'empty index'
            } else {
                $reason | Should -Match '^binary not found:'
            }
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports FALSE for graphenium when the graph exists but .grapheniumignore does not' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'graphenium-out') -Force
        try {
            # The measured counter-example: a graph from an earlier `gm run`
            # with no workspace marker at all (no .grapheniumignore). Must be
            # FALSE - the marker is what `gm init` produces, the graph is not.
            [System.IO.File]::WriteAllText((Join-Path $sandbox 'graphenium-out\graph.json'),
                '{"nodes":[{"id":1}],"edges":[]}', (New-Object System.Text.UTF8Encoding($false)))

            $reason = ''
            $ok = [bool](Test-GrapheniumInitialized -Path $sandbox -Reason ([ref]$reason))
            $ok | Should -BeFalse
            if (Resolve-McpDetectTool -Name 'gm') {
                $reason | Should -Match 'grapheniumignore'
            } else {
                $reason | Should -Match '^binary not found:'
            }
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports FALSE for graft when only graft/.graph/wiring.json exists' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'graft\.graph') -Force
        try {
            # wiring.json alone is the wiring cache, not the graph - INDEX.md is
            # the other half of the $0 build. A lone wiring.json is a partial or
            # interrupted build. Must be FALSE.
            [System.IO.File]::WriteAllText((Join-Path $sandbox 'graft\.graph\wiring.json'),
                '{"stale":true}', (New-Object System.Text.UTF8Encoding($false)))

            $reason = ''
            $ok = [bool](Test-GraftInitialized -Path $sandbox -Reason ([ref]$reason))
            $ok | Should -BeFalse
            if (Resolve-McpDetectTool -Name 'graft') {
                $reason | Should -Match 'graph incomplete'
                $reason | Should -Match 'INDEX\.md'
            } else {
                $reason | Should -Match '^binary not found:'
            }
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports FALSE for memtrace when the scope file lists a different repo' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $sandbox '.memdb') -Force
        try {
            # A real, well-formed scope file - for SOMEBODY ELSE's repository.
            $scope = '{"version":1,"members":[{"repo_id":"other","path":"j:/audio/some-other-repo"}]}'
            [System.IO.File]::WriteAllText((Join-Path $sandbox '.memdb\.memtrace-store-scope.json'),
                $scope, (New-Object System.Text.UTF8Encoding($false)))

            $reason = ''
            $ok = [bool](Test-MemtraceInitialized -Path $sandbox -Reason ([ref]$reason))
            $ok | Should -BeFalse
            if (Resolve-McpDetectTool -Name 'memtrace') {
                $reason | Should -Match 'not a member'
            } else {
                $reason | Should -Match '^binary not found:'
            }
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports FALSE for graphify-rs when graphify-out/ exists without a built graph' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'graphify-out') -Force
        try {
            # A build that died partway leaves the directory behind. Must be FALSE.
            $reason = ''
            $ok = [bool](Test-GraphifyRsInitialized -Path $sandbox -Reason ([ref]$reason))
            $ok | Should -BeFalse
            if (Resolve-McpDetectTool -Name 'graphify-rs') {
                $reason | Should -Match 'no built graph'
            } else {
                $reason | Should -Match '^binary not found:'
            }
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports FALSE for repowise when the store exists but the MCP entry is not registered' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $sandbox '.repowise') -Force
        try {
            # Verbatim detail column from the measured doctor output. Note the
            # status column says OK - only the detail carries the state.
            $doctor = "| Database | OK | 47 pages |`n| Claude Code MCP entry | OK | not registered (repowise init registers it) |`n| MCP server responds | OK | not registered - nothing to launch |"

            $reason = ''
            $ok = [bool](Test-RepowiseInitialized -Path $sandbox -Reason ([ref]$reason) -ProbeOutput $doctor)
            $ok | Should -BeFalse
            if (Resolve-McpDetectTool -Name 'repowise') {
                $reason | Should -Match 'not registered'
            } else {
                $reason | Should -Match '^binary not found:'
            }
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-McpInitializationReport returns one Ok/Reason row per MCP, in a fixed order' {
        $module = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_mcp_detect.ps1'
        . $module
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-detect-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        try {
            $rows = @(Get-McpInitializationReport -Path $sandbox)
            $rows.Count | Should -Be 6
            ($rows | ForEach-Object { $_.Mcp }) -join ',' | Should -Be 'memtrace,grepai,graphenium,graphify-rs,repowise,graft'
            $bad = @()
            foreach ($row in $rows) {
                if ($row.Ok) { $bad += "$($row.Mcp): expected FALSE on an empty directory" }
                elseif (-not $row.Reason) { $bad += "$($row.Mcp): empty reason" }
            }
            ($bad -join '; ') | Should -Be ''
        } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
