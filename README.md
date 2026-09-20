# MCP-Watchers

Standalone repository for the watcher launcher. Extracted from `J:\audio\VAD`
on 2026-09-17. Renamed from `MCP Watchers` to `MCP-Watchers` the same day.

Repo: `J:\audio\MCP-Watchers`
Issue tracker: beads, database `mcpw`, server mode on `127.0.0.1:43413`.
Issues are named `mcpw-<hash>`.

The launcher opens a four-pane Windows Terminal grid. Each pane tails the live
log of one MCP service:

| Pane | Service | Port |
|------|---------|------|
| TL | grepai | - |
| BL | graphify-rs | - |
| TR | graphenium | - |
| BR | repowise | - |

The launcher also supervises the backends:

| Service | Port |
|---------|------|
| cerememory | 8420 |
| litellm (LLM fallback proxy) | 4000 |
| mcp-agent-mail | 8765 |
| claude-mcp | 8080 |
| memtrace | 3030 |
| graphiti embed proxy | 8003 |

`graphiti-mcp` (:8002) is a Docker container (`restart: always`, native HTTP
container :8000 -> host :8002). Toolport reaches it at
`http://127.0.0.1:8002/mcp`. The launcher does not spawn or supervise the
container. It still depends on the host embed proxy (:8003), litellm (:4000)
and FalkorDB (:6379) via `host.docker.internal`.

Toolport talks to the container's HTTP endpoint directly. The former host-side
MCP proxy (`mcp_proxy.py`, :8004) existed to pin the docker `Mcp-Session-Id`
for a stateless client. It was retired on 2026-09-20: an isolated probe showed
Toolport 1.18.0 negotiates the session id itself and connects straight to
:8002 (13 tools). The launcher no longer spawns or supervises it, the
`MCPHttpWatchdog` target for :8004 was removed, and the `GraphitiProxy8004`
scheduled task is disabled.

## Layout

```
###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1   entry point
###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.bat   double-click wrapper
###2.llm_fallback_proxy.py                                             litellm fallback proxy
Modules\watcher_job_helpers.ps1                                        parent-death jobs
Modules\watcher_log_tail.ps1                                           incremental log reader
Modules\watcher_pane_scripts.ps1                                       pane script builder
Modules\watcher_patterns.ps1                                           regex patterns
Modules\watcher_teardown.ps1                                           tree-kill and sweep
tests\                                                                 25 Pester suites, 17 Python tests
docs\                                                                  guides, reviews, plans, changelogs
```

The graphiti glue is install-resident, not repo code. `embed_server.py`
(:8003) is resolved from the graphiti-mcp install tree at runtime:
`%LOCALAPPDATA%\Programs\graphiti-mcp\mcp_server\embed_server.py`. The former
shared copy (`J:\audio\shared\graphiti`) was retired on 2026-09-20 - it was a
byte-identical duplicate of the install copy and has been deleted.
`mcp_proxy.py` (the old :8004 adapter) is also retired and unused since
2026-09-20 (see above).

## Run

Double-click the `.bat`, or run the `.ps1` directly:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
```

The launcher is a single-instance program. A second launch exits silently while
the first one holds the lock.

## Workspace root

The launcher watches the **current working directory**. The Windows Terminal
panes open with `-d .`, so every pane, indexer, and log directory resolves
against the directory the launcher started in.

This makes the tool reusable across repositories. To watch another repository,
place a shortcut in that repository and set the shortcut's *Start in* field to
the repository root. Do not copy the `.ps1` itself.

`$env:VAD_WORKSPACE_ROOT` is an optional fallback. The launcher uses it only to
locate `Modules\watcher_*.ps1` when the module folder is not next to the
launcher. Leave it unset for normal use.

## MCP provisioning

The launcher provisions six MCPs in whatever repository it is launched from,
before any watcher spawns: `graphenium`, `repowise`, `graphify-rs` (optional),
`graft`, `memtrace`, `grepai`. It creates the per-repo artifacts each server
needs — workspace config, wiring graph, store membership, vector index. It does
not install the tools; see Prerequisites.

Two modules split the job:

- `Modules\watcher_mcp_detect.ps1` — the read side. `Test-<Mcp>Initialized`
  answers "is this repo already provisioned?" and
  `Get-McpInitializationReport` prints one row per MCP.
- `Modules\watcher_mcp_provision.ps1` — the write side. Walks
  `Get-McpProvisionPlan` in order and invokes each tool.

It is idempotent. Each completed step is recorded in `.mcpw-provision/state.json`
at the repo root (gitignored, regenerable), so a second launch runs no tool and
costs well under a second. `-Force` re-runs everything. Every step is gated on a
detection probe both before and after its command, so a tool that exits 0 without
producing its artifact is reported as skipped rather than recorded as provisioned.

A provisioning problem never aborts the launch: a missing binary, an
unsatisfiable probe or a failed command degrades to a logged `skipped` row and
the launcher continues with the remaining steps.

## Prerequisites

The launcher does not bundle the watchers it supervises. Install these
separately and keep them on `PATH`:

`memtrace`, `grepai`, `gm` (graphenium), `repowise`, `codegraph`, `litellm`, `cerememory`,
`ollama`, `node`, `python`, and Windows Terminal (`wt.exe`).

`codegraph watch` is opt-in freshness only: `codegraph build` creates
`.codegraph/graph.db` once and every query works without the watcher (data just
goes stale). The launcher runs `codegraph watch <root>` headless when `codegraph`
is on PATH; otherwise it warns and continues. If the graph looks stale, run
`codegraph build` (or `codegraph update <files>`) manually.

Three install shapes are handled. A native `codegraph.exe` is spawned directly.
An npm bin shim of the **real CLI** (`npm install -g @optave/codegraph`) is not a
PE image, so it is re-expressed as `node.exe <cli.js> <args>` - the launcher parses
the shim and expands its `%dp0%` entrypoint rather than hardcoding a package path.
A **declick adapter shim** (`~/.declick/bin/codegraph`, created by wrapping the
codegraph MCP server) is re-expressed as `node.exe <run.mjs> codegraph <args>`.
That adapter exposes only the MCP query surface and has **no `watch` verb**
(verified 2026-09-19: 35 verbs, none of them watch/build/update - `codegraph watch .`
returns `unknown verb watch` and exits 2), so the launcher warns and skips instead of
registering a dead PID. `PATH` must resolve the real shim first;
`J:\Programs\npm-global` (index 58) already precedes `~/.declick\bin` (index 95) here.
On a box where the real CLI is missing, the adapter shim owns the bare name and
`codegraph build` fails with `unknown verb build` - install the real CLI to fix it.
A stale shim whose entrypoint no longer exists is refused rather than spawned.

## Tests

Pester gate (canonical, no pytest needed):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_launcher_tests.ps1
```

Exit code 0 means all checks pass.

Python shims:

```powershell
cd tests
python -m pytest -c pytest.ini test_launcher.py -q
```

`tests\pytest.ini` is intentionally minimal. It does not inherit the VAD audio
suite configuration. Some tests skip when a service such as grepai is not
running. That is by design. Do not start a service just to make a test run.

## Origin

Source: `J:\audio\VAD`, revision of 2026-09-17. The first commit is a verbatim
copy. See `docs\` for the extraction plan, the prior code reviews, and the
change log.
