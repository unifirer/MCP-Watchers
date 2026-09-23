"""Acceptance suite for the ported detect layer - beads mcpw-xeu.3 + mcpw-xeu.6.

Imports the REAL Modules/watcher_mcp_detect.py (never source-text
extraction: that technique breaks silently when an anchor drifts - mcpw-d76).
The PowerShell original stays live; this suite pins the port against the
same vectors and reason vocabulary the .ps1 Pester suite asserts on, so the
two cannot drift.

Determinism: most tests monkeypatch watcher_mcp_detect.resolve_mcp_detect_tool
to a dummy path, testing the real probe logic below the binary gate whatever
this box has installed. The binary-gate itself is tested separately with an
empty PATH.
"""
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Modules import watcher_mcp_detect as detect  # noqa: E402

DETECT_PS1 = ROOT / "Modules" / "watcher_mcp_detect.ps1"

FAKE_TOOL = r"C:\fake\tool.exe"


@pytest.fixture
def tool_present(monkeypatch):
    monkeypatch.setattr(detect, "resolve_mcp_detect_tool",
                        lambda name: FAKE_TOOL)


@pytest.fixture
def no_tools(monkeypatch):
    monkeypatch.setattr(detect, "resolve_mcp_detect_tool", lambda name: None)


def _sandbox(tmp_path, *dirs):
    for rel in dirs:
        (tmp_path / rel).mkdir(parents=True, exist_ok=True)
    return str(tmp_path)


REASON_VOCABULARY = ("binary not found", "missing", "not a member",
                     "did not report", "no output", "unreadable",
                     "path not found")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def test_detect_root_trims_separators_and_falls_back_to_cwd():
    assert detect.get_mcp_detect_root(r"C:\repo\\") == r"C:\repo"
    assert detect.get_mcp_detect_root("C:/repo/") == "C:/repo"
    assert detect.get_mcp_detect_root("") == os.getcwd().rstrip("\\/")


def test_compare_path_matches_ps1_normalisation():
    assert (detect.compare_path("J:\\audio\\MCP-Watchers")
            == detect.compare_path("j:/audio/mcp-watchers/"))
    assert detect.compare_path("") == ""


def test_grepai_signal_keys_on_chunks_not_files():
    assert detect.get_grepai_index_signal("Files indexed: 0\nTotal chunks: 0")[2] is False
    assert detect.get_grepai_index_signal("Files indexed: 0\nTotal chunks: 892")[2] is True
    assert detect.get_grepai_index_signal("Files indexed: 42\nTotal chunks: 0")[2] is True
    files, chunks, _ = detect.get_grepai_index_signal(
        "Files indexed: 42\nTotal chunks: 892")
    assert (files, chunks) == (42, 892)


# ---------------------------------------------------------------------------
# binary gate
# ---------------------------------------------------------------------------

def test_binary_gate_reports_false_with_tool_name(tmp_path, no_tools):
    root = _sandbox(tmp_path)
    probes = {
        "memtrace": (detect.test_memtrace_initialized, "memtrace"),
        "grepai": (detect.test_grepai_initialized, "grepai"),
        "graphenium": (detect.test_graphenium_initialized, "gm"),
        "graphify-rs": (detect.test_graphify_rs_initialized, "graphify-rs"),
        "repowise": (detect.test_repowise_initialized, "repowise"),
        "graft": (detect.test_graft_initialized, "graft"),
    }
    for name, (probe, exe) in probes.items():
        ok, reason = probe(root)
        assert ok is False, name
        assert reason == "binary not found: %s" % exe, (name, reason)


def test_empty_directory_is_false_with_diagnostic_reason(tmp_path,
                                                         tool_present):
    root = _sandbox(tmp_path)
    probes = [detect.test_memtrace_initialized, detect.test_grepai_initialized,
              detect.test_graphenium_initialized,
              detect.test_graphify_rs_initialized,
              detect.test_repowise_initialized, detect.test_graft_initialized,
              detect.test_atlas_initialized]
    for probe in probes:
        ok, reason = probe(root)
        assert ok is False, probe.__name__
        assert reason, probe.__name__
        assert any(v in reason for v in REASON_VOCABULARY), (probe.__name__, reason)


# ---------------------------------------------------------------------------
# synthetic initialized layout (mirrors the Pester vectors)
# ---------------------------------------------------------------------------

