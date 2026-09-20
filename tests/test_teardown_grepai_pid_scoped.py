"""Regression for VAD-49om: watcher teardown must NOT call a bare global
`grepai watch --stop` (which stops a SIBLING launcher's grepai watcher too).
The teardown's grepai stop must be PID-scoped to the grepai PID this launcher
recorded in teardown-state.json (GrepaiPid).

Behavioral teardown is covered by the Pester suite against the real module;
these parse-level guards protect the exact regression (an unconditional global
`grepai watch --stop` must not exist in the shared teardown module).
"""
from pathlib import Path

import pytest

TEARDOWN = Path(__file__).parent.parent / "modules" / "watcher_teardown.ps1"
LAUNCHER = Path(__file__).parent.parent / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"


@pytest.fixture(scope="module")
def teardown_src():
    assert TEARDOWN.exists(), "modules/watcher_teardown.ps1 must exist"
    return TEARDOWN.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def launcher_src():
    assert LAUNCHER.exists(), "watcher launcher must exist"
    return LAUNCHER.read_text(encoding="utf-8")


def test_teardown_has_no_unconditional_global_grepai_stop(teardown_src):
    # The dangerous line was an UNGUARDED `try { & grepai watch --stop ... }`
    # hoisted above the GrepaiPid guard, which stopped grepai globally. The new
    # code only issues `& grepai watch --stop` INSIDE the `$GrepaiPid` guard.
    # Assert every `& grepai watch --stop` call is inside the PID-scoped block:
    # it must be preceded (earlier in the file) by the guard opener.
    idx_call = teardown_src.find("& grepai watch --stop")
    assert idx_call == -1 or "if ($GrepaiPid" in teardown_src[:idx_call], (
        "teardown must not issue a global grepai stop; the call must be inside the "
        "GrepaiPid guard (PID-scoped)."
    )
    # And there must be exactly one such call, nested under the guard.
    assert teardown_src.count("& grepai watch --stop") == 1, (
        "exactly one PID-scoped grepai stop is expected"
    )


def test_all_daemon_pids_tracked_or_documented(launcher_src):
    """Regression for VAD-v14z.4: every background daemon must be PID-tracked.

    Only Start-WatcherDetached PIDs entered $global:WatcherChildren; memtrace,
    claude-mcp and mail start in background jobs and litellm via
    Start-WatcherDetached + supervisor jobs. Each daemon must either persist
    its PID path to teardown-state.json / WatcherChildren (RootPids, GrepaiPid,
    MemtraceStatePath) or carry an explicit intentional-persistence note, and
    no daemon start may be fire-and-forget (``| Out-Null`` discarding the job).
    """
    # Killable watchers incl. litellm go through Start-WatcherDetached.
    assert "Start-WatcherDetached" in launcher_src
    assert "$global:WatcherChildren" in launcher_src
    assert "$script:litellmProc" in launcher_src, (
        "litellm must stay a tracked detached child (WatcherChildren/RootPids)"
    )
    # Memtrace daemon PID is reachable via MemtraceStatePath + tracked job.
    assert "$script:memtraceStartJob" in launcher_src, (
        "memtrace start job must be captured, not piped to Out-Null"
    )
    assert "MemtraceStatePath" in launcher_src
    # Singleton persistent services keep their start-job handles and document
    # intentional exclusion from WatcherChildren/teardown.
    for var in (
        "$script:claudeMcpStartJob",
        "$script:mailMcpStartJob",
    ):
        assert var in launcher_src, f"{var} must be captured, not Out-Null"
    assert "teardown-state.json" in launcher_src
    # Intentional-persistence documentation must exist for the singletons.
    assert "PERSISTS" in launcher_src
    assert "intentionally NOT added to" in launcher_src
    assert "VAD-v14z.4" in launcher_src, "daemon PID model must be documented"



