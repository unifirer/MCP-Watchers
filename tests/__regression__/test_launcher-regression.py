"""
Regression test for test_launcher.py fix.

Verifies that the PowerShell launcher test suite correctly handles
environments where not all watcher binaries are on PATH.

Behavioral seam: uses Path(__file__) to locate launcher_tests.ps1
relative to this test file, not CWD-relative open. This makes the
test robust to running from any directory.
"""
from pathlib import Path

LAUNCHER_TESTS_PS1 = Path(__file__).resolve().parent.parent / "launcher_tests.ps1"


def test_launcher_ps1_has_expected_tailer_count():
    """Verify launcher_tests.ps1 computes expectedTailerCount dynamically
    instead of hardcoding 4."""
    content = LAUNCHER_TESTS_PS1.read_text(encoding="utf-8-sig")

    # The fix: expectedTailerCount is computed from available binaries
    assert '$expectedTailerCount = 0' in content, (
        "launcher_tests.ps1 should compute expectedTailerCount"
    )
    assert '$expectedTailerCount++' in content, (
        "launcher_tests.ps1 should increment expectedTailerCount for available binaries"
    )

    # The fix: polling loop uses expectedTailerCount, not hardcoded 4
    assert '$liveLabels.Count -eq $expectedTailerCount' in content, (
        "Polling loop should break when available tailers are live"
    )

    # The old hardcoded assertion should be gone
    assert '$liveLabels.Count -eq 4' not in content, (
        "Hardcoded '4' should be replaced with dynamic count"
    )


def test_launcher_ps1_honors_available_watchers():
    """Verify the final T8 assertion enforces per-watcher tailer liveness
    rather than requiring all configured watchers."""
    content = LAUNCHER_TESTS_PS1.read_text(encoding="utf-8-sig")

    # The final assertion should check that no available watcher lacks a live
    # tailer, instead of comparing counts against all configured watchers.
    assert '$missingLive.Count -eq 0' in content, (
        "Final assertion should enforce per-watcher tailer liveness via $missingLive"
    )
