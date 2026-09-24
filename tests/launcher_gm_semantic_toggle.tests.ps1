# tests/launcher_gm_semantic_toggle.tests.ps1
# Pester 3.4.0 idiom (same as launcher_gm_semantic_build.tests.ps1): run via
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_gm_semantic_toggle.tests.ps1

# Pin Pester 3.4.0 (this file uses the v3 positional `Should Match` idiom).
# Without this, a newer Pester (6.x) auto-loads and rejects the syntax.
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
#
# Locks the mcpw-b81 live semantic toggle. Before b81 the launcher hardcoded
# `--no-semantic` into Invoke-GmSemanticBuild and gated the WHOLE build on the
# LLM proxy being reachable. Both are now conditional on one switch:
#   <repo>\.mcpw-provision\gm-semantic.mode   ("on" | "off"), absent = OFF.
# Every case below fails on the pre-b81 source and passes after it.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

# ---------------------------------------------------------------------------
# Extraction helpers: pull the two functions out of the launcher VERBATIM, so
# these tests exercise production code rather than a copy that can drift.
# ---------------------------------------------------------------------------
$launcherSrc = Get-Content -LiteralPath $launcher -Raw

# Returns '' rather than throwing when the function is absent. A load-time
# throw would abort the whole file before any It runs, so the pre-b81 source
# would report no counts at all - and this suite's acceptance is that it
# FAILS on pre-b81 with a readable per-test diagnostic.
function Get-LauncherFunction([string]$src, [string]$name) {
    if ($src -notmatch ('(?s)function ' + [regex]::Escape($name) + ' \{.*?\n\}')) {
        return ''
    }
    return $Matches[0]
}

$fnMode  = Get-LauncherFunction $launcherSrc 'Test-GmSemanticEnabled'
$fnBuild = Get-LauncherFunction $launcherSrc 'Invoke-GmSemanticBuild'

