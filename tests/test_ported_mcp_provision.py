"""Acceptance suite for the ported provision layer - beads mcpw-xeu.3 + mcpw-xeu.6.

Imports the REAL Modules/watcher_mcp_provision.py (never source-text
extraction). The PowerShell original stays live; this suite pins the port's
plan, argv, stamp, gate and atlas-file behaviour against the .ps1's, and
proves the detect/provision pairing end to end with a fake tool that really
provisions (exit 0 alone never stamps - mcpw-0zo.1).

Clean-room by construction: every test runs against synthetic layouts in a
temp dir, never a real repository's tool state.
"""
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Modules import watcher_mcp_provision as prov  # noqa: E402
from Modules import watcher_mcp_detect as detect  # noqa: E402

PROVISION_PS1 = ROOT / "Modules" / "watcher_mcp_provision.ps1"


@pytest.fixture
def no_tools(monkeypatch):
    monkeypatch.setattr(detect, "resolve_mcp_detect_tool", lambda name: None)
    monkeypatch.setattr(prov._detect, "resolve_mcp_detect_tool",
                        lambda name: None)


# ---------------------------------------------------------------------------
# plan + argv (pure, no tools needed)
# ---------------------------------------------------------------------------

def test_plan_is_seven_steps_cheap_first():
    plan = prov.get_mcp_provision_plan()
    assert [s["mcp"] for s in plan] == ["atlas", "graphenium", "repowise",
                                        "graphify-rs", "graft", "memtrace",
                                        "grepai"]
    rank = {"config": 1, "build": 2, "index": 3}
    ranks = [rank[s["phase"]] for s in plan]
    assert ranks == sorted(ranks), "no expensive index step before a cheap config step"
    assert [s["mcp"] for s in plan if s["optional"]] == ["graphify-rs"]
    assert [s["mcp"] for s in plan if s["file_only"]] == ["atlas"]


def test_argv_carries_non_interactive_flags():
    root = r"C:\synthetic\repo"
    assert prov.get_mcp_provision_argv("atlas", root) == []
    memtrace = prov.get_mcp_provision_argv("memtrace", root)
    assert "index" in memtrace and "--allow-non-git" in memtrace
    assert "start" not in memtrace and "mcp" not in [a.lower() for a in memtrace][0:1]
    scan = prov.get_mcp_provision_argv("grepai", root)
    assert "watch" in scan and "--no-ui" in scan
    assert "--no-ui" in prov.get_mcp_provision_argv("grepai", root, "status")
    assert "--yes" in prov.get_mcp_provision_argv("grepai", root, "config")
    assert "init" in prov.get_mcp_provision_argv("graphenium", root)
    graphify = prov.get_mcp_provision_argv("graphify-rs", root)
    assert "build" in graphify and "--no-llm" in graphify
    repowise = prov.get_mcp_provision_argv("repowise", root)
    for needle in ("agents", "add", "--target", "claude-code", "--yes"):
        assert needle in repowise
    assert "init" not in repowise  # init regenerates the wiki; never here
    graft = prov.get_mcp_provision_argv("graft", root)
    assert "build" in graft and "--deep" not in graft


def test_arg_line_quotes_only_what_needs_it():
    assert prov.provision_arg_line(["build", r"C:\my repo\x"]) == 'build "C:\\my repo\\x"'
    assert prov.provision_arg_line(["a", ""]) == 'a ""'
    assert prov.provision_arg_line([]) == ""


def test_failure_reason_is_one_truncated_line():
    launched = prov.ProvisionResult()
    assert "no result" in prov.get_mcp_provision_failure_reason(None, 1, "gm init")
    dead = prov.ProvisionResult()
    dead.error = "missing"
    assert "could not be launched" in prov.get_mcp_provision_failure_reason(dead, 1, "gm init")
    timed = prov.ProvisionResult()
    timed.launched = True
    timed.timed_out = True
    assert "timed out after 5ms" in prov.get_mcp_provision_failure_reason(timed, 5, "gm init")
    failed = prov.ProvisionResult()
    failed.launched = True
    failed.exit_code = 3
    failed.error = "\n\nboom\n" + "x" * 500
    reason = prov.get_mcp_provision_failure_reason(failed, 1, "gm init")
    assert reason.startswith("gm init exited 3: boom")
    assert len(reason) <= len("gm init exited 3: ") + 200


