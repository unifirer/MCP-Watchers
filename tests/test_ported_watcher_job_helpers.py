"""Acceptance suite for the ported job helpers - bead mcpw-xeu.5.

Imports the REAL Modules/watcher_job_helpers.py (never source-text
extraction). The PowerShell original stays live; this suite pins every
ported helper name against the .ps1's function list and proves the
pure-function behaviour with vectors, plus the one live property that
matters: a child assigned to the kill-on-close job dies when the job
handle closes (mcpw-xeu.5 acceptance).

Clean-room by construction: everything runs against temp dirs and a
fake process probe - except the job-handle test, which owns its
scratch child and reaps it.
"""
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Modules import watcher_job_helpers as absorbs  # noqa: E402

JOB_HELPERS_PS1 = ROOT / "Modules" / "watcher_job_helpers.ps1"

PS_TO_PY = {
    "Clear-StaleLocks": "clear_stale_locks",
    "Test-GrepaiLockStale": "test_grepai_lock_stale",
    "Get-GrepaiSpawnLogPair": "get_grepai_spawn_log_pair",
    "Resolve-GrepaiPaneLog": "resolve_grepai_pane_log",
    "Get-GrepaiLogDir": "get_grepai_log_dir",
    "Get-GrepaiProcessInfo": "get_grepai_process_info",
    "Test-GrepaiWatcherProcess": "test_grepai_watcher_process",
    "Get-GrepaiPidFileValue": "get_grepai_pid_file_value",
    "Test-GrepaiPidFileStale": "test_grepai_pid_file_stale",
    "Test-GrepaiPidFileOwnedByProject": "test_grepai_pid_file_owned_by_project",
    "Get-GrepaiLockInventory": "get_grepai_lock_inventory",
    "Clear-StaleGrepaiSpawnLocks": "clear_stale_grepai_spawn_locks",
    "Get-GrepaiSpawnBackoffSeconds": "get_grepai_spawn_backoff_seconds",
    "Get-GrepaiSpawnDecision": "get_grepai_spawn_decision",
    "Limit-LogSize": "limit_log_size",
    "New-LogParentDir": "new_log_parent_dir",
    "Test-LauncherAlive": "test_launcher_alive",
    "Test-LitellmConfig": "test_litellm_config",
    "Get-LitellmBackoffDelay": "get_litellm_backoff_delay",
    "Stop-PriorLitellmProxy": "stop_prior_litellm_proxy",
    "Get-LitellmProxyRelaunchPlan": "get_litellm_proxy_relaunch_plan",
    "Backup-LitellmStderr": "backup_litellm_stderr",
    "Test-GrepaiActivityLine": "test_grepai_activity_line",
    "Get-GrepaiWatchStartTime": "get_grepai_watch_start_time",
    "Get-GrepaiIdleMinutesFromConfig": "get_grepai_idle_minutes_from_config",
    "Get-GrepaiIdleMinutesFromLog": "get_grepai_idle_minutes_from_log",
    "Get-GrepaiIdleMinutes": "get_grepai_idle_minutes",
    "Get-GrepaiIdleTimeoutMinutes": "get_grepai_idle_timeout_minutes",
    "New-WatcherParentDeathJob": "new_watcher_parent_death_job",
    "Add-ProcessToWatcherDeathJob": "add_process_to_watcher_death_job",
}


def _ps1_functions():
    src = JOB_HELPERS_PS1.read_text(encoding="utf-8")
    return re.findall(r"^function\s+([A-Za-z-]+)", src, re.M)


# ---------------------------------------------------------------------------
# 1. Equivalence: every .ps1 helper has a Python counterpart
# ---------------------------------------------------------------------------

def test_every_ps1_helper_is_ported():
    missing = [name for name in _ps1_functions() if name not in PS_TO_PY]
    assert not missing, "unported helpers: %r" % missing
    for py_name in PS_TO_PY.values():
        assert callable(getattr(absorbs, py_name, None)), py_name


def test_ps1_original_stays_live_untouched():
    src = JOB_HELPERS_PS1.read_text(encoding="utf-8")
    assert "function New-WatcherParentDeathJob" in src
    assert "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE" in src


# ---------------------------------------------------------------------------
# 2. Stale locks: only provably-stale goes
# ---------------------------------------------------------------------------

def test_stop_marker_dead_owner_is_stale_live_is_not():
    assert absorbs.test_grepai_lock_stale("d/grepai-stop-1", "C:/r",
                                          pid_alive=lambda pid: False) is True
    assert absorbs.test_grepai_lock_stale("d/grepai-stop-1", "C:/r",
                                          pid_alive=lambda pid: True) is False


