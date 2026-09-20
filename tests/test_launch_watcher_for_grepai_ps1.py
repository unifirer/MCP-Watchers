# Pytest wrapper (issue vad-79v): wires the PowerShell suite
# tests/launch_watcher_for_grepai.tests.ps1 into python run_tests_isolated.py,
# whose discovery globs only tests/test_*.py. Runs the PowerShell host
# -NoProfile non-interactively; the ps1 suite exits 0 on all-pass and non-zero
# on any failure.
#
# Environment rules (bead mcpw-tao -- do not re-diagnose these as code bugs):
#   * The suite targets ###2.launch_watcher_for_grepai.ps1. Tier B was ported
#     from VAD on 2026-09-20, so this checkout ships it and the suite runs
#     (19 passed, 0 failed). The guard stays: a checkout that does not ship the
#     script must still SKIP, because the harness then has nothing to exercise.
#   * The host is resolved from PATH, pwsh first. When no host is resolvable
#     the test SKIPS rather than failing.
# See docs/guides/pytest-environment.md.
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PS1_TEST = REPO_ROOT / "tests" / "launch_watcher_for_grepai.tests.ps1"
# The script the suite exercises. It sits beside the launcher under test; a
# checkout that does not ship it cannot run this suite at all.
PS1_TARGET = REPO_ROOT / "###2.launch_watcher_for_grepai.ps1"

# pwsh (7.x) first: the suite is written for PowerShell 7. Windows PowerShell
# 5.1 is only a fallback.
_PS_HOST_NAMES = ("pwsh", "powershell")


def _resolve_ps_host():
    """Return the first PowerShell host on PATH, or None when none exists."""
    for name in _PS_HOST_NAMES:
        found = shutil.which(name)
        if found:
            return found
    return None


def test_launch_watcher_for_grepai_ps1_suite():
    assert PS1_TEST.exists(), f"missing ps1 test suite: {PS1_TEST}"
    if not PS1_TARGET.exists():
        pytest.skip(
            "launcher under test is not shipped by this checkout: "
            f"{PS1_TARGET}"
        )
    ps_host = _resolve_ps_host()
    if ps_host is None:
        pytest.skip(
            "no PowerShell host on PATH (tried: %s)" % ", ".join(_PS_HOST_NAMES)
        )
    result = subprocess.run(
        [ps_host, "-NoProfile", "-NonInteractive", "-File", str(PS1_TEST)],
        capture_output=True,
        text=True,
        timeout=300,
        cwd=str(REPO_ROOT),
    )
    assert result.returncode == 0, (
        "PowerShell launch_watcher_for_grepai suite failed "
        f"(exit {result.returncode}):\n{result.stdout}\n{result.stderr}"
    )
    # Guard against a vacuous pass: the suite prints its own tally.
    assert "passed, 0 failed" in result.stdout, (
        f"suite did not report a clean tally:\n{result.stdout}"
    )
