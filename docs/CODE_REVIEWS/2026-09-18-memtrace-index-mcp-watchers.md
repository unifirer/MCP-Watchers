# Memtrace index — MCP-Watchers

- **Date:** 2026-09-18
- **Repo:** `J:\audio\MCP-Watchers`
- **Command requested:** `/memtrace index`
- **Result:** SUCCESS — 678 symbols, 1,545 edges

---

## 1. Outcome

`J:\audio\MCP-Watchers\.memdb` now holds a real structural graph.

| Metric | Value |
|---|---|
| Symbols | 678 |
| Edges | 1,545 |
| Files indexed | 66 |
| Communities | 18 |
| Processes | 20 |
| Store size | 2.8 MB |
| Dashboard | `http://localhost:3030?repo=MCP-Watchers` |

Verification command and its literal output:

```
$ memtrace insight-card
  Memtrace mapped MCP-Watchers  678 symbols · 1,545 edges
    *  Hottest symbol   _read   12 direct callers · last edited today
    *  Critical bridge  _read — removing it splits the graph into 2 islands
```

## 2. Why the first attempt was refused

Two independent gates blocked the index. Both were needed to explain the failure.

### Gate 1 — the store had no scope manifest

Before any change, `.memdb/` contained only two files:

```
-rw-r--r-- 1 yuni 197121   0 Sep 18 10:18 .memtrace-store-scope.lock
-rw-r--r-- 1 yuni 197121 736 Sep 18 10:13 autoheal.log
```

No `.memtrace-store-scope.json`. No `graph-cache/`. Store size `4.0K` — it had
never held data. The CLI refused:

> refusing to open MemDB store `\\?\J:\audio\MCP-Watchers\.memdb` because its
> repository membership cannot be proven (the authoritative scope manifest is
> missing and the legacy graph cache proof failed: cannot inspect legacy graph
> cache ...: The system cannot find the path specified. (os error 3))

Because the manifest was missing, membership could not be proven for
`SingleRepository` scope, and the store was refused before open.

### Gate 2 — no daemon owned the store

`memcore-server` was not running. The only process present was a parent
`memtrace.exe` (PID 13984, 53 MB) acting as a **liveness lease with no worker**.

Every `memtrace index`, `status`, and `mcp list` invocation therefore became a
*client* start. It spawned a transient sidecar, the sidecar died, and the
`.memdb/autoheal.log` recorded:

```
[2026-09-18T10:13:41] memtrace down (memdb:50051, mcp:3030) fail#1 - healing
```

Ports 50051 and 3030 were both unbound.

## 3. The fix chain

Order matters. Each step depends on the one before it.

1. **`memtrace index . --clear`** — a single shot that did two things at once: it
   wrote the correct scope manifest and spawned a fresh daemon.
   Archive written to `.memdb.history/20260917T222243Z-38304/`. Nothing was deleted.

   The manifest now reads:
   ```json
   {"version": 1, "members": [{"repo_id": "mcp-watchers", "path": "j:/audio/MCP-Watchers"}]}
   ```

   **This pass still failed** — see §4.

2. **`memtrace start`** — run backgrounded, because it is a long-running daemon.
   This gave the store a persistent owner. Port 50051 then reported `LISTENING`.

3. **`memtrace index .`** with the daemon live — the graph landed cleanly, and a
   final pass reached 678 symbols / 1,545 edges.

## 4. Traps encountered

### The sidecar dies with the client

The first pass after `--clear` scanned and parsed correctly, then failed on persist:

```
Indexing MCP-Watchers — persist · Writing 611 symbols — searchable while modules detect
✗  memdb: bulk_create_records (nodes) failed: status: Unknown transport error
```

Cause: the CLI was running in embedded fast-path mode. The `memcore-server`
sidecar is spawned under Windows **kill-on-job-close** containment
(`MEMTRACE_SIDECAR_CRASH_CONTAINMENT=active`). When the CLI process exited, the
containment killed the server mid-write.

The fix is a separate long-lived owner — step 2 above. A one-shot `index` cannot
durably own its own store.

### Stale index lease (120 s)

After the crashed pass, the next `index` refused:

