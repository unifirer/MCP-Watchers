# Code Review: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`

- **Date:** 2026-09-06
- **Scope:** Memory leaks and optimization opportunities (static scan, 3,549 lines)
- **Verdict:** No crash-level leaks in the main pane tailers (the 2026-09-06 incremental log reader and the 500-entry `recentChanges` cap hold). But one **dead-on-arrival thread job**, one **un-fixed variant of the old log-read leak**, and several unbounded-growth / churn sources remain.

---

## P1 — Findings that break features or leak at scale

### 1. The live-incremental gm semantic build thread job never runs (lines 1661–1679)
The scriptblock puts statements (`try { Invoke-GmSemanticBuild ... }`) **before** `param($State, $BuildFn)`. PowerShell parses this, but at runtime `param` is treated as an unknown command and the scriptblock terminates immediately (verified: `The term 'param' is not recognized as a name of a cmdlet...`). Consequences:
- `-ArgumentList $global:gmSemState, ${function:Invoke-GmSemanticBuild}` never binds; the FSW-fed `Changed` flag has no consumer.
- The warm-up call inside the job would also fail: thread jobs inherit no script-scope vars (`$scriptDir`, `$gmRunLog` are undefined there) and the function is not defined in the job's runspace (that was the whole point of passing it via `${function:...}`).
- Net effect: the entire "LIVE INCREMENTAL semantic build" feature silently does nothing; only job-failure warnings (discarded, never `Receive-Job`-ed) hint at it.

**Fix:** make `param($State, $BuildFn)` the first statement, drop the inline warm-up (or route it through `$BuildFn` with explicit paths passed as arguments), and log job failure via `Receive-Job`/a state flag instead of relying on discarded job output.

### 2. Fallback combined tailer still re-reads every log in full, every 500 ms (lines 3426–3473)
The pane tailers were fixed on 2026-09-06 to use incremental byte offsets (`Read-WatcherLogTail`), but the `if (-not $wtOk)` fallback loop kept the old pattern: `Get-Content -LiteralPath $s.Path` on **up to 7 files every 500 ms**, full content each time. Same symptom class the pane fix described: whole-file array churn and CPU burn that grows with log size. A long fallback session on this repo will reproduce the 4 GB-class growth the pane fix removed.

**Fix:** reuse `Read-WatcherLogTail` with per-stream byte offsets here too (rotation/truncation is already handled by its `Rotated` flag).

### 3. Watcher logs grow without bound during a session
`gm.log`, `gm-semantic-build-run.log`, `repowise.log`, `litellm-proxy.log`, `supervisor.log`, `autoheal.log` are append-forever. The pane reader already tolerates rotation (`Rotated` flag), but nothing rotates. A multi-day session can push multi-GB logs on `C:\Temp`.

**Fix:** add a size-cap check in the supervisor loops (e.g. when a log exceeds N MB, truncate/rotate it; the tailers recover via the `Rotated` path).

---

## P2 — Growth / churn risks

### 4. grepai crash-restart supervisor has no backoff (lines 973–1012)
On a permanently broken grepai (e.g. a crash the gob repair cannot fix), the supervisor restarts roughly every 8 s forever: process churn plus unbounded `supervisor.log` growth. Contrast: the memtrace heal job already backs off 10 minutes after 5 failures (lines 2056–2064). Copy that backoff pattern.

### 5. FileSystemWatcher event queue and buffer
- Launcher gm-sem FSW (lines 1629–1637) and each pane FSW (lines 2698–2710) use the default ~4 KB `InternalBufferSize`. On churn-heavy operations (git checkout, npm install inside the repo) the buffer overflows; `InternalBufferOverflowException` is swallowed, events are **dropped**, and `recentChanges` can miss the file the user actually edited.
- `Register-ObjectEvent -Action` handlers run on an unbounded PowerShell event queue. A burst of tens of thousands of events queues faster than the runspaces drain it — transient memory spike in the launcher process.

**Fix:** set `InternalBufferSize = 65536` on each FSW, and prefer a `ConcurrentQueue` filled by the event actions and drained inside the existing 500 ms poll loop, instead of per-event Action runspaces.

