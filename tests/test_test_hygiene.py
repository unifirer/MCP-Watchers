"""
Gate for test-directory hygiene.

Two rules, enforced by dev_tools/check_test_hygiene.py and written up in
docs/guides/test-conventions.md:

  1. Every test file under tests/ must be TRACKED by git. A test that is not in
     the index cannot fail for anyone, so the defect it describes can be "fixed"
     without the suite ever noticing.
  2. A test that encodes known-bad behaviour -- a characterization test -- must
     carry the marker that check_test_hygiene.py looks for, so that landing the
     real fix reads as "invert this assertion" rather than "an unrelated test
     broke".

This wrapper exists so the guard runs inside the committed pytest suite. The
bead that motivated it (mcpw-efu) was about a test that was invisible to exactly
that suite, so a guard nobody runs would miss the point.

The detector's own self-test lives in the tool, not here: its sample strings
contain the phrases the scanner matches on, so a copy under tests/ would make
the tool report this file. See check_test_hygiene.py::self_test.

Run: pytest tests/test_test_hygiene.py -v
"""

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL = REPO_ROOT / "dev_tools" / "check_test_hygiene.py"


def _run_tool(*args):
    """Run the guard with the interpreter running pytest (never a bare `python`)."""
    return subprocess.run(
        [sys.executable, str(TOOL), *args],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        errors="replace",
        timeout=120,
    )


def test_no_test_file_is_untracked_or_pins_a_bug_unmarked():
    r = _run_tool()
    print(r.stdout)
    assert r.returncode == 0, (
        "test hygiene violations (%d):\n%s%s" % (r.returncode, r.stdout, r.stderr)
    )


def test_the_guard_detects_both_bad_shapes():
    r = _run_tool("--self-test")
    print(r.stdout)
    assert r.returncode == 0, "guard self-test failed:\n%s%s" % (r.stdout, r.stderr)