> peer is indexing (holder=agent-38304, acquired_at=2026-09-17T22:22:50.285244400+00:00)
> — skipping; this client will pick up the peer's result.
> Retry after the holder finishes (or its lease expires at ...22:24:50...)

The lease TTL is **120 seconds**. There is no lease-clear flag. Wait it out.

### `memtrace status` cannot verify an index

`status` never opens the store, so `Graph counts:` always prints
`not loaded`. It is useless for confirming an index. Use `insight-card` instead.

### `insight-card` needs a verified owner

Before `memtrace start` it fails with:

> No verified Memtrace owner is running. Run `memtrace start` before requesting an insight card.

## 5. Pre-existing environment issues

These were found during the work. **None were caused by it, and none were fixed.**

### CUDA cannot load — all embedding runs on CPU

An RTX 3080 is present (10239 MB VRAM, compute capability 8.6), but the CUDA
provider DLLs are absent:

```
cudart64_12.dll, cublas64_12.dll, cublasLt64_12.dll,
cufft64_11.dll, cufftw64_11.dll, nvJitLink_120_0.dll, cudnn64_9.dll
```

Effective provider is `CPUExecutionProvider`. Remedy, **not run**:

```
memtrace gpu install-cuda --yes     # ~2 GB, machine-level change
```

### Embedding stage is thin

The first good pass reported, non-fatally:

```
Embedding stage failed (non-fatal): compact embed candidate scan failed ...
status: Unavailable tcp connect error. MemDB endpoint is unreachable.
```

Same crashing-sidecar cause. It cleared once a persistent daemon existed. Final
state: `Embed batching: 4 texts in 4 batches` — semantic search coverage is still
low relative to 678 symbols.

### Nested store below the union store

`C:\Users\yuni\.config\memtrace\.memdb` (9.2 GB) declares seven members including
`vad`, but `J:\audio\VAD\.memdb` is a **nested store below it**. Flagged as a
pre-1.0.8 leftover. Nothing was deleted.

### VAD launch log shows a scope mismatch

`J:\audio\VAD\.memdb\memtrace-launch.log.err` records a refusal where stored
members (7) do not match requested members (12). VAD is not affected in normal
use because it has its own valid `vad`-scoped manifest. Worth a separate look.

### Auto-heal log ticks while no daemon runs

`J:\audio\MCP-Watchers\.memdb\autoheal.log` writes `memtrace down ... fail#1`
roughly every 5 minutes whenever nothing owns the store. Expected behaviour.

## 6. Side effects on running services

Running `memtrace index` from this session terminated the stale parent
`memtrace.exe` (PID 13984) and started fresh daemons.

The MCP-Watchers launcher **was not running** at the time — its supervisor logged
`launcher no longer alive - supervisor exiting` at `2026-09-18T10:15:11`. Nothing
live was disrupted.

Current ownership:

| Process | PID |
|---|---|
| `memtrace.exe` | 60668 |
| `memcore-server.exe` | 31320 |

`daemon-state.json` reports `"status": "healthy"`.

## 7. Notes on tooling

- The Toolport-proxied `memtrace` MCP server exposes `find_symbol`, `find_code`,
  `get_symbol_context`, `get_impact`, and `get_evolution` — **no `index` verb**.
  Indexing must go through the CLI.
- `--clear` archives to `<store>.history`; it never deletes. It is only
  appropriate when the store is empty. Do not use it on a healthy store.
- `memtrace start` blocks by design. Background it.
- `memtrace daemon` **no longer exists in 1.2.6**:
  `memtrace service / daemon was removed in memtrace 1.2.6. Use memtrace start`.
  Any script or doc still calling `memtrace daemon …` is stale.

## 8. Follow-ups checked, both cleared

### `cs.err` — benign

The file contained only:

```
'DOSKEY' is not recognized as an internal or external command,
operable program or batch file.
'"node"' is not recognized as an internal or external command,
operable program or batch file.
```

Shell-parsing noise from a `memtrace` subcommand spawned through a `cmd` shim
without the expected DOSKEY context. Not a defect, no action needed. The runtime
is unaffected.

### The second `memtrace.exe` — transient, not a second runtime

Two `memtrace.exe` processes were visible at one point. Re-checking resolved it:

- PID 60668 — `...\@memtrace\win32-x64\bin\memtrace.exe start`, parent 85472,
  started `10:31:32`. **This is the real runtime.**
