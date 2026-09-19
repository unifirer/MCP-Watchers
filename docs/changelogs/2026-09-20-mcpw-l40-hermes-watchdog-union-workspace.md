# mcpw-l40 — hermes memtrace watchdog: pass `--workspace` and run from the union manifest

Date: 2026-09-20
Bead: mcpw-l40 (P1, BUG) — "hermes memtrace watchdog starts memtrace without
--workspace, churning the union store every 5 min"

## Remedy chosen: (a) — pass `--workspace <manifest>` and run from the manifest dir

Justification (all verified, not assumed):

* `memtrace start --help` states the defect verbatim: *"Bare start cold-scopes the
  invoked folder ... and stores data in that scope's local .memdb"*, while
  *"`--workspace-file <FILE>` (or `--workspace <FILE.toml>`) loads a portable
  versioned member list and anchors data beside it."* The watchdog launched a bare
  `start` from cwd `J:\audio\VAD`, i.e. a ONE-member ColdFolder scope, against the
  8-member union store declared in
  `C:/Users/yuni/.config/memtrace/workspace.toml`.
* The launcher's own auto-heal supervisor already uses the canonical form — see
  `J:/audio/MCP-Watchers/.memdb/autoheal.log`:
  `relaunched 'memtrace start --headless --workspace C:\Users\yuni\.config\memtrace\workspace.toml' via C:\nvm4w\nodejs\node.exe (absolute=True, cwd=C:\Users\yuni\.config\memtrace, child pid=...)`
  (repeated 05:39, 05:42, 05:45, 05:48, 05:50, 05:51, 05:53, 06:06).
* The Toolport proxy `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py`
  `start_daemon()` (v1.4.0, lines 411-438) does the same:
  `[MEMTRACE_NODE, MEMTRACE_JS, "start", "--headless", "--workspace", manifest]`
  with `cwd=CANONICAL_CWD` (= `~/.config/memtrace`).

Remedy (b) — "no-op when a healthy daemon already holds the port" — is already
substantially present: `main()` returns silently after logging `OK (http 200)`
whenever :3030 answers. It is not sufficient alone because the daemon was *down*
every tick precisely because the wrong-form relaunch failed, so the watchdog
restarted it every 5 minutes. (c) disable was rejected as it would drop the only
external recovery for a shared 8-member daemon.

## What changed

File (outside the repo):
`C:/Users/yuni/AppData/Local/hermes/scripts/memtrace_backend_watchdog.py`

1. Added constants (derived, not hardcoded):
   ```python
   UNION_MANIFEST = os.path.join(os.path.expanduser("~"), ".config", "memtrace", "workspace.toml")
   UNION_CWD = os.path.dirname(UNION_MANIFEST)
   RECOVERY_CWD = UNION_CWD if os.path.isdir(UNION_CWD) else WORKDIR
   ```
2. Relaunch now requests the union scope and runs from the manifest directory
   (mirrors the launcher/proxy), dropping `--bless-workspace` (the canonical union
   launch does not use it; help text calls `--bless-workspace` the separate
   "legacy Folder Group marker flow"):
   ```python
   if os.path.exists(UNION_MANIFEST):
       launch_args = f"'{MEMTRACE_JS}','start','--headless','--workspace','{UNION_MANIFEST}'"
       launch_cwd = UNION_CWD
   else:
       launch_args = f"'{MEMTRACE_JS}','start','--headless','--bless-workspace'"
       launch_cwd = WORKDIR
   ```
3. `memtrace stop` (recovery step 1) and `memtrace status` (`owner_pid()`) now run
   from `RECOVERY_CWD` instead of `WORKDIR`, so the whole recovery path resolves
   the same store the daemon serves.

## Evidence

