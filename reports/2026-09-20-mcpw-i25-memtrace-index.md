# mcpw-i25 — memtrace index for this workspace

- **Date:** 2026-09-20
- **Branch:** `mcpw-sweep-20260920-1305`
- **Repo:** `J:\audio\MCP-Watchers`
- **memtrace:** 1.2.6 (`J:\Programs\npm-global\node_modules\memtrace`)
- **Verdict:** **COMPLETED** — `memtrace index` ran for this workspace and the store now
  reports **1101 nodes / 2969 edges**, with `last_indexed_at` advanced to
  `2026-09-20T08:20:24Z`. The run also drove the shared `memcore-server` into a restart
  loop (§5) — reported as a finding.

---

## 1. Deviation confirmed — there is no `memtrace build` verb

Re-verified, not taken on trust:

```
$ memtrace build --help
memtrace 1.2.6 - Memtrace

QUICK START:
  Cursor / Claude Desktop (MCP)   memtrace mcp
  Local workspace + HTTP API      memtrace start
  Headless / CI / agent hosts     memtrace start --headless
```

`build` is not a subcommand, so it falls through to top-level help. The real verb is
`memtrace index`:

```
$ memtrace index --help
Usage: memtrace index [PATH] [--workspace <PATH|NAME|MANIFEST>] [--workspace-file <FILE>]
                      [--clear|--fresh] [--max-cores N] [--allow-non-git] [--index-ignored] [--debug]

Index a repository or explicit workspace into MemDB. PATH defaults to the current directory.
```

## 2. Preconditions — scope and daemon

Workspace IS scoped, as the bead states:

```
$ cat .memdb/.memtrace-store-scope.json
{ "version": 1, "members": [ { "repo_id": "mcp-watchers", "path": "j:/audio/MCP-Watchers" } ] }
```

Union store is global, 3 members (not 8 as the bead text says — the manifest has 3):

```
$ cat ~/.config/memtrace/workspace.toml
version = 1
members = [ "J:/audio/MCP-Watchers", "J:/audio/VAD", "J:/audio/MCP-updater" ]
```

Daemon was live and **had been started with the manifest** — so I did not need to
`start` it, and I never ran a bare `memtrace start` from the member cwd (the 1-member vs
stored-N trap):

```
memtrace.exe  PID 84068  memtrace.exe start --headless --workspace C:/Users/yuni/.config/memtrace/workspace.toml
memcore-server.exe PID 44920  --bind 127.0.0.1:50051 --data-dir \\?\C:\Users\yuni\.config\memtrace\.memdb --default-db memtrace --vector-dims 768
```

**`memtrace mcp` was NOT run** (crash-containment hazard). No model configuration was
touched.

## 3. Measurement point

`memtrace status` cannot confirm store membership by design, exactly as the bead warns:

```
$ memtrace status
  MemDB mode:     local
  Data dir:       \\?\C:\Users\yuni\.config\memtrace\.memdb
  Owner PID:      43792
  UI:             http://localhost:3030
  Store present:  yes
  Graph counts:   not loaded (status never opens a local MemDB store)
```

So I used the runtime's own HTTP API on **:3030**, which was answering:

```
$ curl --noproxy '*' http://127.0.0.1:3030/api/repos
```

That endpoint returns per-repo `node_count`, `edge_count`, `counts_fresh`,
`last_indexed_at` and `indexed_branches` — an independent read of the store.

## 4. BEFORE → command → AFTER

### BEFORE (2026-09-20 20:19 NZT)

```json
{ "repo_id": "MCP-Watchers",
  "current_branch": "mcpw-sweep-20260920-1305",
  "indexed_branches": ["mcpw-sweep-20260920-1305"],
  "node_count": 1051,
  "edge_count": 2991,
  "counts_fresh": true,
  "last_indexed_at": "2026-09-20T01:03:56.171092300+00:00" }
```

(The very first call returned `node_count: null / counts_fresh: false`; the counts
warm on the first read. 1051/2991 is the warmed value.)

### COMMAND

```
$ cd /j/audio/MCP-Watchers
$ memtrace index J:/audio/MCP-Watchers --workspace C:/Users/yuni/.config/memtrace/workspace.toml
```

The `--workspace <manifest>` flag was passed deliberately, per the constraint.

### OUTPUT (verbatim)

```
  ◆  Workspace manifest portable workspace: 3 member(s)  (data anchor: \\?\C:\Users\yuni\.config\memtrace;
      file: \\?\C:\Users\yuni\.config\memtrace\workspace.toml)
  ? MemDB local - sidecar memcore-server (data dir: \\?\C:\Users\yuni\.config\memtrace\.memdb)
  RSS ceiling: 24 GB
  ONNX EP: CUDA=on DirectML=off HW=on VRAM=10239MB CPU=fallback
  ◆  Accelerator  CUDAExecutionProvider -> CPUExecutionProvider

✓
  Indexing workspace  3 repo(s)  (MemDB first-pass)
  - \\?\J:\audio\MCP-Watchers
  - \\?\J:\audio\VAD
  - \\?\J:\audio\MCP-updater

  ◆  Indexing MCP-Watchers — scan · Scanning repository files · 2% · 0s
  ◆  Indexing MCP-Watchers — scan · Scanned 198 files · 10% · 0s
  ◆  Indexing MCP-Watchers — parse · Parsing 198 files · 15% · 0s
  ◆  Indexing MCP-Watchers — parse · Parsed 1018 symbols · 25% · 0s
  ◆  Indexing MCP-Watchers — persist · Writing 1018 symbols — searchable while modules detect · 43% · 1s
  ◆  Indexing MCP-Watchers — persist · Writing 1101 symbols and 2969 relationships · 88% · 5s
  ◆  Indexing MCP-Watchers — persist · Wrote 75 symbols · 1034 relationships · 96% · 12s
✓
  ✓  Indexed 1101 nodes - 2969 edges  (12249 ms)
  -  files: 198  communities: 37  processes: 31  embeddable: 356
```

