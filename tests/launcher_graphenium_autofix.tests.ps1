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
        . ([scriptblock]::Create((Get-TailFunctionText -TailScript $gmTailScript -Name 'Invoke-GrapheniumAutoFix')))
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

    It 'takes the daemon build mutex, before the cooldown, and keeps the marker on contention (mcpw-b81.7)' {
        # The pane heal is a SECOND full `gm run` site. Before b81.7 it took no
        # mutex, while the launcher's Invoke-GmSemanticBuild takes
        # Global\VAD_GmSemanticBuild_<BuildKey> - so a needs_update heal landing
        # mid-build gave two concurrent full re-extractions racing on the same
        # graphenium-out/ cleanup.
        $healText = Get-TailFunctionText -TailScript $gmTailScript -Name 'Invoke-GrapheniumAutoFix'
        # Same name the daemon builds from $BuildKey = 0.
        $healText | Should Match ([regex]::Escape("'Global\VAD_GmSemanticBuild_0'"))
        $healText | Should Match 'WaitOne\(0\)'    # fail fast, never queue
        $healText | Should Match 'ReleaseMutex'    # released on every exit path
        # Acquired BEFORE the cooldown is burned: a contested heal must not cost
        # the next 10 minutes, or the marker sits stale with nothing to retry it.
        $healText.IndexOf('VAD_GmSemanticBuild_0') |
            Should BeLessThan $healText.IndexOf('$script:lastGmAutoFixTicks = $nowTicks')
        # The skip returns before the marker is cleared, so the flag survives.
        $healText.IndexOf('skipping the heal') |
            Should BeLessThan $healText.IndexOf('Remove-Item -LiteralPath $marker')
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
        $script:lastGmAutoFixTicks = 0; $script:gmHealUntilTick = 0
        . (Install-AutoFixStubs) 'C:\fake\bin\gm.exe'
        . (Install-AutoFixHeal)
        # Override the proxy probe with a constant "down" so this case never
        # touches a socket: the heal's skip decision is what is under test, not
        # the probe. (Pointing LLM_PROXY_PORT at a dead port would also work but
        # makes the suite depend on real network behaviour.)
        function Test-GmPaneLlmProxyReady { return $false }
        try {
            { Invoke-GrapheniumAutoFix } | Should Not Throw
            $script:spCalls.Count | Should Be 0            # no build was spawned
            Test-Path -LiteralPath $fx.Marker | Should Be $true   # marker preserved
        } finally {
            Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'mcpw-b81.7: with a build in progress the heal logs a skip and starts nothing' {
        # The heal must LOSE to the launcher's build, not race it. The holder has
        # to live on ANOTHER THREAD: System.Threading.Mutex is RECURSIVE on its
        # owning thread, so a holder acquired in THIS thread would let the heal's
        # own WaitOne(0) succeed and the case would pass while proving nothing
        # (probed 2026-09-24: same-thread double WaitOne(0) -> True, True;
        # cross-thread -> False).
        $fx = New-AutoFixFixture
        $repo = $fx.Repo; $log = $fx.Log; $err = $fx.Err
        $script:lastGmAutoFixTicks = 0; $script:gmHealUntilTick = 0
        . (Install-AutoFixStubs) 'C:\fake\bin\gm.exe'
        . (Install-AutoFixHeal)

        $name  = 'Global\VAD_GmSemanticBuild_0'
        $ready = New-Object System.Threading.ManualResetEventSlim($false)
        $go    = New-Object System.Threading.ManualResetEventSlim($false)
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $h = $null
        try {
            $null = $ps.AddScript({
                param($n, $r, $g)
                $m = New-Object System.Threading.Mutex($false, $n)
                $held = $m.WaitOne(0)
                $r.Set()                       # the mutex is held BEFORE this signal
                $null = $g.Wait(15000)
                try { if ($held) { $m.ReleaseMutex() } } catch {}
                $m.Dispose()
            }).AddArgument($name).AddArgument($ready).AddArgument($go)
            $h = $ps.BeginInvoke()
            # Positive control: if the holder never took the mutex, the skip
            # asserted below would be vacuous - fail loudly instead.
            $ready.Wait(5000) | Should Be $true

            { Invoke-GrapheniumAutoFix } | Should Not Throw

            $script:spCalls.Count             | Should Be 0      # no build spawned
            Test-Path -LiteralPath $fx.Marker | Should Be $true   # flag preserved
            $script:lastGmAutoFixTicks        | Should Be 0       # cooldown NOT burned
        } finally {
            try { $go.Set() } catch {}
            try { if ($h) { $ps.EndInvoke($h) | Out-Null } } catch {}
            try { $ps.Dispose() } catch {}
            try { $rs.Close(); $rs.Dispose() } catch {}
            try { $ready.Dispose(); $go.Dispose() } catch {}
            Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'mcpw-b81.7: with no build in progress the heal behaves as today and releases the mutex' {
        $fx = New-AutoFixFixture
        $repo = $fx.Repo; $log = $fx.Log; $err = $fx.Err
        $script:lastGmAutoFixTicks = 0; $script:gmHealUntilTick = 0
        . (Install-AutoFixStubs) 'C:\fake\bin\gm.exe'
        . (Install-AutoFixHeal)

        $name = 'Global\VAD_GmSemanticBuild_0'
        $probe = $null; $created = $false; $wasFree = $false
        try {
            $probe = New-Object System.Threading.Mutex($false, $name)
            $created = $true
            $wasFree = $probe.WaitOne(0)
            if ($wasFree) { $probe.ReleaseMutex() }
        } catch { }
        # Positive control: if the mutex could not even be created, every branch
        # below is meaningless.
        $created | Should Be $true
        try {
            { Invoke-GrapheniumAutoFix } | Should Not Throw
            if ($wasFree) {
                Test-Path -LiteralPath $fx.Marker | Should Be $false   # healed
                $script:spCalls.Count             | Should Be 1
                # Released on the success path: the daemon's next build must be
                # able to take it, so a lock leaked here is a dead daemon.
                $probe.WaitOne(0) | Should Be $true
                $probe.ReleaseMutex()
            } else {
                # The suite runs on the same machine as the launcher, so a REAL
                # build may own the mutex. Then the free path cannot be exercised
                # here and the honest assertion is the skip path - never a
                # manufactured failure.
                $script:spCalls.Count             | Should Be 0
                Test-Path -LiteralPath $fx.Marker | Should Be $true
            }
        } finally {
            try { $probe.Dispose() } catch {}
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
