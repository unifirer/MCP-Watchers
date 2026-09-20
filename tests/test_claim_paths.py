"""mcpw-gsj: the one-owner-per-file claim tool must fail loudly, never softly.

These run the CLI as a subprocess, because the thing under test is the exit
code and the message an agent actually sees -- an in-process call would not
prove that a collision reaches the shell as a failure.

No git is required: the tool is pure stdlib file I/O (deliberately, so the
declick `git` .cmd shim can never be involved). A `.git` DIRECTORY is all it
needs to locate the default store, so the fixtures just mkdir one.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "dev_tools" / "claim_paths.py"


def run(*args, cwd=None, env=None):
    environ = dict(os.environ)
    if env:
        environ.update(env)
    return subprocess.run(
        [sys.executable, str(TOOL)] + [str(a) for a in args],
        capture_output=True, text=True, cwd=str(cwd or ROOT), env=environ,
    )


@pytest.fixture
def store(tmp_path):
    """A bare claim store; coordination is namespaced by the store itself."""
    d = tmp_path / "claims"
    d.mkdir()
    return d


@pytest.fixture
def fake_repo(tmp_path):
    """A directory with a .git dir, enough for default-store discovery."""
    d = tmp_path / "repo"
    (d / ".git").mkdir(parents=True)
    return d


# --------------------------------------------------------------------------
# the happy path
# --------------------------------------------------------------------------

def test_claim_succeeds_and_is_listed(store):
    p = run("--store", store, "claim", "--owner", "mcpw-gsj", "--wave", "w1",
            "dev_tools/a.py")
    assert p.returncode == 0, p.stderr
    assert "claimed" in p.stdout

    listed = run("--store", store, "list")
    assert listed.returncode == 0
    assert "dev_tools/a.py" in listed.stdout
    assert "mcpw-gsj" in listed.stdout


def test_reclaiming_your_own_path_is_idempotent(store):
    run("--store", store, "claim", "--owner", "mcpw-gsj", "dev_tools/a.py")
    again = run("--store", store, "claim", "--owner", "mcpw-gsj", "dev_tools/a.py")
    assert again.returncode == 0, again.stderr
    assert "already yours" in again.stdout


# --------------------------------------------------------------------------
# the collision that matters
# --------------------------------------------------------------------------

def test_second_owner_fails_and_is_told_who_holds_it(store):
    run("--store", store, "claim", "--owner", "mcpw-gsj", "--wave", "w1",
        "dev_tools/a.py")

    clash = run("--store", store, "claim", "--owner", "mcpw-oft", "--wave", "w2",
                "dev_tools/a.py")
    assert clash.returncode == 1, clash.stdout
    assert "CONFLICT" in clash.stderr
    # The whole point: name the current owner, not just "locked".
    assert "mcpw-gsj" in clash.stderr
    assert "dev_tools/a.py" in clash.stderr
    assert "w1" in clash.stderr


def test_collision_is_all_or_nothing(store):
    """A half-claim is worse than none: it looks like success."""
    run("--store", store, "claim", "--owner", "mcpw-gsj", "dev_tools/taken.py")

    clash = run("--store", store, "claim", "--owner", "mcpw-oft",
                "dev_tools/taken.py", "dev_tools/fresh.py")
    assert clash.returncode == 1

    # The free path in the failed batch must NOT have been left claimed.
    check = run("--store", store, "check", "--owner", "mcpw-oft",
                "dev_tools/fresh.py")
    assert check.returncode == 0, check.stderr
    assert "[free]" in check.stdout


def test_case_and_separator_difference_cannot_bypass_the_claim(store):
    """Windows-only repo: Dev_Tools\\Foo.py and dev_tools/foo.py are one file."""
    run("--store", store, "claim", "--owner", "mcpw-gsj", "dev_tools/foo.py")

    bypass = run("--store", store, "claim", "--owner", "mcpw-oft",
                 "Dev_Tools\\Foo.py")
    assert bypass.returncode == 1, bypass.stdout
    assert "mcpw-gsj" in bypass.stderr


def test_check_reports_without_claiming(store):
    run("--store", store, "claim", "--owner", "mcpw-gsj", "held.py")
    check = run("--store", store, "check", "--owner", "mcpw-oft", "held.py", "free.py")
    assert check.returncode == 1
    assert "[free]" in check.stdout

    # `check` must not have created the free claim.
    listed = run("--store", store, "list", "--json")
    paths = {r["path"] for r in json.loads(listed.stdout)}
    assert paths == {"held.py"}


# --------------------------------------------------------------------------
# release
# --------------------------------------------------------------------------

def test_release_frees_the_path_for_another_owner(store):
    run("--store", store, "claim", "--owner", "mcpw-gsj", "a.py")
    assert run("--store", store, "release", "--owner", "mcpw-gsj", "a.py").returncode == 0
    assert run("--store", store, "claim", "--owner", "mcpw-oft", "a.py").returncode == 0


def test_release_refuses_to_steal_another_owners_claim(store):
    run("--store", store, "claim", "--owner", "mcpw-gsj", "a.py")
    denied = run("--store", store, "release", "--owner", "mcpw-oft", "a.py")
    assert denied.returncode == 1
    assert "mcpw-gsj" in denied.stderr
    # Still held.
    assert run("--store", store, "check", "--owner", "mcpw-gsj", "a.py").returncode == 0


def test_release_all_owned_by_me(store):
    run("--store", store, "claim", "--owner", "mcpw-gsj", "a.py", "b.py")
    run("--store", store, "claim", "--owner", "mcpw-oft", "c.py")
    assert run("--store", store, "release", "--owner", "mcpw-gsj").returncode == 0
    listed = run("--store", store, "list", "--json")
    assert {r["owner"] for r in json.loads(listed.stdout)} == {"mcpw-oft"}


def test_steal_overrides_an_existing_claim(store):
    run("--store", store, "claim", "--owner", "mcpw-gsj", "a.py")
    stolen = run("--store", store, "claim", "--owner", "mcpw-oft", "--steal", "a.py")
    assert stolen.returncode == 0, stolen.stderr
    listed = run("--store", store, "list", "--json")
    assert {r["owner"] for r in json.loads(listed.stdout)} == {"mcpw-oft"}


# --------------------------------------------------------------------------
# store resolution
# --------------------------------------------------------------------------

def test_default_store_lives_inside_the_git_dir(fake_repo):
    p = run("claim", "--owner", "mcpw-gsj", "dev_tools/a.py", cwd=fake_repo)
    assert p.returncode == 0, p.stderr
    # Inside .git: invisible to `git status`, cannot be committed by accident.
    assert (fake_repo / ".git" / "mcpw-claims").is_dir()


def test_env_var_selects_the_store(store):
    p = run("claim", "--owner", "mcpw-gsj", "dev_tools/a.py",
            env={"MCPW_CLAIM_STORE": str(store)})
    assert p.returncode == 0, p.stderr
    assert any(store.glob("*.json"))


def test_claim_key_does_not_depend_on_the_store_location(tmp_path, fake_repo):
    """Two stores must still key the same path identically.

    Keys are hashes of the normalized path. If normalization depended on the
    store, the same file would hash two ways and two agents would both "win".
    """
    a = tmp_path / "s1"
    b = tmp_path / "s2"
    a.mkdir()
    b.mkdir()
    assert run("--store", a, "claim", "--owner", "o1", "dev_tools/a.py",
               cwd=fake_repo).returncode == 0
    assert run("--store", b, "claim", "--owner", "o2", "dev_tools/a.py",
               cwd=fake_repo).returncode == 0
    names_a = {p.name for p in a.glob("*.json")}
    names_b = {p.name for p in b.glob("*.json")}
    assert names_a == names_b and len(names_a) == 1


def test_store_given_before_the_subcommand_is_honoured(store, fake_repo):
    """Regression: a subparser default of None silently discarded --store."""
    p = run("--store", store, "claim", "--owner", "mcpw-gsj", "dev_tools/a.py",
            cwd=fake_repo)
    assert p.returncode == 0, p.stderr
    assert any(store.glob("*.json"))
    assert not (fake_repo / ".git" / "mcpw-claims").exists()


def test_no_store_and_no_repo_is_a_usage_error(tmp_path):
    bare = tmp_path / "nowhere"
    bare.mkdir()
    p = run("claim", "--owner", "mcpw-gsj", "a.py", cwd=bare)
    assert p.returncode == 2
    assert "no claim store" in p.stderr
