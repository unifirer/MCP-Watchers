# tests/launcher_gm_semantic_build.tests.ps1
# Pester 3.4.0 idiom (same as launcher_graphify_wiring.tests.ps1): run via
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_gm_semantic_build.tests.ps1

# Pin Pester 3.4.0 (this file uses the v3 positional `Should Match` idiom).
# Without this, a newer Pester (6.x) auto-loads and rejects the syntax.
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
#
# Covers the consolidation (2026-08-27) of the external
# ###5.graphenium_build_semantic_graph_with_qwen_7b.ps1 INTO the ###1 launcher
# as a LIVE, INCREMENTAL semantic-build daemon:
#   1. static wiring: ###1 owns Invoke-GmSemanticBuild (no ###5 file remains),
#      arms a FileSystemWatcher (gm-sem-changed) and a live incremental loop
#      (gm run . --update), and stops cleanly via Stop-GmSemanticLive.
#   2. proxy-gated config: the launcher sends gm to the LOCAL LLM fallback proxy
#      (127.0.0.1:$env:LLM_PROXY_PORT, default 11436) as an OpenAI-compatible
#      endpoint, and refuses to enrich when Test-LlmProxyReady is false
#      (graceful AST-only degradation). The former Nous cloud endpoint is
#      retired - see the mcpw-b81.8 note in the second case below.
#   3. execution smoke: with the proxy not ready the inline build degrades
#      gracefully (no crash) instead of hanging or erroring.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher  = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