### 6. Pipe-deadlock ordering + undisposed `Process` objects (repeated pattern)
`Invoke-GrepaiSafe` (327–353), `Get-GrepaiStatusText` (365–384), `Repair-CorruptGobIndex` (904–935), and the pane health check (2977–2989) all call `WaitForExit` **before** `ReadToEnd`. If a child writes more than the ~4 KB pipe buffer, the child blocks on write, `WaitForExit` times out, and the process is killed — so `grepai status` corruption detection silently fails exactly when the status output is large. `Invoke-GrepaiSafe` additionally never drains stderr at all. None of them call `$proc.Dispose()` (handle leak until GC).

**Fix:** read both streams (async `ReadToEndAsync()` or read-before-wait) and `Dispose()` the `Process` in a `finally`.

---

## P3 — Dead code and micro-optimizations

| Location | Issue |
|---|---|
| 327–353 | `Invoke-GrepaiSafe` is never called (grep: only the definition). Dead code; also has the stream bugs above. |
| 2415–2470 | Launcher-level `Invoke-GrepaiHealthCheck` is never called at runtime (the pane uses its own embedded copy). Verify no test depends on it, then delete or extract to the shared module. |
| 1597–1602 vs 1656–1660 | `$global:gmSemState` is defined twice; the second overwrites the first and loses `PopupShown`. Consolidate to one definition. |
| 1610–1614 | `$global:gmSemanticLive/Changed/LastBuild`, `$gmSemDebounceSec`, `$gmSemMaxStaleSec` are dead — the real loop uses the state object and its own locals. |
| 1169 / 1173 | Duplicate `$errLog = "$LogFile.err"`. |
| 296–302 | `Test-PortHeldByLauncherDaemon` is called inside the wait loop and again unconditionally right after — one redundant probe per auto-heal. |
| 1501–1534, 1211–1221 | `Ensure-LlmProxyRunning` / `Test-LlmProxyReady` use `Test-NetConnection` per iteration (slow, emits warnings). The raw `TcpClient` probe already used elsewhere (lines 1926–1932) is faster and silent. |
| 2544–2550 + 3075 | The grepai pane has no tracked PID, so `Test-GrepaiWatcherAlive` runs a CIM `Win32_Process` query **every 500 ms, forever** (~172k WMI queries/day). Liveness only needs ~5 s resolution (grace is 30 ticks); throttle the CIM probe to every N ticks, or do a cheap `Get-Process -Name grepai` first and CIM only for CommandLine disambiguation. |
| 2629, 3508–3535 | Heartbeat: 4 panes × 2 writes/s plus the controller reading 4 files/s. A 2 s write interval (timeout is 8 s) cuts the churn 4× with no detection-latency cost. |
| 2683–2690 | `Add-RecentChange` trims by sorting the whole table on every event once above the 500 cap. Fine at 500; if raised, trim lazily instead. |
| 607–617 vs 489–496 | Two different Ollama probes: the startup gate hardcodes port 12134 while `Test-OllamaRunning`/`Get-GrepaiOllamaTarget` use the configured endpoint. A config pointing elsewhere causes a redundant `ollama serve` spawn attempt. Unify on `Get-GrepaiOllamaTarget`. |
| Startup path | Readiness gates run sequentially (grepai up to ~55 s, litellm 20 s, Ensure-LlmProxyRunning 15 s × 2, Ollama 20 s). The already-parallel ones (memtrace/cerememory/mail) show the pattern works; the grepai ready-wait and Ollama wait can overlap. |

---

## Things that are already correct (verified, do not "fix")
- Incremental byte-offset pane log reads (`Read-WatcherLogTail`, leak fix 2026-09-06) and the 500-entry `recentChanges` cap.
- Launcher single-instance design (FileStream gate + mutex + PID liveness + stale-break).
- Per-panes liveness guards: tracked-PID panes use cheap `Get-Process` and only fall back to CIM when the PID is dead.
- Memtrace heal supervisor's backoff after 5 consecutive failures.

## Suggested order of work
1. Fix the semantic-build thread job (`param` first, wire `Receive-Job`-style failure visibility) — restores a whole feature.
2. Port the incremental tailer to the fallback loop — removes the last big leak.
3. Log size-cap rotation in the three supervisor loops.
4. Throttle grepai pane CIM probe + heartbeat interval.
5. Dead-code sweep + `Process.Dispose` + stream-read ordering.
