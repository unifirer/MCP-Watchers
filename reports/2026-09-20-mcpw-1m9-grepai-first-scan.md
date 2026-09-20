# mcpw-1m9 — grepai: finish the first scan

- **Date:** 2026-09-20
- **Branch:** `mcpw-sweep-20260920-1305`
- **Repo:** `J:\audio\MCP-Watchers`
- **grepai:** v0.37.0 (`C:\Users\yuni\AppData\Local\Programs\grepai\grepai.exe`)
- **Verdict:** **COMPLETED** — the first scan finished and the index is live and searchable.
  The bead's stated completion criterion (`grepai status` → `Files indexed > 0`) is
  **unsatisfiable on the qdrant backend** and is a grepai defect, not an indexing failure.
  See §5.

---

## 1. Config — unchanged, verified before any action

`.grepai/config.yaml` was read and left untouched (sha of the file's `embedder`/`store`
blocks matched the bead description exactly):

```yaml
embedder:
    provider: ollama
    model: nomic-embed-text
    endpoint: http://127.0.0.1:12134
    dimensions: 768
    parallelism: 4
store:
    backend: qdrant
    qdrant:
        endpoint: localhost
        port: 16334
```

No `collection` / `vector` overrides. Ollama is on **:12134** (not 11434) and was not
"fixed". Nothing in this report changed the config.

---

## 2. BEFORE

Two baselines, because the scan had already started before this session began.

**(a) Bead baseline, 2026-09-20 ~06:43 NZT** (recorded in mcpw-1m9):

```
Files indexed: 0
Total chunks: 714
Watcher: not running
```

**(b) My baseline, 2026-09-20 20:12 NZT:**

```
$ grepai status --no-ui
grepai index status
Files indexed: 0
Total chunks: 1264
Index size: N/A
Last updated: 2026-09-20 20:12:00
Provider: ollama (nomic-embed-text)
Watcher: running (PID 35460)
Watcher log: C:\Users\yuni\AppData\Local\grepai\logs\grepai-worktree-0882dce4c425.log
```

```
$ curl --noproxy '*' http://127.0.0.1:16333/collections/J__audio_MCP-Watchers
"points_count": 1264, "status": "green"
```

Note the bead's "Watcher: not running" had already become "Watcher: running (PID 35460)"
and chunks had grown 714 → 1264 by the time this session started.

---

## 3. The scan — it ran to completion

The scan was **already in flight** when I started (watcher spawned 19:56:37 NZT).
I did not kill it; I let it run and captured the completion record. It completed at
**20:01:47 NZT, 4m34.08s** after it started, with no reap.

`C:\Users\yuni\AppData\Local\grepai\logs\grepai-worktree-0882dce4c425.log`:

```
[grepai-watch] 2026/09/20 19:56:37.968082 Starting grepai watch in J:\audio\MCP-Watchers
[grepai-watch] 2026/09/20 19:56:37.991663 Provider: ollama (nomic-embed-text)
[grepai-watch] 2026/09/20 19:56:37.991663 Backend: qdrant
[grepai-watch] 2026/09/20 19:57:02.763548 [QUEUED] J:\audio\MCP-Watchers - primary
[grepai-watch] 2026/09/20 19:57:03.371208 Watching project: J:\audio\MCP-Watchers (backend: qdrant)
[grepai-watch] 2026/09/20 19:57:13.405786 Performing initial scan...
...
[grepai-watch] 2026/09/20 20:01:47.487148 Initial scan complete: 160 files indexed, 1249 chunks created, 0 files removed, 0 skipped (took 4m34.08s)
[grepai-watch] 2026/09/20 20:01:47.488997 Building symbol index...
[grepai-watch] 2026/09/20 20:01:47.579963 Symbol index built: 38 symbols extracted
[grepai-watch] 2026/09/20 20:01:52.346536 RPG graph built for J:\audio\MCP-Watchers: 759 nodes, 1469 edges
[grepai-watch] 2026/09/20 20:01:52.626531 [RUNNING] J:\audio\MCP-Watchers - steady
```

