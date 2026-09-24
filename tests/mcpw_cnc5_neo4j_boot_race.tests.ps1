# tests/mcpw_cnc5_neo4j_boot_race.tests.ps1
# Pester 6 idiom (Should -Be / Should -BeTrue / Should -BeFalse). Bead mcpw-cnc.5.
#
# THE DEFECT UNDER TEST (mcpw-cnc.3 is the fix this guards). atlas-mcp-server
# starts with Toolport at login while Docker Desktop is still bringing the Neo4j
# container up. The container publishes 7687 and reports Running well BEFORE Bolt
# serves traffic, so a bare "is the port open?" check passes too early; atlas then
# logs 'Failed to initialize Neo4j driver' / ServiceUnavailable / 'read ECONNRESET'
# - 165 of them between 2026-09-11 and 2026-09-22, the last one landing 9 seconds
# AFTER the container had started.
#
# THE RULE: readiness needs BOTH signals.
#   7474 HTTP - a real HTTP response (Test-HttpPortAnswering), not just a socket.
#   7687 Bolt - a raw LISTEN/TCP connect; the port atlas actually connects through.
# Requiring both is the whole point, so that is what these tests pin. The failure
# mode that broke atlas is test 3: Bolt up, HTTP silent.
#
# HOW THESE TESTS STAY OFF THE LIVE SYSTEM. The launcher's Test-Neo4jReady,
# Wait-Neo4jReady and Test-HttpPortAnswering are AST-extracted and aimed at
# THROWAWAY loopback ports served by fake listeners, so the real container is
# never stopped, started or probed. Wait-Neo4jReady carries -HttpPort/-BoltPort
# pass-through added for exactly this bead.
#
# TWO PESTER-6 CONSTRAINTS THIS FILE IS SHAPED AROUND (same as
# tests/mcpw_p83_sibling_log_writers.tests.ps1):
#
#   1. NOTHING DEFINED AT FILE SCOPE IS VISIBLE INSIDE AN It BLOCK - not a
#      variable, not a function, not a dot-sourced .ps1. Only $PSScriptRoot and
#      $PSCommandPath survive. Every It re-derives what it needs. Do not "tidy"
#      that into a file-scope helper - it will silently stop working.
#
#   2. This file must NOT import the Pester module itself, because
#      dev_tools/run_pester_suite.py's sniff is a plain substring test. Run it
#      as: Invoke-Pester -Path tests/mcpw_cnc5_neo4j_boot_race.tests.ps1
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