### AFTER (2026-09-20 20:31 NZT, independent read)

```json
{ "repo_id": "MCP-Watchers",
  "current_branch": "mcpw-sweep-20260920-1305",
  "indexed_branches": ["mcpw-sweep-20260920-1305"],
  "node_count": 1101,
  "edge_count": 2969,
  "counts_fresh": false,
  "last_indexed_at": "2026-09-20T08:20:24.021614600Z" }
```

### The numbers that changed

| Metric | Before (20:19) | After (20:31) | Δ |
|---|---|---|---|
| `node_count` | 1051 | **1101** | **+50** |
| `edge_count` | 2991 | **2969** | −22 |
| `last_indexed_at` | 2026-09-20T01:03:56Z | **2026-09-20T08:20:24Z** | **advanced ~7h16m** |
| files scanned | — | **198** | — |
| communities / processes | — | 37 / 31 | — |
| embeddable | — | 356 | — |

`last_indexed_at` moved to `08:20:24Z` = **20:20:24 NZT**, i.e. exactly when the index
command ran (launched 20:20:04, tool self-reported `12249 ms`). The API's `node_count`
(1101) independently matches the indexer's own `Indexed 1101 nodes - 2969 edges`.

### On-disk corroboration

A fresh per-branch graph cache was written at 20:20, larger than the branch's previous one:

```
-rw-r--r-- 123636 Sep 20 19:04  graph-cache/MCP-Watchers___head.mtgs
-rw-r--r-- 100751 Sep 20 13:03  graph-cache/MCP-Watchers__main.mtgs
-rw-r--r-- 140857 Sep 20 20:20  graph-cache/MCP-Watchers__mcpw-sweep-20260920-1305.mtgs   <-- new
-rw-r--r--      3 Sep 20 20:20  graph-cache/MCP-Watchers__.generation
```

## 5. Finding — the run drove the shared `memcore-server` into a restart loop

Timeline (all 2026-09-20 NZT):

| Time | Event |
|---|---|
| 20:18:17 | `memcore-server` PID 44920 starts |
| 20:19:33 | `MemDB ready ready_in_ms=75168` — daemon healthy |
| 20:20:04 | my `memtrace index` launches |
| 20:20:24 | MCP-Watchers indexed: 1101 nodes / 2969 edges |
| **20:24:04** | **`memcore-server` dies and restarts (new PID)** |
| 20:24:58 | restarts again |
| 20:25:42 | restarts again |
| 20:27:45, 20:28:19 | restarts again — period ≈ 50-55 s |
| 20:24-20:31 | `:50051` connection refused; `:3030` returns `000` (down) |
| ~20:31 | API recovers; AFTER numbers readable |

Every restart replayed a large WAL and never reached ready:

```
MemDB starting
record-index snapshot is stale; replaying WAL tail  observed: 29901945
HNSW fast-path: ... node_count=30737 ... degraded=true
count_store fast-path: recovered from snapshot, skipping rebuild inc pass
   <-- log ends here; next line is a fresh "MemDB starting"
```

Daemon RSS climbed across restarts: 2.7 GB → 5.9 GB → 9.1 GB (host 31 GB, ceiling 24 GB).
No panic or error line is logged — each attempt just stops, which is the signature of an
external kill rather than a self-terminating crash.

**Causation is not proven.** The loop begins ~4 minutes after my index run started and
while the job was moving on to VAD (the large repo — its 20:22 `insights-cache` entries
show it got that far). But new `memtrace.exe` processes I did not launch also appeared
(e.g. PID 53316 at 20:25:40), so memtrace's own reheal logic and/or another agent is
involved. This is reported as an observation with the timeline, not as a diagnosis.

**My index job is hung and I deliberately left it running.** PID 88968, launched 20:20:04:

```
CPU before=107.8s after=107.8s delta=0.1s   (over 25 s — idle, blocked)
RSS 10 MB
```

It completed MCP-Watchers, then blocked waiting on the unavailable daemon and never
emitted its `EXIT=` line; VAD and MCP-updater were never indexed (VAD still reports
`node_count: null`). I did **not** kill it: the task warns that on this box
`MEMTRACE_SIDECAR_CRASH_CONTAINMENT=active` + Windows kill-on-job-close can take the
**shared** daemon down for all member workspaces, and a hung-but-inert client is the
safer of the two states. **This needs a human decision.**

## 6. What I changed

- `reports/2026-09-20-mcpw-i25-memtrace-index.md` (this file) — new.
- No tracked file was edited. No `git add` / `git commit` / `git checkout` was run.
- No LLM model configuration was touched. `memtrace mcp` was not run.
- One hung `memtrace index` process (PID 88968) left in place, documented above.

## 7. Verdict

**COMPLETED.** `memtrace index` ran against this workspace with the correct
`--workspace` manifest and the store changed measurably: **1051 → 1101 nodes**,
**2991 → 2969 edges**, **`last_indexed_at` 01:03:56Z → 08:20:24Z**, 198 files scanned,
37 communities, 31 processes, 356 embeddable — confirmed by an independent read of the
runtime's own `/api/repos` endpoint, not only by the indexer's self-report.

Caveat carried forward: the shared `memcore-server` entered a restart loop ~4 minutes
into the run (§5), VAD/MCP-updater were not indexed, and one hung client process remains.
