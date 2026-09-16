# tests/launcher_wrapper_stack.tests.ps1
# Pester 3.4.0 (pinned). End-to-end regression: relaunching the REAL ###1 launcher
# must never stack graphify-watch-wrapper processes. Proves the startup sweep's
# idempotency (each launch reaps the prior wrapper). The parent-death guard's
# no-relaunch self-cleanup is proven by Task 2's test + manual sanity.
Import-Module Pester -RequiredVersion 3.4.0 -Force

$repo   = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$teardownModule = Join-Path $repo 'Modules\watcher_teardown.ps1'
$wrapperCmd = 'graphify-watch-wrapper'
. $teardownModule   # safe to dot-source (no top-level side effects); gives Stop-WatcherTree

function Get-WrapperCount {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($wrapperCmd) }).Count
}
function Get-LiveLauncherCount {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape('###1') -and $_.CommandLine -match '\.ps1' }).Count
}

Describe 'launcher relaunch leaves at most one wrapper' {
    It 'launch -> launch -> at most one wrapper remains' {
        # Do NOT run against a live ###1: our launch's startup sweep would kill
        # the user's live session. Skip if ANY wrapper or ###1 launcher is live.
        if ((Get-WrapperCount) -gt 0 -or (Get-LiveLauncherCount) -gt 0) {
            Write-Warning "A live ###1 launcher/wrapper is running - skipping live-stack test to avoid killing it."
            return
        }
        $launched = @()
        try {
            # Launch #1 and #2: run the real launcher, let it get past the startup
            # sweep + wrapper spawn (the wrapper registers its CommandLine in CIM
            # within ~1-2s), then kill the launcher HARD (simulates the crash that
            # orphans wrappers). Launch #2's OWN startup sweep reaps wrapper #1.
            1..2 | ForEach-Object {
                $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcher`"")
                $launched += $p
                $deadline = (Get-Date).AddSeconds(25)
                while ((Get-Date) -lt $deadline -and (Get-WrapperCount) -lt 1) {
                    Start-Sleep -Milliseconds 500
                }
                # Hard-kill the launcher WITHOUT letting its teardown run.
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 6   # guard polls every 1s + settle
            }
            # Idempotency: each launch's startup sweep reaps the prior wrapper, so
            # the worst case is ONE survivor (never a growing stack). With the
            # parent-death guard, the count is typically 0.
            $after = Get-WrapperCount
            $after | Should BeLessThan 2
        } finally {
            # Tree-kill the WHOLE subtree of each launched launcher (gm/repowise/
            # grepai/memtrace children + the Windows Terminal 2x2 grid it opened).
            foreach ($p in $launched) {
                try { Stop-WatcherTree -RootPid $p.Id | Out-Null } catch {}
            }
            # Reap any wrapper survivor by PID (test-owned).
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($wrapperCmd) } |
                ForEach-Object { try { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null } catch {} }
            # Remove the launcher's persisted state + lock so they don't linger.
            if ($launched.Count -gt 0) {
                try { Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'watchers\teardown-state.json') -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'watchers\###1-launcher.lock') -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }
}

if (-not $env:LAUNCHER_STACK_TEST_RAN) {
    $env:LAUNCHER_STACK_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