Constructed relaunch command (verified by evaluating the same expression):
```
Start-Process -FilePath 'C:/nvm4w/nodejs/node.exe'
  -ArgumentList '<memtrace.js>','start','--headless','--workspace','C:\Users\yuni\.config\memtrace\workspace.toml'
  -WorkingDirectory 'C:\Users\yuni\.config\memtrace' -WindowStyle Hidden
```
* `py_compile` -> OK.
* Watchdog run against a healthy daemon (`:3030` = 200): exit 0, silent, logged
  `2026-09-20 06:01:17 OK (http 200)` — the no-op path still works.
* Leak stopped: before the fix one `node.exe memtrace.js start --headless
  --bless-workspace` accumulated per 5-minute tick. After the fix, the 06:05:10
  cron tick ran with the daemon DOWN and produced **NEW_ORPHANS=0**; every live
  `start` process now carries `--workspace`.

## Leaked orphan processes — cleaned up (proof required and obtained)

46 orphaned `node.exe ... memtrace.js start --headless --bless-workspace`
processes (created 2026-09-19 23:19:08 .. 2026-09-20 05:55:14) were terminated.

Proof each was safe to kill (recorded in `C:/Temp/mcpw-l40-orphans.txt` and
`C:/Temp/mcpw-l40-kill2.txt`):

* For **all 46**, the recorded parent PID no longer exists (`orphan=True`,
  `parentExists=False`); the PID-reuse case (parent created *after* the child) was
  also tested. Result: `SUMMARY orphan=46 liveparent=0`.
* None carried `--workspace`, so none belonged to the union daemon tree
  (the daemon is `node memtrace.js start --headless --workspace <manifest>` ->
  `memtrace.exe` -> `memcore-server.exe`).
* Each killed PID was checked against a protected set (every process carrying
  `--workspace`, plus `memcore-server`/`memcortex-daemon`) and against the full
  ancestor chain of the live `memcore-server`: `protected=False` for all 46.
* Result: `REMAINING_ORPHANS=0`; the live `memcore-server`/daemon tree was not
  among the killed PIDs.

(The first kill attempt reported `KILLED=0` because the loop assigned to the
read-only PowerShell automatic variable `$pid`; renamed to `$tpid` and re-run.
No process was touched by the failed attempt.)

## Flagged / unverified — concurrent daemon churn (NOT caused by this fix)

The union daemon is currently flapping, but from *other* actors, not from this
change:

* `.memdb/autoheal.log`: the **launcher's** auto-heal supervisor repeatedly ran
  `memtrace stop` + `start --headless --workspace <manifest>` (05:39..05:54, then a
  10-minute backoff, resuming 06:05:28).
* `~/.memtrace/cwd-proxy.log` 06:04:45-47: the **proxy** logged a *different*
  failure — `refusing to open MemDB store ... ; requested members: {}` — i.e. a
  client requested an EMPTY scope. That is not this bead.
* The old daemon tree (`node` 66204 -> `memtrace.exe` 34536 -> `memcore-server`
  22624) disappeared at ~06:02:52, ~18 s after the orphan kill. I could not
  attribute that to the kill: the kill targeted only the 46 proven orphans, and
  the owning proxy (pid 64784) is gone while the launcher was concurrently
  stopping/starting the daemon. **I cannot fully exclude a contribution, so I am
  labelling the daemon's 06:02:52 exit as unverified in cause.** The orphan
  cleanup itself is proven safe by the checks above.
* Post-fix, three actors (launcher heal supervisor, proxy, watchdog) now all
  launch with the canonical `--workspace <manifest>` form; the store is large
  (`memcore-server` "MemDB ready" took ~71 s), so the daemon takes ~1 min to bind
  after a restart. Multi-actor restart races are out of scope for this bead.

`memtrace reset` was NOT run; the Toolport gateway was NOT killed.

## Backup / rollback

Backup: `C:/Users/yuni/AppData/Local/hermes/scripts/memtrace_backend_watchdog.py.bak-20260920-0600`

Roll back:
```sh
cp "C:/Users/yuni/AppData/Local/hermes/scripts/memtrace_backend_watchdog.py.bak-20260920-0600" \
   "C:/Users/yuni/AppData/Local/hermes/scripts/memtrace_backend_watchdog.py"
```