# ---------------------------------------------------------------------------
# Behavioural harness. Invoke-GmSemanticBuild is dot-sourced into a child
# powershell.exe with gm.exe, the proxy probe and Start-Process all stubbed,
# so no real rebuild runs and no tokens are ever spent. The stub Start-Process
# records the argv it was handed; its presence/absence IS the assertion.
# ---------------------------------------------------------------------------
function Invoke-ToggleCase {
    param(
        [string]$ModeFileContent,   # $null => no mode file at all
        [bool]  $ProxyUp,
        [int]   $BuildKey
    )
    $tmp = Join-Path $env:TEMP ('gm_sem_toggle_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $prov = Join-Path $tmp '.mcpw-provision'
    New-Item -ItemType Directory -Path $prov | Out-Null
    if ($null -ne $ModeFileContent) {
        Set-Content -LiteralPath (Join-Path $prov 'gm-semantic.mode') -Value $ModeFileContent -Encoding ASCII
    }
    $argvFile = Join-Path $tmp 'argv.txt'

    $harness = @'
$ErrorActionPreference = 'Stop'
# Keep the mode-file assertion honest: a stray inherited env default would
# otherwise satisfy the "no file" fallback and mask a broken reader.
$env:MCPW_GM_SEMANTIC = $null
$r = '__REPO__'
$gmRunLog = Join-Path $r 'run.log'
function Get-Command { param($Name) if ($Name -eq 'gm.exe') { return [pscustomobject]@{ Source = 'stub-gm' } } ; return $null }
function Test-LlmProxyReady { __PROBE__ }
__FNMODE__
__FNBUILD__
function Start-Process {
    [CmdletBinding()]
    param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle,
        $RedirectStandardOutput, $RedirectStandardError,
        [switch]$PassThru, [switch]$Wait)
    ($ArgumentList -join ' ') | Set-Content -LiteralPath '__ARGV__' -Encoding ASCII
    return [pscustomobject]@{ ExitCode = 0 }
}
$threw = ''
try {
    Invoke-GmSemanticBuild -BuildDir $r -RunLog $gmRunLog -BuildKey __KEY__
} catch {
    $threw = $_.Exception.Message
}
if ($threw) { Write-Output ("RESULT: THREW " + $threw) }
elseif (Test-Path -LiteralPath '__ARGV__') { Write-Output ("RESULT: BUILT " + (Get-Content -LiteralPath '__ARGV__' -Raw)) }
else { Write-Output "RESULT: SKIPPED" }
'@
    if ($fnMode -eq '' -or $fnBuild -eq '') {
        return [pscustomobject]@{ Built = $false; Argv = ''; Threw = 'LAUNCHER MISSING Test-GmSemanticEnabled / Invoke-GmSemanticBuild'; ExitCode = -1; StdErr = '' }
    }
    $harness = $harness.Replace('__REPO__', $tmp)
    $harness = $harness.Replace('__ARGV__', $argvFile)
    $harness = $harness.Replace('__KEY__',  [string]$BuildKey)
    $harness = $harness.Replace('__PROBE__', $(if ($ProxyUp) { 'return $true' } else { 'return $false' }))
    $harness = $harness.Replace('__FNMODE__',  $fnMode)
    $harness = $harness.Replace('__FNBUILD__', $fnBuild)

    $hScript = Join-Path $env:TEMP ('gm_sem_toggle_case_' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $hScript -Value $harness -Encoding utf8
    try {
        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hScript) `
            -WindowStyle Hidden -Wait -PassThru `
            -RedirectStandardOutput ($hScript + '.out') -RedirectStandardError ($hScript + '.err')
        $out = (Get-Content -LiteralPath ($hScript + '.out') -Raw -ErrorAction SilentlyContinue)
        $err = (Get-Content -LiteralPath ($hScript + '.err') -Raw -ErrorAction SilentlyContinue)
        $res = [pscustomobject]@{ Built = $false; Argv = ''; Threw = ''; ExitCode = $p.ExitCode; StdErr = [string]$err }
        if ($out -match 'RESULT: THREW (.*)')   { $res.Threw = $Matches[1].Trim() }
        elseif ($out -match 'RESULT: BUILT (.*)') { $res.Built = $true; $res.Argv = $Matches[1].Trim() }
        if ([string]::IsNullOrWhiteSpace($out)) { $res.Threw = "(no stdout; exit $($p.ExitCode)) $err" }
        return $res
    } finally {
        Remove-Item -LiteralPath $hScript -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($hScript + '.out') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($hScript + '.err') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A fresh mutex name per case: two cases sharing Global\VAD_GmSemanticBuild_N
# would see the first hold the lock and the second skip spuriously.
$script:keySeq = 50000
function New-BuildKey { $script:keySeq++; return $script:keySeq }

Describe 'graphenium semantic live toggle (mcpw-b81)' {

    # --- static wiring -----------------------------------------------------
    It 'launcher reads one shared mode file and no longer hardcodes the flag' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'function Test-GmSemanticEnabled'
        $c | Should Match 'function Invoke-GmSemanticBuild'
        $c | Should Match ([regex]::Escape(".mcpw-provision\gm-semantic.mode"))
        # The flag is CONDITIONAL. On the pre-b81 source this line was a bare
        # `$runArgs += "--no-semantic"`, which is what this assertion kills.
        $c | Should Match ([regex]::Escape('if (-not $semanticOn) { $runArgs += "--no-semantic" }'))
        # ...and the proxy gate is conditional too, so an AST-only rebuild no
        # longer dies with a downed proxy.
        $c | Should Match ([regex]::Escape('if ($semanticOn -and -not (Test-LlmProxyReady))'))
        # The literal survives, because the sibling suite still matches it.
        $c | Should Match '--no-semantic'
    }

    It 'thread job receives the mode reader and rebuilds it in its runspace' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match ([regex]::Escape('param($State, $BuildSrc, $ProbeSrc, $BuildDir, $RunLog, $ModeSrc)'))
        $c | Should Match ([regex]::Escape('Set-Item -Path function:Test-GmSemanticEnabled -Value ([scriptblock]::Create($ModeSrc))'))
        # A thread job inherits no launcher functions: without this the mode
        # read would throw CommandNotFoundException on every build.
        $c | Should Match ([regex]::Escape('${function:Test-GmSemanticEnabled}.ToString()'))
        # Live propagation state.
        $c | Should Match 'SemanticModeSeen'
        $c | Should Match 'ModeChanged'
    }

    It 'ships an operator CLI for the switch' {
        (Test-Path -LiteralPath (Join-Path $repo 'dev_tools\gm-semantic-toggle.ps1')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $repo 'dev_tools\gm-semantic-toggle.bat')) | Should Be $true
    }

    # --- behaviour ---------------------------------------------------------
    It 'mode OFF builds with --no-semantic present' {
        $r = Invoke-ToggleCase -ModeFileContent 'off' -ProxyUp $true -BuildKey (New-BuildKey)
        $r.Threw | Should Be ''
        $r.Built | Should Be $true
        $r.Argv | Should Match '--no-semantic'
    }

    It 'mode ON builds with --no-semantic absent and the provider flags intact' {
        $r = Invoke-ToggleCase -ModeFileContent 'on' -ProxyUp $true -BuildKey (New-BuildKey)
        $r.Threw | Should Be ''
        $r.Built | Should Be $true
        $r.Argv | Should Not Match '--no-semantic'
        # Regex anchors on the JOINED argv (built at runtime, not present in the
        # launcher source as a single literal), so dev_tools/scan_stale_anchors.py
        # -- which only validates plain, metacharacter-free literals against the
        # source -- cannot mistake these for source anchors.
        $r.Argv | Should Match '--provider\s+openai-compatible'
        $r.Argv | Should Match '--model\s+\S+'
    }

    It 'mode ON with the proxy down skips the build without throwing' {
        $r = Invoke-ToggleCase -ModeFileContent 'on' -ProxyUp $false -BuildKey (New-BuildKey)
        $r.Threw | Should Be ''
        $r.Built | Should Be $false
    }

    It 'mode OFF with the proxy down STILL builds (the b81.1 bug fix)' {
        # Pre-b81 this skipped: an AST-only rebuild needs no LLM, yet the gate
        # was unconditional, so a downed proxy cost the operator the
        # structural graph as well as the semantic one.
        $r = Invoke-ToggleCase -ModeFileContent 'off' -ProxyUp $false -BuildKey (New-BuildKey)
        $r.Threw | Should Be ''
        $r.Built | Should Be $true
        $r.Argv | Should Match '--no-semantic'
    }

    It 'no mode file means OFF (builds, AST-only), never ON' {
        $r = Invoke-ToggleCase -ModeFileContent $null -ProxyUp $true -BuildKey (New-BuildKey)
        $r.Threw | Should Be ''
        $r.Built | Should Be $true
        $r.Argv | Should Match '--no-semantic'
    }

    # --- the reader --------------------------------------------------------
    It 'reader maps every file shape onto a boolean without ever throwing' {
        $tmp = Join-Path $env:TEMP ('gm_sem_reader_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $tmp '.mcpw-provision') | Out-Null
        $f = Join-Path $tmp '.mcpw-provision\gm-semantic.mode'
        # content -> expected boolean. $null means "delete the file".
        $cases = @(
            @('on', $true), @('ON', $true), @('On', $true), @('  on  ', $true),
            @('1', $true), @('true', $true), @('TRUE', $true), @('yes', $true),
            @('enabled', $true),
            @('off', $false), @('OFF', $false), @('0', $false), @('false', $false),
            @('', $false), @('   ', $false), @('garbage', $false), @('banana', $false),
            @('on off', $false)
        )
        # Deliberately NOT a tab/csv split: two cases are '' and '   ', and a
        # delimiter-based parse would eat exactly the shapes under test. One
        # content per line, read back verbatim.
        $readerHarness = @'
$env:MCPW_GM_SEMANTIC = $null
__FNMODE__
$r = '__REPO__'
$f = Join-Path $r '.mcpw-provision\gm-semantic.mode'
$out = @()
foreach ($content in (Get-Content -LiteralPath '__CASES__' -Encoding UTF8)) {
    Set-Content -LiteralPath $f -Value $content -Encoding ASCII
    $v = 'ERR'
    try { $v = [string](Test-GmSemanticEnabled -RepoRoot $r) } catch { $v = 'THREW' }
    $out += $v
}
# No file at all AND no env default -> OFF.
if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
$out += [string](Test-GmSemanticEnabled -RepoRoot $r)
# Same absent file, but with the env launch default set -> ON.
$env:MCPW_GM_SEMANTIC = '1'
$out += [string](Test-GmSemanticEnabled -RepoRoot $r)
$out | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
'@
        $casesFile = Join-Path $tmp 'cases.txt'
        $resultFile = Join-Path $tmp 'result.txt'
        $lines = @()
        foreach ($c in $cases) { $lines += $c[0] }
        Set-Content -LiteralPath $casesFile -Value ($lines -join "`n") -Encoding UTF8

        $rh = $readerHarness.Replace('__FNMODE__', $fnMode)
        $rh = $rh.Replace('__REPO__', $tmp)
        $rh = $rh.Replace('__CASES__', $casesFile)
        $rh = $rh.Replace('__RESULT__', $resultFile)

        $hScript = Join-Path $env:TEMP ('gm_sem_reader_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $hScript -Value $rh -Encoding utf8
        try {
            $p = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hScript) `
                -WindowStyle Hidden -Wait -PassThru
            $p.ExitCode | Should Be 0
            $got = @(Get-Content -LiteralPath $resultFile -Encoding UTF8)
            $got.Count | Should Be ($cases.Count + 2)
            for ($i = 0; $i -lt $cases.Count; $i++) {
                $want = [string]$cases[$i][1]
                $got[$i] | Should Be $want
            }
            # No file + no env  -> OFF.  No file + MCPW_GM_SEMANTIC=1 -> ON.
            $got[$cases.Count]     | Should Be 'False'
            $got[$cases.Count + 1] | Should Be 'True'
        } finally {
            Remove-Item -LiteralPath $hScript -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard with
# an env var so the rediscovery child skips the second Invoke-Pester. -Path keeps
# the run scoped to THIS file (no cross-file contamination).
if (-not $env:GM_SEM_TOGGLE_TEST_RAN) {
    $env:GM_SEM_TOGGLE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
