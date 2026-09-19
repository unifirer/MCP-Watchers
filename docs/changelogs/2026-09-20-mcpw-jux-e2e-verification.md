# mcpw-jux — end-to-end verification of the memtrace launcher/proxy repair

Date: 2026-09-20 (Pacific/Auckland, +1200)
Verifier: verification sub-agent (team-lead session; no team tools available — all checks run directly)
Box: Windows 11 Pro, Git Bash, `J:\audio\MCP-Watchers`
Bead: `mcpw-jux` (left **open** — see Verdict)

## Scope

Prove at runtime that the six committed changes work:

- `27e8fc3` / `864ddaf` / `d0e034e` — launcher passes `--workspace <manifest>` + runs with
  cwd = the manifest's directory, at BOTH start sites (`Start-MemtraceHidden` ~3342/3410,
  `Restart-MemtraceDaemon` ~3664-3673)
- `165e967` — nested `.memdb` documented as intentionally retained
- `e2ed191` — `memtrace_mcp_cwd_proxy.py` fails fast when the mcp child exits immediately
- `5d176e2` — proxy serves WSL agent roots under the union scope

## Verdict

| # | Check | Result |
|---|-------|--------|
| 1 | Launcher start succeeds, no new `PERMANENT FAILURE` | **PASS** for the repair-specific criterion; **NOT PROVEN** that the launcher's own daemon binds |
| 2 | `:50051` owner + 8-member union scope | **PASS** |
| 3 | `memtrace mcp` attaches (handshake, not timeout) | **FAIL** |
| 4 | A real `tools/call` served live | **FAIL** |
| 5 | Regression gates | **PASS** (heal 5/5; canonical gate PASS=149 FAIL=0, rc=0) |

Checks 3 and 4 fail on a *different* fault than the one this repair fixed. `mcpw-jux` is left **open**.

---

## Check 1 — Launcher start / no new PERMANENT FAILURE — PASS (repair behaviour proven)

**Before snapshot** (2026-09-20 05:31:25):
```
.memdb/autoheal.log size=4540 mtime=2026-09-19 23:50:52.710923200 +1200
last line: [2026-09-19T23:50:52] relaunched 'memtrace start --headless' via ... (cwd=J:/audio/MCP-Watchers, child pid=53112)
PERMANENT FAILURE count: 3
```

**Launcher run**: started 05:41:03 from `J:\audio\MCP-Watchers` via
`& '.\###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'`.
Launcher stdout:
```
Starting Memtrace index for repo root (background; modules-level index removed)...
[memtrace AUTO-HEAL] killing stale daemon PID 11164 (memcore-server holding port 50051...
[memtrace AUTO-HEAL] port 50051 is now free - proceeding with launch.
Memtrace auto-heal supervisor spawned (job 22) - log: J:\audio\MCP-Watchers\.memdb\autoheal.log
Starting Cerememory backend (background)...
Starting Claude MCP Server (background)...
```

**After snapshot**: `.memdb/autoheal.log size=5152 mtime=2026-09-20 05:41:58`. New lines:
```
[2026-09-20T05:39:26] memtrace auto-heal supervisor started (ports 50051 + 3030, poll 30s)
[2026-09-20T05:39:28] memtrace down (memdb:50051) fail#1 - healing (stop clears stale lock, then start)
[2026-09-20T05:39:54] relaunched 'memtrace start --headless --workspace C:\Users\yuni\.config\memtrace\workspace.toml' via C:\nvm4w\nodejs\node.exe (absolute=True, cwd=C:\Users\yuni\.config\memtrace, child pid=75816)
[2026-09-20T05:41:56] memtrace auto-heal supervisor started (ports 50051 + 3030, poll 30s)
[2026-09-20T05:41:57] memtrace down (memdb:50051) fail#1 - healing (stop clears stale lock, then start)
[2026-09-20T05:42:06] relaunched 'memtrace start --headless --workspace C:\Users\yuni\.config\memtrace\workspace.toml' via C:\nvm4w\node.exe (absolute=True, cwd=C:\Users\yuni\.config\memtrace, child pid=25944)
...
[2026-09-20T05:50:13] relaunched 'memtrace start --headless --workspace ...' child pid=36832
[2026-09-20T05:51:52] relaunched 'memtrace start --headless --workspace ...' child pid=44192
[2026-09-20T05:53:59] relaunched 'memtrace start --headless --workspace ...' child pid=56588
[2026-09-20T05:54:55] 5 consecutive heal failures - backing off 10 minutes
```

