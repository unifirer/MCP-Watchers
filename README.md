# MCP Watchers

Standalone repository for the watcher launcher. Extracted from `J:\audio\VAD`
on 2026-09-17.

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

## Prerequisites

The launcher does not bundle the watchers it supervises. Install these
separately and keep them on `PATH`:

`memtrace`, `grepai`, `gm` (graphenium), `repowise`, `litellm`, `cerememory`,
`ollama`, `node`, `python`, and Windows Terminal (`wt.exe`).

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
