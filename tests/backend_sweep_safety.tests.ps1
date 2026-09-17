Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/backend_sweep_safety.tests.ps1 (vad-10m.3)
# Pester 3.4.0 (pinned). Guards the PID-safe backend sweep contract: every
# backend kill is scoped by BOTH image name AND a command-line token, so an
# unrelated python.exe / node.exe (no token) never matches. No live
# processes are touched - all assertions run Test-WatcherSweepMatch against
# literal command lines only.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$patternsModule = Join-Path $repo 'Modules\watcher_patterns.ps1'

Describe 'backend sweep safety (vad-10m.3)' {
    It 'dot-sources with no side effects' {
        Test-Path -LiteralPath $patternsModule | Should Be $true
        { . $patternsModule } | Should Not Throw
    }

    It 'matches real backend command lines against their own patterns' {
        . $patternsModule
        $cerememory = @($script:WatcherSweepPatterns | Where-Object { $_.Name -eq 'cerememory.exe' })[0]
        # Select by Pattern, not by index: python.exe now carries several
        # token-scoped entries (mail :8765, embed :8003) and
        # index order is not part of the contract.
        $mail = @($script:WatcherSweepPatterns | Where-Object { $_.Name -eq 'python.exe' -and $_.Pattern -eq 'mcp_agent_mail' })[0]
        $claude = @($script:WatcherSweepPatterns | Where-Object { $_.Name -eq 'node.exe' })[0]
        @($script:WatcherSweepPatterns | Where-Object { $_.Name -eq 'cerememory.exe' }).Count | Should Be 1
        # Each token-scoped python.exe pattern must be declared exactly once.
        # graphiti-mcp (:8002) is a Docker container now, not a python.exe, so
        # only mail + embed remain here.
        foreach ($pat in @('mcp_agent_mail', 'embed_server')) {
            @($script:WatcherSweepPatterns | Where-Object { $_.Name -eq 'python.exe' -and $_.Pattern -eq $pat }).Count | Should Be 1
        }
        $cerememoryCmd = 'C:\ProgramData\cerememory\cerememory.exe serve --config C:\ProgramData\cerememory\cerememory.toml'
        $mailCmd = 'C:\Python311\python.exe C:\Users\yuni\.local\mcp-agent-mail\mcp_agent_mail\server.py --port 8765'
        $claudeCmd = 'C:\Program Files\nodejs\node.exe C:\npm-global\node_modules\claude-mcp-server\dist\cli.js --port 8080'
        Test-WatcherSweepMatch -CommandLine $cerememoryCmd -Pattern $cerememory.Pattern | Should Be $true
        Test-WatcherSweepMatch -CommandLine $mailCmd -Pattern $mail.Pattern | Should Be $true
        Test-WatcherSweepMatch -CommandLine $claudeCmd -Pattern $claude.Pattern | Should Be $true
    }

    It 'leaves unrelated decoy processes unmatched by every backend pattern' {
        . $patternsModule
        $backendEntries = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'cerememory.exe' -or $_.Name -eq 'python.exe' -or $_.Name -eq 'node.exe' })
        # Do not pin the entry count: new token-scoped backends get added over
        # time (mail :8765, embed :8003). What matters is that
        # every backend image name is represented, so the decoy loop below is
        # never vacuously true.
        foreach ($name in @('cerememory.exe', 'python.exe', 'node.exe')) {
            @($backendEntries | Where-Object { $_.Name -eq $name }).Count | Should BeGreaterThan 0
        }
        $pythonDecoy = 'C:\tools\python.exe worker.py'
        $nodeDecoy = 'C:\app\node.exe server.js'
        foreach ($entry in $backendEntries) {
            Test-WatcherSweepMatch -CommandLine $pythonDecoy -Pattern $entry.Pattern | Should Be $false
            Test-WatcherSweepMatch -CommandLine $nodeDecoy -Pattern $entry.Pattern | Should Be $false
        }
    }

    It 'contains the node.exe/claude-mcp-server entry exactly once' {
        . $patternsModule
        $claude = @($script:WatcherSweepPatterns | Where-Object {
            $_.Name -eq 'node.exe' -and $_.Pattern -eq 'claude-mcp-server' })
        $claude.Count | Should Be 1
    }

    It 'port contract: :8291 survives only on legacy-annotated lines; claude block pins :8080' {
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        Test-Path -LiteralPath $launcher | Should Be $true
        $lines = @(Get-Content -LiteralPath $launcher)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '8291') {
                $lo = $i - 20; if ($lo -lt 0) { $lo = 0 }
                $hi = $i + 20; if ($hi -ge $lines.Count) { $hi = $lines.Count - 1 }
                $ctx = ($lines[$lo..$hi] -join "`n")
                ($ctx -match 'legacy|vad-10m') | Should Be $true
            }
        }
        $cmHits = @(Select-String -LiteralPath $launcher -Pattern 'CM_PORT')
        foreach ($h in $cmHits) {
            ($h.Line -match 'legacy|vad-10m') | Should Be $true
        }
        foreach ($mod in @(Get-ChildItem -LiteralPath (Join-Path $repo 'Modules') -Filter '*.ps1')) {
            $mh = @(Select-String -LiteralPath $mod.FullName -Pattern 'CM_PORT|8291')
            $mh.Count | Should Be 0
        }
        $src = Get-Content -LiteralPath $launcher -Raw
        $cStart = $src.IndexOf('$claudeMcpJobScript = {')
        ($cStart -ge 0) | Should Be $true
        $cEnd = $src.IndexOf('# --- MCP Agent Mail', $cStart)
        ($cEnd -gt $cStart) | Should Be $true
        $claudeBlock = $src.Substring($cStart, $cEnd - $cStart)
        ($claudeBlock -match [regex]::Escape('$backendPort = 8080')) | Should Be $true
    }

    It 'persistent backend entries are never bare-image kills' {
        . $patternsModule
        foreach ($name in @('python.exe', 'node.exe')) {
            $entries = @($script:WatcherSweepPatterns | Where-Object { $_.Name -eq $name })
            ($entries.Count -ge 1) | Should Be $true
            foreach ($e in $entries) {
                (([string]$e.Pattern).Length -gt 0) | Should Be $true
            }
        }
        foreach ($name in @('claude-mcp.exe', 'node.exe', 'cerememory.exe', 'python.exe')) {
            $hit = @($script:WatcherSweepPatterns | Where-Object { $_.Name -eq $name -and $_.Persistent })
            ($hit.Count -ge 1) | Should Be $true
        }
    }

    It 'backend supervisor exits with launcher; CIM reap is legacy/dup-scoped only' {
        $launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
        $src = Get-Content -LiteralPath $launcher -Raw
        $bStart = $src.IndexOf('$backendSupervisorScript = {')
        ($bStart -ge 0) | Should Be $true
        $bEnd = $src.IndexOf('$script:cerememorySupJob', $bStart)
        ($bEnd -gt $bStart) | Should Be $true
        $sup = $src.Substring($bStart, $bEnd - $bStart)
        $supLines = @($sup -split "`r?`n")
        $liveIdx = -1
        for ($i = 0; $i -lt $supLines.Count; $i++) {
            if ($supLines[$i] -match 'Test-LauncherAlive -Path \$LockFile') { $liveIdx = $i; break }
        }
        ($liveIdx -ge 0) | Should Be $true
        $tail = ($supLines[$liveIdx..($liveIdx + 5)] -join "`n")
        ($tail -match 'return') | Should Be $true
        ($sup -match 'Stop-Process') | Should Be $false
        ($sup -match '\.Kill\(') | Should Be $false
        ($sup -match '->Kill\(') | Should Be $false
        for ($i = 0; $i -lt $supLines.Count; $i++) {
            if ($supLines[$i] -match 'Invoke-CimMethod') {
                $lo = $i - 10; if ($lo -lt 0) { $lo = 0 }
                $hi = $i + 10; if ($hi -ge $supLines.Count) { $hi = $supLines.Count - 1 }
                $ctx = ($supLines[$lo..$hi] -join "`n")
                ($ctx -match '8291|duplicate|vad-10m') | Should Be $true
            }
        }
    }
}

if (-not $env:BACKEND_SWEEP_TEST_RAN) {
    $env:BACKEND_SWEEP_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
