# mcpw-e7v — `memtrace mcp` refuses to attach to an unverifiable runtime

Date: 2026-09-20
Bead: `mcpw-e7v` (P2 bug, label `mcp, memtrace, proxy`)
Component: `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py` (outside this repo)

## Symptom

`memtrace mcp` would not attach to an otherwise reachable daemon. The proxy
reported only:

```
session failed: mcp handshake failed: mcp request timed out after 180s
```

while the mcp child had in fact exited immediately with its own, precise error:

```
Error: workspace owner pid 57744 has no runtime record for store
\\?\C:/Users/yuni/.config/memtrace/.memdb in C:/Users/yuni/.memtrace/runtimes;
refusing to attach to an unverifiable runtime.
```

## Root-cause verdict (determined, not guessed)

**The pid/record disagreement is a consequence of short-lived memtrace
processes churning :50051 — not of the proxy's daemon start racing the mcp
attach.** The proxy's cwd pinning (`canonical_cwd()`) is *not* the defect.

Evidence:

1. `daemon-state.json` (`~/.memdb/daemon-state.json`) is rewritten by whichever
   memtrace process ran most recently, including short-lived ones such as
   `memtrace reset` or a `start` that loses the `:50051` bind race. The
   `runtimes/<hash>.json` record for the union store is only published by a
   daemon that reaches steady state. When the two disagree, `memtrace mcp`
   reads the pid from the state file, finds no matching record, and exits.
2. The refusal names a **different pid almost every time** — 50 occurrences
   across ~20 distinct pids (`33872`, `22656`, `59156`, `39124`, `57744`, …) in
   `~/.memtrace/cwd-proxy.log`. That is the transient pid, not the pid the proxy
   started, and not a stable single racer.
3. Timing in every failing cycle is `daemon ready on :50051` → `mcp attached` →
   refusal ~2 s later (e.g. 04:31:08 → 04:31:10), i.e. the child exits at once;
   there is no long attach wait to race against.
4. When a daemon genuinely persists, the same code and the same store attach
   fine. Live now: `memtrace.exe` pid 29872 with `memcore-server.exe` pid 57492
   owning `:50051`, matching runtime record
   `runtimes/d1b7d98….json` (pid 29872, `memdbDataDir
   \\?\C:\Users\yuni\.config\memtrace\.memdb`), and `memtrace mcp` logs
   `[memtrace] attaching to existing workspace owner pid 29872` followed by
   `MemDB ready`.

So the *trigger* is external churn that cannot be fixed inside the proxy.
What the proxy did own was its failure mode: it never noticed the child had
exited.

## Defect fixed in the proxy

`Session._read_responses()` hit EOF when the mcp child exited, `break`-ed out of
its loop, and left `self._response_futures` unresolved. The pending
`initialize` future therefore never completed and `Session.call()` sat in
`asyncio.wait_for(..., timeout=180)` before raising the misleading
`mcp request timed out after 180s` — while the child's real error had already
been captured by `_drain_stderr()` and written to the log.

Changes (all in `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py`):

| Area | Change |
| --- | --- |
| `RUNTIMES_DIR`, `DAEMON_STATE_PATHS` (~line 33) | new constants; `get_daemon_port()` now reuses `DAEMON_STATE_PATHS` |
| `daemon_state_owner_pid()`, `runtime_record_owner_pids()`, `unverifiable_owner_reason()` (~lines 44-113) | read-only cross-check of the advertised owner pid against `runtimes/*.json`. Returns a reason **only when the mismatch is provable** (the pid appears in no record at all); an unreadable runtimes dir returns `None` so memtrace still decides |
| `Session.__init__` (~line 516) | `self._stderr_tail` ring buffer (last 20 lines) |
| `Session._drain_stderr` (~line 530) | also records each stderr line into the ring buffer |
| `Session._fail_pending` / `_read_responses` `finally` (~lines 636-681) | on child exit, fail every in-flight request immediately, quoting the stderr tail: `memtrace mcp exited (code N) without answering: <stderr tail>` |
| `Session.start()` fast path (~line 550) | call `unverifiable_owner_reason()` before attaching; fail fast with the precise reason |
| `Session._wait_and_attach()` (~line 600) | same check before attaching to another proxy's daemon |
| `Proxy._on_initialize()` already-running branch (~line 973) | same check before `_attach_mcp`; `_fail_init` with the precise reason |