# ---------------------------------------------------------------------------
# stamps
# ---------------------------------------------------------------------------

def test_stamp_round_trip_and_shape(tmp_path):
    root = str(tmp_path)
    state = str(tmp_path / "state")
    assert prov.test_mcp_provision_stamp(root, "graft", state) is False
    assert prov.set_mcp_provision_stamp(root, "graft", "built", "graft.exe",
                                        state) is True
    assert prov.test_mcp_provision_stamp(root, "graft", state) is True
    doc = json.loads((Path(state) / "state.json").read_text(encoding="utf-8"))
    assert set(doc["graft"]) == {"At", "Tool", "Detail", "Head"}
    assert doc["graft"]["Tool"] == "graft.exe"


def test_corrupt_stamp_reads_empty_never_throws(tmp_path):
    state = str(tmp_path / "state")
    os.makedirs(state, exist_ok=True)
    (Path(state) / "state.json").write_text("{truncated", encoding="utf-8")
    assert prov.read_mcp_provision_state(state) == {}
    assert prov.test_mcp_provision_stamp(str(tmp_path), "graft", state) is False


def test_explicit_tool_path_missing_is_skip_not_path_fallback(tmp_path):
    assert prov.resolve_mcp_provision_tool("graft", r"C:\no\such\tool.exe") == ""


def test_state_dir_defaults_under_repo_and_env_override(tmp_path, monkeypatch):
    root = str(tmp_path)
    assert prov.get_mcp_provision_state_dir(root) == os.path.join(root, ".mcpw-provision")
    assert prov.get_mcp_provision_state_dir(root, state_dir=r"C:\s\\") == r"C:\s"
    monkeypatch.setenv("MCPW_PROVISION_STATE_DIR", str(tmp_path / "env-state"))
    assert prov.get_mcp_provision_state_dir(root) == str(tmp_path / "env-state")


# ---------------------------------------------------------------------------
# already-reason + post-gate (the detect/provision pairing, mcpw-0zo.1/.5)
# ---------------------------------------------------------------------------

def test_exit_zero_without_artifact_does_not_stamp(tmp_path, monkeypatch):
    # A fake that exits 0 and produces nothing is a fake of a FAILED step:
    # the post-gate refuses the stamp.
    root = str(tmp_path)
    monkeypatch.setattr(detect, "resolve_mcp_detect_tool",
                        lambda name: r"C:\fake\tool.exe")
    gate = prov.get_mcp_provision_post_command_gate("graft", root, "graft build")
    assert gate["ok"] is False
    assert "graft build exited 0 but the probe still reports" in gate["reason"]


def test_stale_stamp_reruns_instead_of_authorizing_skip(tmp_path, monkeypatch):
    # Stamp present, artifact deleted -> already-reason says not-initialized
    # (answered), so the stamp is stale and must NOT authorize a skip.
    root = str(tmp_path)
    state = str(tmp_path / "state")
    monkeypatch.setattr(detect, "resolve_mcp_detect_tool",
                        lambda name: r"C:\fake\tool.exe")
    assert prov.set_mcp_provision_stamp(root, "graft", "built", "", state)
    verdict = prov.get_mcp_provision_already_reason("graft", root)
    assert verdict == {"ok": False, "answered": True,
                       "reason": verdict["reason"]}
    assert "graph missing" in verdict["reason"]


def test_unanswerable_probe_holds_the_stamp(tmp_path, monkeypatch):
    # Silence is not evidence: an unknown MCP keeps answered=False.
    verdict = prov.get_mcp_provision_already_reason("no-such-mcp", str(tmp_path))
    assert verdict["answered"] is False and verdict["ok"] is False


# ---------------------------------------------------------------------------
# fake-tool end to end: graft provisions for real, stamps, then re-stamps
# ---------------------------------------------------------------------------