def _build_initialized_layout(root, include_atlas=True):
    root = Path(root)
    for rel in (".memdb", ".grepai", "graphenium-out", "graphify-out",
                ".repowise", "graft", "graft/.graph"):
        (root / rel).mkdir(parents=True, exist_ok=True)
    scope = {"version": 1, "members": [
        {"repo_id": "synthetic", "path": str(root).replace("\\", "/")}]}
    (root / ".memdb" / ".memtrace-store-scope.json").write_text(
        json.dumps(scope), encoding="utf-8")
    (root / ".grepai" / "config.yaml").write_text("embedder:\n  provider: ollama\n",
                                                  encoding="utf-8")
    (root / ".grapheniumignore").write_text("target/\n", encoding="utf-8")
    (root / "graphenium-out" / "graph.json").write_text('{"nodes":[]}',
                                                        encoding="utf-8")
    (root / "graphify-out" / "graph.json").write_text('{"nodes":[]}',
                                                      encoding="utf-8")
    (root / "graft" / ".graph" / "wiring.json").write_text('{"wiring":[]}',
                                                           encoding="utf-8")
    (root / "graft" / "INDEX.md").write_text("# graft index", encoding="utf-8")
    if include_atlas:
        (root / ".env").write_text(
            "NEO4J_URI=bolt://localhost:7687\nNEO4J_USER=neo4j\n"
            "NEO4J_PASSWORD=password2\n", encoding="utf-8")


def test_synthetic_initialized_layout_is_true(tmp_path, tool_present):
    root = _sandbox(tmp_path)
    _build_initialized_layout(root)
    grepai_status = "grepai index status\nFiles indexed: 42\nTotal chunks: 892\nWatcher: running"
    repowise_doctor = ("| Claude Code MCP entry | OK | registered: repowise mcp . "
                       "--transport stdio |")
    cases = [
        detect.test_memtrace_initialized(root),
        detect.test_grepai_initialized(root, grepai_status),
        detect.test_graphenium_initialized(root),
        detect.test_graphify_rs_initialized(root),
        detect.test_repowise_initialized(root, repowise_doctor),
        detect.test_graft_initialized(root),
        detect.test_atlas_initialized(root),
    ]
    bad = ["%s: FALSE (%s)" % (probe, reason)
           for probe, (ok, reason) in zip(
               ("memtrace", "grepai", "graphenium", "graphify-rs",
                "repowise", "graft", "atlas"), cases) if not ok]
    assert bad == []


# ---------------------------------------------------------------------------
# partial-signal counter-examples (each measured on 2026-09-20)
# ---------------------------------------------------------------------------

def test_grepai_chunks_alone_satisfy_when_files_zero(tmp_path, tool_present):
    root = _sandbox(tmp_path, ".grepai")
    (Path(root) / ".grepai" / "config.yaml").write_text("embedder:\n",
                                                        encoding="utf-8")
    status = ("grepai index status\nFiles indexed: 0\nTotal chunks: 892\n"
              "Last updated: 2026-09-20 14:31:22\nWatcher: not running")
    ok, reason = detect.test_grepai_initialized(root, status)
    assert ok is True
    assert "Total chunks: 892" in reason


def test_grepai_empty_index_is_false(tmp_path, tool_present):
    root = _sandbox(tmp_path, ".grepai")
    (Path(root) / ".grepai" / "config.yaml").write_text("embedder:\n",
                                                        encoding="utf-8")
    ok, reason = detect.test_grepai_initialized(
        root, "Files indexed: 0\nTotal chunks: 0\n")
    assert ok is False
    assert "empty index" in reason


def test_graphenium_graph_without_marker_is_false(tmp_path, tool_present):
    root = _sandbox(tmp_path, "graphenium-out")
    (Path(root) / "graphenium-out" / "graph.json").write_text(
        '{"nodes":[{"id":1}],"edges":[]}', encoding="utf-8")
    ok, reason = detect.test_graphenium_initialized(root)
    assert ok is False
    assert "grapheniumignore" in reason


def test_graft_wiring_alone_is_false(tmp_path, tool_present):
    root = _sandbox(tmp_path, "graft/.graph")
    (Path(root) / "graft" / ".graph" / "wiring.json").write_text(
        '{"stale":true}', encoding="utf-8")
    ok, reason = detect.test_graft_initialized(root)
    assert ok is False
    assert "graph incomplete" in reason and "INDEX.md" in reason