`grep -c 'PERMANENT FAILURE'` = **3 before and 3 after** — no new line. Every relaunch after the fix
carries `--workspace C:\Users\yuni\.config\memtrace\workspace.toml` and
`cwd=C:\Users\yuni\.config\memtrace`; the pre-fix line at 23:50:52 carried neither. The
`cwd=J:/audio/MCP-Watchers` + no-`--workspace` shape is gone, and the scope-mismatch
PERMANENT FAILURE no longer appears.

**Caveat (not proven)**: the launcher's own `Start-MemtraceHidden` daemon never bound.
`.memdb/memtrace-launch.log.err` shows the start reaching `MemDB local - sidecar memcore-server`
and then failing with:
```
Error: timed out waiting for store-scope lock \\?\C:\Users\yuni\.config\memtrace\.memdb\.memtrace-store-scope.lock;
another Memtrace startup or reset is still changing this store
```
This is **not** the old scope error — it is lock contention from overlapping starts (below).

**Harness note (not a launcher defect)**: under this session the launcher aborts at
`###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1:1880`
(`$repowiseExe = Join-Path $env:APPDATA "uv\tools\repowise\Scripts\repowise.exe"`) because the
tool session does not export `$env:APPDATA` (`APPDATA=[]`, while `LOCALAPPDATA`/`USERPROFILE`/`TEMP`
are set). The exception is `ParameterBindingValidationException: Cannot bind argument to parameter
'Path' because it is null.`, caught by the launcher's own `trap` at line 4522, which prints
"Stopping all watchers (Ctrl+C)...". Restoring `$env:APPDATA = 'C:\Users\yuni\AppData\Roaming'`
(no file edited) let the launcher run through to the memtrace block. The unguarded `Join-Path` is a
latent robustness gap but is outside this repair.

## Check 2 — `:50051` owner + 8-member union scope — PASS

Captured 2026-09-20 05:59:39 / 05:59:59:
```
TCP    127.0.0.1:50051        0.0.0.0:0              LISTENING       22624

LocalAddress LocalPort OwningProcess
127.0.0.1        50051         22624

Name            : memcore-server.exe
CommandLine     : "...\@memtrace\win32-x64\bin\memcore-server.exe" --bind 127.0.0.1:50051
                  --data-dir \\?\C:\Users\yuni\.config\memtrace\.memdb --default-db memtrace --vector-dims 768
```
`--data-dir` is the union store, as required. Parent chain shows the daemon was started with the
**fixed** argument form:
```
memcore-server.exe 22624  <- memtrace.exe 34536  "start --headless --workspace C:/Users/yuni/.config/memtrace/workspace.toml"
                          <- node.exe 66204     "memtrace.js start --headless --workspace C:/Users/yuni/.config/memtrace/workspace.toml"
                          <- python.exe 64784   "memtrace_mcp_cwd_proxy.py"
```
Member count = **8**, read from
`C:\Users\yuni\.config\memtrace\.memdb\.memtrace-store-scope.json` (`grep -c '"repo_id"'` = 8:
diffusers, mcp-watchers, nforma, opencode-mcp, orpheustts-webui, sesame, vad, vibevoice) and
independently from `workspace.toml` (8 quoted entries).

## Check 3 — `memtrace mcp` attaches — **FAIL**

`C:\Users\yuni\.memtrace\cwd-proxy.log` shows a **failed session**, not a handshake:
```
2026-09-20T05:59:08 session failed: daemon-state.json advertises workspace owner pid 34536, but no runtime
                   record in C:\Users\yuni\.memtrace\runtimes names that pid (records present for pids
                   [29064, 63804, 71296, 78604, 87920, 154540]) ...
2026-09-20T05:59:09 daemon ready on :50051
2026-09-20T05:59:14 mcp: Error: workspace owner pid 34536 has no runtime record for store
                   \\?\C:\Users\yuni\.config\memtrace\.memdb in C:\Users\yuni\.memtrace\runtimes;
                   refusing to attach to an unverifiable runtime
2026-09-20T05:59:15 mcp child gone (exit code None) with 1 request(s) in flight; failing fast
2026-09-20T05:59:16 session failed: mcp handshake failed: memtrace mcp exited (code None) without answering: ...
```
A fresh run (below) reproduces it with a different, equally fatal error. Timestamps before/after the
run: last pre-run lines were the 05:59:16 failures; post-run lines are the 06:00:2x-06:00:4x block.

## Check 4 — A real `tools/call` served live — **FAIL**