No restart, no `taskkill`, no `memtrace stop`, no `memtrace reset` was added —
the daemon is only ever observed. Behaviour is unchanged for a healthy daemon:
in that case the advertised pid *is* in `runtimes/`, so the check returns
`None` and the attach proceeds exactly as before.

## Verification (real output)

Harness: `C:/Temp/verify_e7v.py` (unit) and `C:/Temp/e2e_e7v.py` (end-to-end
through a real MCP stdio handshake).

Unit harness, against the live machine:

```
=== 1. real daemon state vs runtime records ===
owner pid from daemon-state.json: 29872
pids in runtimes/: [29064, 29872, 63804, 71296, 78604, 87920, 154540]
unverifiable_owner_reason() -> None                      # healthy: never refused

=== 2. synthetic mismatch (state pid not in runtimes/) ===
unverifiable_owner_reason() -> daemon-state.json advertises workspace owner pid
999999, but no runtime record in C:\Users\yuni\.memtrace\runtimes names that pid
(records present for pids [29064, 29872, ...]), so `memtrace mcp` would refuse to
attach to this unverifiable runtime

=== 3. synthetic unreadable runtimes dir (must NOT refuse) ===
unverifiable_owner_reason() -> None                      # cannot prove: let memtrace decide

=== 4. dead mcp child -> pending future fails fast with stderr ===
PASS: failed after an instant with: memtrace mcp exited (code None) without
answering: Error: workspace owner pid 57744 has no runtime record for store
\\?\C:/Users/yuni/.config/memtrace/.memdb; refusing to attach to an unverifiable run…

=== 5. healthy child -> no premature failure ===
PASS: real response delivered: {'jsonrpc': '2.0', 'id': 1, 'result': {'ok': True}}
```

End-to-end, live deployment (the important half): `tool schemas loaded: 90
tools, 61 repo-scoped` appears repeatedly in `~/.memtrace/cwd-proxy.log` after
`[memtrace] MemDB ready` — e.g. 05:05:30, 05:06:27, 05:06:22 — so real gateway
sessions are completing a live handshake and are **not** being served from the
90-tool cache.

Before/after on the failure path, same harness, same machine, driven through the
real proxy over stdio:

| Proxy build | Wall clock to failure | Reported reason |
| --- | --- | --- |
| pre-fix `.bak-20260920-0502` | **186.9 s** | `session failed: mcp handshake failed: mcp request timed out after 180s` (misleading) |
| fixed | **18.3 s** | `session failed: mcp handshake failed: memtrace mcp exited (code None) without answering: … Error: could not acquire runtime owner lock … Access is denied. (os error 5)` (accurate) |

The remaining 18.3 s is memtrace's own `still starting (5s)` wait plus child
startup, not proxy idle time. Both runs were driven through the same
`C:/Temp/e2e_e7v.py` harness, which only ever attaches — it never starts,
restarts or stops a daemon.

## Unverified / out of scope — flagged, not fixed

Driving the proxy from a harness shell reproduces a *different* memtrace
failure that the real gateway does not show:

```
[memtrace] still starting (5s): looking for the workspace owner
[memtrace] attaching to existing workspace owner pid 29872 (http://127.0.0.1:50051)
Error: could not acquire runtime owner lock at
\\?\C:\Users\yuni\.config\memtrace\.memdb\daemon.pid: Access is denied. (os error 5)
```

Reproduced with and without the tool sandbox, so it is not simply sandbox
interference, but gateway-launched sessions attach to the same daemon at the
same time and log `MemDB ready`, so the cause is environment-specific and
**unverified**. It is not `mcpw-e7v`, it is not caused by this change (the lock
is taken by `memtrace.exe`, which the proxy never touches), and no fix was
attempted. The change does make it visible: ~18 s and an accurate message
instead of a 180 s silent timeout.

## Rollback

The pre-change file is preserved verbatim:

- `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py.bak-20260920-0502`
  (md5 `1cee14fe52a41c6f0366ecb0a3a8bca1`, identical to the edited file's
  predecessor)

To roll back: copy that `.bak-20260920-0502` file over
`memtrace_mcp_cwd_proxy.py`. An earlier backup from the previous change
(`.bak-20260918-100705`) is also still present.
