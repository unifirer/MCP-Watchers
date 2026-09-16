"""
Launcher test shim.

The VAD watcher launcher (###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1)
is a PowerShell script, not Python, so its real test suite is
tests/launcher_tests.ps1 (run via the PowerShell interpreter). This shim
lets pytest discover and gate that suite without collecting the repo's large
Python test tree (per AGENTS.md, running the full pytest collection here exhausts
the paging file). It executes the actual PS suite and asserts it passes.

Run: pytest tests/test_launcher.py -v
"""

import subprocess
import sys
from pathlib import Path

import pytest
from filelock import FileLock

REPO_ROOT = Path(__file__).resolve().parent.parent
PS_SUITE = REPO_ROOT / "tests" / "launcher_tests.ps1"

# The PS suite's T8 block starts and stops the SHARED global watchers (grepai,
# graphenium, repowise, graphify-rs). test_launch_watcher.py drives the same
# grepai watcher and already serialises on this cross-process lock. Without
# taking it here too, T8's auto-start/stop races it: one test sees "no background
# watcher is running" while the other sees "watcher is already running" in the
# SAME suite run.
_GREPAI_LOCK_PATH = Path(__file__).resolve().parent / ".grepai_watcher_tests.lock"
# Clear any stale lock left by an orphaned watcher test process from a prior
# run: the cross-process FileLock has no owner PID to check, so a dead holder
# would block acquisition and burn the entire subprocess timeout (the PS suite
# can exceed 120s under watcher contention). Removing a stale file is safe --
# no live holder exists, so the lock file is just a leftover socket on disk.
if _GREPAI_LOCK_PATH.exists():
    try:
        _GREPAI_LOCK_PATH.unlink()
    except OSError:
        pass  # held open by a live process -- leave it, FileLock will wait
_grepai_lock = FileLock(str(_GREPAI_LOCK_PATH), timeout=600)


@pytest.mark.skipif(
    sys.platform != "win32",
    reason="Launcher + Windows Terminal are Windows-only",
)
def test_launcher_powershell_suite_passes():
    assert PS_SUITE.exists(), f"PS suite missing: {PS_SUITE}"
    # Hold the shared watcher lock for the WHOLE suite run: T8 stops/starts the
    # global watchers, and that is exactly the window the other watcher tests
    # must not overlap with.
    with _grepai_lock:
        result = subprocess.run(
            [
                "powershell",
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
