<#
    Tests for ###2.launch_watcher_for_grepai.ps1 (issue vad-79v, extended vad-7uj
    and vad-vxr).

    Covers the extracted pure units plus two source-level contracts:
      - Get-GrepaiOllamaTarget: documented-default fallback, endpoint read from
        .grepai/config.yaml (vad-7uj).
      - Ollama launch regression (vad-7uj): no unsupported `serve --host`, bare
        `serve` subcommand.
      - grepai launch regression (vad-vxr): never --background (30s self-kill
        crash loop on this repo), never --status as truth, foreground detached +
        hidden launch with redirected logs, CIM/log readiness.
      - Prerequisite exit path: running the REAL launcher with grepai scrubbed
        from PATH must exit non-zero and say why, without touching Ollama.
      - Double-click wrapper (vad-1ku): ###2.required_for_launch_watcher_for_grepai.bat
        bypasses execution policy AND its SCRIPT target exists on disk. Ported
        from the deleted tests/test_launch_watcher_standalone.py, whose ###3
        wrapper was orphaned by pointing at a script name that never existed.

    NOTE: same dependency-free assertion harness as
    tests/update_mcps_pure_functions.tests.ps1 (Pester 3.4.0 Should is broken
    under pwsh 7 on this host). Real shipped functions are extracted from the
    script source by brace matching - no drift-prone copies.

    Run: pwsh -NoProfile -File "tests/launch_watcher_for_grepai.tests.ps1"
    Exit code 0 = all pass; non-zero = at least one failure (RED/GREEN gate).
    Wired into python run_tests_isolated.py via
    tests/test_launch_watcher_for_grepai_ps1.py.
#>

$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path $PSScriptRoot '..\###2.launch_watcher_for_grepai.ps1'
$launcherPath = [System.IO.Path]::GetFullPath($launcherPath)
if (-not (Test-Path $launcherPath)) {
    # Tier B landed here on 2026-09-20: ###2.launch_watcher_for_grepai.ps1 and
    # its .bat wrapper were ported from VAD, so this checkout DOES ship the
    # launcher and this guard no longer fires here (the suite reports 19 passed,
    # 0 failed). It is kept because a checkout that does not ship the script
    # must still SKIP: a missing target says nothing about the launcher, and
    # tests/test_launch_watcher_for_grepai_ps1.py SKIPs on exactly this
    # condition for the pytest run, so this file has to behave the same way
    # when a sweep runs it directly.
    Write-Host "SKIP: launcher under test is not shipped by this checkout: $launcherPath"
    exit 0
}
$launcherSource = Get-Content -LiteralPath $launcherPath -Raw

# --- mini harness (no Pester) ---------------------------------------------
$script:__pass = 0
$script:__fail = 0
function Describe($name, [ScriptBlock]$body) {
    Write-Host "`n== $name ==" -ForegroundColor Cyan
    & $body
}
function It($name, [ScriptBlock]$body) {
    try { & $body; Write-Host "  [PASS] $name" -ForegroundColor Green; $script:__pass++ }
    catch { Write-Host "  [FAIL] $name : $_" -ForegroundColor Red; $script:__fail++ }
}
function Should-Be($actual, $expected) { if ($actual -ne $expected) { throw "expected '$expected' but got '$actual'" } }
function Should-BeTrue($actual) { if (-not $actual) { throw "expected `$true but got '$actual'" } }
function Should-BeFalse($actual) { if ($actual) { throw "expected `$false but got '$actual'" } }
function Should-BeNullOrEmpty($actual) { if ($null -ne $actual -and @($actual).Count -gt 0) { throw "expected null/empty but got: $($actual -join ', ')" } }
function Should-MatchText($text, $pattern) {
    if ("$text" -notmatch [regex]::Escape($pattern)) { throw "expected output containing '$pattern'" }
}

