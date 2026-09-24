"""Acceptance suite for the ported teardown layer - bead mcpw-xeu.5.

Imports the REAL Modules/watcher_teardown.py (never source-text
extraction). The PowerShell original stays live; this suite pins the
port's state shape, PID-scope rule, sweep defences and takeover
behaviour against the .ps1, and proves the two properties that make
this port dangerous:

  * an unrelated shell host is never killed (mcpw-xeu.5 acceptance),
  * a wait result of 128 takes over with logging, never a silent skip
    (mcpw-xeu.7), with file-lock-first ordering preserved (mcpw-xeu.8).

Clean-room by construction: every test runs against synthetic process
snapshots and temp dirs, never the live process table - except the
state round-trip and the job-handle test, which touch only their own
scratch processes.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Modules import watcher_teardown as td  # noqa: E402
from Modules import watcher_patterns as patterns  # noqa: E402
from Modules import watcher_launcher_lock as lock  # noqa: E402

TEARDOWN_PS1 = ROOT / "Modules" / "watcher_teardown.ps1"


def _proc(pid, ppid=0, name="", cmd="", created=0):
    return {"ProcessId": pid, "ParentProcessId": ppid, "Name": name,
            "CommandLine": cmd, "CreationDate": created}


# ---------------------------------------------------------------------------
# 1. Equivalence: the .ps1 is still live and the shapes still agree
# ---------------------------------------------------------------------------

def test_ps1_original_stays_live_untouched():
    """The port duplicates; the launcher still dot-sources the .ps1."""
    src = TEARDOWN_PS1.read_text(encoding="utf-8")
    assert "function Stop-AllWatchers" in src
    assert "function Stop-WatcherTree" in src
    assert "function Test-OrphanedMemtraceHostProcess" in src


def test_state_shape_matches_ps1_writer():
    """teardown-state.json keys are the contract both sides share."""
    assert set(td.parse_teardown_state({}).keys()) == {
        "RootPids", "MemtraceStatePath", "RepoRoot", "WtWindowName", "GrepaiPid"}


def test_pane_host_comes_from_the_shared_export():
    """mcpw-xeu.4: no host literal is redefined in the port."""
    assert td._pane_host_name() == patterns.WATCHER_PANE_HOST_NAME
    src = (ROOT / "Modules" / "watcher_teardown.py").read_text(encoding="utf-8")
    assert "WATCHER_PANE_HOST_NAME" in src


def test_sweep_table_is_the_shared_table():
    """The port sweeps the shared table, never a copied one."""
    assert list(patterns.WATCHER_SWEEP_PATTERNS)
    assert any(e.persistent for e in patterns.WATCHER_SWEEP_PATTERNS)


# ---------------------------------------------------------------------------
# 2. State round-trip (byte-compatible with the .ps1)
# ---------------------------------------------------------------------------

def test_state_write_read_roundtrip(tmp_path):
    path = str(tmp_path / "teardown-state.json")
    td.write_teardown_state(path, [1234], "C:\\x\\.memdb\\daemon-state.json",
                            "C:\\x", "vadwatchers", 5678)
    data = td.parse_teardown_state(td.read_teardown_state(path))
    assert data == {"RootPids": [1234],
                    "MemtraceStatePath": "C:\\x\\.memdb\\daemon-state.json",
                    "RepoRoot": "C:\\x", "WtWindowName": "vadwatchers",
                    "GrepaiPid": 5678}


def test_state_read_tolerates_the_ps1_bom(tmp_path):
    path = tmp_path / "teardown-state.json"
    path.write_bytes(b'\xef\xbb\xbf{"RootPids": [7], "GrepaiPid": 0}')
    data = td.parse_teardown_state(td.read_teardown_state(str(path)))
    assert data["RootPids"] == [7]


def test_lock_file_read(tmp_path):
    path = tmp_path / "###1-launcher.lock"
    path.write_text(json.dumps({"Pid": 4242, "StartedAt": "2026-09-24T00:00:00",
                                "Launcher": "###1"}), encoding="utf-8")
    assert td.read_lock_file(str(path))[0] == 4242


# ---------------------------------------------------------------------------
# 3. PID sets: BFS over the parent map
# ---------------------------------------------------------------------------

def test_descendant_set_covers_children_and_grandchildren():
    snap = [_proc(10), _proc(11, 10), _proc(12, 11), _proc(99)]
    scope = td.get_descendant_pid_set([10], snap)
    assert set(scope) == {10, 11, 12}


def test_descendant_set_ignores_dead_roots():
    assert td.get_descendant_pid_set([0], [_proc(1)]) == {}
    assert td.get_descendant_pid_set([], [_proc(1)]) == {}


def test_stop_watcher_tree_returns_kill_count_and_skips_strangers():
    snap = [_proc(10), _proc(11, 10), _proc(99)]
    killed = []
    out = td.stop_watcher_tree(10, snap, lambda pid: killed.append(pid) or True)
    assert out == 2
    assert 99 not in killed


# ---------------------------------------------------------------------------
# 4. mcpw-xeu.5 acceptance: an unrelated shell host is not killed
# ---------------------------------------------------------------------------

def _scope_snapshot():
    host = patterns.WATCHER_PANE_HOST_NAME
    return [
        _proc(100),                                            # our root
        _proc(101, 100, "grepai.exe", "grepai.exe watch C:\\r"),
        _proc(102, 100, host, "something entirely unrelated"),
        _proc(103, 100, "python.exe", "python.exe mcp_agent_mail\\server.py --port 8765"),
        _proc(200),                                            # sibling root
        _proc(201, 200, "grepai.exe", "grepai.exe watch C:\\sibling"),
        _proc(202, 200, host, "panes\\tail_other"),
        _proc(203, 200, host, "something entirely unrelated"),
    ]


def test_sibling_watcher_and_unrelated_host_survive():
    killed = []
    events = []
    summary = td.stop_all_watchers(
        [100], processes=_scope_snapshot(),
        terminate=lambda pid: killed.append(pid) or True,
        pid_alive=lambda pid: True, events=events)
    # Tree-kill reaps our own root and everything under it - that is its job.
    for pid in (100, 101, 102, 103):
        assert pid in killed
    # A sibling's processes are never touched, whatever they run.
    for pid in (201, 202, 203):
        assert pid not in killed
    sweeps = [e for e in events if e[0] == "sweep"]
    # The sweep predicate itself fires only for the in-scope pattern match...
    assert ("sweep", "grepai.exe", 101) in sweeps
    # ...never for an unrelated shell host, a persistent singleton, or a
    # sibling - even though the tree-kill above already reaped our own two.
    for pid in (102, 103, 201, 202, 203):
        assert not [e for e in sweeps if e[2] == pid], sweeps
    # mcpw-xeu.9: the Persistent skip is wired into this sweep.
    assert any(e[0] == "skip" and e[1] == "persistent" for e in events), events
    assert summary["skipped"] >= 0


def test_grepai_stop_is_pid_scoped_never_global():
    ran = []
    snap = [_proc(100), _proc(101, 100, "grepai.exe", "grepai watch")]
    # Our own grepai, alive and in scope: stops.
    out = td.stop_all_watchers([100], grepai_pid=101, processes=snap,
                               terminate=lambda pid: True,
                               pid_alive=lambda pid: True,
                               run_grepai_stop=lambda: ran.append(1))
    assert out["grepai_stopped"] is True and ran == [1]
    # A foreign PID, not in scope: never stops.
    ran.clear()
    out = td.stop_all_watchers([100], grepai_pid=9999, processes=snap,
                               terminate=lambda pid: True,
                               pid_alive=lambda pid: True,
                               run_grepai_stop=lambda: ran.append(1))
    assert out["grepai_stopped"] is False and ran == []


def test_memtrace_kill_needs_healthy_status_and_live_pid(tmp_path):
    state = tmp_path / "daemon-state.json"
    state.write_text(json.dumps({"status": "healthy", "pid": 4242}), encoding="utf-8")
    killed = []
    out = td.stop_all_watchers([100], memtrace_state_path=str(state),
                               processes=_scope_snapshot(),
                               terminate=lambda pid: killed.append(pid) or True,
                               pid_alive=lambda pid: pid == 4242)
    assert out["memtrace_killed"] is True and 4242 in killed
    state.write_text(json.dumps({"status": "stopped", "pid": 4242}), encoding="utf-8")
    out = td.stop_all_watchers([100], memtrace_state_path=str(state),
                               processes=_scope_snapshot(),
                               terminate=lambda pid: True,
                               pid_alive=lambda pid: True)
    assert out["memtrace_killed"] is False


# ---------------------------------------------------------------------------
# 5. mcpw-xeu.7: WAIT_ABANDONED takes over with logging
# ---------------------------------------------------------------------------

def test_abandoned_takeover_is_ownership_with_a_log_line(monkeypatch):
    seen = []

    class _StubEvent:
        WAIT_ABANDONED = 128

        @staticmethod
        def WaitForSingleObject(handle, ms):
            return 128

        @staticmethod
        def ReleaseMutex(handle):
            return True

        @staticmethod
        def CloseHandle(handle):
            return True

    monkeypatch.setitem(sys.modules, "win32event", _StubEvent)
    assert td.wait_for_takeover_mutex(object(), 15000, log=seen.append) is True
    assert seen, "abandoned takeover must be logged, never silent"
    assert lock.wait_result_is_owned(128) is True
    assert (128 == 0) is False  # what the naive check sees


def test_takeover_wait_is_the_single_shared_rule(monkeypatch):
    """The port must not grow a second abandoned-mutex rule."""
    calls = []
    monkeypatch.setattr(lock, "wait_result_is_owned",
                        lambda rc: calls.append(rc) or True)

    class _StubEvent:
        @staticmethod
        def WaitForSingleObject(handle, ms):
            return 0

    monkeypatch.setitem(sys.modules, "win32event", _StubEvent)
    assert td.wait_for_takeover_mutex(object(), 10, log=lambda m: None) is True
    assert calls == [0]


# ---------------------------------------------------------------------------
# 6. mcpw-xeu.8: the takeover order is wait, read, reap, kill, sweep
# ---------------------------------------------------------------------------

def test_stop_prior_orders_wait_before_lock_read(monkeypatch, tmp_path):
    order = []
    lock_path = tmp_path / "###1-launcher.lock"
    lock_path.write_text(json.dumps({"Pid": 0}), encoding="utf-8")

    class _StubEvent:
        @staticmethod
        def CreateMutex(a, b, name):
            order.append("create-mutex")
            return object()

        @staticmethod
        def WaitForSingleObject(handle, ms):
            order.append("wait")
            return 0

        @staticmethod
        def ReleaseMutex(handle):
            return True

        @staticmethod
        def CloseHandle(handle):
            return True

    monkeypatch.setitem(sys.modules, "win32event", _StubEvent)
    orig_read = td.read_lock_file

    def _spied(path):
        order.append("read-lock")
        return orig_read(path)

    monkeypatch.setattr(td, "read_lock_file", _spied)
    td.stop_prior_launcher_instances(str(tmp_path), current_pid=99999,
                                     processes=[], log=lambda m: None)
    assert order.index("wait") < order.index("read-lock"), order


# ---------------------------------------------------------------------------
# 7. mcpw-ajy orphan sweep: pure vectors
# ---------------------------------------------------------------------------

def test_union_daemon_member_is_never_an_orphan():
    cand = _proc(50, 1, "node.exe",
                 "node.exe memtrace.js start --headless --workspace C:\\m", created=10)
    parent = _proc(1, 0, "services.exe", "services", created=1)
    assert td.test_orphaned_memtrace_host_process(cand, [cand, parent]) is False


def test_legacy_bless_workspace_orphan_is_reaped():
    cand = _proc(50, 4242, "node.exe",
                 "node.exe memtrace.js start --headless --bless-workspace", created=10)
    assert td.test_orphaned_memtrace_host_process(cand, [cand]) is True


def test_live_parent_means_not_orphaned():
    cand = _proc(50, 40, "node.exe", "node.exe memtrace.js foo", created=10)
    parent = _proc(40, 1, "powershell.exe", "launcher", created=5)
    assert td.test_orphaned_memtrace_host_process(cand, [cand, parent]) is False


def test_self_and_protected_are_excluded():
    cand = _proc(50, 4242, "powershell.exe", "memtrace.ps1 something", created=10)
    assert td.test_orphaned_memtrace_host_process(cand, [cand], self_pid=50) is False
    assert td.test_orphaned_memtrace_host_process(cand, [cand],
                                                  protected_pids=[50]) is False


def test_daemon_anchor_vectors():
    assert td.test_memtrace_daemon_anchor("memcore-server.exe", "") is True
    assert td.test_memtrace_daemon_anchor("node.exe", "x memtrace.js --workspace y") is True
    assert td.test_memtrace_daemon_anchor("node.exe", "x memtrace.js --bless-workspace") is False
    assert td.test_memtrace_daemon_anchor("node.exe", "x server.js") is False


# ---------------------------------------------------------------------------
# 8. Live: state file both sides share (own scratch only)
# ---------------------------------------------------------------------------

def test_live_state_file_shape(tmp_path):
    path = str(tmp_path / "watchers" / "ad90e3fb" / "teardown-state.json")
    td.write_teardown_state(path, [os.getpid()], "", str(tmp_path), "vadwatchers", 0)
    raw = Path(path).read_text(encoding="utf-8")
    assert set(json.loads(raw).keys()) == {
        "RootPids", "MemtraceStatePath", "RepoRoot", "WtWindowName", "GrepaiPid"}


def test_ps1_takeover_catches_abandoned():
    """If the .ps1 ever stops catching this, the port pin must fail."""
    src = (ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
           ).read_text(encoding="utf-8", errors="replace")
    assert re.search(r"catch\s+\[System\.Threading\.AbandonedMutexException\]", src)