Describe 'mcpw-cnc.5: the atlas readiness gate needs BOTH 7687 and 7474' {

    It 'is NOT ready when nothing is listening on either port' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0 -Because 'the launcher must parse before anything else is asserted'
        foreach ($name in @('Test-HttpPortAnswering', 'Test-Neo4jReady')) {
            $fn = $ast.Find({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty -Because "$name is part of the gate under test"
            Invoke-Expression $fn.Extent.Text
        }

        # A port we just bound and released is free for practical purposes.
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $deadPort = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()

        Test-Neo4jReady -Address '127.0.0.1' -HttpPort $deadPort -BoltPort $deadPort -TimeoutMs 500 | Should -BeFalse
    }

    It 'is ready only when BOTH the HTTP port answers AND the Bolt port listens' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0
        foreach ($name in @('Test-HttpPortAnswering', 'Test-Neo4jReady')) {
            $fn = $ast.Find({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty
            Invoke-Expression $fn.Extent.Text
        }

        $hl = New-Object System.Net.HttpListener
        $tl = $null
        $rs = $null; $ps = $null
        try {
            # Free ports, taken by binding to 0 and reading back the assignment.
            $p1 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $p1.Start(); $httpPort = ([System.Net.IPEndPoint]$p1.LocalEndpoint).Port; $p1.Stop()
            $p2 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $p2.Start(); $boltPort = ([System.Net.IPEndPoint]$p2.LocalEndpoint).Port; $p2.Stop()

            $hl.Prefixes.Add("http://127.0.0.1:$httpPort/")
            $hl.Start()
            # Answer in a child runspace: HttpListener needs a loop, and this test
            # is synchronous. The listener object is passed by reference (same
            # process), so the runspace answers on the SAME port.
            $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
            $ps = [powershell]::Create(); $ps.Runspace = $rs
            [void]$ps.AddScript({
                    param($hl)
                    while ($true) {
                        try { $ctx = $hl.GetContext() } catch { break }
                        try {
                            $b = [System.Text.Encoding]::UTF8.GetBytes('ok')
                            $ctx.Response.StatusCode = 200
                            $ctx.Response.ContentLength64 = $b.Length
                            $ctx.Response.OutputStream.Write($b, 0, $b.Length)
                        } catch { }
                        try { $ctx.Response.Close() } catch { }
                    }
                }).AddArgument($hl)
            $null = $ps.BeginInvoke()

            # Bolt: a plain LISTEN is enough - Test-Neo4jReady only does a raw connect.
            $tl = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $boltPort)
            $tl.Start()

            Test-Neo4jReady -Address '127.0.0.1' -HttpPort $httpPort -BoltPort $boltPort -TimeoutMs 3000 | Should -BeTrue
        } finally {
            try { $hl.Stop() } catch { }
            try { $hl.Close() } catch { }
            if ($tl) { try { $tl.Stop() } catch { } }
            if ($ps) { try { $ps.Stop() } catch { }; try { $ps.Dispose() } catch { } }
            if ($rs) { try { $rs.Close() } catch { } }
        }
    }

    It 'is NOT ready when ONLY the Bolt port listens (the boot race that broke atlas)' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0
        foreach ($name in @('Test-HttpPortAnswering', 'Test-Neo4jReady')) {
            $fn = $ast.Find({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty
            Invoke-Expression $fn.Extent.Text
        }

        $tl = $null
        try {
            $p1 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $p1.Start(); $httpPort = ([System.Net.IPEndPoint]$p1.LocalEndpoint).Port; $p1.Stop()
            $p2 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $p2.Start(); $boltPort = ([System.Net.IPEndPoint]$p2.LocalEndpoint).Port; $p2.Stop()

            # Exactly the container's premature state: 7687 open, 7474 silent.
            $tl = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $boltPort)
            $tl.Start()

            Test-Neo4jReady -Address '127.0.0.1' -HttpPort $httpPort -BoltPort $boltPort -TimeoutMs 1500 | Should -BeFalse `
                -Because 'an open Bolt port is not readiness - this is the 165-failure case'
        } finally {
            if ($tl) { try { $tl.Stop() } catch { } }
        }
    }

    It 'is NOT ready when ONLY the HTTP port answers (Bolt silent)' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0
        foreach ($name in @('Test-HttpPortAnswering', 'Test-Neo4jReady')) {
            $fn = $ast.Find({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty
            Invoke-Expression $fn.Extent.Text
        }

        $hl = New-Object System.Net.HttpListener
        $rs = $null; $ps = $null
        try {
            $p1 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $p1.Start(); $httpPort = ([System.Net.IPEndPoint]$p1.LocalEndpoint).Port; $p1.Stop()
            $p2 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $p2.Start(); $boltPort = ([System.Net.IPEndPoint]$p2.LocalEndpoint).Port; $p2.Stop()

            $hl.Prefixes.Add("http://127.0.0.1:$httpPort/")
            $hl.Start()
            $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
            $ps = [powershell]::Create(); $ps.Runspace = $rs
            [void]$ps.AddScript({
                    param($hl)
                    while ($true) {
                        try { $ctx = $hl.GetContext() } catch { break }
                        try {
                            $b = [System.Text.Encoding]::UTF8.GetBytes('ok')
                            $ctx.Response.StatusCode = 200
                            $ctx.Response.ContentLength64 = $b.Length
                            $ctx.Response.OutputStream.Write($b, 0, $b.Length)
                        } catch { }
                        try { $ctx.Response.Close() } catch { }
                    }
                }).AddArgument($hl)
            $null = $ps.BeginInvoke()

            # 7474 answers, 7687 has nothing - still not ready.
            Test-Neo4jReady -Address '127.0.0.1' -HttpPort $httpPort -BoltPort $boltPort -TimeoutMs 1500 | Should -BeFalse
        } finally {
            try { $hl.Stop() } catch { }
            try { $hl.Close() } catch { }
            if ($ps) { try { $ps.Stop() } catch { }; try { $ps.Dispose() } catch { } }
            if ($rs) { try { $rs.Close() } catch { } }
        }
    }

    It 'Wait-Neo4jReady gives up within its bounded timeout and never throws' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0
        foreach ($name in @('Test-HttpPortAnswering', 'Test-Neo4jReady', 'Wait-Neo4jReady')) {
            $fn = $ast.Find({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty -Because "$name is part of the bounded wait"
            Invoke-Expression $fn.Extent.Text
        }

        # The pass-through exists precisely so the TIMEOUT path is reachable
        # without the live database; an untested timeout path is how a bounded
        # wait quietly becomes unbounded.
        $fnW = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Wait-Neo4jReady' }, $true)
        $fnW.Extent.Text | Should -Match '\$HttpPort' -Because 'the port pass-through is what makes this testable'
        $fnW.Extent.Text | Should -Match '\$BoltPort'

        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $deadPort = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()

        $threw = ''
        $result = $null
        # The timeout path deliberately emits a Write-Warning diagnostic. That is
        # correct behaviour, but it is not this test's subject and would otherwise
        # land in the suite output - silence it via the preference variable, which
        # is deterministic, rather than relying on -WarningAction being honoured
        # by a function with no CmdletBinding attribute.
        $oldWarnPref = $WarningPreference
        $WarningPreference = 'SilentlyContinue'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # 2s budget, 1s poll -> must return after ~2s, never hang.
            $result = Wait-Neo4jReady -TimeoutSec 2 -PollSec 1 -HttpPort $deadPort -BoltPort $deadPort
        } catch { $threw = $_.Exception.Message } finally { $WarningPreference = $oldWarnPref }
        $sw.Stop()

        $threw | Should -Be '' -Because 'the bounded wait must never throw'
        $result | Should -BeFalse -Because 'a dead backend is never reported as usable'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'a 2s budget must not run away'
    }

    It 'the launcher wires the same both-signal gate onto the atlas path' {
        $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $src = Get-Content -LiteralPath $launcher -Raw

        # The atlas path must carry BOTH signals: the Bolt port AND the 7474 HTTP
        # health endpoint. A supervisor with -Port 7687 and no 7474 health probe
        # is the original defect.
        $src | Should -Match "Start-BackendSupervisor -Name 'neo4j' -Port 7687 -Health 'http://127\.0\.0\.1:7474'"

        # ...and Test-Neo4jReady itself must require the HTTP probe BEFORE the
        # Bolt connect, so neither signal alone can pass.
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tk, [ref]$er)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-Neo4jReady' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $body = $fn.Extent.Text
        $httpIdx = $body.IndexOf('Test-HttpPortAnswering')
        $boltIdx = $body.IndexOf('$BoltPort')
        $httpIdx | Should -BeGreaterThan -1 -Because 'the HTTP probe is half the gate'
        $boltIdx | Should -BeGreaterThan -1 -Because 'the Bolt connect is the other half'
        $httpIdx | Should -BeLessThan $boltIdx -Because 'HTTP is checked first and short-circuits'
        ([regex]::Matches($body, 'return \$false')).Count | Should -BeGreaterThan 1 `
            -Because 'each of the two signals must be able to fail the gate on its own'
    }
}
