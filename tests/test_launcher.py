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

See docs/guides/pytest-environment.md for the full write-up.
"""

import shutil
import subprocess
import sys
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
    # Hold the shared watcher lock for the WHOLE suite run: T8 stops/starts the
    # global watchers, and that is exactly the window the other watcher tests
    # must not overlap with.
    with _grepai_lock:
        result = subprocess.run(
            [
                ps_host,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(PS_SUITE),
            ],
            capture_output=True,
            text=True,
            timeout=300,  # widened from 120: launcher_tests.ps1 exceeds 120s under watcher contention
            creationflags=0x08000000,  # CREATE_NO_WINDOW
        )
    print(result.stdout)
    if result.stderr.strip():
        print("STDERR:", result.stderr, file=sys.stderr)
    assert result.returncode == 0, (
        f"launcher_tests.ps1 failed (exit {result.returncode})\n"
        f"{result.stdout}\n{result.stderr}"
    )
