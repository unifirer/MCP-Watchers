# Launcher Drift Report — VAD vs MCP-Watchers

**Date:** 2026-09-18
**Purpose:** Determine whether MCP-Watchers' launcher can replace VAD's, and whether
VAD holds any newer fix that MCP lacks. Prerequisite for deleting VAD's copy.

## Method
All comparisons CR-stripped (VAD is CRLF, MCP is LF) to avoid whole-file false diffs.
Raw `diff` showed 4,248 changed lines; the real change set is 470 lines / 51 hunks.

## Files compared

| File | VAD | MCP | Verdict |
|---|---|---|---|
| launcher `.ps1` | 249,087 B | 256,665 B | MCP ahead on mcpw-ybs; VAD has graphiti :8002 subsystem |
| `Modules/watcher_workspace.ps1` | **absent** | 5,093 B | MCP-only new file |
| `Modules/watcher_pane_scripts.ps1` | 43,871 B | 48,487 B | MCP ahead (mcpw-qfy RC1/RC2 supersede VAD) |
| `Modules/watcher_teardown.ps1` | 9,920 B | 10,640 B | MCP ahead (mcpw-ybs.2 keyed state) |
| `Modules/watcher_patterns.ps1` | 2,558 B | 2,435 B | VAD +1 line: graphiti `mcp_proxy` (:8002) |
| `Modules/watcher_job_helpers.ps1` | 27,637 B | 27,637 B | identical |
| `Modules/watcher_log_tail.ps1` | 3,983 B | 3,983 B | identical |

## MCP-ahead changes confirmed (all mcpw-ybs / mcpw-qfy work)

1. `$watchersWorkspaceRoot` split from `$scriptDir` (mcpw-ybs.1)
2. Keyed lock dir + keyed mutexes `Global\VAD_Watchers_Launcher_$workspaceKey` (mcpw-ybs.4)
3. Attributed orphan sweep with `Test-WatchersProcessAttribution` (mcpw-ybs.2/.5)
4. `$wtWindowName = "vadwatchers-$workspaceKey"` (mcpw-ybs.3)
5. All 4 grid steps use `-d $watchersWorkspaceRoot`, zero bare `-d .` (mcpw-ybs.1)
6. Keyed teardown-state with legacy fallback (mcpw-ybs.2)
7. `mcpw-qfy RC1`: VAD never assigned `$LockFile` in the pane script, so the heal gate
   was dead and the pane always raced the supervisor heal. MCP bakes `__LOCKFILE__`.
8. `mcpw-qfy RC2`: VAD probes `CommandLine -match 'watch'` for graphene rebuild; never
   true post-a8107e24. MCP probes `'serve'` + launcher-lock fallback with PID/StartTime
   anti-reuse guards.
9. `Test-GrepaiIdleMarker`: idle-reaped watcher shows IDLE and must not heal.

## VAD-only content — analysed, none is a newer fix

### A. Superseded mcpw-ybs work (safe to drop)
`Set-Location -LiteralPath $scriptDir`, unkeyed `Global\VAD_Watchers_Launcher`,
`Global\VAD_Watchers_Takeover`, `$wtWindowName = "vadwatchers"`, 4x `-d '.'`,
`$tdDir = watchers` (unkeyed), `$logsDir`/`$wtPaneDir` unkeyed, `-RepoRoot $scriptDir`.

### B. graphiti MCP proxy :8002 — DELIBERATELY SUPERSEDED, not a fix to preserve
VAD spawns `mcp_proxy.py` as a Python child (`$graphitiMcpJobScript`,
`Start-GraphitiMcpBackend`, `Test-GraphitiPort`). MCP removed this and documents why:

> "graphiti-mcp runs as a Docker container (restart: always, native HTTP on ...)
>  ... The launcher no longer spawns it."
> "Graphiti MCP :8002 not listening - start the Docker container
>  (docker start graphiti-mcp). The launcher no longer spawns it."

**Live proof the Docker path is the current one:**
```
graphiti-mcp   Up About an hour (healthy)   0.0.0.0:8002->8000/tcp
```
:8002 is served by the healthy Docker container. VAD's launcher still tries to spawn a
Python proxy onto the same port. **VAD's code path is stale and would conflict.**

### C. Genuinely VAD-specific — RESOLVED
- `watcher_patterns.ps1`: `python.exe` / `mcp_proxy` Persistent entry for :8002.
  Becomes dead once graphiti is Docker-managed. MCP omits it. **Correctly obsolete.**
- `Enable-GrepaiOllamaPortFix` — **NOT missing from MCP.** Present at
  `###1.watchers...ps1:667` with Pester coverage (`tests/launcher_tests.ps1` T12,
  lines 1219/1313/1335). Body diffed line-for-line against VAD's: **IDENTICAL**.
  It appeared in the VAD-only list only because line offsets shifted.
