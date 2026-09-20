# tests/launcher_proxy_wiring.tests.ps1 — Pester 3.4.0
Import-Module Pester -RequiredVersion 3.4.0 -Force -ErrorAction SilentlyContinue
$launcher = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
Describe 'fallback proxy wiring' {
    It 'Invoke-GmSemanticBuild uses proxy api-base (11436) not NOUS_BASE_URL' {
        $c = Get-Content -LiteralPath $launcher -Raw
        ($c | Select-String -Pattern 'function Invoke-GmSemanticBuild[\s\S]{0,3000}--api-base.*127\.0\.0\.1.*11436' -AllMatches).Matches.Count | Should BeGreaterThan 0
        $block = [regex]::Match($c, 'function Invoke-GmSemanticBuild[\s\S]{0,4000}?\$runArgs\s*=\s*@\([^)]*\)')
        $block.Success | Should Be $true
        $block.Value | Should Not Match 'NOUS_BASE_URL'
    }
    It 'Ensure-LlmProxyRunning helper exists' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'function Ensure-LlmProxyRunning'
    }
    It 'proxy gate runs before gm semantic warm-up' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $gateIdx = $c.IndexOf('Ensure-LlmProxyRunning')
        # Invoke-GmSemanticBuild no longer takes a -Mode parameter at all: the
        # "full" warm-up was replaced by the incremental daemon, which calls
        # Invoke-GmSemanticBuild -BuildDir ... (launcher line 2795). Anchoring on
        # '-Mode "full"' made $warmIdx -1, so this test failed on a string that
        # no longer exists rather than on the ordering it is meant to lock.
        $warmIdx = $c.IndexOf('Invoke-GmSemanticBuild -BuildDir')
        $gateIdx | Should BeGreaterThan -1
        $warmIdx | Should BeGreaterThan -1
        $gateIdx | Should BeLessThan $warmIdx
    }
    It 'proxy gate runs before repowise watch' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $gateIdx = $c.IndexOf('Ensure-LlmProxyRunning')
        $rwIdx = $c.IndexOf('Start-WatcherDetached "repowise"')
        $gateIdx | Should BeGreaterThan -1
        $rwIdx | Should BeGreaterThan -1
        $gateIdx | Should BeLessThan $rwIdx
    }
    It 'litellm proxy (4000) starts before fallback proxy gate' {
        $c = Get-Content -LiteralPath $launcher -Raw
        # VAD-7m1y (2026-09-06): the "proxy is up" MESSAGE moved to the probe
        # job's join point (after the gate), so the launch call is the marker for
        # "starts". The launch must still precede the fallback proxy gate.
        $litIdx = $c.IndexOf('Start-WatcherDetached "litellm"')
        $gateIdx = $c.IndexOf('Ensure-LlmProxyRunning')
        $litIdx | Should BeGreaterThan -1
        $gateIdx | Should BeGreaterThan -1
        $litIdx | Should BeLessThan $gateIdx
    }
}

Describe 'startup readiness gate overlap (VAD-7m1y)' {
    $c = Get-Content -LiteralPath $launcher -Raw
    It 'Ollama readiness gate starts as a background job before the grepai ready-wait' {
        $ollamaJobIdx = $c.IndexOf('$ollamaGateJob = Start-')
        $grepaiReadyIdx = $c.IndexOf('Readiness: wait for a live watch process')
        $ollamaJobIdx | Should BeGreaterThan -1
        $grepaiReadyIdx | Should BeGreaterThan -1
        $ollamaJobIdx | Should BeLessThan $grepaiReadyIdx
    }
    It 'Ollama gate job is joined after the grepai ready-wait' {
        $grepaiReadyIdx = $c.IndexOf('Readiness: wait for a live watch process')
        $joinIdx = $c.IndexOf('Wait-Job -Job $ollamaGateJob')
        $joinIdx | Should BeGreaterThan -1
        $joinIdx | Should BeGreaterThan $grepaiReadyIdx
    }
    It 'litellm readiness probe starts as a job and is joined before the pane grid' {
        $probeIdx = $c.IndexOf('$script:litellmProbeJob = Start-')
        $joinIdx = $c.IndexOf('Wait-Job -Job $script:litellmProbeJob')
        $paneIdx = $c.IndexOf('Combined watcher view: Windows Terminal 3x2 pane grid')
        $probeIdx | Should BeGreaterThan -1
        $joinIdx | Should BeGreaterThan $probeIdx
        $paneIdx | Should BeGreaterThan -1
        $joinIdx | Should BeLessThan $paneIdx
    }
}
if (-not $env:PROXY_WIRING_TEST_RAN) { $env:PROXY_WIRING_TEST_RAN='1'; Invoke-Pester -Path $MyInvocation.MyCommand.Path }
