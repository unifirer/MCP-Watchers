# modules/watcher_patterns.ps1
# SINGLE SOURCE OF TRUTH for every process sweep in the ###1 watcher stack.
# Dot-sourced by:
#   - Modules/watcher_teardown.ps1 (Stop-AllWatchers exit teardown)
#   - ###1. watchers ... .ps1 (Stop-PriorLauncherInstances startup sweep)
#   - tests/watcher_patterns.tests.ps1
# SAFE TO DOT-SOURCE: no top-level side effects.
#
# Entries: Name = process image name; Pattern = literal CommandLine substring
# to match, or '' = match EVERY process of that image name (used for
# graphify-rs.exe rebuild children, whose command line is
# `build --path . --update --no-llm` and carries NO 'watch' token).
# The 'graphify-watch-wrapper' pattern must stay DEDICATED: never glue it onto
# another pattern with '|' (see changelogs/2026-08-18-...-orphaned-graphify-watchers.md).

# mcpw-xeu.4: single source of truth for the shell host name. Every sweep site
# that keys on the pane host (teardown wrapper hosts, pane-scripts liveness,
# launcher shim-host + pane-tailer sweeps) consumes these instead of
# hardcoding 'powershell.exe' / 'pwsh.exe', so a host change is one line.
$script:WatcherPaneHostName = 'powershell.exe'
$script:WatcherShellHostNames = @('powershell.exe', 'pwsh.exe')

$script:WatcherSweepPatterns = @(
    @{ Name = 'gm.exe';          Pattern = 'watch' },
    @{ Name = 'repowise.exe';    Pattern = 'watch' },
    @{ Name = 'codegraph.exe';   Pattern = 'watch' },
    @{ Name = 'graphify-rs.exe'; Pattern = '' },                 # rebuild child: no watch token
    @{ Name = 'grepai.exe';      Pattern = 'watch' },
    @{ Name = 'memtrace.exe';    Pattern = '' },
    @{ Name = 'memcortex-daemon.exe'; Pattern = '' },
    @{ Name = 'claude-mcp.exe';  Pattern = '--port'; Persistent = $true }, # backend singleton family, never swept on takeover
    @{ Name = 'node.exe';        Pattern = 'claude-mcp-server'; Persistent = $true }, # vad-10m.1: node hosts dist/cli.js --port (never claude-mcp.exe)
    # codegraph npm shim: node.exe <cli.mjs> codegraph watch <root>. Token is
    # 'codegraph watch', NOT 'codegraph': the codegraph MCP backend runs as
    # `npx @optave/codegraph mcp --multi-repo` and must never be swept.
    @{ Name = 'node.exe';        Pattern = 'codegraph watch' },
    # codegraph REAL CLI (`npm install -g @optave/codegraph`): Resolve-CodegraphLaunch
    # re-expresses the npm bin shim as node.exe <...>\@optave\codegraph\dist\cli.js
    # watch <root>. Package path + verb, NOT the bare 'codegraph' token: the MCP
    # backend command line carries the same cli.js but ends `cli.js" mcp --multi-repo`,
    # so it cannot match this entry.
    @{ Name = 'node.exe';        Pattern = 'codegraph\dist\cli.js watch' },
    # mcpw-qxj.4: heimdall's reconciler runs as node.exe <...>/bin/heimdall.js
    # daemon. The token MUST include the verb: Toolport's heimdall MCP server is
    # the SAME heimdall.js ending in `mcp`, and sweeping it would kill the live
    # MCP backend for every session on this box. 'heimdall.js daemon' matches
    # only the reconciler.
    @{ Name = 'node.exe';        Pattern = 'heimdall.js daemon' },
    @{ Name = 'python.exe';      Pattern = 'mcp_agent_mail'; Persistent = $true }, # vad-10m.3: mail singleton (:8765), token-scoped
    @{ Name = 'python.exe';      Pattern = 'embed_server'; Persistent = $true }, # graphiti embed proxy (:8003), token-scoped
    @{ Name = 'pwsh.exe';        Pattern = 'vad-grepai-sup' },
    @{ Name = 'powershell.exe';  Pattern = 'vad-grepai-sup' },
    @{ Name = 'powershell.exe';  Pattern = 'panes\tail_' },      # WT pane tailers
    @{ Name = 'powershell.exe';  Pattern = 'graphify-watch-wrapper' }  # ignore-aware wrapper host
)

function Test-WatcherSweepMatch {
    param(
        [string]$CommandLine,
        [string]$Pattern
    )
    if ($Pattern -eq '') { return [bool]$CommandLine }   # match-all
    return ($CommandLine -and $CommandLine -match [regex]::Escape($Pattern))
}