# Extract a single named function from a .ps1 file by brace matching so we test
# the REAL shipped code. Fails closed on missing/unbalanced braces.
function Extract-Function([string]$Source, [string]$Name) {
    $pattern = "function\s+$Name\b"
    $idx = [regex]::Match($Source, $pattern).Index
    if ($idx -lt 0) { throw "function $Name not found in source" }
    $braces = 0; $started = $false; $end = -1
    for ($k = $idx; $k -lt $Source.Length; $k++) {
        $c = $Source[$k]
        if ($c -eq '{') { $braces++; $started = $true }
        elseif ($c -eq '}') {
            $braces--
            if ($started -and $braces -eq 0) { $end = $k; break }
        }
    }
    if ($end -lt 0) { throw "unbalanced braces for $Name" }
    $fn = $Source.Substring($idx, $end - $idx + 1)
    $tmp = Join-Path $env:TEMP ("fn_" + $Name + "_" + [guid]::NewGuid() + ".ps1")
    Set-Content -Path $tmp -Value $fn -Encoding utf8
    return $tmp
}

foreach ($name in @('Get-GrepaiOllamaTarget')) {
    . (Extract-Function $launcherSource $name)
}

# --- Get-GrepaiOllamaTarget (vad-7uj regression: config-driven endpoint) -----
Describe 'Get-GrepaiOllamaTarget' {
    It 'falls back to the documented default 11434 when no config exists' {
        $scriptDir = Join-Path $env:TEMP ("gh_target_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $scriptDir | Out-Null
        try {
            Should-Be (Get-GrepaiOllamaTarget) '127.0.0.1:11434'
        } finally {
            Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'reads the endpoint from .grepai/config.yaml' {
        $scriptDir = Join-Path $env:TEMP ("gh_target_" + [guid]::NewGuid())
        $ghDir = Join-Path $scriptDir '.grepai'
        New-Item -ItemType Directory -Path $ghDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ghDir 'config.yaml') -Value "version: 1`nembedder:`n    provider: ollama`n    endpoint: http://127.0.0.1:12134`n" -Encoding utf8
        try {
            Should-Be (Get-GrepaiOllamaTarget) '127.0.0.1:12134'
        } finally {
            Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- vad-7uj regression: no unsupported serve --host flag, no hardcoded port --
Describe 'Ollama launch regression (vad-7uj)' {
    It 'never passes --host to ollama serve (unsupported on this build)' {
        Should-BeFalse ($launcherSource -match '-ArgumentList\s+"serve","--host"')
    }
    It 'starts ollama with the bare serve subcommand' {
        Should-BeTrue ($launcherSource -match '-ArgumentList "serve"')
    }
}

# --- vad-vxr regression: foreground-detached launch, no --background/--status -
Describe 'grepai launch regression (vad-vxr)' {
    It 'never launches grepai in --background mode (30s self-kill crash loop)' {
        Should-BeFalse ($launcherSource -match 'watch --background')
    }
    It 'never uses --status as the readiness or already-running truth source' {
        Should-BeFalse ($launcherSource -match 'watch --status')
    }
    It 'launches grepai watch detached + hidden with redirected logs' {
        Should-BeTrue ($launcherSource -match 'Start-Process .*-ArgumentList "watch"')
        Should-BeTrue ($launcherSource -match '-WindowStyle Hidden')
        Should-BeTrue ($launcherSource -match 'RedirectStandardOutput')
        Should-BeTrue ($launcherSource -match 'RedirectStandardError')
    }
    It 'judges readiness by CIM process liveness + worktree log artifacts' {
        Should-BeTrue ($launcherSource -match "Name='grepai\.exe'")
        Should-BeTrue ($launcherSource -match "CommandLine -match 'watch'")
        Should-BeTrue ($launcherSource -match 'grepai-worktree-')
    }
    It 'extracts the shipped liveness probe' {
        # The probe must be a real function so future refactors keep it testable.
        $fnPath = Extract-Function $launcherSource 'Test-GrepaiWatchAlive'
        try {
            $fnText = Get-Content -LiteralPath $fnPath -Raw
            Should-MatchText $fnText "Name='grepai.exe'"
        } finally {
            Remove-Item $fnPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- double-click wrapper (vad-1ku) ------------------------------------------
# Explorer has no reliable open-command for .ps1 under Restricted policy, so the
# launcher ships a .bat wrapper. The ###3 wrapper was orphaned: its SCRIPT
# variable named a file that never existed on disk, so double-click silently did
# nothing. Pin both the bypass flags and the SCRIPT target's existence.
$wrapperPath = Join-Path $PSScriptRoot '..\###2.required_for_launch_watcher_for_grepai.bat'
$wrapperPath = [System.IO.Path]::GetFullPath($wrapperPath)

Describe 'double-click wrapper' {
    It 'exists for the ###2 launcher' {
        Should-BeTrue (Test-Path $wrapperPath)
    }
    It 'runs the launcher via pwsh (or powershell) with -ExecutionPolicy Bypass -File' {
        $text = Get-Content -LiteralPath $wrapperPath -Raw
        Should-BeTrue ($text.Contains('-ExecutionPolicy Bypass'))
        Should-BeTrue ($text.Contains('-File'))
        Should-BeTrue ($text.Contains('pwsh.exe'))
        Should-BeTrue ($text.Contains('powershell.exe'))
    }
    It 'points SCRIPT at a launcher file that exists on disk' {
        $text = Get-Content -LiteralPath $wrapperPath -Raw
        $m = [regex]::Match($text, 'set\s+"SCRIPT=%~dp0([^"]+)"')
        Should-BeTrue ($m.Success)
        $target = Join-Path (Split-Path -Parent $wrapperPath) $m.Groups[1].Value
        Should-BeTrue (Test-Path $target)
    }
}

# --- prerequisite exit path (real script, no grepai on PATH) -----------------
Describe 'launcher prerequisite gate' {
    It 'exits non-zero with a reason when grepai is absent from PATH' {
        # System32 only: no stub, no real grepai. The gate must fire first,
        # before any Ollama or worktree work runs.
        $runPath = 'C:\Windows\System32'
        $out = & pwsh -NoProfile -NonInteractive -Command "`$env:PATH='$runPath'; & '$launcherPath'" 2>&1
        $code = $LASTEXITCODE
        Should-BeTrue ($code -ne 0)
        $text = ($out | Out-String)
        Should-MatchText $text 'grepai executable not found'
    }
}

# --- vad-r0i: parent-death propagation for the grepai watcher ----------------
Describe 'grepai parent-death wiring (vad-r0i)' {
    $jobModule = Join-Path $PSScriptRoot '..\Modules\watcher_job_helpers.ps1'
    $jobModule = [System.IO.Path]::GetFullPath($jobModule)

    It 'ships both parent-death helpers in the shared job-scope module' {
        Should-BeTrue (Test-Path $jobModule)
        $moduleSrc = Get-Content -LiteralPath $jobModule -Raw
        Should-BeTrue ($moduleSrc -match 'function New-WatcherParentDeathJob')
        Should-BeTrue ($moduleSrc -match 'function Add-ProcessToWatcherDeathJob')
        Should-BeTrue ($moduleSrc -match 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE')
        Should-BeTrue ($moduleSrc -match 'AssignProcessToJobObject')
    }

    It 'assigns EVERY grepai it spawns to the kill-on-close job' {
        Should-BeTrue ($launcherSource -match 'New-WatcherParentDeathJob')
        Should-BeTrue ($launcherSource -match 'Modules\\watcher_job_helpers\.ps1')
        # One assignment per spawn site (initial + stale-lock retry): a spawn
        # without an assignment is exactly the orphan this issue is about.
        $spawns = @([regex]::Matches($launcherSource, 'Start-Process .*-ArgumentList "watch"')).Count
        $assigns = @([regex]::Matches($launcherSource, 'Add-ProcessToWatcherDeathJob -Job')).Count
        Should-Be $assigns $spawns
        Should-BeTrue ($launcherSource -match '\$script:GrepaiPid = \$gp\.Id')
        Should-BeTrue ($launcherSource -match '\$script:GrepaiPid = \$gp2\.Id')
    }

    It 'keeps teardown PID-scoped to our own grepai (never a sibling watcher)' {
        Should-BeTrue ($launcherSource -match '\$script:GrepaiPid = 0')
        Should-BeTrue ($launcherSource -match 'if \(\$script:GrepaiPid -gt 0\)')
        Should-BeTrue ($launcherSource -match 'Modules\\watcher_teardown\.ps1')
    }

    It 'tears down on the graceful paths too (trap + PowerShell.Exiting)' {
        Should-BeTrue ($launcherSource -match '(?m)^trap \{')
        Should-BeTrue ($launcherSource -match 'grepai watch --stop')
        Should-BeTrue ($launcherSource -match 'Stop-AllWatchers')
        Should-BeTrue ($launcherSource -match 'Register-EngineEvent -SourceIdentifier PowerShell\.Exiting')
    }

    It 'builds a PowerShell.Exiting handler that parses and carries our grepai PID' {
        # The handler runs in a separate runspace with no script scope, so the
        # PID + module path are baked in at creation. A syntax slip there would
        # only surface as a silent "no teardown" on window close, so rebuild the
        # exact here-string here and prove it parses + interpolates.
        $m = [regex]::Match($launcherSource, '(?s)\$teardownAction = \[scriptblock\]::Create\(@"(.*?)"@\)')
        Should-BeTrue ($m.Success)
        $teardownModule = 'C:\Temp\vad-watchers\Modules\watcher_teardown.ps1'
        $grepaiTeardownPid = 4242
        $rendered = $ExecutionContext.InvokeCommand.ExpandString($m.Groups[1].Value)
        $handler = $null
        try { $handler = [scriptblock]::Create($rendered) } catch { throw "generated handler does not parse: $_" }
        Should-BeTrue ($null -ne $handler)
        Should-MatchText ($handler.ToString()) '4242'
        Should-MatchText ($handler.ToString()) 'Stop-AllWatchers'
    }
}

Describe 'parent-death propagation (vad-r0i)' {
    It 'kills a job-assigned throwaway child when its dummy parent is hard-killed' {
        # Bounded experiment: a throwaway `cmd /c ping` child (never grepai, no
        # port) assigned to the shipped job must die when the dummy parent is
        # TerminateProcess-ed - the crash/kill case where no trap or engine event
        # can run. Cleans up its own scratch dir and every process it spawns.
        $jobModule = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Modules\watcher_job_helpers.ps1'))
        $work = Join-Path $env:TEMP ('vad_r0i_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $parentScript = Join-Path $work 'dummy_parent.ps1'
        $marker = Join-Path $work 'child.txt'
        $parentSrc = @"
param([string]`$Module, [string]`$Marker)
. `$Module
`$job = New-WatcherParentDeathJob
if (`$job -eq [IntPtr]::Zero) { 'NOJOB' | Set-Content -LiteralPath `$Marker; exit 1 }
`$child = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','ping -n 300 127.0.0.1' -PassThru -WindowStyle Hidden
`$ok = Add-ProcessToWatcherDeathJob -Job `$job -ProcessId `$child.Id
"`$(`$child.Id)|`$ok" | Set-Content -LiteralPath `$Marker
Start-Sleep -Seconds 300
"@
        Set-Content -LiteralPath $parentScript -Value $parentSrc -Encoding UTF8
        $parent = $null
        $childPid = 0
        try {
            $parent = Start-Process -FilePath 'pwsh.exe' -PassThru -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $parentScript, '-Module', $jobModule, '-Marker', $marker)
            $raw = ''
            for ($i = 0; $i -lt 150; $i++) {
                Start-Sleep -Milliseconds 200
                if (Test-Path -LiteralPath $marker) {
                    $raw = (Get-Content -LiteralPath $marker -Raw).Trim()
                    if ($raw) { break }
                }
            }
            Should-BeFalse ($raw -eq 'NOJOB')
            Should-BeTrue ($raw -match '^\d+\|True$')
            $childPid = [int](($raw -split '\|')[0])
            Should-BeTrue ([bool](Get-Process -Id $childPid -ErrorAction SilentlyContinue))
            Stop-Process -Id $parent.Id -Force -ErrorAction SilentlyContinue
            $gone = $false
            for ($i = 0; $i -lt 60; $i++) {
                Start-Sleep -Milliseconds 100
                if (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { $gone = $true; break }
            }
            Should-BeTrue $gone
        } finally {
            if ($childPid -gt 0) { try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {} }
            if ($parent) { try { Stop-Process -Id $parent.Id -Force -ErrorAction SilentlyContinue } catch {} }
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- teardown ----------------------------------------------------------------

Write-Host ""
Write-Host ("launch_watcher_for_grepai.tests.ps1: {0} passed, {1} failed" -f $script:__pass, $script:__fail)
if ($script:__fail -gt 0) { exit 1 }
exit 0
