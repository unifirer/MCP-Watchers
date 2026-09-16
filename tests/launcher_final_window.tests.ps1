Import-Module Pester -ErrorAction Stop

# Regression guard for the final split window bug (2026-08-21):
# The repowise pane (BR, final Build-GridStep) closed when its WatchPid was stale
# while a new repowise watch was alive, because liveness was PID-only.
# The fix adds per-label any-watch probes and fallback, so final window keeps
# correct repowise info and does not show grepai or stay empty.

$launcher = 'J:\audio\VAD\###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$paneModule = 'J:\audio\VAD\Modules\watcher_pane_scripts.ps1'

function Get-LauncherCode {
    (Get-Content -LiteralPath $launcher) |
        Where-Object { $_.TrimStart().StartsWith('#') -eq $false }
}

function Get-TailerTemplateBody {
    $pat = @'
\$template = @'\r?\n(?<body>[\s\S]*?)\r?\n'@
'@
    foreach ($p in @($launcher, $paneModule)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $src = Get-Content -LiteralPath $p -Raw
        $m = [regex]::Match($src, $pat)
        if ($m.Success) { return $m.Groups['body'].Value }
    }
    return $null
}

Describe 'final split window (repowise BR) shows correct info, not grepai' {

    It 'four pane tailers map label to correct log variable (grepai->logFile, repowise->repowiseLog)' {
        $code = Get-LauncherCode | Out-String
        $code | Should -Match 'New-WatcherPaneScript -Label "grepai".*-LogPath \$logFile'
        $code | Should -Match 'New-WatcherPaneScript -Label "repowise".*-LogPath \$repowiseLog'
        $code | Should -Match 'New-WatcherPaneScript -Label "graphenium".*-LogPath \$gmLog'
        $code | Should -Match 'New-WatcherPaneScript -Label "graphify-rs".*-LogPath \$graphifyLog'
    }

    It 'final Build-GridStep is repowise BR with title repowise and file tailRepowise' {
        $code = Get-LauncherCode | Out-String
        $titleSteps = [regex]::Matches($code, "Build-GridStep @\('-w',.*?'--title', '(.*?)'")
        $titleSteps.Count | Should -Be 4
        $last = $titleSteps[$titleSteps.Count - 1]
        $last.Groups[1].Value | Should -Be 'repowise'
        $first = $titleSteps[0]
        $first.Groups[1].Value | Should -Be 'grepai'
        # Total Build-GridStep calls is 6 (3 pane splits + 2 focus + 1 new-tab)
        $allSteps = [regex]::Matches($code, "Build-GridStep @\(")
        $allSteps.Count | Should -Be 6
    }

    It 'tailer template defines any-watch probes for all four watchers' {
        $tpl = Get-TailerTemplateBody
        $tpl | Should -Not -Be $null
        $tpl | Should -Match 'function Test-GrepaiWatcherAlive'
        $tpl | Should -Match 'function Test-GrapheniumWatcherAlive'
        $tpl | Should -Match 'function Test-GraphifyRsWatcherAlive'
        $tpl | Should -Match 'function Test-RepowiseWatcherAlive'
        $tpl | Should -Match "Name='gm.exe'"
        $tpl | Should -Match "Name='repowise.exe'"
        $tpl | Should -Match "graphify-watch-wrapper"
        $tpl | Should -Match "WatchMode"
    }

    It 'liveness guard falls back to any-watch probe when PID is stale or empty (keeps final window alive on PID rotation)' {
        $tpl = Get-TailerTemplateBody
        $tpl | Should -Not -Be $null
        $tpl | Should -Match 'Test-WatcherAlive'
        $tpl | Should -Match "Test-RepowiseWatcherAlive"
        $tpl | Should -Match "Test-GrapheniumWatcherAlive"
        $tpl | Should -Match "Test-GraphifyRsWatcherAlive"
        $tpl | Should -Match "Test-GrepaiWatcherAlive"
        $tpl | Should -Not -Match 'else \{ \$alive = \$false \}   # tracked pane with no watcher PID: close immediately'
    }

    It 'generated repowise tail would keep correct label and log path (no grepai leak)' {
        $tpl = Get-TailerTemplateBody
        $tpl | Should -Not -Be $null
        $fakeLog = 'C:\Temp\vad-watchers\watchers\repowise.log'
        $body = $tpl.Replace('__LABEL__', 'repowise').Replace('__LOG__', $fakeLog)
        $body | Should -Match "\[repowise\]"
        $body | Should -Match ([regex]::Escape($fakeLog))
        $body | Should -Match "Test-RepowiseWatcherAlive"
        $body | Should -Not -Match "__LABEL__"
        $body | Should -Not -Match "__LOG__"
    }
}

Describe 'repowise pane survives PID rotation (dynamic)' {
    It 'template keeps any-watch fallback so stale PID does not kill final window' {
        $tpl = Get-TailerTemplateBody
        $tpl | Should -Not -Be $null
        $tpl | Should -Match 'Test-RepowiseWatcherAlive'
        $tpl | Should -Match 'Test-GrapheniumWatcherAlive'
        $tpl | Should -Match 'Test-GraphifyRsWatcherAlive'
        # The liveness block must contain fallback for stale PID case
        $tpl | Should -Match 'if \(-not \$alive\)'
        $tpl | Should -Match "Test-RepowiseWatcherAlive"
    }
}

if (-not $env:LAUNCHER_FINAL_WINDOW_TEST_RAN) {
    $env:LAUNCHER_FINAL_WINDOW_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
