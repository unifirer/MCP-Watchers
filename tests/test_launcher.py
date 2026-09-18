"""
Launcher test shim.

The VAD watcher launcher (###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1)
is a PowerShell script, not Python, so its real test suite is
tests/launcher_tests.ps1 (run via the PowerShell interpreter). This shim
lets pytest discover and gate that suite without collecting the repo's large
Python test tree (per AGENTS.md, running the full pytest collection here exhausts
the paging file). It executes the actual PS suite and asserts it passes.

Run: pytest tests/test_launcher.py -v

Environment rules (bead mcpw-tao -- do not re-diagnose these as code bugs):

  * The PS suite runs under whichever PowerShell host is found on PATH,
    Windows PowerShell 5.1 first. When no host is resolvable the test SKIPS:
    a missing interpreter is an environment gap, not a launcher defect.
  * This module never deletes the cross-process lock file. filelock 4.x
    WindowsFileLock guards with a LockFileEx byte-range lock, which the OS
    releases when the holder dies, and it unlinks the file itself on release.
    A leftover file therefore cannot block acquisition, while deleting it at
    import time can drop it out from under a LIVE holder in a concurrent run.
    An earlier revision did exactly that, and the delete made pytest abort
    during collection in sandboxes that intercept unlink.
  * The suite is slow and its runtime is load-dependent: 160 s alone, but it
    blew a 300 s ceiling inside a full pytest run where other modules were
    driving the same watchers. The ceiling is 900 s. The suite's stdout goes
    to a file so that a timeout still leaves partial output to diagnose.

See docs/guides/pytest-environment.md for the full write-up.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest
from filelock import FileLock

REPO_ROOT = Path(__file__).resolve().parent.parent
PS_SUITE = REPO_ROOT / "tests" / "launcher_tests.ps1"

# Windows PowerShell 5.1 first: launcher_tests.ps1 exercises the launcher's
# Windows PowerShell paths. pwsh (7.x) is only a fallback.
_PS_HOST_NAMES = ("powershell", "pwsh")

# The PS suite's T8 block starts and stops the SHARED global watchers (grepai,
# graphenium, repowise, graphify-rs). test_launch_watcher.py drives the same
# grepai watcher and already serialises on this cross-process lock. Without
# taking it here too, T8's auto-start/stop races it: one test sees "no background
# watcher is running" while the other sees "watcher is already running" in the
# SAME suite run.
_GREPAI_LOCK_PATH = Path(__file__).resolve().parent / ".grepai_watcher_tests.lock"
_grepai_lock = FileLock(str(_GREPAI_LOCK_PATH), timeout=600)


def _resolve_ps_host():
    """Return the first PowerShell host on PATH, or None when none exists."""
    for name in _PS_HOST_NAMES:
        found = shutil.which(name)
        if found:
            return found
    return None


@pytest.mark.skipif(
    sys.platform != "win32",
    reason="Launcher + Windows Terminal are Windows-only",
)
def test_launcher_powershell_suite_passes():
    assert PS_SUITE.exists(), f"PS suite missing: {PS_SUITE}"
    ps_host = _resolve_ps_host()
    if ps_host is None:
        pytest.skip(
            "no PowerShell host on PATH (tried: %s)" % ", ".join(_PS_HOST_NAMES)
        )
    # Stream to a file rather than capture_output: on a timeout, capture_output
    # yields NOTHING at all, and a suite that can legitimately run for minutes
    # is exactly the case where partial output is what tells you where it hung.
    fd, out_path = tempfile.mkstemp(prefix="launcher_tests_", suffix=".log")
    os.close(fd)
    timed_out = False
    result = None
    with _grepai_lock, open(out_path, "w", encoding="utf-8", errors="replace") as sink:
        # Hold the shared watcher lock for the WHOLE suite run: T8 stops/starts
        # the global watchers, and that is exactly the window the other watcher
        # tests must not overlap with.
        try:
            result = subprocess.run(
                [
                    ps_host,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(PS_SUITE),
                ],
                stdout=sink,
                stderr=subprocess.STDOUT,
                text=True,
                # Raised from 120 -> 300 -> 900. Measured 160 s running this
                # module alone, but over 300 s inside a full pytest run where
                # sibling modules drive the same watchers; the ceiling has to
                # survive the loaded case, or a slow run reads as a failure.
                timeout=900,
                creationflags=0x08000000,  # CREATE_NO_WINDOW
            )
        except subprocess.TimeoutExpired:
            timed_out = True
    captured = Path(out_path).read_text(encoding="utf-8", errors="replace")
    try:
        os.unlink(out_path)
    except BaseException:
        pass  # sandbox intercepts unlink; the file is a temp leftover at worst
    print(captured)
    if timed_out:
        tail = "\n".join(captured.splitlines()[-40:])
        pytest.fail(
            "launcher_tests.ps1 exceeded the 900 s ceiling. Last output:\n" + tail
        )
    assert result.returncode == 0, (
        f"launcher_tests.ps1 failed (exit {result.returncode})\n{captured}"
    )