def test_worktree_lock_needs_sibling_log_naming_us(tmp_path):
    mine = tmp_path / "repo"
    mine.mkdir()
    lock = tmp_path / "grepai-worktree-abc.pid"
    lock.write_text("1", encoding="utf-8")
    (tmp_path / "grepai-worktree-abc.log").write_text(
        "Starting grepai watch in %s" % mine, encoding="utf-8")
    assert absorbs.test_grepai_lock_stale(str(lock), str(mine)) is True
    assert absorbs.test_grepai_lock_stale(str(lock), "C:/other") is False
    assert absorbs.test_grepai_lock_stale("d/weird-name.xyz", str(mine)) is False
    assert absorbs.test_grepai_lock_stale("", str(mine)) is False


def test_clear_stale_locks_leaves_live_ones(tmp_path, monkeypatch):
    (tmp_path / "grepai-stop-111").write_text("", encoding="utf-8")
    (tmp_path / "grepai-stop-222").write_text("", encoding="utf-8")
    alive = {222}
    monkeypatch.setattr(absorbs, "_pid_alive", lambda pid: pid in alive)
    removed = absorbs.clear_stale_locks("C:/r", lock_dir=str(tmp_path))
    assert len(removed) == 1 and removed[0].endswith("grepai-stop-111")
    assert os.path.exists(str(tmp_path / "grepai-stop-222"))


def test_spawn_log_pair_attempt1_is_canonical():
    assert absorbs.get_grepai_spawn_log_pair("a.log", "a.err", 1) == {
        "Log": "a.log", "Err": "a.err"}
    assert absorbs.get_grepai_spawn_log_pair("a.log", "a.err", 3) == {
        "Log": "a.log.attempt3", "Err": "a.err.attempt3"}


def test_pane_log_prefers_fresh_worktree_over_newer_dead_history(tmp_path):
    old_wt = tmp_path / "grepai-worktree-x.log"
    new_ll = tmp_path / "grepai-launch.log"
    old_wt.write_text("stale history", encoding="utf-8")
    new_ll.write_text("this run", encoding="utf-8")
    ancient = time.time() - 4 * 24 * 3600
    os.utime(str(old_wt), (ancient, ancient))
    assert absorbs.resolve_grepai_pane_log(str(old_wt), str(new_ll)) == str(new_ll)
    os.utime(str(old_wt), None)
    assert absorbs.resolve_grepai_pane_log(str(old_wt), str(new_ll)) == str(old_wt)


# ---------------------------------------------------------------------------
# 3. Watcher identity: recycled PIDs fail
# ---------------------------------------------------------------------------

def _probe(table):
    def _inner(pid):
        return table.get(int(pid))
    return _inner


def test_live_watch_matches_recycled_pid_does_not():
    table = {10: {"Name": "grepai.exe", "CommandLine": "grepai.exe watch C:/r"},
             11: {"Name": "grepai.exe", "CommandLine": "grepai.exe mcp-serve"},
             12: {"Name": "python.exe", "CommandLine": "grepai.exe watch C:/r"}}
    probe = _probe(table)
    assert absorbs.test_grepai_watcher_process(10, probe) is True
    assert absorbs.test_grepai_watcher_process(11, probe) is False
    assert absorbs.test_grepai_watcher_process(12, probe) is False
    assert absorbs.test_grepai_watcher_process(999, probe) is False
    assert absorbs.test_grepai_watcher_process(0, probe) is False


def test_pid_file_value_shapes(tmp_path):
    good = tmp_path / "grepai-watch.pid"
    good.write_text("4242\n", encoding="utf-8")
    assert absorbs.get_grepai_pid_file_value(str(good)) == 4242
    bad = tmp_path / "grepai-watch.pid.bad"
    bad.write_text("not-a-pid", encoding="utf-8")
    assert absorbs.get_grepai_pid_file_value(str(bad)) == 0
    assert absorbs.get_grepai_pid_file_value(str(tmp_path / "missing")) == 0


