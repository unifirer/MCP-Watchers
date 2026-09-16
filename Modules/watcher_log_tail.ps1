# modules/watcher_log_tail.ps1
# Incremental, byte-offset log reader for the watcher pane tailers.
#
# LEAK FIX (2026-09-06, beads VAD-iuyp): the pane tailers used to re-read the
# ENTIRE log with Get-Content on every 500ms poll tick - roughly 173,000 full
# reads per day, each allocating a large string array (large-object-heap
# churn). Measured on this repo: 4.25 GB working set and a constant CPU burn
# after 8 h of idle watching. This module reads ONLY the bytes appended since
# the previous call.
#
# DISPLAY SEMANTICS: every byte read is decoded and split into lines, INCLUDING
# a trailing line that does not (yet) end on a newline. This matches the
# shipped whole-file reader exactly (see the repowise_changed_files regression
# tests): repowise writes its final "N changed file(s)" line with NO trailing
# CR/LF, and suppressing unterminated lines would hide that change-event line
# forever. The offset always advances to end-of-file, so a line is displayed
# exactly once, just like the old line-count watermark.
#
# PS 5.1 compatible: no ?? operator, ASCII-only comments (project rule).

function Read-WatcherLogTail {
    # Reads all lines appended to $Path since byte offset $Offset and advances
    # $Offset to the current end of the file. Returns a pscustomobject:
    #   Lines   - string[] of lines read this call (may be empty)
    #   Offset  - byte offset to pass as -Offset on the NEXT call
    #   Rotated - $true when the file shrank below the stored offset (log
    #             rotation/truncation); Offset is then re-seated to show a
    #             small backlog so the caller can print its rotate message.
    #
    # Encoding is UTF-8 (the watcher logs are UTF-8; a leading BOM is skipped).
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [long] $Offset,
        [int] $BacklogBytes = 65536
    )
    $result = [pscustomobject]@{
        Lines   = @()
        Offset  = $Offset
        Rotated = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    # FileShare ReadWrite: the watched process keeps its log open for writing;
    # a share violation just means "retry next tick".
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    } catch { return $result }
    try {
        $length = $fs.Length
        if ($length -lt $Offset) {
            # Log rotated or truncated: re-seat to a small fresh backlog.
            $newOff = [Math]::Max(0, $length - $BacklogBytes)
            $result.Offset = $newOff
            $result.Rotated = $true
            $Offset = $newOff
        }
        if ($length -le $Offset) { return $result }
        $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] ($length - $Offset)
        $read = 0
        while ($read -lt $bytes.Length) {
            $n = $fs.Read($bytes, $read, $bytes.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -le 0) { return $result }
        # Skip a UTF-8 BOM when reading the very start of the file.
        $start = 0
        if ($Offset -eq 0 -and $read -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $read - $start)
        $lines = @($text -split '\r?\n')
        # The split leaves one empty element after a trailing newline; a final
        # line WITHOUT a terminator survives as a real (unterminated) line -
        # that is intentional, see DISPLAY SEMANTICS above.
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
            $lines = @($lines[0..($lines.Count - 2)])
        }
        if ($lines.Count -eq 0) { $lines = @() }
        $result.Lines = $lines
        $result.Offset = $Offset + $read
        return $result
    } finally {
        $fs.Dispose()
    }
}
