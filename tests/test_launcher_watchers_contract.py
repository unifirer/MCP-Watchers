"""Static contract locks for the ###1 watcher launcher's LIVE-DATA plumbing.

These tests pin the exact tokens the launcher emits so a refactor that drops a
watcher or changes the persisted live-state shape fails loudly. No processes are
spawned. Behavioral teardown is covered by the Pester suite
(launcher_watcher_teardown plus the keyed workspace suites).
Live round-trip via tests/test_launcher_teardown_state_live.py was deleted
2026-09-18 (mcpw-ybs.6): helper never existed, REAL_STATE pointed at the
pre-.2a un-keyed path, WT-title probe unreliable.

Contract facts taken from ###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1:
  - gm:   NO `gm watch` process. gm 0.19.3's incremental writers (`gm watch`,
          `gm run . --update`) REPLACE graph.json with only the changed files'
          nodes, so freshness comes from (a) the in-process full-rebuild daemon
          (Invoke-GmSemanticBuild -> `gm run . --no-semantic`) and (b) the
          Toolport-registered `gm serve --graph <path> --watch`, which
          hot-reloads graph.json into the MCP server's memory.
  - graphify-rs: dev_tools\\graphify-watch-wrapper.ps1 -WatchMode -Repo <root>
  - repowise: Start-WatcherDetached "repowise" "repowise" @("watch", ".", "--index-only", "--debounce", "30000")
  - grepai: grepai watch --background
  - memtrace: start --headless on 127.0.0.1:50051, state at <root>/.memdb/daemon-state.json
  - persisted live state: $env:LOCALAPPDATA\\watchers\\<key>\\teardown-state.json
      { RootPids[], MemtraceStatePath, RepoRoot, WtWindowName, GrepaiPid }
      where RepoRoot = workspace root, WtWindowName = vadwatchers-<key>
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
PANE_MODULE = ROOT / "Modules" / "watcher_pane_scripts.ps1"


def _read():
    return LAUNCHER.read_text(encoding="utf-8")


def test_launcher_powershell_syntax_ok():
    # ParseFile returns diagnostics; non-empty diagnostics => syntax error.
    result = subprocess.run(
        ["pwsh.exe", "-NoProfile", "-Command",
         f"[System.Management.Automation.Language.Parser]::ParseFile"
         f"('{LAUNCHER}', [ref]$null, [ref]$null) | Out-Null; "
         f"$e=@(); [void][System.Management.Automation.Language.Parser]::ParseFile"
         f"('{LAUNCHER}', [ref]$null, [ref]$e); if($e){{exit 1}}; exit 0"],
        capture_output=True, text=True,
        creationflags=0x08000000,  # CREATE_NO_WINDOW
    )
    assert result.returncode == 0, f"PowerShell syntax check failed:\n{result.stderr}"


def test_launcher_launches_every_watcher_except_destructive_gm_watch():
    src = _read()
    # graphenium: NO `gm watch`. Its incremental writer replaced graph.json with
    # only the changed files' nodes (live-reproduced 2026-09-16), so the
    # launcher must not spawn it; the full `gm run` rebuild daemon owns the file.
    assert 'Start-WatcherDetached "gm"' not in src, (
        "The destructive `gm watch` launch must stay removed."
    )
    assert '"watch", ".", "--debounce", "3"' not in src, (
        "`gm watch . --debounce 3` must stay removed (incremental = destructive)."
    )
    # ...but the full, non-destructive rebuild must be wired instead.
    assert "function Invoke-GmSemanticBuild" in src, "gm rebuild function missing."
    assert '"--no-semantic"' in src, "gm rebuild must be AST-only (no --update)."
    # graphify-rs via the ignore-aware wrapper (CommandLine must carry 'watch').
    assert "dev_tools\\graphify-watch-wrapper.ps1" in src, "graphify-rs wrapper not referenced."
    assert "-WatchMode" in src and "-Repo" in src, "graphify wrapper missing -WatchMode -Repo."
    # repowise file watcher (index-only, debounced).
    assert 'Start-WatcherDetached "repowise"' in src, "repowise launch missing."
    assert '"watch", ".", "--index-only", "--debounce", "30000"' in src, "repowise watch args must be index-only debounced."
    # grepai tracked background watcher.
    assert "grepai watch --background" in src, "grepai must launch in tracked --background mode."
    # memtrace headless daemon + readiness port.
    assert "start --headless" in src, "memtrace must launch headless."
    assert "50051" in src, "memtrace readiness port 50051 must be referenced."


def test_launcher_spawns_grepai_supervisor():
    """The crash-restart supervisor generated in-plan step 2 must be spawned
    detached/hidden and its log path must reference supervisor.log."""
    src = _read()
    assert "vad-grepai-sup.ps1" in src, (
        "Launcher must generate/spawn the grepai supervisor script."
    )
    assert "supervisor.log" in src, (
        "Supervisor must log restarts to supervisor.log."
    )


def test_launcher_persisted_supervisor_pid():
    """Supervisor PID must survive into RootPids so teardown tree-kills it."""
    src = _read()
    assert "childProcs" in src, "Supervisor must be added to childProcs for teardown."


def test_launcher_persists_live_state_shape():
    src = _read()
    assert "teardown-state.json" in src, "Launcher must persist tracked root PIDs to teardown-state.json."
    assert "RootPids" in src, "teardown-state.json must carry RootPids."
    assert "MemtraceStatePath" in src, "teardown-state.json must carry MemtraceStatePath."
    assert "RepoRoot" in src, "teardown-state.json must carry RepoRoot."
    assert "watchers" in src, "State file must live under $env:LOCALAPPDATA\\watchers."


def test_launcher_repo_root_is_script_dir():
    src = _read()
    assert "$scriptDir = $PSScriptRoot" in src, "RepoRoot must be derived from $PSScriptRoot."


def test_launcher_defines_teardown_helpers():
    src = _read()
    assert "function Start-WatcherDetached" in src, "Start-WatcherDetached helper missing."
    # vad-uzb: New-WatcherPaneScript is DEFINED in Modules/watcher_pane_scripts.ps1
    # and CALLED from the launcher. Assert both ends. A bare substring check
    # against the launcher alone is a false green: the launcher's call-site
    # comment contains the literal text "function New-WatcherPaneScript".
    # The definition must be anchored and name-exact -- a plain substring check
    # would also accept a renamed "New-WatcherPaneScriptMUTANT" definition.
    pane_src = PANE_MODULE.read_text(encoding="utf-8")
    assert re.search(r"^function New-WatcherPaneScript\s*\{", pane_src, re.M), (
        "New-WatcherPaneScript definition missing from Modules/watcher_pane_scripts.ps1."
    )
    assert re.search(r"^[^#]*New-WatcherPaneScript\s+-Label", src, re.M), (
        "launcher does not call New-WatcherPaneScript."
    )


def test_launcher_uses_shared_sweep_pattern_module():
    """The launcher's startup sweep and the teardown module must share ONE
    sweep-pattern list (modules/watcher_patterns.ps1) so they cannot drift.
    Regression guard for the orphan-stack class: Stop-PriorLauncherInstances
    previously matched only the ###1 token and missed graphify wrappers."""
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "watcher_patterns.ps1" in content, (
        "Launcher must dot-source modules/watcher_patterns.ps1 (shared sweep list)."
    )
    module = ROOT / "modules/watcher_patterns.ps1"
    assert module.exists(), "modules/watcher_patterns.ps1 must exist."
    mtext = module.read_text(encoding="utf-8")
    assert "graphify-watch-wrapper" in mtext, (
        "Shared list must contain the dedicated graphify-watch-wrapper pattern."
    )


def test_t8_autostart_spawns_wrapper_with_watchmode():
    """tests/launcher_tests.ps1's T8 auto-start must spawn the wrapper with
    -WatchMode, matching the launcher's real invocation. A -WatchMode-less
    wrapper silently never rebuilds (behavior drift) and its CommandLine does
    not carry the sweep contract."""
    harness = ROOT / "tests" / "launcher_tests.ps1"
    htext = harness.read_text(encoding="utf-8")
    block = htext[htext.index("$graphifyWrapper = "):htext.index("Ensure-WatcherRunning 'grepai'")]
    assert "'-WatchMode'" in block, (
        "T8 auto-start must pass -WatchMode to the wrapper (matches the launcher)."
    )