**No idle-TTL reap occurred during this run** (mcpw-rkg.4 hazard did not fire here).
The watcher PID 35460 stayed alive from 19:56:37 through the end of this session
(>25 minutes), through a completed scan and continuous incremental writes.

Incremental writes continued after the initial scan, all logged:

```
20:02:19 Treating DELETE of .claude\CLAUDE.md as a modification: file is still on disk (atomic write)
20:02:20 Indexed .claude\CLAUDE.md (4 chunks)
20:02:39 Indexed .repowise\knowledge-graph.json (161 chunks)
20:05:10 Indexed .workbuddy-ai\memory\2026-09-20.md (52 chunks)
20:08:13 Indexed .workbuddy-ai\memory\MEMORY.md (9 chunks)
20:11:53 rpg_persist_ms=11 project=J:\audio\MCP-Watchers persist_lag_ms=971
```

---

## 4. AFTER — write-side verification (the signal that actually matters)

The bead correctly notes that `watch.last_index_time` is written at scan/checkpoint
boundaries, so it is not per-write evidence. The write side is therefore proven two
ways: the store's own point count, and an end-to-end functional search.

### 4a. Store point count

```
$ curl --noproxy '*' http://127.0.0.1:16333/collections/J__audio_MCP-Watchers
"points_count": 1266, "status": "green", "indexed_vectors_count": 0, "segments_count": 8
```

1264 (my baseline) → **1266** (during the session). The `content_hash` payload index
that grepai creates (`store/qdrant.go: ensureCollection`) is present:

```
"payload_schema": { "content_hash": { "data_type": "keyword", "points": 1266 } }
```

### 4b. Distinct files actually in the store

`grepai status` cannot tell us this, so I paged the whole collection and counted
distinct `file_path` payload values:

```
$ python -c "… paged POST /collections/J__audio_MCP-Watchers/points/scroll …"
pages: 2 total_points_scrolled: 1264
DISTINCT_FILES_IN_STORE: 163
```

**163 distinct files / 1264 points.** The scan's own claim (160 files, 1249 chunks at
completion) plus subsequent incremental writes reconciles to this.

### 4c. Functional proof — search returns real content

```
$ grepai search "qdrant collection naming"
Found 10 results for: "qdrant collection naming"

─── Result 1 (score: 0.4841) ───
File: .serena\project.yml:150-169
Feature: .serena/project/general
...
─── Result 2 (score: 0.4578) ───
File: .repowise\knowledge-graph.json:8789-8797
...
```

Semantic search against the qdrant store works. There is nothing "empty" about this index.

### 4d. Live end-to-end write proof (file on disk → qdrant point)

This report file itself was used as the write probe. Writing it triggered the running
watcher to embed and persist it:

```
[grepai-watch] 2026/09/20 20:23:02.380006 Indexed reports\2026-09-20-mcpw-1m9-grepai-first-scan.md (7 chunks)
```

```
points_count: 1266  →  1273      (+7 chunks, matching the 7 logged)
```

Full chain confirmed working in one shot: filesystem event → chunker → ollama
(`nomic-embed-text` @ 127.0.0.1:12134) → qdrant `J__audio_MCP-Watchers` @ 16334.
This is a per-write signal, independent of `watch.last_index_time`.

### 4e. AFTER `grepai status`

```
$ grepai status --no-ui
grepai index status
Files indexed: 0
Total chunks: 1266
Index size: N/A
Last updated: 2026-09-20 20:22:41
Provider: ollama (nomic-embed-text)
Watcher: running (PID 35460)
```

| Metric | Before (06:43) | My baseline (20:12) | After (20:23) |
|---|---|---|---|
| Files indexed (grepai) | 0 | 0 | **0** |
| Total chunks (grepai) | 714 | 1264 | **1273** |
| qdrant points_count | — | 1264 | **1273** |
| distinct files in store | — | — | **163** (+ this report) |
| Watcher | not running | running | **running** |

---

## 5. Root cause of `Files indexed: 0` — a grepai defect, proven from source

`grepai status` prints `Files indexed` from `IndexStats.TotalFiles`:

```go
// cli/status.go  →  renderStatusSummary / viewStats
sb.WriteString(fmt.Sprintf("Files indexed: %d\n", stats.TotalFiles))
sb.WriteString(fmt.Sprintf("Total chunks: %d\n", stats.TotalChunks))
```

Both fields come from one call, `st.GetStats(ctx)`. The **Qdrant** implementation of
`GetStats` (`store/qdrant.go`, upstream `main`) hardcodes the file count to zero:

```go
func (s *QdrantStore) GetStats(ctx context.Context) (*IndexStats, error) {
	collectionInfo, err := s.client.GetCollectionInfo(ctx, s.collectionName)
	...
	stats := &IndexStats{
		TotalFiles:  0,                      // <-- HARDCODED. Never computed.
		TotalChunks: int(pointsCount),       // <-- accurate (points_count)
		IndexSize:   0,
		LastUpdated: time.Now(),
	}
	return stats, nil
}
```

`ListFilesWithStats` (which *does* correctly enumerate files by scrolling and grouping
`file_path`) is called by `status` only to populate the interactive browser list —
it never feeds the "Files indexed" counter.

**Consequences, all matching observation:**

- `Files indexed` is **0 for every qdrant-backed project, always** — 714, 892, 1264 and
  1266 chunks all reported 0. It is a constant, not a measurement.
- `Total chunks` *is* accurate (`= points_count`), which is why 1264/1266 tracked reality.
- The same store is simultaneously fully populated and searchable (§4).
- Independent confirmation that the deployed binary contains this code path: the
  v0.37.0 binary embeds `runner/work/grepai/grepai/store/qdrant.go` and the exact
  error string `failed to get collection info: %w` from that function.

### Corroborating control: the `file_path` payload index is *not* the cause

I tested the competing hypothesis that the counter was a failed distinct-count needing
a payload index. Creating `file_path` as a keyword payload index made qdrant's `facet`
API work:

```
before: {"status":{"error":"Wrong input: No appropriate index for faceting: `file_path`…"}}
after:  {"result":{"hits":[{"value":".repowise\\knowledge-graph.json","count":161}, …]}}
```

…and `grepai status` **still** printed `Files indexed: 0`. That rules facet out and
isolates the hardcoded `TotalFiles: 0`. The experimental index was then deleted to
leave the store in its found state:

```
$ curl -X DELETE '…/collections/J__audio_MCP-Watchers/index/file_path?wait=true'
{"result":{"operation_id":18300,"status":"completed"},"status":"ok"}
$ …payload_schema  →  { "content_hash": { … } }   # back to original
```

### Impact on the epic (mcpw-rkg / mcpw-rkg.1 detection contract)

`Modules/watcher_mcp_detect.ps1: Test-GrepaiInitialized` requires
`Files indexed > 0` and returns `false` on 0, with the reason
*"grepai status reports Files indexed: 0 (config present, index empty)"*.

Because `TotalFiles` is hardcoded to 0 for the qdrant backend, **this predicate can
never return true for this repository's configuration.** The launcher will report
grepai as uninitialized forever, no matter how many times the scan completes. The
detection contract needs a different grepai signal for the qdrant backend —
e.g. `Total chunks > 0`, or `store.ListFilesWithStats` / a search probe.

---

## 6. What I changed

- `reports/2026-09-20-mcpw-1m9-grepai-first-scan.md` (this file) — new.
- One **temporary** qdrant payload index on `file_path`, created to falsify a
  hypothesis, then **deleted** in the same session (§5). Store is back to its found
  state; the only remaining index is grepai's own `content_hash`.
- No tracked file was edited. No `git add` / `git commit` / `git checkout` was run.
- No LLM model configuration was touched.

## 7. Verdict

**COMPLETED.** The first scan ran to completion in 4m34s with no reap, and the index is
live: 1266 points, 163 distinct files, `grepai search` returns real results, watcher
steady. The literal acceptance string `Files indexed > 0` is unreachable because of the
upstream `QdrantStore.GetStats` hardcode documented in §5 — that is a grepai defect and
a detection-contract bug in `Modules/watcher_mcp_detect.ps1`, not an unfinished scan.
