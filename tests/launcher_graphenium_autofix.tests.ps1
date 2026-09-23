# tests/launcher_graphenium_autofix.tests.ps1
# Pester 3.4.0 (pinned). Regression suite for the graphenium stale-graph
# AUTO-FIX added to New-WatcherPaneScript's tailer template (beads VAD-be9):
# when the graphenium pane reads gm's "Flag: .\graphenium-out\needs_update"
# line, the tailer itself must reap any lingering pre-fix `gm watch`, clear the
# marker, heal with a FULL `gm run` (never the destructive incremental modes),
# append through cmd byte-redirection (UTF-8 safe), and survive the rebuild
# window - label-gated so no other pane reacts.
#
# Run (single pass, reliable exit code):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
#     "if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }; Invoke-Pester -Path 'tests\launcher_graphenium_autofix.tests.ps1' -EnableExit"
if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }

$repo      = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher  = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$paneModule = Join-Path $repo 'Modules\watcher_pane_scripts.ps1'
if (-not $env:VAD_WORKSPACE_ROOT) { $env:VAD_WORKSPACE_ROOT = "$repo" }
$wtPaneDir = Join-Path $env:TEMP ("vad-autofix-tails-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null

function Get-LauncherFunctionText {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "launcher parse error: $($errors[0].Message)" }
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
    if ($fn.Count -eq 1) { return $fn[0].Extent.Text }
    if (($fn.Count -eq 0) -and (Test-Path -LiteralPath $paneModule)) {
        $mtokens = $null; $merrors = $null
        $mast = [System.Management.Automation.Language.Parser]::ParseFile($paneModule, [ref]$mtokens, [ref]$merrors)
        if ($merrors.Count -gt 0) { throw "pane module parse error: $($merrors[0].Message)" }
        $mfn = $mast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
        if ($mfn.Count -eq 1) { return $mfn[0].Extent.Text }
        throw "expected exactly 1 definition of $Name, found 0 in launcher and $($mfn.Count) in pane module"
    }
    throw "expected exactly 1 definition of $Name, found $($fn.Count)"
}

# Materialize a REAL tail script by invoking the production generator.
function New-TailScriptForLabel {
    param([string]$Label)
    . ([scriptblock]::Create((Get-LauncherFunctionText -Name 'New-WatcherPaneScript')))
    return New-WatcherPaneScript -Label $Label `
        -LogPath (Join-Path $wtPaneDir "$Label.log") `
        -ErrPath (Join-Path $wtPaneDir "$Label.log.err") `
        -RepoRoot 'J:\fake\repo' `
        -HeartbeatPath (Join-Path $wtPaneDir "$Label.hb")
}

