# tests/watcher_log_tail.tests.ps1
# Pester 3.4.0 idiom (team harness): run via
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/watcher_log_tail.tests.ps1
# Regression tests for the incremental byte-offset log reader (leak fix
# 2026-09-06, beads VAD-iuyp): the pane tailers previously re-read the whole
# log every 500ms tick. Each It builds its own scratch log (idempotent).
# Pin any installed Pester 3.x explicitly BEFORE dot-sourcing anything: some
# hosts leak pwsh7 module dirs onto PSModulePath, and 5.1 auto-load then picks
# Pester 6.x, whose Should does not bind the legacy positional form used here.
$pesterLegacy = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -lt 4 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pesterLegacy) { Import-Module $pesterLegacy.Path -DisableNameChecking }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\..\Modules\watcher_log_tail.ps1"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Describe 'Read-WatcherLogTail' {
    BeforeEach { $log = Join-Path $env:TEMP ("gf_tail_test_" + [guid]::NewGuid().ToString("N") + ".log") }
    AfterEach { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }

    It 'returns nothing for a missing file and keeps the offset' {
        $r = Read-WatcherLogTail -Path $log -Offset 0
        $r.Lines.Count | Should Be 0
        $r.Offset | Should Be 0
        $r.Rotated | Should Be $false
    }
    It 'reads complete lines and advances the offset to end of file' {
        [System.IO.File]::WriteAllText($log, "line1`nline2`n", $utf8NoBom)
        $r1 = Read-WatcherLogTail -Path $log -Offset 0
        ($r1.Lines -join '|') | Should Be 'line1|line2'
        $r1.Offset | Should Be (Get-Item -LiteralPath $log).Length
        $r1.Rotated | Should Be $false
        # A second read at the returned offset sees nothing new.
        $r2 = Read-WatcherLogTail -Path $log -Offset $r1.Offset
        $r2.Lines.Count | Should Be 0
        $r2.Offset | Should Be $r1.Offset
    }
    It 'reads ONLY newly appended lines on the next call' {
        [System.IO.File]::WriteAllText($log, "one`n", $utf8NoBom)
        $r1 = Read-WatcherLogTail -Path $log -Offset 0
        [System.IO.File]::AppendAllText($log, "two`nthree`n", $utf8NoBom)
        $r2 = Read-WatcherLogTail -Path $log -Offset $r1.Offset
        ($r2.Lines -join '|') | Should Be 'two|three'
        $r2.Offset | Should Be (Get-Item -LiteralPath $log).Length
    }
    It 'displays an unterminated trailing line immediately (no-EOL regression)' {
        [System.IO.File]::WriteAllText($log, "done`n", $utf8NoBom)
        $r1 = Read-WatcherLogTail -Path $log -Offset 0
        ($r1.Lines -join '|') | Should Be 'done'
        # A writer may flush a line in chunks. The trailing unterminated line
        # must still display (the old whole-file reader displayed it too), and
        # the offset advances so it is shown exactly once.
        [System.IO.File]::AppendAllText($log, "par", $utf8NoBom)
        $r2 = Read-WatcherLogTail -Path $log -Offset $r1.Offset
        ($r2.Lines -join '|') | Should Be 'par'
        $r2.Offset | Should Be (Get-Item -LiteralPath $log).Length
        # The completed remainder surfaces as the next chunk when written.
        [System.IO.File]::AppendAllText($log, "tial`n", $utf8NoBom)
        $r3 = Read-WatcherLogTail -Path $log -Offset $r2.Offset
        ($r3.Lines -join '|') | Should Be 'tial'
    }
    It 'handles CRLF line endings without stray carriage returns' {
        [System.IO.File]::WriteAllText($log, "alpha`r`nbeta`r`n", $utf8NoBom)
        $r = Read-WatcherLogTail -Path $log -Offset 0
        ($r.Lines -join '|') | Should Be 'alpha|beta'
    }
    It 'skips a UTF-8 BOM on the first read' {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($log, "bomline`n", $utf8Bom)
        $r = Read-WatcherLogTail -Path $log -Offset 0
        $r.Lines.Count | Should Be 1
        $r.Lines[0] | Should Be 'bomline'
        $r.Offset | Should Be (Get-Item -LiteralPath $log).Length
    }
    It 'decodes multi-byte UTF-8 characters correctly' {
        [System.IO.File]::WriteAllText($log, "caf" + [char]0x00E9 + "`n", $utf8NoBom)
        $r = Read-WatcherLogTail -Path $log -Offset 0
        $r.Lines[0] | Should Be ("caf" + [char]0x00E9)
    }
    It 'detects rotation/shrink and re-seats to a backlog' {
        $content = (1..50 | ForEach-Object { "row$_" }) -join "`n"
        [System.IO.File]::WriteAllText($log, $content + "`n", $utf8NoBom)
        $r1 = Read-WatcherLogTail -Path $log -Offset 0
        $r1.Rotated | Should Be $false
        # Watcher restart truncates/rotates the log to a much smaller file.
        [System.IO.File]::WriteAllText($log, "fresh`n", $utf8NoBom)
        $r2 = Read-WatcherLogTail -Path $log -Offset $r1.Offset
        $r2.Rotated | Should Be $true
        ($r2.Lines -join '|') | Should Be 'fresh'
        $r2.Offset | Should Be (Get-Item -LiteralPath $log).Length
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard
# with an env var so the rediscovery child skips the second Invoke-Pester.
if (-not $env:GF_WATCH_LOG_TAIL_TEST_RAN) {
    $env:GF_WATCH_LOG_TAIL_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
