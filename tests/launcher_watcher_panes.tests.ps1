# tests/launcher_watcher_panes.tests.ps1
# Pester 3.4.0 team idiom. Run via:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_panes.tests.ps1
# Proves the 3x2 pane grid created by
# "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1" shows
# info for all five pane-backed watchers (grepai, graphenium, graphify-rs,
# repowise, codegraph) plus the reserved empty cell. mcpw-0sp.
# memtrace is intentionally pane-less and is NOT covered.
$launcher = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$paneModule = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'Modules\watcher_pane_scripts.ps1'
if (-not $env:VAD_WORKSPACE_ROOT) { $env:VAD_WORKSPACE_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
# Pin any installed Pester 3.x explicitly BEFORE anything else: some hosts leak
# pwsh7 module dirs onto PSModulePath, and 5.1 auto-load then picks Pester 6.x,
# whose Should does not bind the legacy positional form used here.
$pesterLegacy = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -lt 4 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pesterLegacy) { Import-Module $pesterLegacy.Path -DisableNameChecking }

# AST-based extraction of an embedded function (quote/comment-aware).
# Brace-counting would break on the single-quoted here-string template inside
# New-WatcherPaneScript (full of literal { } braces). The PowerShell parser
# understands strings, so AST extraction returns the true function text.
function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { throw "launcher missing: $Path" }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "parse errors in $Path" }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

