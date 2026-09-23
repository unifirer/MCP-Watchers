"""Port of Modules/watcher_log_tail.ps1 - bead mcpw-xeu.2.

Incremental, byte-offset log reader for the watcher pane tailers.

LEAK FIX (2026-09-06, beads VAD-iuyp): the pane tailers used to re-read the
ENTIRE log with Get-Content on every 500ms poll tick - roughly 173,000 full reads
per day, each allocating a large string array (large-object-heap churn). Measured
on this repo: 4.25 GB working set and a constant CPU burn after 8 h of idle
watching. This module reads ONLY the bytes appended since the previous call.

DISPLAY SEMANTICS: every byte read is decoded and split into lines, INCLUDING a
trailing line that does not (yet) end on a newline. This matches the shipped
whole-file reader exactly (see the repowise_changed_files regression tests):
repowise writes its final "N changed file(s)" line with NO trailing CR/LF, and
suppressing unterminated lines would hide that change-event line forever. The
offset always advances to end-of-file, so a line is displayed exactly once, just
like the old line-count watermark.

TWO REPRESENTATIONS EXIST UNTIL THE PANE SCRIPTS AND THE LAUNCHER ARE PORTED. The
PowerShell module is still live, and its text is EMBEDDED into every generated
pane script by Modules/watcher_pane_scripts.ps1. tests/test_ported_leaf_modules.py
holds this port to the same display semantics as the .ps1.

Fidelity notes, verified against the live .ps1 rather than assumed:
  - The PowerShell reader opens with FileShare.ReadWrite because the watched
    process keeps its log open for writing. CPython opens with share-all on
    Windows, so a plain open() already tolerates the writer; a failure to open is
    still treated as "retry next tick", never an exception to the caller.
  - [System.Text.Encoding]::UTF8.GetString REPLACES malformed bytes with U+FFFD
    rather than raising, so decoding here uses errors="replace" to match. A
    strict decode would turn a torn write into a crashed tailer.
  - The BOM is skipped only when the offset in use is 0 - and that offset is the
    RE-SEATED one after a rotation, exactly as the PowerShell reassigns $Offset
    before its BOM check.
"""
import os
import re
from typing import NamedTuple

_DEFAULT_BACKLOG_BYTES = 65536
_LINE_SPLIT = re.compile(r"\r?\n")
_UTF8_BOM = b"\xef\xbb\xbf"


class LogTailResult(NamedTuple):
    """Lines read this call, the offset for the NEXT call, and rotation state."""

    lines: tuple
    offset: int
    rotated: bool


def read_watcher_log_tail(path, offset, backlog_bytes=_DEFAULT_BACKLOG_BYTES):
    """Read all lines appended to `path` since byte offset `offset`.

    Advances the returned offset to the current end of the file. `rotated` is
    True when the file shrank below the stored offset (log rotation or
    truncation); the offset is then re-seated to show a small backlog so the
    caller can print its rotate message.

    Encoding is UTF-8; a leading BOM is skipped.
    """
    if not os.path.exists(path):
        return LogTailResult((), offset, False)

    try:
        handle = open(path, "rb")
    except OSError:
        # Share violation, or the file vanished between the check and the open.
        # Either way this means "retry next tick", not "fail the tailer".
        return LogTailResult((), offset, False)

    try:
        handle.seek(0, os.SEEK_END)
        length = handle.tell()

        current = offset
        rotated = False
        if length < current:
            # Log rotated or truncated: re-seat to a small fresh backlog.
            current = max(0, length - backlog_bytes)
            rotated = True

        if length <= current:
            return LogTailResult((), current, rotated)

        handle.seek(current, os.SEEK_SET)
        data = handle.read(length - current)
        if not data:
            return LogTailResult((), current, rotated)

        start = 0
        if current == 0 and data.startswith(_UTF8_BOM):
            start = len(_UTF8_BOM)

        text = data[start:].decode("utf-8", errors="replace")
        lines = _LINE_SPLIT.split(text)
        # The split leaves one empty element after a trailing newline; a final
        # line WITHOUT a terminator survives as a real (unterminated) line -
        # that is intentional, see DISPLAY SEMANTICS above.
        if lines and lines[-1] == "":
            lines = lines[:-1]

        return LogTailResult(tuple(lines), current + len(data), rotated)
    finally:
        handle.close()
