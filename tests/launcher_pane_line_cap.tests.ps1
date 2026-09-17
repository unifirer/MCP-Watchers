# tests/launcher_pane_line_cap.tests.ps1
# Pester 3.4.0 team idiom. Run via:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_pane_line_cap.tests.ps1
# Regression for the multi-pane window crash (systematic-debugging root cause):
# graphify-rs (and any watcher) can emit a SINGLE multi-megabyte log line. The
# pane tailer forwards log lines verbatim via Write-Host. A multi-million-char
# line crashes Microsoft.Terminal.Control.dll (access violation 0xc0000005 /
# 0xc000041d at offset 0x10494) and takes down the whole 4-pane window. CleanLogLine
# must cap every emitted line to a safe length, with a visible truncation marker.
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

# AST-based extraction of an embedded function (quote/comment-aware). Brace-counting
# would break on the single-quoted here-string template (full of literal { } braces).
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

Describe 'pane tailer never forwards an oversized line to the terminal' {
    It 'caps a 7.3 MB log line to a safe length and emits a truncation marker (no window crash)' {
        $src = Extract-FunctionAst -Path $paneModule -Name 'New-WatcherPaneScript'
        $fnTmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $fnTmp -Value $src -Encoding utf8
        # The function reads the module-level $wtPaneDir; point it at a temp dir so
        # the generated tailer is written out-of-repo.
        $wtPaneDir = Join-Path $env:TEMP ('wtpanes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        . $fnTmp
        try {
            $label = 'grepai'   # no repo scan -> fast launch; the cap applies to all labels equally
            $log = Join-Path $env:TEMP ("log_cap_$([guid]::NewGuid().ToString('N')).txt")
            # Reproduce the observed killer: a single 7.3 MB line (graphify-rs-watch.log
            # was observed with MAX LINE LEN 7297060).
            $giant = 'X' * 7297060
            $lines = @('normal line A', $giant, 'normal line B')
            Set-Content -LiteralPath $log -Value ($lines -join "`r`n") -Encoding utf8
            $tailer = New-WatcherPaneScript -Label $label -LogPath $log -ErrPath '' -RepoRoot ''
            # Launch the REAL tailer headless; merge its information stream (Write-Host)
            # into stdout via 6>&1 so Start-Process -RedirectStandardOutput captures it.
            # It loops forever, so we kill it after the backlog + header appear.
            $cap = Join-Path $env:TEMP ("cap_out_$([guid]::NewGuid().ToString('N')).txt")
            # Widen the headless console buffer so the cap is measured faithfully:
            # the default 80-col buffer wraps the long line and injects CRLF bytes
            # inside the cap marker, which would otherwise break a contiguous match
            # (and would defeat the max-length assertion). Real WT panes are wide,
            # so this mirrors actual terminal behavior.
            $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-Command', "try { [console]::BufferWidth = 10000 } catch {} ; & '$tailer' 6>&1") `
                -RedirectStandardOutput $cap
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
                $probe = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
                if ($probe -match [regex]::Escape("=== $label live log ===")) { break }
            }
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 200
            $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
            # The headless 80-col buffer wraps the long line and injects CRLF bytes
            # inside the cap marker, so collapse whitespace before matching.
            $outFlat = $out -replace "`r?`n",' '
            # Wiring check: the tailer emitted the giant line through CleanLogLine
            # and surfaced the cap marker (tolerate the CRLF the buffer may inject
            # inside the marker).
            $outFlat | Should Match '\[\+\d+\s+chars truncated\]'
            # The marker must report the exact truncated count for the full line,
            # which proves CleanLogLine observed the ENTIRE 7.3M-char line and cut
            # the tail (not a wrapped fragment).
            $outFlat | Should Match ('\[\+' + ($giant.Length - 2000) + '\s+chars truncated\]')
            # Length safety (wrap-proof, content-agnostic): the cap keeps exactly the
            # first 2000 chars, so the total count of the giant line's characters in
            # the emitted output must stay well under the crash-inducing size. If the
            # cap ever regressed, this count would jump into the millions.
            $totalGiantChars = ([regex]::Matches($out, [regex]::Escape($giant[0]))).Count
            $totalGiantChars | Should BeLessThan 2100
            Remove-Item -LiteralPath $cap -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
        finally {
            Remove-Item -LiteralPath $fnTmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wtPaneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $env:PANE_CAP_TEST_RAN) {
    $env:PANE_CAP_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
