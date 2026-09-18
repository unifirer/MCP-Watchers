"""Regression tripwire for mcpw-sr4: slash-named branches must produce a real ref.

On 2026-09-18 `git branch fix-tests/<ts>` returned exit 0 in this repository
while writing NO ref: `.git/logs/refs/heads/fix-tests/` was created with correct
reflog entries, but `.git/refs/heads/fix-tests/` and the ref file never appeared.
`git show-ref` and `git branch` then agreed the branch did not exist, and the
same name silently failed again through `git worktree add -b` and `git switch -c`
inside a linked worktree (which produced a rootless branch: "No commits yet").

CAVEAT, added 2026-09-18 22:12 -- the defect is VOLUME-SPECIFIC, not gone. The
tests below build their scratch repo with tempfile.mkdtemp(), which is %TEMP%
and therefore C:. Re-measured with the same git build (2.55.0.windows.3):
a fresh repo on C: writes slash-named refs correctly; a fresh repo on J: does
not -- not at drive root, not nested. So these tests only ever probe C: and
cannot fail on the J: case. `test_branch_with_slash_..._on_the_repo_volume`
below closes that hole by putting the scratch repo on the repo's own volume;
it is marked xfail(strict=True) because the J: defect is live, so it fails as
recorded and turns into a loud failure the day someone actually fixes it.

This module is the tripwire: if the condition returns, these tests fail loudly
instead of the branch silently vanishing again. It exercises all three forms the
bead recorded, in a throwaway repository, and never touches the repository
under test.
"""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

PREFIX = "fix-tests"


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=str(repo),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def _new_repo(tmp: Path, name: str) -> Path:
    repo = tmp / name
    repo.mkdir(parents=True)
    _git(repo, "init", "-q", ".")
    _git(repo, "config", "user.email", "tripwire@example.invalid")
    _git(repo, "config", "user.name", "mcpw-sr4 tripwire")
    (repo / "seed.txt").write_text("seed\n", encoding="utf-8")
    _git(repo, "add", "seed.txt")
    _git(repo, "commit", "-qm", "seed")
    return repo


def _refs(repo: Path) -> str:
    return _git(repo, "show-ref").stdout


def test_branch_with_slash_writes_a_real_ref():
    tmp = Path(tempfile.mkdtemp(prefix="mcpw-sr4-"))
    try:
        repo = _new_repo(tmp, "repo")
        name = f"{PREFIX}/branch-form"
        created = _git(repo, "branch", name)
        assert created.returncode == 0, f"git branch {name} failed: {created.stderr}"

        listed = _git(repo, "branch", "--list", name).stdout.strip()
        assert listed, f"git branch --list shows nothing for {name}"

        assert f"refs/heads/{name}" in _refs(repo), (
            f"mcpw-sr4 REGRESSION: `git branch {name}` returned exit 0 but no ref "
            "was written. show-ref output:\n" + _refs(repo)
        )

        ref_file = repo / ".git" / "refs" / "heads" / PREFIX / "branch-form"
        assert ref_file.exists(), (
            f"mcpw-sr4 REGRESSION: nested ref file {ref_file} was never created "
            "(the reflog directory can exist while the ref write is lost)."
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _repo_volume_tmp() -> Path:
    """Scratch directory on the SAME volume as this repository.

    tempfile.mkdtemp() lands in %TEMP% (C: here). mcpw-sr4 is volume-specific:
    C: is fine, J: silently drops the ref with the same git build. Put the
    probe under the repo's own (gitignored) temp/ so it runs where it matters.
    """
    root = Path(__file__).resolve().parents[1] / "temp"
    root.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="mcpw-sr4-vol-", dir=str(root)))


@pytest.mark.xfail(
    reason="mcpw-sr4: slash-named branches are silently discarded on the J: volume",
    strict=True,
)
def test_branch_with_slash_writes_a_real_ref_on_the_repo_volume():
    tmp = _repo_volume_tmp()
    try:
        repo = _new_repo(tmp, "repo")
        name = f"{PREFIX}/volume-form"
        created = _git(repo, "branch", name)
        assert created.returncode == 0, f"git branch {name} failed: {created.stderr}"
        assert f"refs/heads/{name}" in _refs(repo), (
            f"mcpw-sr4 REGRESSION on the repo's own volume: `git branch {name}` "
            f"returned exit 0 but no ref was written (scratch repo: {repo}). "
            "show-ref output:\n" + _refs(repo)
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_worktree_add_with_slash_branch_writes_a_real_ref():
    tmp = Path(tempfile.mkdtemp(prefix="mcpw-sr4-"))
    try:
        repo = _new_repo(tmp, "repo")
        name = f"{PREFIX}/worktree-form"
        added = _git(repo, "worktree", "add", "-b", name, str(tmp / "wt"))
        assert added.returncode == 0, f"git worktree add -b {name} failed: {added.stderr}"
        assert f"refs/heads/{name}" in _refs(repo), (
            f"mcpw-sr4 REGRESSION: `git worktree add -b {name}` reported success but "
            "no ref was written. show-ref output:\n" + _refs(repo)
        )
    finally:
        # Drop the worktree registration before deleting its directory, or the
        # main repo keeps a stale administrative entry pointing at a dead path.
        _git(tmp / "repo", "worktree", "remove", "--force", str(tmp / "wt"))
        shutil.rmtree(tmp, ignore_errors=True)


def test_switch_c_in_a_detached_worktree_is_not_rootless():
    tmp = Path(tempfile.mkdtemp(prefix="mcpw-sr4-"))
    try:
        repo = _new_repo(tmp, "repo")
        wt = tmp / "wt"
        assert _git(repo, "worktree", "add", "--detach", str(wt)).returncode == 0

        name = f"{PREFIX}/switch-form"
        switched = _git(wt, "switch", "-c", name)
        assert switched.returncode == 0, f"git switch -c {name} failed: {switched.stderr}"

        assert f"refs/heads/{name}" in _refs(wt), (
            f"mcpw-sr4 REGRESSION: `git switch -c {name}` reported success but no ref "
            "was written. show-ref output:\n" + _refs(wt)
        )

        # A rootless branch (the bead's third symptom) reports no commits and
        # stages the whole tree as new. It was created from a real commit, so it
        # must still see that commit as an ancestor.
        head = _git(wt, "rev-parse", "HEAD").stdout.strip()
        assert head, "HEAD is unresolvable after switch -c: branch is rootless."
        assert _git(wt, "cat-file", "-e", f"{head}^{{commit}}").returncode == 0, (
            "mcpw-sr4 REGRESSION: HEAD does not resolve to a real commit; the branch "
            "created by switch -c is rootless (bead symptom 3)."
        )
    finally:
        _git(tmp / "repo", "worktree", "remove", "--force", str(tmp / "wt"))
        shutil.rmtree(tmp, ignore_errors=True)


def test_environment_is_writable_for_nested_refs():
    """Guard the fixture itself: a read-only or full disk fakes a sr4 failure."""
    tmp = Path(tempfile.mkdtemp(prefix="mcpw-sr4-"))
    try:
        nested = tmp / PREFIX
        nested.mkdir()
        (nested / "ref").write_text("0" * 40 + "\n", encoding="utf-8")
        assert (nested / "ref").exists()
        assert os.access(str(nested), os.W_OK)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
