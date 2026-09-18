"""Static guards for bead VAD-v14z.2 (launcher worktree quoting + heal logging).

These tests read the launcher source (plus the shared watcher job helpers
module for the liveness helper, vad-0si); they spawn no processes. They pin the
two fixes from VAD-v14z.2:

  (a) the `git ... worktree remove` call passes a QUOTED worktree path, so a
      path containing spaces cannot split into extra git arguments.
  (b) heal/repair path catches surface `$_.Exception.Message` instead of
      swallowing the error silently.
  (c) no unquoted `$wt` path is passed as a bare git argument.

Companion gate: tests/test_launcher_watchers_contract.py runs a pwsh AST parse
of the same file, so a syntax error introduced by these edits fails the gate.
"""
import re
from pathlib import Path

ROOT = Path(__file__).parent.parent
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
MODULE = ROOT / "Modules" / "watcher_job_helpers.ps1"
PANE_MODULE = ROOT / "Modules" / "watcher_pane_scripts.ps1"


def _read():
    return LAUNCHER.read_text(encoding="utf-8")


def _region(src, start, end):
    i = src.index(start)
    j = src.index(end, i)
    return src[i:j]


def test_worktree_remove_passes_quoted_path():
    src = _read()
    assert 'worktree remove "$wt" --force 2>$null' in src, (
        "worktree remove must pass a quoted worktree path."
    )
    assert "worktree remove $wt " not in src, (
        "an unquoted worktree path in `worktree remove` splits on spaces."
    )


def test_git_path_operands_are_quoted():
    src = _read()
    # Every `git -C <path>` form must quote the path operand.
    assert not re.search(r"git -C \$", src), (
        "found an unquoted `git -C $path` operand."
    )
    # mcpw-759: commit 026765e re-rooted the repository-scoped paths from
    # $scriptDir to $watchersWorkspaceRoot. This pin tracked the old root.
    assert (
        'git -C "$watchersWorkspaceRoot" rev-parse --show-toplevel 2>$null' in src
    )
    assert 'git -C "$gitRoot" worktree list --porcelain 2>$null' in src
    assert 'git -C "$wt" rev-parse HEAD 2>$null' in src
    assert 'git -C "$wt" status --porcelain 2>$null' in src
    assert 'git -C "$wt" rev-parse --abbrev-ref HEAD 2>$null' in src
    assert 'git -C "$gitRoot" worktree prune 2>$null' in src


def test_no_unquoted_wt_bare_argument():
    src = _read()
    for line in src.splitlines():
        if "git" not in line or "$wt" not in line:
            continue
        assert '"$wt"' in line, f"unquoted $wt git argument: {line.strip()}"


def test_heal_path_catches_surface_exception_message():
    src = _read()
    pane_src = PANE_MODULE.read_text(encoding="utf-8")
    regions = {
        "ollama-port-heal": (
            src,
            "function Enable-GrepaiOllamaPortFix",
            "function Test-OllamaRunning",
        ),
        "port-owner-heal": (
            src,
            "function Test-PortHeldByLauncherDaemon",
            "function Exit-IfPortHeldByLauncherDaemon",
        ),
        "worktree-prune-heal": (
            src,
            "# Layer 1: Prune fully-merged stale worktrees",
            "# --- Log directory + paths",
        ),
        # vad-uzb: the pane heal moved to Modules/watcher_pane_scripts.ps1.
        "pane-grepai-heal": (
            pane_src,
            "function Invoke-GrepaiHealthCheck",
            'Write-Host "=== __LABEL__ live log ===',
        ),
    }
    for name, (haystack, start, end) in regions.items():
        block = _region(haystack, start, end)
        assert "$_.Exception.Message" in block, (
            f"{name} still swallows heal-path errors silently."
        )
    # vad-0si: the liveness helper now lives in the shared module; the
    # supervisor gets it via dot-source (fresh runspace inherits nothing).
    # Pin the canonical body in the module, not an inline copy.
    module_src = MODULE.read_text(encoding="utf-8")
    assert "function Test-LauncherAlive" in module_src, (
        "shared module must define Test-LauncherAlive."
    )
    assert "$_.Exception.Message" in module_src, (
        "launcher-supervisor-heal still swallows heal-path errors silently."
    )
    sup_start = src.index("$supervisorScript = {")
    sup_spawn = re.search(r"Start-(?:ThreadJob|Job)\s+-ScriptBlock", src[sup_start:])
    assert sup_spawn, "no supervisor job spawn found."
    sup_block = src[sup_start:sup_start + sup_spawn.start()]
    assert ". $JobHelpersModule" in sup_block, (
        "supervisor must dot-source the shared module for Test-LauncherAlive."
    )
    assert "function Test-LauncherAlive" not in sup_block, (
        "supervisor still embeds an inline Test-LauncherAlive copy."
    )


def test_named_heal_cmdlets_are_not_silently_caught():
    src = _read()
    # Heal sites that wrap netsh / Get-NetTCPConnection / Get-CimInstance must
    # log, not swallow. Check the two cmdlet-dense priority regions have no
    # empty catch left.
    for start, end in [
        ("function Enable-GrepaiOllamaPortFix", "function Test-OllamaRunning"),
        ("function Test-PortHeldByLauncherDaemon", "function Exit-IfPortHeldByLauncherDaemon"),
    ]:
        block = _region(src, start, end)
        assert "} catch {}" not in block, f"silent catch remains in {start}"
        assert "} catch { }" not in block, f"silent catch remains in {start}"
