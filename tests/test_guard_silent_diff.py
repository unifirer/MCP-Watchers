"""mcpw-gsj: a stray hunk must not be able to ride into an unrelated commit.

The central test is the premise itself (test_plain_git_diff_is_silent_...):
once a change is staged, plain `git diff` reports NOTHING, because it compares
the worktree to the index and they agree. Every other test pins that the guard
still sees the hunk through `git diff HEAD`, which is the only view that cannot
be blinded that way.

The fixtures are scratch repos under tmp_path (on C:, not the J: volume where
slash-named refs are silently discarded -- mcpw-sr4).
"""
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "dev_tools" / "guard_silent_diff.py"

sys.path.insert(0, str(ROOT / "dev_tools"))
import guard_silent_diff as gsd  # noqa: E402

try:
    GIT = gsd.resolve_git()
except RuntimeError:  # pragma: no cover - only on a box with no git at all
    GIT = None

pytestmark = pytest.mark.skipif(GIT is None, reason="no working git on this box")

STRAY = "line1\nSTRAY OTHER-AGENT HUNK\nline2\n"
SEED = "line1\nline2\n"


def git(repo, *args):
    return subprocess.run([GIT, "-C", str(repo)] + list(args),
                          capture_output=True, text=True, errors="replace")


def guard(*args):
    return subprocess.run([sys.executable, str(TOOL)] + [str(a) for a in args],
                          capture_output=True, text=True, errors="replace")


@pytest.fixture
def repo(tmp_path):
    d = tmp_path / "r"
    d.mkdir()
    git(d, "init", "-q")
    git(d, "config", "user.email", "guard@example.invalid")
    git(d, "config", "user.name", "mcpw-gsj guard")
    # The attribute that makes every tracked file a diff-silent candidate.
    (d / ".gitattributes").write_text("* -text\n", encoding="utf-8")
    (d / "launcher.ps1").write_text(SEED, encoding="utf-8")
    (d / "mine.py").write_text("seed\n", encoding="utf-8")
    (d / ".repowise").mkdir()
    (d / ".repowise" / "cache.pkl").write_text("churn\n", encoding="utf-8")
    git(d, "add", "-A")
    git(d, "commit", "-qm", "seed")
    return d


def stage_stray_hunk(repo):
    """Another agent's in-flight edit, already in the index."""
    (repo / "launcher.ps1").write_text(STRAY, encoding="utf-8")
    assert git(repo, "add", "launcher.ps1").returncode == 0


# --------------------------------------------------------------------------
# the premise
# --------------------------------------------------------------------------

def test_plain_git_diff_is_silent_once_the_hunk_is_staged(repo):
    stage_stray_hunk(repo)
    plain = git(repo, "diff", "--stat")
    assert plain.stdout.strip() == "", (
        "premise changed: plain `git diff` now shows a staged hunk, so the "
        "guard's rationale needs revisiting"
    )
    assert "launcher.ps1" in git(repo, "diff", "--cached", "--stat").stdout


def test_guard_still_sees_the_hunk_through_diff_head(repo):
    stage_stray_hunk(repo)
    names = git(repo, "diff", "HEAD", "--name-only")
    assert "launcher.ps1" in names.stdout


# --------------------------------------------------------------------------
# scan
# --------------------------------------------------------------------------

def test_scan_flags_the_hunk_that_plain_git_diff_hides(repo):
    stage_stray_hunk(repo)
    p = guard("--repo", repo, "scan")
    assert p.returncode == 1, p.stdout
    assert "launcher.ps1" in p.stdout
    assert "hidden by : git diff (staged only)" in p.stdout


def test_scan_names_the_other_blind_spot_for_an_unstaged_change(repo):
    (repo / "launcher.ps1").write_text(STRAY, encoding="utf-8")
    p = guard("--repo", repo, "scan")
    assert p.returncode == 1, p.stdout
    assert "hidden by : git diff --cached (unstaged only)" in p.stdout


def test_scan_reports_the_text_attribute(repo):
    stage_stray_hunk(repo)
    p = guard("--repo", repo, "scan")
    assert "unset" in p.stdout
    assert "-text" in p.stdout


def test_scan_is_clean_on_an_untouched_repo(repo):
    p = guard("--repo", repo, "scan")
    assert p.returncode == 0, p.stdout
    assert "clean" in p.stdout.lower()


# --------------------------------------------------------------------------
# verify -- the actual gate
# --------------------------------------------------------------------------

def test_verify_fails_loudly_and_names_the_offender(repo):
    stage_stray_hunk(repo)
    p = guard("--repo", repo, "verify", "--expect", "mine.py")
    assert p.returncode == 1
    assert "RIDE-ALONG RISK" in p.stderr
    assert "launcher.ps1" in p.stderr
    assert "mine.py" not in p.stderr


def test_verify_passes_when_the_offender_is_expected(repo):
    stage_stray_hunk(repo)
    p = guard("--repo", repo, "verify", "--expect", "mine.py", "launcher.ps1")
    assert p.returncode == 0, p.stderr


def test_verify_passes_on_a_clean_tree(repo):
    p = guard("--repo", repo, "verify", "--expect", "mine.py")
    assert p.returncode == 0, p.stderr
    assert "SAFE" in p.stdout


def test_verify_accepts_an_absolute_expected_path(repo):
    stage_stray_hunk(repo)
    p = guard("--repo", repo, "verify", "--expect", str(repo / "mine.py"),
              str(repo / "launcher.ps1"))
    assert p.returncode == 0, p.stderr


def test_verify_accepts_repeated_expect_flags(repo):
    stage_stray_hunk(repo)
    p = guard("--repo", repo, "verify", "--expect", "mine.py",
              "--expect", "launcher.ps1")
    assert p.returncode == 0, p.stderr


def test_verify_uses_a_substring_safe_exact_path_match(repo):
    """`mine.py` must not accidentally cover `not_mine.py`."""
    (repo / "not_mine.py").write_text("x\n", encoding="utf-8")
    git(repo, "add", "not_mine.py")
    p = guard("--repo", repo, "verify", "--expect", "mine.py")
    assert p.returncode == 1
    assert "not_mine.py" in p.stderr


# --------------------------------------------------------------------------
# allowlist
# --------------------------------------------------------------------------

def test_machine_churn_is_allowlisted_but_source_is_not(repo):
    (repo / ".repowise" / "cache.pkl").write_text("churn v2\n", encoding="utf-8")
    git(repo, "add", ".repowise/cache.pkl")

    allowed = guard("--repo", repo, "verify", "--expect", "mine.py")
    assert allowed.returncode == 0, allowed.stderr

    strict = guard("--repo", repo, "verify", "--expect", "mine.py",
                   "--no-default-allow")
    assert strict.returncode == 1
    assert ".repowise/cache.pkl" in strict.stderr


def test_extra_allow_glob_widens_the_gate(repo):
    (repo / "launcher.ps1").write_text(STRAY, encoding="utf-8")
    p = guard("--repo", repo, "verify", "--expect", "mine.py",
              "--allow", "*.ps1")
    assert p.returncode == 0, p.stderr
