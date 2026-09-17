# tests/launcher_pane_exit_qfy.tests.ps1
# Pester 3.4.0 team idiom. Run via:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_pane_exit_qfy.tests.ps1
# Regression locks for beads mcpw-qfy (pane-exit debug handover 2026-09-17):
#   RC1 idle-reaped grepai parks on IDLE (no heal, no exit, heartbeat kept)
#   RC2 Test-GrapheniumWatcherAlive probes gm serve / launcher lock (no gm watch)
#   RC3 known-label panes get a 30s dead-tick grace before closing
#   RC4 controller forgives sleep/resume gaps and waits 15s (was 8s)
# PS 5.1 compatible: no ?? operator, ASCII-only comments/hyphens (project rule).
$pesterLegacy = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -lt 4 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pesterLegacy) { Import-Module $pesterLegacy.Path -DisableNameChecking }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher = Join-Path $repoRoot '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$paneModule = Join-Path $repoRoot 'Modules\watcher_pane_scripts.ps1'
if (-not $env:VAD_WORKSPACE_ROOT) { $env:VAD_WORKSPACE_ROOT = $repoRoot }

function Get-PaneTemplateBody {
    $pat = @'
\$template = @'\r?\n(?<body>[\s\S]*?)\r?\n'@
'@
    $src = Get-Content -LiteralPath $paneModule -Raw
    $m = [regex]::Match($src, $pat)
    if (-not $m.Success) { throw 'tailer template not found in pane module' }
    return $m.Groups['body'].Value
}

