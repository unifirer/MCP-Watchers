"""Parse-level checks that the ###1 watcher launcher wires teardown correctly.

Behavioral (process-tree) teardown is covered by the Pester suite
(tests/launcher_watcher_teardown.tests.ps1) against the real shared module.
These Python tests guard the LAUNCHER's wiring only.
"""
from pathlib import Path
import re

import pytest

ROOT = Path(__file__).parent.parent
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
PANE_MODULE = ROOT / "Modules" / "watcher_pane_scripts.ps1"


def test_launcher_dot_sources_teardown_module():
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "Modules\\watcher_teardown.ps1" in content, (
        "Launcher must dot-source the shared teardown module."
    )


def test_launcher_trap_calls_stop_all_watchers():
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "Stop-AllWatchers" in content, (
        "trap must call Stop-AllWatchers (the shared teardown)."
    )
    assert "Register-EngineEvent" in content, (
        "Launcher must register a PowerShell.Exiting handler for window-close teardown."
    )
    assert "PowerShell.Exiting" in content, (
        "Engine event must be PowerShell.Exiting (fires on window [X] close)."
    )


def test_launcher_persists_teardown_state():
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "teardown-state.json" in content, (
        "Launcher must persist tracked root PIDs to teardown-state.json "
        "so the Exiting handler (separate runspace) can reach the processes."
    )


def test_launcher_kills_watchers_when_wt_tab_closed():
    content = LAUNCHER.read_text(encoding="utf-8")
    pane_content = PANE_MODULE.read_text(encoding="utf-8")
    # When the controller console is hidden, the only visible surface is the WT
    # tab. The launcher must detect a dead/closed tab (via pane heartbeats) and
    # run Stop-AllWatchers -- otherwise closing the tab orphans every watcher.
    # vad-uzb: the heartbeat writer lives in the pane tailer template, which is
    # now Modules/watcher_pane_scripts.ps1; the watching side stays in the launcher.
    assert "Write-WatcherHeartbeat" in pane_content, (
        "Each pane tailer must write a heartbeat so the controller can detect "
        "a closed WT tab."
    )
    assert "hbPaths" in content, (
        "Launcher must collect the pane heartbeat paths to watch."
    )
    assert "No WT pane heartbeat" in content, (
        "Controller loop must stop all watchers when no pane has ticked (tab "
        "was closed)."
    )
    assert "Stop-AllWatchers" in content, (
        "The WT-tab-dead guard must call Stop-AllWatchers."
    )


def test_first_wins_port_gate_teardowns_before_exit():
    """Regression for VAD-ygdo.7: FIRST-WINS port exit must not orphan watchers.

    Exit-IfPortHeldByLauncherDaemon can exit 0 at the memtrace (:50051)
    and claude-mcp-server (:8080) gates. Those gates run
    AFTER the launcher already spawned detached watchers (litellm, gm watch,
    graphify-rs wrapper, repowise, grepai watch), while teardown-state.json
    (written near the end) and the PowerShell.Exiting handler (registered
    mid-script) are never reached -- so five processes orphan.

    Acceptance (either satisfies):
      (a) both port gates run before the first Start-WatcherDetached
          spawn, OR
      (b) the exit-0 path inside Exit-IfPortHeldByLauncherDaemon invokes
          Stop-AllWatchers first (with explicit PIDs, since the state file
          does not exist yet at gate time).
    """
    content = LAUNCHER.read_text(encoding="utf-8")
    gate_calls = [
        m.start()
        for m in re.finditer(
            r"Exit-IfPortHeldByLauncherDaemon\s+-Port", content
        )
    ]
    assert len(gate_calls) >= 2, (
        "Expected at least two FIRST-WINS port gates "
        "(memtrace/claude-mcp-server)."
    )
    spawn_calls = [
        m.start()
        for m in re.finditer(r'Start-WatcherDetached\s+"', content)
    ]
    assert spawn_calls, "Expected Start-WatcherDetached spawns in launcher."
    if max(gate_calls) < min(spawn_calls):
        # Option (a): gates-before-spawns satisfies acceptance alone.
        return
    # Option (b): exit-0 path must teardown first.
    m = re.search(
        r"function\s+Exit-IfPortHeldByLauncherDaemon\s*\{", content
    )
    assert m, "Exit-IfPortHeldByLauncherDaemon function missing."
    tail = content[m.start():]
    # Line-anchored so inline mentions (e.g. "# a bare exit") do not match;
    # only the real `exit 0` statement counts.
    exit_m = re.search(r"(?m)^\s*exit\s+0\b", tail)
    assert exit_m, "FIRST-WINS exit 0 missing in port-gate function."
    body_before_exit = tail[: exit_m.start()]
    assert "Stop-AllWatchers" in body_before_exit, (
        "VAD-ygdo.7: FIRST-WINS port exit must call Stop-AllWatchers before "
        "exit 0, or move all port gates before the first spawn -- otherwise "
        "already-spawned detached watchers orphan."
    )
    assert ("WatcherChildren" in body_before_exit) or (
        "RootPids" in body_before_exit
    ), (
        "VAD-ygdo.7: early exit teardown must pass explicit PIDs "
        "(WatcherChildren/RootPids) -- teardown-state.json is not written "
        "yet at gate time, so a bare Stop-AllWatchers would be a no-op."
    )