Drove the proxy directly (`initialize` + `notifications/initialized` + `tools/call
list_indexed_repositories`, which declares no required args), cwd `J:\audio\MCP-Watchers`:
```
start=2026-09-20 06:00:22.455
<-- {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"roots":{},"tools":{}},
     "serverInfo":{"name":"memtrace-cwd-proxy","version":"1.4.0"}}}
<-- {"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"memtrace daemon unavailable: mcp handshake failed:
     memtrace mcp exited (code None) without answering: [memtrace] still starting (5s): looking for the workspace owner
     | [memtrace] attaching to existing workspace owner pid 34536 (http://127.0.0.1:50051)
     | [memtrace] MemDB local - sidecar or workspace owner at http://127.0.0.1:50051
     | Error: could not acquire runtime owner lock at \\?\C:\Users\yuni\.config\memtrace\.memdb\daemon.pid:
       Access is denied. (os error 5)"}}
LIVE_CALL_RESULT_AT=2026-09-20 06:00:47.782
```
**Live vs cached**: the proxy caches only `tools/list` (log line `tools/list served from cache (90
tools)`); a `tools/call` is always forwarded to the child. So the error above proves the call was
forwarded live — but **no live result was served**, which is what check 4 requires. FAIL.

**Incidental positive**: the `e2ed191` fail-fast works. The proxy surfaced the child's real stderr and
returned the error in ~25 s (06:00:22 → 06:00:47) instead of waiting out the 180 s timeout.

## Check 5 — Regression gates — PASS

Heal suite (via `dev_tools/run_pester_suite.py`, not bare `Invoke-Pester`):
```
VERDICT : passed=5 failed=0   (rc=0, ignored)
```
Canonical gate `tests\run_launcher_tests.ps1 -SkipSmoke`:
```
=== T10 summary: PASS=149 FAIL=0 ===     rc=0
[SKIP] T7 grepai not running / T8,T8b real ###1 launcher running / T19 grepai already running /
       T20 skipped via -SkipSmoke / T21 skipped via -SkipSmoke
```
**Run 1 vs run 2**: run 1 gave 130 PASS / 0 FAIL / rc=1 — T23 was truncated to 7 of its 23
assertions by `Set-Content : The process cannot access the file '...\lt_t23_<guid>\watch.log' because
it is being used by another process` (`tests/launcher_tests.ps1:1882`), while the launcher I started
was spawning watchers/tailers. Run 2, with the box quieter, was clean (PASS=149, FAIL=0, rc=0).
Run 1 is a **load-induced flake**, not a regression. The stated expectation was "152 passed"; the
observed green total is 149 — recorded as observed, not massaged.

## Root cause of the check 2-4 instability (confounder, out of repair scope)

Two independent supervisors fight over one union store whose boot now takes **53 s**:

1. **hermes cron watchdog** — `C:\Users\yuni\AppData\Local\hermes\scripts\memtrace_backend_watchdog.py`,
   fires every 5 min (`~/.hermes/logs/memtrace-watchdog.log`: 05:40:11, 05:45:11, 05:50:10, 05:55:10...).
   It runs `memtrace stop` then relaunches
   `node.exe memtrace.js start --headless --bless-workspace` with `WORKDIR=J:\audio\VAD` — a **third**
   start shape (neither `--workspace` nor the launcher), and the source of the ~40 orphaned
   `--bless-workspace` `node.exe` processes seen from 09-19 23:19 onward.
2. **the launcher heal supervisor** — reaps its child after 45 s:
   `[2026-09-20T05:49:05] reaping heal child pid 46696 (ports still down after 45s (fail#2))`.

`memcore-server.log` shows a successful boot takes `ready_in_ms=53234` — longer than the 45 s
tolerance — so the daemon is killed before it can bind. Overlapping starts then leave the
store-scope lock held, producing the observed
`timed out waiting for store-scope lock ...; another Memtrace startup or reset is still changing this store`,
and finally `could not acquire runtime owner lock ... daemon.pid: Access is denied. (os error 5)`.

**Not a `memtrace reset` sweep**: no `memtrace reset` process was observed, and no reset was run by
this verification.

## What is needed to close mcpw-jux

1. De-conflict the store: make the hermes watchdog stop (or point it at the same `--workspace` start
   as the launcher) so only one supervisor starts the union daemon.
2. Raise the heal supervisor's readiness tolerance above the store's boot time (45 s < 53 s today), or
   make boot time independent of store size.
3. Resolve the `daemon.pid` runtime-owner-lock `Access is denied (os error 5)` /
   missing runtime-record condition so `memtrace mcp` can attach to a healthy `:50051` owner.
4. Re-run checks 3 and 4 once `:50051` is stably owned by the union daemon.

Checks 1, 2 and 5 stand as recorded; the `--workspace` repair itself is behaving correctly.