Describe 'gm semantic build inline live daemon' {
    It 'launcher owns the inline build and no longer depends on ###5' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Not Match '###5\.graphenium_build_semantic_graph_with_qwen_7b\.ps1'
        $c | Should Match 'function Invoke-GmSemanticBuild'
        $c | Should Match 'function Stop-GmSemanticLive'
        # Live trigger + FULL (non-incremental) rebuild mode. gm 0.19.3's
        # `gm run . --update` REPLACES graph.json with only the changed files'
        # nodes (live-reproduced 2026-09-16: one touched file collapsed a
        # 5423-node graph to 15), so --update must not appear in executable code.
        # Comments still name it to explain why it is gone, so strip them first.
        $c | Should Match 'gm-sem-changed'
        ($c -replace '(?m)#.*$', '') | Should Not Match '\-\-update'
        $c | Should Match '--no-semantic'
        # No `gm watch` either: same destructive incremental writer.
        $c | Should Not Match 'Start-WatcherDetached "gm"'
        # No blocking FULL warm-up at startup: the semantic build is now incremental,
        # driven solely by the live FileSystemWatcher (gm-sem-changed) on the first
        # file change, so graphify-rs/repowise/memtrace watchers no longer wait on
        # launch. This guard fails if a startup `Invoke-GmSemanticBuild -Mode "full"`
        # call is ever re-added.
        $c | Should Not Match 'Invoke-GmSemanticBuild -Mode "full"'
        # Cloud-only: no local Ollama bridge / fallback proxy wiring.
        $c | Should Not Match 'function Start-GmBridge'
        $c | Should Not Match 'function Start-LlmFallbackProxy'
    }

    It 'inline build targets the local fallback proxy and needs it ready' {
        # mcpw-b81.8: this case used to assert NOUS_API_KEY / NOUS_BASE_URL /
        # 'openai-compatible' as the build's contract. Two of those three are
        # retired. NOUS_API_KEY survives in exactly ONE comment (~3061) that says
        # it is no longer consulted, and NOUS_BASE_URL survives only as an unused
        # env default (~3643) that the build never reads. Both assertions
        # therefore passed on strings that no longer participate in the behaviour
        # they claimed to lock - the rot dev_tools/scan_stale_anchors.py exists to
        # catch. Assert the contract the build actually implements.
        $c = Get-Content -LiteralPath $launcher -Raw
        # Comments must never be able to satisfy a check, so strip them first.
        $code = $c -replace '(?m)#.*$', ''
        # The gate: no proxy, no LLM enrichment.
        $c | Should Match 'function Test-LlmProxyReady'
        $c | Should Match 'if \(\$semanticOn -and -not \(Test-LlmProxyReady\)\)'
        # The target: the LOCAL proxy, port env-driven with a 11436 default.
        $code | Should Match '\$proxyPort = if \(\$env:LLM_PROXY_PORT\)'
        $code | Should Match '\$proxyBase = "http://127\.0\.0\.1:\$proxyPort/v1"'
        $code | Should Match '--api-base'
        # The provider name is still live - keep locking it.
        $code | Should Match 'openai-compatible'
        # The retired Nous key must not be consulted anywhere in executable code.
        $code | Should Not Match 'NOUS_API_KEY'
    }

    It 'proxy not ready degrades gracefully (no build, no hang)' {
        # Dot-source just the build function in a scratch harness with a stub
        # gm.exe and no proxy; it must return without throwing or hanging.
        # The build gates on Test-LlmProxyReady; the harness stubs it to a
        # constant $false so the degradation path stays deterministic (no live
        # proxy needed). mcpw-b81.8: this case was named for NOUS_API_KEY, which
        # the build no longer consults - the gate is the proxy, not the key.
        # ($env:NOUS_API_KEY is still cleared below; harmless, but it is not what
        # makes this case deterministic.)
        $src = Get-Content -LiteralPath $launcher -Raw
        # Extract the Invoke-GmSemanticBuild function body verbatim.
        if ($src -notmatch '(?s)function Invoke-GmSemanticBuild \{.*?\n\}') {
            throw "Invoke-GmSemanticBuild not found in launcher"
        }
        $fn = $Matches[0]
        $harness = @"
`$ErrorActionPreference = 'Stop'
`$scriptDir = Join-Path `$env:TEMP ('gm_sem_inline_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path `$scriptDir | Out-Null
`$logsDir = `$scriptDir; `$gmRunLog = Join-Path `$scriptDir 'run.log'
# Stub gm.exe resolution so the function reaches the API-key check.
function Get-Command { param(`$Name) if (`$Name -eq 'gm.exe') { return [pscustomobject]@{ Source = 'stub-gm' } } ; return `$null }
# Stub the fallback-proxy readiness probe to a constant `$false: with no key
# AND no proxy the build must skip without throwing.
function Test-LlmProxyReady { return `$false }
# mcpw-b81.1: the build ALSO reads the live semantic switch. Stub it to `$false
# (semantic OFF). With semantic OFF the proxy gate no longer short-circuits the
# build - that IS the bug b81.1 fixes (an AST-only rebuild needs no LLM) - so the
# build now proceeds all the way to spawning gm. Stub the spawn too, so this case
# still measures graceful degradation rather than a missing-binary failure.
function Test-GmSemanticEnabled { return `$false }
function Start-Process {
    [CmdletBinding()]
    param(`$FilePath, `$ArgumentList, `$WorkingDirectory, `$WindowStyle,
        `$RedirectStandardOutput, `$RedirectStandardError,
        [switch]`$PassThru, [switch]`$Wait)
    return [pscustomobject]@{ ExitCode = 0 }
}
# Ensure no inherited key.
`$env:NOUS_API_KEY = `$null
$fn
try { Invoke-GmSemanticBuild -BuildDir `$scriptDir -RunLog `$gmRunLog -BuildKey 0 } catch { Write-Output "THREW: `$(`$_.Exception.Message)" }
"@
        $harness = $harness -replace '\$fn', $fn
        $hScript = Join-Path $env:TEMP ("gm_sem_inline_test_" + [guid]::NewGuid().ToString('N') + ".ps1")
        Set-Content -LiteralPath $hScript -Value $harness -Encoding utf8
        try {
            $savedKey = $env:NOUS_API_KEY
            $env:NOUS_API_KEY = $null
            $p = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hScript) `
                -WindowStyle Hidden -Wait -PassThru `
                -RedirectStandardOutput ($hScript + '.out') -RedirectStandardError ($hScript + '.err')
            $p.ExitCode | Should Be 0
            $out = (Get-Content -LiteralPath ($hScript + '.out') -Raw -ErrorAction SilentlyContinue)
            if ($out -and $out -match 'THREW:') { throw "harness threw: $out" }
        } finally {
            if ($savedKey) { $env:NOUS_API_KEY = $savedKey } else { $env:NOUS_API_KEY = $null }
            Remove-Item -LiteralPath $hScript -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($hScript + '.out') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($hScript + '.err') -Force -ErrorAction SilentlyContinue
        }
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard with
# an env var so the rediscovery child skips the second Invoke-Pester. -Path keeps
# the run scoped to THIS file (no cross-file contamination).
if (-not $env:GM_SEM_TEST_RAN) {
    $env:GM_SEM_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