def _write_fake_graft(fake_dir):
    # A fake that PROVISIONS: creates exactly the artifacts the graft probe
    # looks for, in the child's cwd (the repo root).
    shim = Path(fake_dir) / "fake-graft.cmd"
    shim.write_text(
        "@echo off\r\n"
        "mkdir graft\\.graph 2>nul\r\n"
        "echo {\"wiring\":[]} > graft\\.graph\\wiring.json\r\n"
        "echo # graft index > graft\\INDEX.md\r\n"
        "exit /b 0\r\n", encoding="utf-8")
    return str(shim)


def test_fake_graft_provisions_stamps_and_idempotently_restamps(tmp_path,
                                                                monkeypatch):
    root = str(tmp_path)
    state = str(tmp_path / "state")
    fake_dir = str(tmp_path / "fakebin")
    os.makedirs(fake_dir, exist_ok=True)
    shim = _write_fake_graft(fake_dir)
    monkeypatch.setattr(detect, "resolve_mcp_detect_tool",
                        lambda name: r"C:\fake\tool.exe")
    first = prov.initialize_graft_for_repo(root, state_dir=state,
                                           tool_path=shim, timeout_ms=60000)
    assert first["status"] == "done", first
    assert prov.test_mcp_provision_stamp(root, "graft", state) is True
    second = prov.initialize_graft_for_repo(root, state_dir=state,
                                            tool_path=shim, timeout_ms=60000)
    assert second["status"] == "stamped", second
    assert "probe agrees" in second["reason"]


# ---------------------------------------------------------------------------
# atlas file step (FileOnly: no tool needed, real file write)
# ---------------------------------------------------------------------------

def test_atlas_defaults_come_from_the_compose_example():
    defaults = prov.get_atlas_env_defaults()
    assert defaults["ok"] is True, defaults["reason"]
    assert defaults["values"] == {"NEO4J_URI": "bolt://localhost:7687",
                                  "NEO4J_USER": "neo4j",
                                  "NEO4J_PASSWORD": "password2"}


def test_atlas_writes_env_idempotently_and_never_commits(tmp_path):
    root = str(tmp_path)
    state = str(tmp_path / "state")
    first = prov.initialize_atlas_for_repo(root, state_dir=state)
    assert first["status"] == "done", first
    body = (Path(root) / ".env").read_text(encoding="utf-8")
    assert "NEO4J_URI=bolt://localhost:7687" in body
    assert "NEO4J_PASSWORD=password2" in body
    assert "cannot\nisolate one repository" in body.replace(" \n", "\n") or \
        "cannot" in body  # shared-graph warning is in the file
    second = prov.initialize_atlas_for_repo(root, state_dir=state)
    assert second["status"] == "stamped", second
    assert "probe agrees" in second["reason"]


def test_report_only_plans_without_writing(tmp_path, no_tools):
    root = str(tmp_path)
    summary = prov.invoke_provision_for_repo(root, report_only=True)
    by_mcp = {r["mcp"]: r["status"] for r in summary["results"]}
    assert summary["total"] == 7
    assert by_mcp["atlas"] == "planned"  # FileOnly: no tool needed
    assert by_mcp["graphify-rs"] == "skipped"  # optional, no toml
    assert by_mcp["memtrace"] == "skipped"  # no runnable tool
    assert not os.path.exists(os.path.join(root, ".mcpw-provision"))
    assert not os.path.exists(os.path.join(root, ".env"))


def test_aggregate_never_throws_and_counts(tmp_path, no_tools):
    root = str(tmp_path)
    summary = prov.invoke_provision_for_repo(root)
    assert summary["total"] == 7
    assert summary["done"] + summary["stamped"] + summary["planned"] + \
        summary["skipped"] == 7
    assert {r["mcp"] for r in summary["results"]} == {
        "atlas", "graphenium", "repowise", "graphify-rs", "graft",
        "memtrace", "grepai"}


def test_powershell_original_is_still_present():
    assert PROVISION_PS1.is_file(), "watcher_mcp_provision.ps1 disappeared"
