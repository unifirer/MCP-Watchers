"""Regression tripwire for mcpw-sr4: slash-named branches must produce a real ref.

On 2026-09-18 `git branch fix-tests/<ts>` returned exit 0 in this repository
while writing NO ref: `.git/logs/refs/heads/fix-tests/` was created with correct
reflog entries, but `.git/refs/heads/fix-tests/` and the ref file never appeared.
`git show-ref` and `git branch` then agreed the branch did not exist, and the
same name silently failed again through `git worktree add -b` and `git switch -c`
inside a linked worktree (which produced a rootless branch: "No commits yet").

CORRECTION, 2026-09-19 -- the "VOLUME-SPECIFIC" claim below was WRONG. It was
inferred from a scratch repo built with tempfile.mkdtemp() (%TEMP%, C:) versus
one on J:, but the real variable is the INVOKING ENVIRONMENT, not the volume.
Measured 2026-09-19 on J:, identical directory, same nominal version
(2.55.0.windows.3), scratch repos created the same way:

  * git spawned by Python subprocess (PortableGit 1.2.0) -- 13/13 refs written
  * `git` as Git Bash resolves it (/mingw64/bin/git)   --  0/7 refs written
  * explicit C:\\Program Files\\Git\\mingw64\\bin\\git.exe --  2/2 refs written
  * explicit PortableGit 1.2.0 git.exe                 --  0/2 refs written

So the same binary both writes and drops depending on how it is reached, and
the drop is NOT tied to J: -- C: scratch repos only ever looked clean because
they were always driven from Python. Root cause is still unidentified; this is
an observation, not an explanation.

`test_branch_with_slash_..._on_the_repo_volume` below keeps probing the repo's
own volume, but is marked xfail(strict=False): with strict=True an ordinary
passing run is reported as a failure, which is what happened on 2026-09-19.
Non-strict keeps the case visible in the summary as XFAIL or XPASS without
turning the suite red while the cause is unknown.

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
    reason="mcpw-sr4: slash-named branches are silently dropped by some git "
    "invocations; see the module docstring for the 2026-09-19 measurements",
    strict=False,
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
