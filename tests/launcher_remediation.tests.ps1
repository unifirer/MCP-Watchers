# tests/launcher_remediation.tests.ps1
# Pester 3.4.0 idiom (same as launcher_gm_semantic_build.tests.ps1): run via
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_remediation.tests.ps1
#
# Regression locks for the 2026-09-06 gauntlet remediation of the ###1 watcher
# launcher (beads VAD-3apv, VAD-z7rf, VAD-1aw0, VAD-hne6, VAD-pp50, VAD-zfb6,
# VAD-kesg, VAD-lnhe, VAD-ltnq). Each test names the bead it locks.

Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop

$repo     = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$jobHelpers = Join-Path $repo 'Modules\watcher_job_helpers.ps1'
$paneModule = Join-Path $repo 'Modules\watcher_pane_scripts.ps1'

function Get-LauncherSource {
    Get-Content -LiteralPath $launcher -Raw
}

function Get-JobHelpersSource {
    Get-Content -LiteralPath $jobHelpers -Raw
}

function Get-PaneModuleSource {
    Get-Content -LiteralPath $paneModule -Raw
}

Describe 'launcher gauntlet remediation (2026-09-06)' {

    It 'VAD-3apv: gm-semantic thread job scriptblock starts with param() (no statements before it)' {
        $src = Get-LauncherSource
        ($src -match '\$gmSemJob = Start-ThreadJob') | Should Be $true
        if ($src -notmatch '(?s)\$gmSemJob = Start-ThreadJob.*?-ScriptBlock \{(.*?)\} -ErrorAction SilentlyContinue') {
            throw 'gm-semantic Start-ThreadJob scriptblock not found'
        }
        $body = $Matches[1]
        # The dead-on-arrival bug: any statement before param() makes PowerShell
        # throw "The term 'param' is not recognized" when the job invokes it.
        ($body -match '^\s*param\(\$State, \$BuildSrc, \$ProbeSrc, \$BuildDir, \$RunLog\)') | Should Be $true
        # Startup FULL warm-up stays removed (the build is change-driven only).
        $src | Should Not Match 'Invoke-GmSemanticBuild -Mode "full"'
        # Failures surface instead of being discarded.
        $body | Should Match '\$State\.Failed'
    }

    It 'VAD-3apv: exactly ONE $global:gmSemState definition (duplicate lost PopupShown)' {
        $src = Get-LauncherSource
        @([regex]::Matches($src, [regex]::Escape('$global:gmSemState = @{'))).Count | Should Be 1
    }

    It 'VAD-z7rf: fallback combined tailer reads incrementally (no whole-file Get-Content per tick)' {
        $src = Get-LauncherSource
        if ($src -notmatch '(?s)if \(-not \$wtOk\) \{(.*?)\r?\n\}\r?\n\r?\n# Controller loop \(WT panes open\): keep this window alive as the controller\.') {
            throw 'fallback tailer block not found'
        }
        $fb = $Matches[1]
        $fb | Should Match 'Read-WatcherLogTail -Path \$s\.Path -Offset'
        $fb | Should Match '\$offStreams'
        # The old leak pattern: whole-file read inside the poll loop.
        $fb | Should Not Match 'Get-Content -LiteralPath \$s\.Path -Encoding UTF8'
    }

    It 'VAD-1aw0: Get-GrepaiStatusText drains pipes concurrently BEFORE WaitForExit and disposes the Process' {
        $src = Get-LauncherSource
        if ($src -notmatch '(?s)function Get-GrepaiStatusText \{.*?\n\}') { throw 'Get-GrepaiStatusText not found' }
        $fn = $Matches[0]
        ($fn.IndexOf('ReadToEndAsync') -ge 0) | Should Be $true
        ($fn.IndexOf('ReadToEndAsync') -lt $fn.IndexOf('WaitForExit(15000)')) | Should Be $true
        $fn | Should Match '\$proc\.Dispose\(\)'
        # Both streams are drained (the old version never read stderr before wait).
        $fn | Should Match '\$errTask'
    }

    It 'VAD-1aw0: supervisor gob repair and pane health probe use the same drain-then-wait pattern' {
        $src = Get-LauncherSource
        $paneSrc = Get-PaneModuleSource
        ($src -match '\$outTask = \$proc\.StandardOutput\.ReadToEndAsync\(\)') | Should Be $true
        # vad-uzb: the pane health probe moved to Modules/watcher_pane_scripts.ps1.
        ($paneSrc -match '\$hOut = \$hproc\.StandardOutput\.ReadToEndAsync\(\)') | Should Be $true
        # No redirected-pipe helper may call StandardOutput.ReadToEnd() after a
        # completed WaitForExit anymore (deadlock-then-kill on large output).
        foreach ($s in @($src, $paneSrc)) {
            $s | Should Not Match '\$proc\.StandardOutput\.ReadToEnd\(\)'
            $s | Should Not Match '\$hproc\.StandardOutput\.ReadToEnd\(\)'
        }
    }

    It 'VAD-hne6: append-style supervisor logs are size-capped before appending' {
        $src = Get-LauncherSource
        # VAD-v14z.5 removed the copy-pasted helper bodies: Limit-LogSize now lives
        # ONCE in Modules\watcher_job_helpers.ps1 and the launcher plus every
        # thread-job runspace dot-source it from a literal path. Counting verbatim
        # copies here would re-assert the duplication the dedupe deliberately
        # removed, so assert the single-source-of-truth shape instead.
        (@([regex]::Matches($src, 'function Limit-LogSize')).Count) | Should Be 0
        (@([regex]::Matches((Get-JobHelpersSource), 'function Limit-LogSize')).Count) | Should Be 1
        $src | Should Match '\. \$jobHelpersModule'
        $src | Should Match 'function Write-SupLog \{[^}]*Limit-LogSize -Path \$SupervisorLog'
        $src | Should Match 'function Write-HealLog \{[^}]*Limit-LogSize -Path \$HealLog'
        $src | Should Match 'Limit-LogSize -Path \$restartLog'
    }

    It 'VAD-pp50: grepai supervisor backs off after consecutive failed restarts' {
        $src = Get-LauncherSource
        if ($src -notmatch '(?s)\$supervisorScript = \{(.*?)\}\r?\n\s*\$supervisorJob = Start-ThreadJob') {
            throw 'grepai supervisor scriptblock not found'
        }
        $sup = $Matches[1]
        $sup | Should Match '\$consecutiveRestarts'
        $sup | Should Match '\$consecutiveRestarts -ge 5'
        $sup | Should Match 'Start-Sleep -Seconds 600'
    }

    It 'VAD-zfb6: both FileSystemWatchers set a 64 KB InternalBufferSize and coalesce via ConcurrentQueue' {
        $src = Get-LauncherSource
        $paneSrc = Get-PaneModuleSource
        # vad-uzb: one watcher stays in the launcher (gm-semantic) and the other
        # now lives in Modules/watcher_pane_scripts.ps1 (repowise recentChanges).
        @([regex]::Matches($src, 'InternalBufferSize = 65536')).Count | Should Be 1
        @([regex]::Matches($paneSrc, 'InternalBufferSize = 65536')).Count | Should Be 1
        @([regex]::Matches($src, [regex]::Escape('[System.Collections.Concurrent.ConcurrentQueue[string]]::new()'))).Count | Should Be 1
        @([regex]::Matches($paneSrc, [regex]::Escape('[System.Collections.Concurrent.ConcurrentQueue[string]]::new()'))).Count | Should Be 1
        # Event actions only enqueue; per-event canonicalization moved to the
        # consumer loops (unbounded PS event queue no longer carries work).
        foreach ($s in @($src, $paneSrc)) {
            $s | Should Not Match '\{ Add-GmSemanticChange \$Event\.SourceEventArgs'
            $s | Should Not Match '\{ Add-RecentChange \$Event\.SourceEventArgs'
        }
        $src | Should Match '\$global:gmSemState\.Queue\.Enqueue\(\$Event\.SourceEventArgs\.FullPath\)'
        $paneSrc | Should Match '\$global:recentChangesQueue\.Enqueue\(\$Event\.SourceEventArgs\.FullPath\)'
    }

    It 'VAD-kesg: the Ollama startup gate probes the config-driven target (12134 only as fallback)' {
        $src = Get-LauncherSource
        $src | Should Match '\$ollamaTarget = Get-GrepaiOllamaTarget'
        $src | Should Not Match '\$ollamaPort = 12134'
        # Documented fallback kept.
        $src | Should Match '\$ollamaLegacyPort = 12134'
    }

    It 'VAD-ltnq: grepai pane probe is cached, heartbeat throttled, no Test-NetConnection left' {
        $src = Get-LauncherSource
        $paneSrc = Get-PaneModuleSource
        # vad-uzb: the grepai pane probe moved to Modules/watcher_pane_scripts.ps1.
        $paneSrc | Should Match '\$script:grepaiAliveCacheAt'
        $paneSrc | Should Match 'if \(\$script:hbTick -ge 4\)'
        foreach ($s in @($src, $paneSrc)) {
            $s | Should Not Match 'Test-NetConnection -ComputerName'
        }
        (@([regex]::Matches($src, 'New-Object System\.Net\.Sockets\.TcpClient')).Count -ge 6) | Should Be $true
        # The probe function the other test suites lock must still exist.
        $paneSrc | Should Match 'function Test-GrepaiWatcherAlive'
    }

    It 'VAD-lnhe: dead code is gone (Invoke-GrepaiSafe, launcher-level health check, dead vars, dup errLog)' {
        $src = Get-LauncherSource
        $src | Should Not Match 'function Invoke-GrepaiSafe'
        # Exactly one Invoke-GrepaiHealthCheck remains, and it lives in the pane
        # module (vad-uzb) -- the launcher keeps no inline copy.
        @([regex]::Matches($src, 'function Invoke-GrepaiHealthCheck')).Count | Should Be 0
        @([regex]::Matches((Get-PaneModuleSource), 'function Invoke-GrepaiHealthCheck')).Count | Should Be 1
        $src | Should Not Match '\$global:gmSemanticLive = '
        $src | Should Not Match '\$global:gmSemanticChanged = '
        $src | Should Not Match '\$global:gmSemanticLastBuild = '
        $src | Should Not Match '\$gmSemDebounceSec = '
        $src | Should Not Match '\$gmSemMaxStaleSec = '
        @([regex]::Matches($src, [regex]::Escape('$errLog = "$LogFile.err"'))).Count | Should Be 1
    }

    It 'VAD-3apv live smoke: the gm-semantic job pattern runs, drains the queue, and builds incrementally' {
        # Live replica of the launcher's thread-job pattern: param() FIRST,
        # functions rebuilt from source text inside the job (a function passed
        # as an argument is parent-session-bound and its cmdlets do not resolve
        # across the runspace hop), queue drain -> debounce -> incremental
        # build, $State.Failed surfaced. Uses a LITERAL scriptblock like the
        # launcher does. Runs in a child pwsh (Start-ThreadJob ships with PS7;
        # skipped cleanly when no thread-job host exists).
        $harness = @"
`$ErrorActionPreference = 'Stop'
if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) { Write-Output 'GM_SEM_JOB_SKIPPED'; exit 0 }
`$buildSrc = 'param(`$Mode, `$BuildDir, `$RunLog, `$BuildKey) Add-Content -LiteralPath (`$RunLog + ''.built'') -Value `$Mode'
`$probeSrc = 'return `$true'
`$state = @{
    Live = `$true; Changed = `$false
    LastBuild = [datetime]::UtcNow.AddDays(-1)
    PopupShown = `$false
    Queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
}
`$scriptDir = Join-Path `$env:TEMP ('gm_sem_job_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path `$scriptDir | Out-Null
`$gmRunLog = Join-Path `$scriptDir 'run.log'
`$state.Queue.Enqueue((Join-Path `$scriptDir 'sample.py'))
`$job = Start-ThreadJob -ArgumentList `$state, `$buildSrc, `$probeSrc, `$scriptDir, `$gmRunLog -ScriptBlock {
    param(`$State, `$BuildSrc, `$ProbeSrc, `$BuildDir, `$RunLog)
    Set-Item -Path function:Test-LlmProxyReady     -Value ([scriptblock]::Create(`$ProbeSrc))
    Set-Item -Path function:Invoke-GmSemanticBuild -Value ([scriptblock]::Create(`$BuildSrc))
    `$debounceSec  = 10
    `$maxStaleSec  = 600
    while (`$State.Live) {
        Start-Sleep -Seconds 1
        `$drainedPath = `$null
        `$sawChange = `$false
        while (`$State.Queue.TryDequeue([ref]`$drainedPath)) {
            try {
                `$p = [System.IO.Path]::GetFullPath(`$drainedPath)
                if (`$p -match '^[a-z]:') { `$p = [char]::ToUpper(`$p[0]) + `$p.Substring(1) }
                `$skip = `$false
                foreach (`$seg in (`$p -split '[\\/]')) {
                    if (`$seg -like '.?*') { `$skip = `$true; break }
                    if (@('temp','panes','graphenium-out','graphify-out','!!!AUTO_SCRIPTS!!!','node_modules','target','dist','build') -ccontains `$seg) { `$skip = `$true; break }
                }
                if (-not `$skip) { `$sawChange = `$true }
            } catch { }
        }
        if (`$sawChange) { `$State.Changed = `$true }
        `$now = [datetime]::UtcNow
        `$quiet = (`$now - `$State.LastBuild).TotalSeconds
        `$stale = (`$now - `$State.LastBuild).TotalSeconds -ge `$maxStaleSec
        if ((`$State.Changed -and `$quiet -ge `$debounceSec) -or `$stale) {
            `$State.Changed = `$false
            `$State.LastBuild = [datetime]::UtcNow
            try {
                Invoke-GmSemanticBuild -Mode "incremental" -BuildDir `$BuildDir -RunLog `$RunLog -BuildKey 0
            } catch {
                Write-Warning ("[gm-semantic] incremental build raised: " + `$_.Exception.Message)
                `$State.Failed = `$true
            }
        }
    }
}
`$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt `$deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath (`$gmRunLog + '.built')) { break }
}
`$state.Live = `$false
Wait-Job `$job -Timeout 20 | Out-Null
`$jobOut = (Receive-Job `$job -ErrorAction SilentlyContinue *>&1) | Out-String
# Capture evidence BEFORE removing the scratch dir (deleting first would
# destroy the very artifact the assertions check).
`$builtPath = (`$gmRunLog + '.built')
`$builtOk = Test-Path -LiteralPath `$builtPath
`$builtText = if (`$builtOk) { Get-Content -LiteralPath `$builtPath -Raw } else { '' }
Remove-Item -LiteralPath `$scriptDir -Recurse -Force -ErrorAction SilentlyContinue
if (`$job.State -ne 'Completed') { throw ('JOB-' + `$job.State + ': ' + `$jobOut) }
if (-not `$builtOk) { throw ('BUILD-NEVER-RAN: ' + `$jobOut) }
if (`$builtText -notmatch 'incremental') { throw ('WRONG-MODE: ' + `$builtText) }
if (`$builtText -match 'full') { throw 'A startup FULL warm-up ran (forbidden)' }
Write-Output 'GM_SEM_JOB_OK'
"@
        $hScript = Join-Path $env:TEMP ("launcher_remediation_" + [guid]::NewGuid().ToString('N') + ".ps1")
        Set-Content -LiteralPath $hScript -Value $harness -Encoding utf8
        try {
            # Start-ThreadJob ships with pwsh (PS7); 5.1 has no ThreadJob module.
            # The ###1 .bat wrapper prefers pwsh.exe, so smoke against pwsh first
            # and skip cleanly when neither host can run thread jobs.
            $host1 = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
            $p = Start-Process -FilePath $host1 `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hScript) `
                -WindowStyle Hidden -Wait -PassThru `
                -RedirectStandardOutput ($hScript + '.out') -RedirectStandardError ($hScript + '.err')
            $out = (Get-Content -LiteralPath ($hScript + '.out') -Raw -ErrorAction SilentlyContinue)
            $err = (Get-Content -LiteralPath ($hScript + '.err') -Raw -ErrorAction SilentlyContinue)
            if ($out -and $out -match 'GM_SEM_JOB_SKIPPED') { Write-Host 'Start-ThreadJob unavailable - smoke skipped'; return }
            $p.ExitCode | Should Be 0
            ($out -match 'GM_SEM_JOB_OK') | Should Be $true
            if ($err -and $err.Trim()) { throw "harness stderr: $err" }
        } finally {
            Remove-Item -LiteralPath $hScript -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($hScript + '.out') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($hScript + '.err') -Force -ErrorAction SilentlyContinue
        }
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir.
# Guard with an env var so the rediscovery child skips the second Invoke-Pester.
if (-not $env:LAUNCHER_REMEDIATION_TEST_RAN) {
    $env:LAUNCHER_REMEDIATION_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