- PID 43860 — **already exited.** It was a transient *client* (a one-shot
  `index`/`status` invocation connecting to the running owner), not a competing
  runtime. `memcore-server` parentage confirms the singleton:

```
$ cat .memdb/sidecars.json
  memcore-server     pid 31320   owner_pid 60668   store J:\audio\MCP-Watchers\.memdb
  memcortex-daemon   pid 104032  owner_pid 60668   store C:\Users\yuni\.memtrace\cortex-store
```

Both sidecars are owned by **60668 alone** — no contention for the store.

Final process state:

```
memtrace.exe          60668    runtime
memcore-server.exe    31320    sidecar, holds 127.0.0.1:50051
memcortex-daemon.exe  104032   cortex sidecar
```

### Residual caveat — semantic search is thin

`Embed batching: 4 texts in 4 batches`, and one
`Embedding stage failed (non-fatal)` message appeared during the run. Structural
search (symbols, edges, blast radius) is solid and verified. **Semantic search
reliability is not yet proven** — re-check after the CUDA provider is installed,
since embedding is currently CPU-only.

## 9. The runtime does not survive its parent — and the launcher reclaims it

This is the most important operational finding of the session, because it
determines whether the index stays queryable.

### `memtrace start` is bound to its parent process

`memtrace start` was run three ways. All three ended the same way.

| Launch method | Result |
|---|---|
| Backgrounded from an agent shell | Died when the task's shell was cleaned up (17m 52s) |
| `nohup ... &` (detached from shell) | Died within ~30 s — the sidecar is under kill-on-job-close containment, and the job ends with the parent |
| Foreground `memtrace start` | Holds while the shell lives; dies with it |

The `memcore-server` sidecar is spawned under Windows
`MEMTRACE_SIDECAR_CRASH_CONTAINMENT=active` (kill-on-job-close). When the owning
process goes away, the job closes and the server is killed **with it**, so the
store returns to `NOT LISTENING` on 50051 and 3030.

The only owner that persists is the one the **watcher stack** creates.

### The launcher's auto-heal reclaims the store

`.memdb/autoheal.log` shows the recovery loop working exactly as designed:

```
[10:45:45] memtrace down (memdb:50051, mcp:3030) fail#1 - healing
[10:46:12] relaunched 'memtrace start --headless' via C:\nvm4w\nodejs\node.exe (absolute=True, cwd=J:/audio/MCP-Watchers)
[10:46:31] memtrace healed - both ports listening again
[10:47:04] memtrace down (memdb:50051, mcp:3030) fail#1 - healing
[10:47:20] relaunched 'memtrace start --headless' via C:\nvm4w\nodejs\node.exe (absolute=True, cwd=J:/audio/MCP-Watchers)
```

Two things follow.

1. **There is only ever one legitimate owner**: the `--headless` runtime the
   auto-heal spawns via node, parented to the watcher tree. A manual
   `memtrace start` is a *second* claimant and will be fought over.
2. **While no owner exists, the log writes `down … fail#1` every ~5 minutes.**
   Expected, self-correcting, and not a defect.

### Consequence for this session

The MCP-Watchers launcher came up during the work (`pwsh.exe` PID 76780 running
`###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`). It took
ownership of the store and ran `memtrace stop` against the runtime I had started —
correctly, since it owns that lifecycle.

**The durable artifact is the store itself.** It survived every runtime restart
intact: `.memdb` remained 6.8 MB with the scope manifest and a fully rebuilt
graph (`Bootstrap complete - all 1 repos indexed, embedded, and replayed`).
Queryability returns as soon as any runtime owns it.

**Do not start a competing `memtrace start` while the launcher is up.** Let the
watcher stack own it.

### Also observed

- The launcher spawns `python.exe C:\Users\yuni\.local\bin\memtrace_mcp_cwd_proxy.py`
  (six instances seen). That is the Toolport cwd-proxy, not a fault.
- `memtrace start` logged `System at Critical but memtrace is under budget
  (rss=0.7 GB / budget=24 GB) - proceeding with reduced batch=8`. It adapts
  downward correctly, but "System at Critical" indicates unrelated memory
  pressure on the host worth a look.