def test_launcher_last_wins_takeover_restarts_panes():
    """LAST-WINS takeover (restored 2026-09-15): a double-click must always
    bring up the pane grid.

    VAD-v14z.8 replaced the pre-lock takeover with a silent FIRST-WINS exit.
    That left an established headless launcher - grid window closed, watchers
    still alive - blocking every later double-click: the new instance exited at
    ``Write-LauncherLock`` and no panes ever appeared. The launcher must stop an
    ESTABLISHED prior launcher before claiming the lock.

    The VAD-v14z.8 anti-race fix must survive: the takeover is serialized by a
    machine-wide mutex and skips a YOUNG holder (a concurrent double-click), so
    two racers can never kill each other and orphan watchers.
    """
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "Write-LauncherLock" in content, (
        "Launcher must claim the single-instance lock via Write-LauncherLock."
    )
    # The pre-lock takeover call must be present (the pane-grid guarantee).
    assert re.search(r"(?m)^Stop-PriorLauncherInstances\b", content), (
        "LAST-WINS: an established prior launcher must be stopped before the "
        "lock is claimed, or the panes never restart."
    )
    # Anti-race guards: serialized takeover + young-holder skip.
    assert "VAD_Watchers_Takeover" in content, (
        "Takeover must be serialized by a machine-wide mutex so two concurrent "
        "double-clicks cannot kill each other."
    )
    assert "MinAgeSec" in content, (
        "Takeover must skip a young holder (the concurrent double-click case)."
    )
    fn = re.search(r"function\s+Stop-PriorLauncherInstances\s*\{", content)
    assert fn, "Stop-PriorLauncherInstances definition missing."
    start = fn.start()
    nxt = content.find("\nfunction ", start + 1)
    body = content[start: nxt if nxt != -1 else len(content)]
    assert "Stop-AllWatchers" in body, (
        "Takeover must tear the prior launcher's watchers down (PID-scoped) "
        "before killing its PID, or detached daemons orphan."
    )
    assert "Stop-Process -Id $holderPid" in body, (
        "Takeover must stop the prior launcher process itself."
    )


