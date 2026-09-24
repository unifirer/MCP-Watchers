---
title: Launchers And Watchers
topics: [workflows]
sources:
  - id: launcher-1
    type: file
    path: "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
  - id: launcher-1-bat
    type: file
    path: "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.bat"
  - id: launcher-2
    type: file
    path: "###2.launch_pyside6_ui.ps1"
  - id: dev-tools
    type: file
    path: dev_tools/
  - id: ci
    type: file
    path: .gitlab-ci.yml
---

# Launchers And Watchers

Day-to-day work in this repository starts by running a PowerShell launcher from
the repository root. The launchers are named with a `###` prefix and a leading
number that orders them, and each one owns the lifecycle of a set of long-lived
processes rather than just starting a command. The task in this guide is to
bring the environment up correctly and tear it down without leaving orphans.

## The Launchers

`###2.launch_pyside6_ui.ps1` starts the desktop application [@launcher-2]. That
is the one to use when you only want to run VAD itself.

`###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1` is the
environment launcher, and it is the complicated one [@launcher-1]. It starts
the code-intelligence watchers and keeps them running in a single console. Its
structure is a set of named functions: `Stop-PriorLauncherInstances`,
`Write-LauncherLock` and `Remove-LauncherLock`, `Invoke-GrepaiSafe`,
`Start-WatcherDetached`, `Stop-WatcherOrphans`, `New-WatcherPaneScript`,
`Write-WatcherHeartbeat`, `Add-RecentChange`, `ScrubNulBytes`, `CleanLogLine`,
`Resolve-ChangedFiles`, `Show-ChangedFiles`, and `Get-CompleteLineCount`
[@launcher-1].

Three things about that function list are worth internalising before editing
the script. It takes a lock and kills prior instances of itself, so running it
twice is not additive — the second run terminates the first [@launcher-1]. It
launches foreground-blocking watchers detached and tails their logs itself,
which is why `CleanLogLine` and `ScrubNulBytes` exist: the consolidated output
is filtered before display [@launcher-1]. And it has an explicit orphan reaper,
`Stop-WatcherOrphans`, because detached watchers survive an ungraceful exit
[@launcher-1].

## Double-Click Wrappers

`.ps1` files do not reliably run on double-click under a Restricted execution
policy; the window can close silently. The repository's convention is a
same-named `.bat` wrapper that invokes `pwsh.exe` with
`-NoProfile -ExecutionPolicy Bypass -File`, falling back to `powershell.exe`
when `pwsh.exe` is not on `PATH` [@launcher-1-bat]. The wrapper for the
environment launcher states this reasoning in its own comments
[@launcher-1-bat]. Any new launcher meant for double-click use should copy that
exact shape rather than inventing a variant.

## The Graphenium Semantic Toggle

Graphenium's semantic analysis (LLM enrichment on top of the AST graph) has a
live on/off switch, so an operator does not have to edit the launcher and
restart it to change modes [@launcher-1].

**Control file.** `<repo>\.mcpw-provision\gm-semantic.mode`, containing `on` or
`off`. The reader is `Test-GmSemanticEnabled` in the launcher [@launcher-1]. The
mode is re-read on **every** rebuild, so a flip takes effect from the next
rebuild onward — there is no restart, and no watcher is disturbed.

**Default is off.** If the file is absent, blank, or unparseable, semantic
analysis is OFF and the rebuild is pure AST extraction. The environment variable
`MCPW_GM_SEMANTIC` supplies the launch default only when the file is absent; it
does not override a file that says `off`.

**Flipping it.** Use `dev_tools/gm-semantic-toggle.ps1`, which writes the control
file. Do not hand-edit the launcher's `--no-semantic` literal — the launcher
remains the single source of truth for that flag, and the test suite matches the
literal [@launcher-1].

**What it costs.** Semantic ON means the rebuild makes **LLM chat-completion
calls through the local fallback proxy** (`###2.llm_fallback_proxy.py`, port
11436). Semantic OFF issues no tokens and no cloud calls, and the rebuild is
cheap. The proxy gate is conditional on the mode for exactly this reason: with
semantic OFF an unreachable proxy no longer blocks the structural rebuild, which
it used to [@launcher-1].

**Constraint (mcpw-96y).** The semantic path is **chat-completions only**. It
rides the fallback proxy and **cannot** be served by an embedding model. This is
the most re-litigated dead end in this area — do not propose an embedding
endpoint for it.

**Seeing the current mode.** The graphenium pane prints a status line
(`=== graphenium | semantic: on (LLM enrichment) ===` / `off (AST-only)`) at
startup and whenever the value changes, read from the same control file, so the
pane can never disagree with what a rebuild will do [@launcher-1].

## Recovering From A Bad State

If a watcher appears dead but its port is still held, do not simply relaunch —
the lock and the prior-instance killer will fight the leftover process. Run the
launcher once so `Stop-PriorLauncherInstances` and `Stop-WatcherOrphans` clear
the previous generation, and confirm the heartbeat file is being refreshed by
`Write-WatcherHeartbeat` before assuming the watcher is live [@launcher-1].

## Dev Tools

`dev_tools/` holds the one-off diagnostics and fixups that support the above:
smoke tests for the code-intelligence servers, gateway and process inspection
scripts, `graphify-watch-wrapper.ps1`, `memtrace-mcp.ps1`, an MCP stdio proxy.
The LLM fallback proxy lives at the repo root as `###4.llm_fallback_proxy.py`.
These are operational scripts, not application code, and nothing under
`Modules/` or `UI/` imports them.

## Continuous Integration

CI is deliberately minimal. `.gitlab-ci.yml` defines two stages, `test` and
`secret-detection`, runs GitLab's `sast` job in the `test` stage, and includes
the `Security/Secret-Detection.gitlab-ci.yml` template with
`SECRET_DETECTION_ENABLED` set to `"true"` [@ci]. There is no CI job that runs
the Python test suite [@ci]. The suite is a local gate only — see
[Run the tests](run-the-tests).

Related: [Run the tests](run-the-tests), [Architecture](../architecture).