function Get-TailFunctionText {
    param([string]$TailScript, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($TailScript, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "tail parse error in ${TailScript}: $($errors[0].Message)" }
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
    if ($fn.Count -ne 1) { throw "expected exactly 1 definition of $Name in tail, found $($fn.Count)" }
    return $fn[0].Extent.Text
}

function New-AutoFixFixture {
    param()
    $dir = Join-Path $env:TEMP ("vad-autofix-fx-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $dir 'graphenium-out') -Force | Out-Null
    Set-Content -Path (Join-Path $dir 'graphenium-out\needs_update') -Value 'stale'
    Set-Content -Path (Join-Path $dir 'gm.log')     -Value ''
    Set-Content -Path (Join-Path $dir 'gm.log.err') -Value ''
    return @{
        Repo   = $dir
        Log    = Join-Path $dir 'gm.log'
        Err    = Join-Path $dir 'gm.log.err'
        Marker = Join-Path $dir 'graphenium-out\needs_update'
    }
}

# Returns a PLAIN scriptblock that installs process-boundary stubs INTO THE
# CALLER'S SCOPE when dot-sourced (. ). Callers MUST dot-source the result and
# pass the fake gm path as an argument. NEVER wrap this block in GetNewClosure:
# a closure carries its own module scope, so dot-sourcing it would define the
# stub functions THERE, silently leaving the production code to hit REAL
# cmdlets/processes (observed in the first RED run).
function Install-AutoFixStubs {
    param([string]$FakeGmSource)
    return {
        param([string]$FakeGmSource_)
        $script:cimFilters = @(); $script:cimKills = 0; $script:spCalls = @()
        if ($FakeGmSource_) { $script:fakeGmSource = $FakeGmSource_ } else { $script:fakeGmSource = $null }
        function Get-CimInstance  { [CmdletBinding()] param([string]$ClassName, [string]$Filter) $script:cimFilters += $Filter; @() }
        function Invoke-CimMethod { [CmdletBinding()] param($InputObject, [string]$MethodName, $Arguments) if ($MethodName -eq 'Terminate') { $script:cimKills++ } }
        function Get-Command      { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name) if ($script:fakeGmSource) { [pscustomobject]@{ Source = $script:fakeGmSource } } else { $null } }
        function Start-Process    { [CmdletBinding()] param([string]$FilePath, $ArgumentList, [string]$WorkingDirectory, $WindowStyle) $script:spCalls += ,@($FilePath, [string]$ArgumentList); [pscustomobject]@{ Id = 424242 } }
    }
}

# Returns a PLAIN scriptblock that installs the heal function TOGETHER WITH the
# two mcpw-b81.4 helpers it calls. The generated tail contains all three, and
# extracting Invoke-GrapheniumAutoFix alone leaves Test-GmSemanticMode /
# Test-GmPaneLlmProxyReady unresolved - the heal then throws on the very first
# line, its own catch swallows it, and every behavioural assertion below fails on
# "the marker was never deleted" instead of on the real cause.
# Same contract as Install-AutoFixStubs: callers MUST dot-source the result.
function Install-AutoFixHeal {
    return {
        . ([scriptblock]::Create((Get-TailFunctionText -TailScript $gmTailScript -Name 'Test-GmSemanticMode')))
        . ([scriptblock]::Create((Get-TailFunctionText -TailScript $gmTailScript -Name 'Test-GmPaneLlmProxyReady')))
        . (Install-AutoFixHeal)
    }
}

$gmTailScript = New-TailScriptForLabel -Label 'graphenium'
$rpTailScript = New-TailScriptForLabel -Label 'repowise'
$gmTailText   = Get-Content -LiteralPath $gmTailScript -Raw
$rpTailText   = Get-Content -LiteralPath $rpTailScript -Raw

Describe 'graphenium AUTO-FIX template contract (beads VAD-be9)' {

    It 'leaves the launcher parseable with zero errors' {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }

    It 'arms the stdout trigger on the raw Flag+needs_update predicate' {
        $pin = "'graphenium' -eq 'graphenium' -and " + [regex]::Escape('$line') + " -match 'Flag'"
        $gmTailText | Should Match $pin
    }

    It 'arms the stderr trigger with the same predicate' {
        # Both the stdout loop and the stderr loop now iterate `foreach ($line ...)`,
        # so the predicate must appear at least TWICE in the generated pane.
        $pin = "'graphenium' -eq 'graphenium' -and " + [regex]::Escape('$line') + " -match 'Flag'"
        $count = (Select-String -InputObject $gmTailText -Pattern $pin -AllMatches).Matches.Count
        $count | Should BeGreaterThan 1
    }

    It 'wires the 45 s post-heal liveness grace into the pane guard' {
        $pin = "-not " + [regex]::Escape('$alive') + " -and " + [regex]::Escape('$script:gmHealUntilTick')
        $gmTailText | Should Match $pin
        $gmTailText | Should Match 'FromSeconds\(45\)'
    }

    It 'does not arm any trigger inside non-graphenium panes' {
        $aliveGate = [regex]::Escape("'graphenium' -eq 'graphenium'")
        $count = (Select-String -InputObject $rpTailText -Pattern $aliveGate -AllMatches).Matches.Count
        $count | Should Be 0
    }

    It 'heals with a FULL gm rebuild via cmd byte-append redirection, never Start-Process redirect (mojibake pin)' {
        $healText = Get-TailFunctionText -TailScript $gmTailScript -Name 'Invoke-GrapheniumAutoFix'
        $healText | Should Match ([regex]::Escape('/c ""'))
        # FULL rebuild, never the incremental writers: `gm watch` and
        # `gm run . --update` REPLACE graph.json with only the changed files'
        # nodes (live-reproduced 2026-09-16: 5423 nodes -> 15), so a heal that
        # used either would destroy the very graph it is repairing.
        # mcpw-b81.4: the heal obeys the SAME live semantic switch as the
        # launcher's rebuild daemon, so --no-semantic is now CONDITIONAL and the
        # command line is assembled in three pieces. With semantic OFF the three
        # pieces concatenate to exactly the pre-b81 string
        # ' run . --no-semantic --no-viz --no-report >> "'. Assert the pieces and
        # the conditional, not the assembled literal.
        $healText | Should Match ([regex]::Escape("' run .'"))
        $healText | Should Match ([regex]::Escape("if (-not `$gmSemOn) { `$gmArgs += ' --no-semantic' }"))
        $healText | Should Match ([regex]::Escape("' --no-viz --no-report >> `"'"))
        $healText | Should Not Match ([regex]::Escape(' watch . --debounce'))
        $healText | Should Match ([regex]::Escape('2>> "'))
        $healText | Should Not Match 'RedirectStandard'
    }

    It 'pins the 10-minute self-limiting cooldown' {
        $gmTailText | Should Match 'FromMinutes\(10\)'
    }

    It 'detection reads RAW log lines, not cleaned output' {
        $pin = [regex]::Escape('$line -match ''Flag''')
        $gmTailText | Should Match $pin
    }
}

Describe 'Invoke-GrapheniumAutoFix behavior (generated tail, stubbed processes)' {

    It 'kills the watcher sweep, deletes the marker, and respawns cmd once' {
        $fx = New-AutoFixFixture
        $repo = $fx.Repo; $log = $fx.Log; $err = $fx.Err
        $script:lastGmAutoFixTicks = 0; $script:gmHealUntilTick = 0
        . (Install-AutoFixStubs) 'C:\fake\bin\gm.exe'
        . (Install-AutoFixHeal)

        { Invoke-GrapheniumAutoFix } | Should Not Throw

        Test-Path -LiteralPath $fx.Marker | Should Be $false
        $script:cimFilters.Count          | Should Be 1
        $script:cimFilters[0]             | Should Match 'gm\.exe'
        $script:spCalls.Count             | Should Be 1
        $script:spCalls[0][0]             | Should Be 'cmd.exe'
        $script:spCalls[0][1]             | Should Match ([regex]::Escape('C:\fake\bin\gm.exe'))
        $script:lastGmAutoFixTicks        | Should BeGreaterThan 0
        $script:gmHealUntilTick           | Should BeGreaterThan ([datetime]::UtcNow.Ticks)
    }

    It 'suppresses an immediate second heal via the cooldown' {
        $fx = New-AutoFixFixture
        $repo = $fx.Repo; $log = $fx.Log; $err = $fx.Err
        $script:lastGmAutoFixTicks = 0; $script:gmHealUntilTick = 0
        . (Install-AutoFixStubs) 'C:\fake\bin\gm.exe'
        . (Install-AutoFixHeal)

        Invoke-GrapheniumAutoFix
        $afterFirst = $script:spCalls.Count
        Invoke-GrapheniumAutoFix

        $afterFirst           | Should Be 1
        $script:spCalls.Count | Should Be 1
    }

    It 'obeys the live semantic switch: ON with no reachable proxy skips the heal and keeps the marker' {
        # mcpw-b81.4. The whole point of the bead: a heal must never silently
        # downgrade a semantic graph to AST-only. With semantic ON and the LLM
        # proxy unreachable it skips instead - and it must NOT clear the
        # needs_update marker, or the flag is lost and the graph stays stale with
        # nothing left to re-trigger the heal.
        $fx = New-AutoFixFixture
        $repo = $fx.Repo; $log = $fx.Log; $err = $fx.Err
        $prov = Join-Path $repo '.mcpw-provision'
        New-Item -ItemType Directory -Path $prov -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $prov 'gm-semantic.mode') -Value 'on' -Encoding ASCII
        # Port 1: nothing listens, so the bounded probe fails fast and deterministically.
        $savedPort = $env:LLM_PROXY_PORT
        $env:LLM_PROXY_PORT = '1'
        $script:lastGmAutoFixTicks = 0; $script:gmHealUntilTick = 0
        . (Install-AutoFixStubs) 'C:\fake\bin\gm.exe'
        . (Install-AutoFixHeal)
        try {
            { Invoke-GrapheniumAutoFix } | Should Not Throw
            $script:spCalls.Count | Should Be 0            # no build was spawned
            Test-Path -LiteralPath $fx.Marker | Should Be $true   # marker preserved
        } finally {
            if ($savedPort) { $env:LLM_PROXY_PORT = $savedPort } else { Remove-Item env:LLM_PROXY_PORT -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still clears the marker and throws nothing when gm.exe is missing from PATH' {
        $fx = New-AutoFixFixture
        $repo = $fx.Repo; $log = $fx.Log; $err = $fx.Err
        $script:lastGmAutoFixTicks = 0; $script:gmHealUntilTick = 0
        . (Install-AutoFixStubs) ''
        . (Install-AutoFixHeal)

        { Invoke-GrapheniumAutoFix } | Should Not Throw

        Test-Path -LiteralPath $fx.Marker | Should Be $false
        $script:spCalls.Count             | Should Be 0
        $script:lastGmAutoFixTicks        | Should BeGreaterThan 0
    }
}

Describe 'scratch hygiene' {
    It 'removes every scratch tree this suite created' {
        Get-ChildItem -Path $env:TEMP -Filter 'vad-autofix-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        @(Get-ChildItem -Path $env:TEMP -Filter 'vad-autofix-*' -Directory -ErrorAction SilentlyContinue).Count | Should Be 0
    }
}
