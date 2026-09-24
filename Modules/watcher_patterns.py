"""Port of Modules/watcher_patterns.ps1 - bead mcpw-xeu.2.

SINGLE SOURCE OF TRUTH for every process sweep in the ###1 watcher stack.
Dot-sourced (PowerShell) by:
  - Modules/watcher_teardown.ps1 (Stop-AllWatchers exit teardown)
  - ###1. watchers ... .ps1 (Stop-PriorLauncherInstances startup sweep)
  - tests/watcher_patterns.tests.ps1

SAFE TO IMPORT: no top-level side effects.

Entries: name = process image name; pattern = literal CommandLine substring to
match, or '' = match EVERY process of that image name (used for graphify-rs.exe
rebuild children, whose command line is `build --path . --update --no-llm` and
carries NO 'watch' token). The 'graphify-watch-wrapper' pattern must stay
DEDICATED: never glue it onto another pattern with '|' (see
changelogs/2026-08-18-...-orphaned-graphify-watchers.md).

TWO REPRESENTATIONS EXIST UNTIL THE LAUNCHER IS PORTED. The PowerShell module is
still live and is still what the launcher dot-sources, so this file duplicates a
safety-critical table. tests/test_ported_leaf_modules.py cross-checks the two
against each other on every run, so a divergence fails the gate instead of
silently weakening the sweep. Delete this caveat only when the .ps1 is retired.

Fidelity notes, each verified against the live .ps1 rather than assumed:
  - PowerShell `-match` is CASE-INSENSITIVE by default, and the pattern is run
    through [regex]::Escape first, so the test is a case-insensitive literal
    substring, not a regex. test_watcher_sweep_match reproduces that.
  - `if ($Pattern -eq '') { return [bool]$CommandLine }` means an empty pattern
    matches every process EXCEPT an unattributable one: an empty command line is
    still False.
"""
from typing import NamedTuple


# mcpw-xeu.4: single source of truth for the shell host name. The sweep table
# below IS the definition site (entries stay literal so the equivalence test
# can parse the .ps1), and every other sweep site consumes these constants.
WATCHER_PANE_HOST_NAME = "powershell.exe"
WATCHER_SHELL_HOST_NAMES = ("powershell.exe", "pwsh.exe")


class SweepPattern(NamedTuple):
    """One sweep rule. `persistent` mirrors the PowerShell `Persistent = $true`."""

    name: str
    pattern: str
    persistent: bool = False


WATCHER_SWEEP_PATTERNS = (
    SweepPattern("gm.exe", "watch"),
    SweepPattern("repowise.exe", "watch"),
    SweepPattern("codegraph.exe", "watch"),
    SweepPattern("graphify-rs.exe", ""),  # rebuild child: no watch token
    SweepPattern("grepai.exe", "watch"),
    SweepPattern("memtrace.exe", ""),
    SweepPattern("memcortex-daemon.exe", ""),
    # backend singleton family, never swept on takeover
    SweepPattern("claude-mcp.exe", "--port", persistent=True),
    # vad-10m.1: node hosts dist/cli.js --port (never claude-mcp.exe)
    SweepPattern("node.exe", "claude-mcp-server", persistent=True),
    # codegraph npm shim: node.exe <cli.mjs> codegraph watch <root>. Token is
    # 'codegraph watch', NOT 'codegraph': the codegraph MCP backend runs as
    # `npx @optave/codegraph mcp --multi-repo` and must never be swept.
    SweepPattern("node.exe", "codegraph watch"),
    # codegraph REAL CLI (`npm install -g @optave/codegraph`):
    # Resolve-CodegraphLaunch re-expresses the npm bin shim as
    # node.exe <...>\\@optave\\codegraph\\dist\\cli.js watch <root>. Package path +
    # verb, NOT the bare 'codegraph' token: the MCP backend command line carries
    # the same cli.js but ends `cli.js" mcp --multi-repo`, so it cannot match.
    SweepPattern("node.exe", "codegraph\\dist\\cli.js watch"),
    # mcpw-qxj.4: heimdall's reconciler runs as node.exe <...>/bin/heimdall.js
    # daemon. The token MUST include the verb: Toolport's heimdall MCP server is
    # the SAME heimdall.js ending in `mcp`, and sweeping it would kill the live
    # MCP backend for every session on this box. 'heimdall.js daemon' matches
    # only the reconciler.
    SweepPattern("node.exe", "heimdall.js daemon"),
    # mcpw-qxj.3: graftd.exe is heimdall's Graft backend daemon, started detached
    # by the launcher (the ONE supervised starter). Match by IMAGE NAME with an
    # empty pattern (same shape as graphify-rs.exe), NOT by a 'graft' token: the
    # two unrelated programs also called "graft" -- the npm `graft` CLI and this
    # repo's graft MCP -- both run as node.exe, so an image-name match on
    # graftd.exe can never reach them (see the qxj.6 invariant test).
    SweepPattern("graftd.exe", ""),
    # vad-10m.3: mail singleton (:8765), token-scoped
    SweepPattern("python.exe", "mcp_agent_mail", persistent=True),
    # graphiti embed proxy (:8003), token-scoped
    SweepPattern("python.exe", "embed_server", persistent=True),
    SweepPattern("pwsh.exe", "vad-grepai-sup"),
    SweepPattern("powershell.exe", "vad-grepai-sup"),
    SweepPattern("powershell.exe", "panes\\tail_"),  # WT pane tailers
    SweepPattern("powershell.exe", "graphify-watch-wrapper"),  # ignore-aware wrapper host
)


def test_watcher_sweep_match(command_line, pattern):
    """Does `command_line` match one sweep `pattern`?

    Port of Test-WatcherSweepMatch. The comparison is a case-insensitive literal
    substring, because PowerShell `-match` is case-insensitive and the pattern is
    escaped first. An empty pattern is match-all for a non-empty command line;
    an empty command line never matches anything, including an empty pattern.
    """
    if pattern == "":
        return bool(command_line)
    if not command_line:
        return False
    return pattern.lower() in command_line.lower()