def test_memtrace_scope_for_another_repo_is_false(tmp_path, tool_present):
    root = _sandbox(tmp_path, ".memdb")
    (Path(root) / ".memdb" / ".memtrace-store-scope.json").write_text(
        '{"version":1,"members":[{"repo_id":"other",'
        '"path":"j:/audio/some-other-repo"}]}', encoding="utf-8")
    ok, reason = detect.test_memtrace_initialized(root)
    assert ok is False
    assert "not a member" in reason


def test_memtrace_scope_matches_case_and_slash_insensitively(tmp_path,
                                                             tool_present):
    root = _sandbox(tmp_path, ".memdb")
    cased = str(Path(root)).replace("\\", "/").upper()
    (Path(root) / ".memdb" / ".memtrace-store-scope.json").write_text(
        json.dumps({"version": 1,
                    "members": [{"repo_id": "s", "path": cased}]}),
        encoding="utf-8")
    ok, _ = detect.test_memtrace_initialized(root)
    assert ok is True


def test_graphify_rs_empty_dir_is_false(tmp_path, tool_present):
    root = _sandbox(tmp_path, "graphify-out")
    ok, reason = detect.test_graphify_rs_initialized(root)
    assert ok is False
    assert "no built graph" in reason


def test_repowise_unregistered_entry_is_false(tmp_path, tool_present):
    root = _sandbox(tmp_path, ".repowise")
    doctor = ("| Database | OK | 47 pages |\n"
              "| Claude Code MCP entry | OK | not registered (repowise init registers it) |\n"
              "| MCP server responds | OK | not registered - nothing to launch |")
    ok, reason = detect.test_repowise_initialized(root, doctor)
    assert ok is False
    assert "not registered" in reason


def test_repowise_does_not_confuse_agent_row(tmp_path, tool_present):
    # The `Agent: claude-code` row also contains "not registered" but must
    # not be confused with the entry row.
    root = _sandbox(tmp_path, ".repowise")
    doctor = ("| Agent: claude-code | OK | not registered |\n"
              "| Claude Code MCP entry | OK | registered: repowise mcp . |")
    ok, _ = detect.test_repowise_initialized(root, doctor)
    assert ok is True


# ---------------------------------------------------------------------------
# atlas env parsing
# ---------------------------------------------------------------------------

def test_atlas_env_parsing_subset(tmp_path):
    env = tmp_path / ".env"
    env.write_text(
        "# comment\n\nexport QUOTED=\"a=b\"\nSINGLE='v'\n"
        "EMPTY=\nno-equals-line\nneo4j_uri=lower\n",
        encoding="utf-8")
    mapping = detect.read_atlas_env_file(str(env))
    assert mapping["QUOTED"] == "a=b"
    assert mapping["SINGLE"] == "v"
    assert mapping["EMPTY"] == ""
    assert "neo4j_uri" in mapping  # parsed, but never accepted as a key
    assert detect.read_atlas_env_file(str(tmp_path / "absent")) is None


def test_atlas_probe_requires_all_three_keys(tmp_path, tool_present):
    root = _sandbox(tmp_path)
    ok, reason = detect.test_atlas_initialized(root)
    assert ok is False and ".env missing" in reason
    (Path(root) / ".env").write_text("NEO4J_URI=x\n", encoding="utf-8")
    ok, reason = detect.test_atlas_initialized(root)
    assert ok is False
    assert "NEO4J_USER" in reason and "NEO4J_PASSWORD" in reason
    assert "password2" not in reason and "=x" not in reason  # no values leak


def test_atlas_probe_has_no_binary_gate(tmp_path, no_tools):
    root = _sandbox(tmp_path)
    (Path(root) / ".env").write_text(
        "NEO4J_URI=u\nNEO4J_USER=n\nNEO4J_PASSWORD=p\n", encoding="utf-8")
    ok, _ = detect.test_atlas_initialized(root)
    assert ok is True


# ---------------------------------------------------------------------------
# aggregate + originals live
# ---------------------------------------------------------------------------

def test_initialization_report_fixed_order_seven_rows(tmp_path, tool_present):
    root = _sandbox(tmp_path)
    rows = detect.get_mcp_initialization_report(root)
    assert [r["mcp"] for r in rows] == ["memtrace", "grepai", "graphenium",
                                        "graphify-rs", "repowise", "graft",
                                        "atlas"]
    assert all(r["ok"] is False and r["reason"] for r in rows)


def test_powershell_original_is_still_present():
    assert DETECT_PS1.is_file(), "watcher_mcp_detect.ps1 disappeared"
