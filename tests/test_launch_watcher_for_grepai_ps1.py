# Pytest wrapper (issue vad-79v): wires the PowerShell suite
# tests/launch_watcher_for_grepai.tests.ps1 into python run_tests_isolated.py,
# whose discovery globs only tests/test_*.py. Runs pwsh -NoProfile non-
# interactively; the ps1 suite exits 0 on all-pass and non-zero on any failure.
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PS1_TEST = REPO_ROOT / "tests" / "launch_watcher_for_grepai.tests.ps1"


def test_launch_watcher_for_grepai_ps1_suite():
    assert PS1_TEST.exists(), f"missing ps1 test suite: {PS1_TEST}"
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(PS1_TEST)],
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