- `$hbTimeoutSec = 8` — MCP replaces the timeout model; MCP's pane comment cites the
  same 8s controller timeout. No fix lost.

**Conclusion: no VAD-only item is a newer fix. The drift is strictly one-directional.**

## Risk if VAD's launcher is overwritten blindly
1. Loses graphiti :8002 spawn path — **desirable**, it conflicts with the Docker container.
2. Loses `Enable-GrepaiOllamaPortFix` — **unknown impact**, MCP lacks it.
3. Loses the `mcp_proxy` sweep pattern — harmless once graphiti is Docker.
4. Deletes `Modules/graphiti/mcp_proxy.py`, `config-litellm.yaml` if VAD's Modules are
   pruned — these are still present in VAD and may be referenced elsewhere.

## Backup taken
`J:\audio\MCP-Watchers\temp\vad-backup-2026-09-18-0819\` with `SHA256SUMS.txt`.
Launcher hash `d6f2606ac5d1cd816db827ec9c8be02f0d229fe1f51241cc56df2586011015b8`.
Restoration is provable.

## Open question before proceeding — RESOLVED
`Enable-GrepaiOllamaPortFix` exists in MCP and is byte-identical to VAD's. It is not a
missing fix. No blocker remains on the "does VAD hold anything newer" question.

## Deterministic gate — REPRODUCED
Ran `temp\_gate.bat` (2026-09-18 08:2x). This gate is deliberately built to exclude any
suite that launches the launcher, opens a Windows Terminal window, or starts a daemon.

```
watcher_patterns.tests.ps1                 EXIT=0
watcher_log_tail.tests.ps1                 EXIT=0
backend_sweep_safety.tests.ps1             EXIT=0
launcher_final_window.tests.ps1            EXIT=0
launcher_sweep_attribution.tests.ps1       EXIT=0
launcher_lock_keying.tests.ps1             EXIT=0
launcher_grid_reset_attribution.tests.ps1  EXIT=0
launcher_window_name_keying.tests.ps1      EXIT=0

PASS [+] markers : 158
FAIL [-] markers : 0
non-zero EXITs   : 0
```

This independently confirms the brief's "158/158 markers, 0 failures" claim.

Safety property directly relevant to VAD coexistence:
`launcher_grid_reset_attribution.tests.ps1` contains the marker
**"SKIPS a tailer at the legacy UN-KEYED pane dir (VAD Tier A today)"** — the suite
explicitly asserts that a keyed launcher leaves an unkeyed (current VAD) pane tailer
alone. Coexistence with VAD's present layout is a tested property, not an assumption.

## Syntax parse sweep — CLEAN
All 7 relevant files parse with zero errors via `[Parser]::ParseFile`:
both launchers, both `watcher_pane_scripts.ps1`, both `watcher_teardown.ps1`,
and MCP's `watcher_workspace.ps1`.

## Key derivation — VERIFIED BY EXECUTION
Ran the real module (`Modules\watcher_workspace.ps1`):

| Input path | Derived key |
|---|---|
| `J:\audio\VAD` | **77442b14** ✅ matches plan |
| `J:\audio\MCP-Watchers` | **ad90e3fb** ✅ matches plan |
| `J:\audio\VAD\` (trailing sep) | 77442b14 (normalized) |
| `J:\AUDIO\VAD` (uppercase) | 77442b14 (normalized) |
| `J:/audio/VAD` (forward slash) | **75bac9a2** — NOT normalized |

Repeat-call stability: `run1=77442b14 run2=77442b14 stable=True`.

**Latent trap (not fixed, not asked):** the normalizer lowercases and trims trailing
separators but does NOT convert `/` to `\`. The launcher passes
`(Get-Location).ProviderPath`, which is always backslash on Windows, so this is safe in
practice. A caller passing a forward-slash path would silently get a different key.

## Blocking decision for the operator
Overwriting VAD's launcher removes its graphiti :8002 spawn path. That path is **already
obsolete** (Docker container `graphiti-mcp` owns :8002 and is healthy), so the change is
a cleanup rather than a regression. It is still a behavioural change to a live stack.

Two ways forward, both needing operator sign-off:
1. **Full port** — replace VAD's launcher with MCP's and drop the graphiti :8002 spawn
   path. VAD then matches MCP-Watchers exactly.
2. **Surgical port** — apply only the mcpw-ybs/mcpw-qfy hunks to VAD's launcher, keeping
   its graphiti subsystem untouched. More churn, preserves VAD's current graphiti logic.

Recommendation: option 1. The Docker container already serves :8002, so VAD's spawn path
cannot work; keeping it invites a port conflict on VAD's next launch.