def test_launcher_second_instance_exits_first_keeps_lock():
    """Regression: a CONCURRENT double-click resolves without stacking.

    LAST-WINS takeover replaces an ESTABLISHED prior launcher, but a young
    holder (still starting up) must be left alone: the loser path reports the
    live holder via Acquire-LauncherLock and exits 0 instead of killing a peer
    mid-startup and orphaning its watchers.
    """
    content = LAUNCHER.read_text(encoding="utf-8")
    # Loser path: live holder -> Acquire-LauncherLock reports and returns $null.
    assert "Launcher already running" in content, (
        "The lock loser must report the live holder PID."
    )
    assert "if ($null -eq $global:LauncherLock) { exit 0 }" in content, (
        "Second launcher must exit 0 when the lock is held."
    )
    # Port-held guard stays FIRST-WINS too.
    assert "Exiting (FIRST-WINS)" in content, (
        "Port-held sibling exit must remain FIRST-WINS."
    )


def test_stop_prior_launcher_instances_sweeps_orphaned_graphify_wrappers():
    """Regression guard for the virtual-desktop slowness root cause.

    VAD-v14z.8 deprecated Stop-PriorLauncherInstances as a pre-lock startup
    kill but kept its body; the LAST-WINS takeover (restored 2026-09-15) calls
    it pre-lock again, so this test pins the orphan-sweep shape it still owns.
    It must sweep orphaned graphify-watch-wrapper processes
    (powershell.exe hosting the ignore-aware wrapper with -WatchMode). Without
    this sweep, a hard-killed/crashed prior ###1 leaves its wrappers alive; each
    surviving wrapper keeps a FileSystemWatcher over the whole repo and spawns a
    full graphify-rs rebuild on every file change -- 10+ stacked orphans
    saturated the disk and CPU (verified 2026-08-18), which made Windows virtual-
    desktop switching stutter.

    The sweep must use the SAME dedicated 'graphify-watch-wrapper' literal
    pattern as Stop-AllWatchers in modules/watcher_teardown.ps1 (tested there),
    NOT a '|'-glued alternation with 'panes\\tail_' (which [regex]::Escape
    neutralizes so neither token matches).

    After the shared-pattern-module hardening, the literal pattern lives in
    modules/watcher_patterns.ps1 and the launcher consumes it via
    $script:WatcherSweepPatterns — so we assert the launcher dotsources the shared
    module AND iterates $script:WatcherSweepPatterns, and that the shared module's
    dedicated pattern is the dedicated literal (not a '|'-glued alternation).
    """
    content = LAUNCHER.read_text(encoding="utf-8")
    # Launcher must dot-source the shared patterns module.
    assert "watcher_patterns.ps1" in content, (
        "Launcher must dot-source modules/watcher_patterns.ps1 for the shared sweep list."
    )
    # Launcher must iterate the shared list (not a hand-rolled inline sweep).
    assert "$script:WatcherSweepPatterns" in content, (
        "Stop-PriorLauncherInstances must sweep via $script:WatcherSweepPatterns."
    )
    # It must NOT glue the wrapper onto the pane-tailer pattern with '|'.
    assert "|graphify-watch-wrapper'" not in content and "|graphify-watch-wrapper\"" not in content, (
        "Do not merge 'graphify-watch-wrapper' onto 'panes\\tail_' with '|' -- "
        "[regex]::Escape neutralizes the alternation so neither token matches."
    )
    # It must terminate via Invoke-CimMethod (CimInstance has no .Terminate()
    # method on this Windows build -- a direct .Terminate() throws).
    assert "Invoke-CimMethod" in content, (
        "Stop-PriorLauncherInstances must terminate orphans via Invoke-CimMethod "
        "(CimInstance has no .Terminate() method on this host)."
    )
    # The shared list itself must carry the dedicated literal pattern.
    shared = ROOT / "modules/watcher_patterns.ps1"
    assert shared.exists(), "modules/watcher_patterns.ps1 must exist."
    stext = shared.read_text(encoding="utf-8")
    assert "'graphify-watch-wrapper'" in stext or '"graphify-watch-wrapper"' in stext, (
        "Shared sweep list must contain the dedicated graphify-watch-wrapper pattern."
    )
    assert "|'graphify-watch-wrapper'" not in stext, (
        "Shared list must NOT glue graphify-watch-wrapper onto another pattern with '|'."
    )