Describe 'pane tailer generation' {
    It 'extracts and dot-sources New-WatcherPaneScript without error' {
        $src = Extract-FunctionAst -Path $paneModule -Name 'New-WatcherPaneScript'
        $tmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        try { { . $tmp } | Should Not Throw }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'bakes the correct Label + LogPath + ErrPath into each of the 6 tailers' {
        $src = Extract-FunctionAst -Path $paneModule -Name 'New-WatcherPaneScript'
        $tmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        $wtPaneDir = Join-Path $env:TEMP ('panes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        try {
            . $tmp
            $labels = @('grepai', 'graphenium', 'graphify-rs', 'repowise', 'codegraph', 'heimdall')
            foreach ($lbl in $labels) {
                $log = Join-Path $env:TEMP ("log_$lbl.txt")
                $err = "$log.err"
                $repo = if ($lbl -eq 'graphify-rs') { 'J:\audio\VAD' } else { '' }
                $p = New-WatcherPaneScript -Label $lbl -LogPath $log -ErrPath $err -RepoRoot $repo
                Test-Path -LiteralPath $p | Should Be $true
                $body = Get-Content -LiteralPath $p -Raw
                # The baked label must appear as the [label] tag prefix in the body.
                $body | Should Match ([regex]::Escape("[$lbl]"))
                # The log path must be baked (single-quoted assignment in the template).
                $body | Should Match ([regex]::Escape("`$log = '$log'"))
                # graphify-rs must bake the repo root (used to resolve changed files).
                if ($lbl -eq 'graphify-rs') {
                    $body | Should Match ([regex]::Escape("`$repo = 'J:\audio\VAD'"))
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wtPaneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'pane grid wiring' {
    It 'generates exactly one tailer per pane-backed watcher (grepai/graphenium/graphify-rs/repowise/codegraph/heimdall)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'New-WatcherPaneScript -Label "grepai"'
        $c | Should Match 'New-WatcherPaneScript -Label "graphenium"'
        $c | Should Match 'New-WatcherPaneScript -Label "graphify-rs"'
        $c | Should Match 'New-WatcherPaneScript -Label "repowise"'
        $c | Should Match 'New-WatcherPaneScript -Label "codegraph"'
        $c | Should Match 'New-WatcherPaneScript -Label "heimdall"'
    }

    It 'wires each watcher to the correct log path' {
        $c = Get-Content -LiteralPath $launcher -Raw
        # graphenium -> $gmLog ; graphify-rs -> $graphifyLog (+ RepoRoot) ; repowise -> $repowiseLog ; grepai -> $logFile
        # NOTE: the launcher pads these calls with 2-6 spaces between the label
        # and -LogPath (e.g. line 772 "...-Label \"graphenium\"  -LogPath $gmLog"),
        # so the assertions use \s+ rather than a single literal space.
        $c | Should Match 'New-WatcherPaneScript -Label "graphenium"\s+-LogPath \$gmLog'
        $c | Should Match 'New-WatcherPaneScript -Label "graphify-rs"\s+-LogPath \$graphifyLog\s+-ErrPath "\$graphifyLog\.err"\s+-RepoRoot \$watchersWorkspaceRoot'
        $c | Should Match 'New-WatcherPaneScript -Label "repowise"\s+-LogPath \$repowiseLog'
        $c | Should Match 'New-WatcherPaneScript -Label "grepai"\s+-LogPath \$logFile\s+-ErrPath ""'
    }

    It 'wt 3x2 grid references all 6 tailer scripts and a --title per pane' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match '\$tailGrepai'
        $c | Should Match '\$tailGraphenium'
        $c | Should Match '\$tailGraphifyRs'
        $c | Should Match '\$tailRepowise'
        $c | Should Match '\$tailCodegraph'
        $c | Should Match '\$tailHeimdall'
        # one --title per watcher, quoted token form used by the wt args
        $c | Should Match "'grepai'"
        $c | Should Match "'graphenium'"
        $c | Should Match "'graphify-rs'"
        $c | Should Match "'repowise'"
        $c | Should Match "'codegraph'"
        $c | Should Match "'heimdall'"
        (($c | Select-String -Pattern "--title" -AllMatches).Matches.Count) | Should BeGreaterThan 5
    }
}

Describe 'pane tailer shows watcher info at runtime' {
    It 'each generated tailer prints its watcher log lines tagged with [label]' {
        $src = Extract-FunctionAst -Path $paneModule -Name 'New-WatcherPaneScript'
        $tmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        $wtPaneDir = Join-Path $env:TEMP ('panes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        . $tmp
        # One case per pane-backed watcher. graphenium carries a '[graphenium]' prefix
        # that CleanLogLine strips, and ships an stderr line (printed under [graphenium],
        # not [graphenium ERR]) — both verified below.
        $cases = @(
            @{ Label = 'grepai';      Lines = @('grepai watch indexing worktree', 'watching for file changes') },
            @{ Label = 'graphenium';  Lines = @('[graphenium] Watching modules/', 'changed (code): VAD.py'); Err = @('stderr line for graphenium') },
            @{ Label = 'graphify-rs'; Lines = @('Files changed (1)', 'built graph for VAD') },
            @{ Label = 'repowise';    Lines = @('watching repo for changes', 'indexed 12 modules') }
        )
        try {
            foreach ($case in $cases) {
                $log = Join-Path $env:TEMP ("log_$($case.Label).txt")
                $err = "$log.err"
                # Seed the log BEFORE launching so the tailer's backlog print picks it up.
                Set-Content -LiteralPath $log -Value ($case.Lines -join "`r`n") -Encoding utf8
                if ($case.Err) { Set-Content -LiteralPath $err -Value ($case.Err -join "`r`n") -Encoding utf8 }
                $repo = if ($case.Label -eq 'graphify-rs') { 'J:\audio\VAD' } else { '' }
                $tailer = New-WatcherPaneScript -Label $case.Label -LogPath $log -ErrPath $err -RepoRoot $repo
                # Launch the REAL tailer; merge its information stream (Write-Host) into
                # stdout via 6>&1 so Start-Process -RedirectStandardOutput captures it.
                # It loops forever, so we kill it after a beat (fail-safe: Stop-Process
                # is wrapped so a missing PID never throws).
                $cap = Join-Path $env:TEMP ("cap_$($case.Label).txt")
                $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                    -ArgumentList @('-NoProfile', '-Command', "& '$tailer' 6>&1") `
                    -RedirectStandardOutput $cap
                # The tailer seeds a repo-wide baseline scan at launch (graphify-rs
                # walks the whole repo, which takes ~13s on a 146k-file tree) BEFORE
                # it prints the header + backlog. A fixed 1s sleep would capture
                # nothing for graphify-rs, so poll for the header to appear (generous
                # deadline) and then kill. The three light watchers exit this loop in ~1s.
                $deadline = (Get-Date).AddSeconds(40)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 250
                    $probe = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
                    if ($probe -match [regex]::Escape("=== $($case.Label) live log ===")) { break }
                }
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Milliseconds 200
                $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
                $out | Should Match ([regex]::Escape("=== $($case.Label) live log ==="))
                foreach ($ln in $case.Lines) {
                    # graphenium lines carry a '[graphenium]' prefix CleanLogLine strips,
                    # so assert the stripped content under the pane's own [graphenium] tag.
                    $stripped = $ln -replace '^\[graphenium(?: [A-Z]+)?\]\s*', ''
                    $out | Should Match ([regex]::Escape("[$($case.Label)] $stripped"))
                }
                if ($case.Err) {
                    # graphenium prints stderr under [graphenium]; others under [label ERR].
                    $tag = if ($case.Label -eq 'graphenium') { '[graphenium]' } else { "[$($case.Label) ERR]" }
                    $out | Should Match ([regex]::Escape("$tag $($case.Err[0])"))
                }
                Remove-Item -LiteralPath $cap -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wtPaneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'reserved and optional panes stay open (mcpw-0sp)' {
    # The 3x2 grid is only stable if these two cells never close themselves: a
    # pane whose command exits is closed by Windows Terminal (closeOnExit) and
    # the surviving panes re-flow into a ragged layout. Before mcpw-0sp the
    # template's liveness chain fell through to "else { $alive = $false }" for
    # any label it did not recognise, so BOTH panes exited on their first tick.
    It 'the heimdall cell and a PID-less codegraph pane never self-close' {
        $src = Extract-FunctionAst -Path $paneModule -Name 'New-WatcherPaneScript'
        $tmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        $wtPaneDir = Join-Path $env:TEMP ('panes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        . $tmp
        try {
            foreach ($lbl in @('heimdall', 'codegraph')) {
                $log = Join-Path $env:TEMP ("log_$lbl.txt")
                Set-Content -LiteralPath $log -Value 'seed line' -Encoding utf8
                # NO -WatchPid: exactly how the launcher builds these two panes
                # (heimdall always; codegraph when the watcher never started).
                # mcpw-qxj.8: heimdall MUST be a recognised label -- an unknown
                # label closes on its first tick and the whole 3x2 grid re-flows.
                $tailer = New-WatcherPaneScript -Label $lbl -LogPath $log -ErrPath '' -RepoRoot ''
                $cap = Join-Path $env:TEMP ("cap_$lbl.txt")
                $proc = Start-Process -FilePath (Get-Command powershell).Source -PassThru -WindowStyle Hidden `
                    -ArgumentList @('-NoProfile', '-Command', "& '$tailer' 6>&1") -RedirectStandardOutput $cap
                # 4s = ~7 poll ticks, well past the first liveness branch.
                Start-Sleep -Seconds 4
                $stillUp = $null
                try { $stillUp = Get-Process -Id $proc.Id -ErrorAction Stop } catch { $stillUp = $null }
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Milliseconds 200
                $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
                $stillUp | Should Not BeNullOrEmpty
                $out | Should Not Match 'closing pane'
                Remove-Item -LiteralPath $cap -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wtPaneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $env:WPANE_TEST_RAN) {
    $env:WPANE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