function New-TestPane {
    param([string]$Dir, [string]$Label, [string]$Log, [string]$Err = '', [string]$WatchPid = '', [string]$LockFile = '')
    $hb = Join-Path $Dir ($Label + '.hb')
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($paneModule, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw 'parse errors in pane module' }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-WatcherPaneScript' }, $true)
    if (-not $func) { throw 'New-WatcherPaneScript not found' }
    $tmp = Join-Path $env:TEMP ('qfy_fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $tmp -Value $func.Extent.Text -Encoding utf8
    try {
        . $tmp
        $wtPaneDir = $Dir
        $p = New-WatcherPaneScript -Label $Label -LogPath $Log -ErrPath $Err -RepoRoot '' -HeartbeatPath $hb -WatchPid $WatchPid -LockFile $LockFile
        return @{ Tailer = $p; Hb = $hb }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Test-LiveGrepaiWatch {
    return (@(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' }).Count -gt 0)
}

function Test-LiveGmServe {
    return (@(Get-CimInstance Win32_Process -Filter "Name='gm.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'serve' }).Count -gt 0)
}

Describe 'mcpw-qfy RC1: idle-reaped grepai parks on IDLE' {
    It 'template defines the idle marker probe and IDLE state' {
        $tpl = Get-PaneTemplateBody
        $tpl | Should Match 'function Test-GrepaiIdleMarker'
        $tpl | Should Match 'IDLE - WAITING FOR QUERIES'
        $tpl | Should Match '\$script:idleShown'
        $tpl | Should Match "\`$LockFile = '__LOCKFILE__'"
    }

    It 'supervisor writes and clears the idle marker around intentional idle stops' {
        $src = Get-Content -LiteralPath $launcher -Raw
        $src | Should Match "ChangeExtension\(\`$LockFile, '.idle'\)"
        $src | Should Match 'supervisor exiting \(no restart\)'
    }

    It 'grepai tailer with an idle marker stays open, shows IDLE, and heartbeats' {
        if (Test-LiveGrepaiWatch) { Write-Host '  [SKIP] live grepai watch - IDLE scenario untestable'; return }
        $dir = Join-Path $env:TEMP ('qfy_idle_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $proc = $null
        try {
            $log = Join-Path $dir 'grepai.log'
            Set-Content -LiteralPath $log -Value @('seed') -Encoding UTF8
            $fakeLock = Join-Path $dir 'launcher.lock'
            Set-Content -LiteralPath $fakeLock -Value '{"Pid":1}' -Encoding UTF8
            Set-Content -LiteralPath ([System.IO.Path]::ChangeExtension($fakeLock, '.idle')) -Value (Get-Date -Format 'o') -Encoding UTF8
            $made = New-TestPane -Dir $dir -Label 'grepai' -Log $log -LockFile $fakeLock
            $cap = Join-Path $dir 'out.txt'
            $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-File', ("`"" + $made.Tailer + "`"")) `
                -RedirectStandardOutput $cap
            Start-Sleep -Seconds 7
            $proc.Refresh()
            $proc.HasExited | Should Be $false
            $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
            $out | Should Match 'IDLE - WAITING FOR QUERIES'
            $out | Should Not Match 'auto-heal SUCCESS'
            (Test-Path -LiteralPath $made.Hb) | Should Be $true
            $hbAge = ((Get-Date) - (Get-Item -LiteralPath $made.Hb).LastWriteTime).TotalSeconds
            $hbAge | Should BeLessThan 10
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'mcpw-qfy RC2: graphenium liveness without gm watch' {
    It 'graphenium probe targets serve / launcher lock, never gm watch' {
        $tpl = Get-PaneTemplateBody
        if ($tpl -notmatch '(?s)function Test-GrapheniumWatcherAlive \{(.*?)\n\}') { throw 'graphenium probe not found' }
        $fn = $Matches[1]
        $fn | Should Match "Name='gm.exe'"
        $fn | Should Match "'serve'"
        $fn | Should Not Match "'watch'"
    }

    It 'launcher passes its lock file to the graphenium pane' {
        $src = Get-Content -LiteralPath $launcher -Raw
        $src | Should Match 'New-WatcherPaneScript -Label "graphenium".*-LockFile \$lockFile'
    }
}

Describe 'mcpw-qfy RC3: dead-tick grace for known panes, fast exit otherwise' {
    It 'template graces graphenium / graphify-rs / repowise and keeps the unknown-label fast exit' {
        $tpl = Get-PaneTemplateBody
        $tpl | Should Match "'__LABEL__' -eq 'graphenium' -or '__LABEL__' -eq 'graphify-rs' -or '__LABEL__' -eq 'repowise'"
        $tpl | Should Match 'deadTicks -ge 60'
        $tpl | Should Match 'watcher exited - closing pane'
        $tpl | Should Match 'else \{ \$alive = \$false \}'
    }

    It 'graphenium tailer with a dead PID waits out transients, then closes' {
        if (Test-LiveGmServe) { Write-Host '  [SKIP] live gm serve - grace scenario untestable'; return }
        $dir = Join-Path $env:TEMP ('qfy_grace_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $dummy = $null; $proc = $null
        try {
            $log = Join-Path $dir 'gm.log'
            Set-Content -LiteralPath $log -Value @('seed') -Encoding UTF8
            $dummy = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -WindowStyle Hidden -PassThru
            $deadPid = [string]$dummy.Id
            Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
            $dummy = $null
            $made = New-TestPane -Dir $dir -Label 'graphenium' -Log $log -WatchPid $deadPid
            $cap = Join-Path $dir 'out.txt'
            $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-File', ("`"" + $made.Tailer + "`"")) `
                -RedirectStandardOutput $cap
            # 4s ~= 8 ticks: the old code exited on the first dead tick (~1s).
            Start-Sleep -Seconds 4
            $proc.Refresh()
            $proc.HasExited | Should Be $false
            # 60 ticks ~= 30s grace, then the pane closes as before (no orphan).
            $proc.WaitForExit(45000) | Out-Null
            $proc.Refresh()
            $proc.HasExited | Should Be $true
            $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
            $out | Should Match 'watcher exited - closing pane'
        } finally {
            if ($dummy) { Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue }
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'mcpw-qfy RC4: controller survives sleep and starvation' {
    It 'controller waits 15s, forgives resume gaps, and keeps the any-pane rule' {
        $src = Get-Content -LiteralPath $launcher -Raw
        $src | Should Match '\$hbTimeoutSec = 15'
        $src | Should Match 'System resume detected'
        $src | Should Match '\$hbLastLoop'
        $src | Should Match '\$anyAlive = \$false'
        $src | Should Match 'if \(\$anyAlive\) \{ \$hbStaleSince = \$null; continue \}'
    }
}

if (-not $env:LAUNCHER_PANE_EXIT_QFY_TEST_RAN) {
    $env:LAUNCHER_PANE_EXIT_QFY_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