def test_pid_file_stale_vectors(tmp_path):
    tmp_file = tmp_path / "grepai-worktree-a.pid.tmp"
    tmp_file.write_text("1", encoding="utf-8")
    assert absorbs.test_grepai_pid_file_stale(str(tmp_file)) is True
    lock = tmp_path / "grepai-watch.pid.lock"
    lock.write_text("1", encoding="utf-8")
    assert absorbs.test_grepai_pid_file_stale(str(lock)) is False
    live = tmp_path / "grepai-watch.pid"
    live.write_text("10", encoding="utf-8")
    probe = _probe({10: {"Name": "grepai.exe", "CommandLine": "grepai watch"}})
    assert absorbs.test_grepai_pid_file_stale(str(live), probe) is False
    gone = tmp_path / "grepai-worktree-b.pid"
    gone.write_text("11", encoding="utf-8")
    assert absorbs.test_grepai_pid_file_stale(str(gone), _probe({})) is True


def test_spawn_decision_spawn_adopt_backoff(tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    out = absorbs.get_grepai_spawn_decision(str(empty), "C:/r")
    assert out["Action"] == "spawn" and out["DelaySeconds"] == 0

    owned = tmp_path / "owned"
    owned.mkdir()
    (owned / "grepai-worktree-a.pid").write_text("10", encoding="utf-8")
    # The sibling log carries the project path the way the watcher wrote it:
    # os.path.abspath form (backslashes on Windows), which is what the
    # ownership check normalises the project root to.
    (owned / "grepai-worktree-a.log").write_text(
        "Starting grepai watch in %s" % os.path.abspath("C:/r"), encoding="utf-8")
    probe = _probe({10: {"Name": "grepai.exe", "CommandLine": "grepai watch"}})
    out = absorbs.get_grepai_spawn_decision(str(owned), "C:/r", process_probe=probe)
    assert out["Action"] == "adopt" and out["BlockerPid"] == 10

    foreign = tmp_path / "foreign"
    foreign.mkdir()
    (foreign / "grepai-watch.pid").write_text("10", encoding="utf-8")
    out = absorbs.get_grepai_spawn_decision(str(foreign), "C:/r", process_probe=probe)
    assert out["Action"] == "backoff" and out["BlockerPid"] == 10
    assert out["DelaySeconds"] == 15


def test_backoff_tables():
    assert absorbs.get_grepai_spawn_backoff_seconds(0) == 15
    assert absorbs.get_grepai_spawn_backoff_seconds(1) == 15
    assert absorbs.get_grepai_spawn_backoff_seconds(2) == 30
    assert absorbs.get_grepai_spawn_backoff_seconds(3) == 60
    assert absorbs.get_grepai_spawn_backoff_seconds(99) == 600
    assert absorbs.get_litellm_backoff_delay(1) == 10
    assert absorbs.get_litellm_backoff_delay(2) == 20
    assert absorbs.get_litellm_backoff_delay(99) == 300


# ---------------------------------------------------------------------------
# 4. Logs, launcher liveness, litellm config
# ---------------------------------------------------------------------------

def test_limit_log_size_rotates_once(tmp_path):
    path = tmp_path / "watch.log"
    path.write_bytes(b"x" * (2 * 1024 * 1024))
    absorbs.limit_log_size(str(path), max_mb=1)
    assert os.path.exists(str(path) + ".old") and not os.path.exists(str(path))
    absorbs.limit_log_size(str(tmp_path / "missing"), max_mb=1)


def test_new_log_parent_dir_creates_parents(tmp_path):
    target = tmp_path / "a" / "b" / "c.log"
    absorbs.new_log_parent_dir(str(target))
    assert os.path.isdir(str(tmp_path / "a" / "b"))
    absorbs.new_log_parent_dir("")


def test_launcher_alive_vectors(tmp_path):
    assert absorbs.test_launcher_alive(str(tmp_path / "missing")) is False
    bad = tmp_path / "bad.lock"
    bad.write_text("not json", encoding="utf-8")
    assert absorbs.test_launcher_alive(str(bad)) is False
    live = tmp_path / "live.lock"
    live.write_text('{"Pid": 10, "StartedAt": "", "Launcher": "###1"}',
                    encoding="utf-8")
    probe = _probe({10: {"Name": "powershell.exe",
                         "CommandLine": "powershell ###1 watchers"}})
    assert absorbs.test_launcher_alive(str(live), process_probe=probe,
                                       pid_alive=lambda pid: True) is True
    assert absorbs.test_launcher_alive(str(live), process_probe=probe,
                                       pid_alive=lambda pid: False) is False


def test_litellm_config_ascii_gate(tmp_path):
    missing = tmp_path / "missing.yaml"
    assert absorbs.test_litellm_config(str(missing)) is False
    bad = tmp_path / "bad.yaml"
    bad.write_text("api_key: sk-\u00abquote\u00bb\n", encoding="utf-8")
    assert absorbs.test_litellm_config(str(bad)) is False
    good = tmp_path / "good.yaml"
    good.write_text("model: foo\napi_key: sk-replace-me\n", encoding="utf-8")
    assert absorbs.test_litellm_config(str(good)) is True


def test_litellm_relaunch_plan_reuse_then_spawn():
    now = datetime.now()
    plan = absorbs.get_litellm_proxy_relaunch_plan(
        0, port=4000, listening_pids=[10],
        proc_start=lambda pid: now - timedelta(seconds=5))
    assert plan["Action"] == "reuse" and plan["ReapPids"] == []
    plan = absorbs.get_litellm_proxy_relaunch_plan(
        9, port=4000, listening_pids=[10],
        proc_start=lambda pid: now - timedelta(seconds=90))
    assert plan["Action"] == "spawn" and set(plan["ReapPids"]) == {9, 10}


def test_stop_prior_litellm_proxy_shapes():
    assert absorbs.stop_prior_litellm_proxy(0) is False
    assert absorbs.stop_prior_litellm_proxy(999999999,
                                            pid_alive=lambda pid: False) is False


def test_backup_litellm_stderr_preserves(tmp_path):
    base = tmp_path / "litellm"
    (tmp_path / "litellm.err").write_text("boom\n", encoding="utf-8")
    absorbs.backup_litellm_stderr(str(base))
    history = tmp_path / "litellm.err.history"
    assert history.exists() and "boom" in history.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 5. Idle clocks: unknown is -1, never a reap
# ---------------------------------------------------------------------------

def test_activity_line_vectors():
    assert absorbs.test_grepai_activity_line("") is False
    assert absorbs.test_grepai_activity_line("x rpg_full_reconcile_triggered=1") is False
    assert absorbs.test_grepai_activity_line("x rpg_derived_refresh_ms=5 changed_files=0 ") is False
    assert absorbs.test_grepai_activity_line("x rpg_persist_ms=3") is False
    assert absorbs.test_grepai_activity_line("2026/09/24 10:00:00 indexed 5 files") is True


def test_idle_minutes_unknown_is_minus_one(tmp_path):
    assert absorbs.get_grepai_idle_minutes_from_log(str(tmp_path)) == -1
    assert absorbs.get_grepai_idle_minutes(str(tmp_path), config_path="") == -1
    assert absorbs.get_grepai_idle_timeout_minutes("") == 20
    cfg = tmp_path / "config.yaml"
    cfg.write_text("watch:\n  idle_timeout_minutes: 0\n", encoding="utf-8")
    assert absorbs.get_grepai_idle_timeout_minutes(str(cfg)) == 0


def test_idle_from_config_freshness_guard(tmp_path):
    cfg = tmp_path / "config.yaml"
    cfg.write_text("watch:\n  last_index_time: 2020-01-01T00:00:00\n", encoding="utf-8")
    future = datetime.now() + timedelta(hours=1)
    assert absorbs.get_grepai_idle_minutes_from_config(str(cfg), watch_start=future) is None


def test_watch_start_newest_wins():
    snap = [{"ProcessId": 1, "Name": "grepai.exe", "CommandLine": "grepai watch",
             "CreationDate": 100.0},
            {"ProcessId": 2, "Name": "grepai.exe", "CommandLine": "grepai watch",
             "CreationDate": 200.0}]
    assert absorbs.get_grepai_watch_start_time(snap) == datetime.fromtimestamp(200.0)
    assert absorbs.get_grepai_watch_start_time([]) is None


# ---------------------------------------------------------------------------
# 6. Live: kill-on-close on the job object (mcpw-xeu.5 acceptance)
# ---------------------------------------------------------------------------

def test_live_child_dies_on_job_handle_close():
    job = absorbs.new_watcher_parent_death_job()
    assert job, "no job object on this machine"
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        assert absorbs.add_process_to_watcher_death_job(job, child.pid) is True
        assert child.poll() is None
        assert absorbs.close_watcher_parent_death_job(job) is True
        job = None
        dead = False
        for _ in range(50):
            if child.poll() is not None:
                dead = True
                break
            time.sleep(0.1)
        assert dead, "child SURVIVED job-handle close"
    finally:
        if job:
            absorbs.close_watcher_parent_death_job(job)
        if child.poll() is None:
            child.kill()
            child.wait(timeout=15)


def test_assign_rejects_shapes():
    assert absorbs.add_process_to_watcher_death_job(None, os.getpid()) is False
    assert absorbs.add_process_to_watcher_death_job(0, os.getpid()) is False
    assert absorbs.add_process_to_watcher_death_job(1234, 0) is False
