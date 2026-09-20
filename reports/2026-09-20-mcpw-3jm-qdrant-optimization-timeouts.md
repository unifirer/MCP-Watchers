# mcpw-3jm — qdrant `optimization_worker` handle-timeout warnings

Date: 2026-09-20 · Branch: mcpw-sweep-20260920-1305 · Read-only investigation
Status: **CAUSAL LINK TO EMPTY COLLECTIONS NOT ESTABLISHED** · **CONTAINER RESOURCE-LIMIT ALTERNATIVE REFUTED** (direct counter-evidence found)

---

## 1. The warnings, verbatim and complete

`docker logs --timestamps qdrant-grepai` contains **exactly 7** occurrences of

```
WARN collection::update_workers::optimization_worker: Cleaned an optimization handle after timeout, explicitly triggering optimizers
```

| # | UTC |
|---|---|
| 1 | 2026-09-18T17:28:16.256323Z |
| 2 | 2026-09-18T21:04:54.245974Z |
| 3 | 2026-09-19T00:13:52.413981Z |
| 4 | 2026-09-19T05:14:17.356748Z |
| 5 | 2026-09-19T05:48:37.087030Z |
| 6 | 2026-09-19T06:22:03.653096Z |
| 7 | 2026-09-19T08:10:37.236091Z |

Gaps: 3 h 37 m · 3 h 09 m · 4 h 59 m · 34 m · 34 m · 1 h 48 m. The bead's "roughly every 30-90 min" holds only for the 05:14→06:22 stretch; the series is **bursty, not periodic**.

**All 7 sit inside the container's FIRST lifetime** (started 2026-09-18T14:22:25Z). **Zero** have occurred since the 2026-09-19T11:19:47Z restart — a 14+ hour window.

## 2. Collection inventory (measured 2026-09-20 via REST :16333)

```
collections          = 73      (bead said 54 — it has grown)
temp-like            = 70      (C__Users_yuni_AppData_Local_Temp_gh_clean_* / gh_wt_*)
real                 =  3      J__audio_MCP-Watchers, J__audio_MCP-Watchers-wt-fixtests-1907, J__audio_VAD
total_segments       = 584
total_points         = 1406
nonzero_collections  = 2       J__audio_MCP-Watchers (892 pts, 8 seg)
                               J__audio_MCP-Watchers-wt-fixtests-1907 (514 pts, 8 seg)
optimizer_status     = ok for all 73
wal_capacity_mb      = 32 for every collection  →  73 x 32 = 2336 MB of WAL capacity configured
```

So **568 of 584 segments (97%) belong to 0-point collections** — each empty leftover still carries 8 segments. The bead's structural description is accurate (and now larger than reported).

## 3. Container resource limits — **REFUTED**

```
docker inspect qdrant-grepai:
  NanoCpus=0  CpuQuota=0  CpuPeriod=0  Memory=0  MemoryReservation=0  MemorySwap=0
docker stats --no-stream:
  qdrant-grepai   5.62% CPU   694.6MiB / 15.57GiB   4.36%
docker info:  MemTotal=16720224256 (15.6 GiB)   NCPU=16
```

**There is no CPU or memory cap on the container at all.** It is running at ~4.4% of host memory and ~5.6% of one core's worth of CPU. A container-limit-induced resource-pressure explanation is not supported.

## 4. The causal link to the empty collections — counter-evidence

The hypothesis predicts that the 70 empty collections (each with 8 segments and a 32 MB WAL) drive the optimizer over its timeout. The strongest test available without deleting anything (mcpw-0uo owns that) is: **do warnings continue while collections keep being created?**

They do not.

```
warnings AFTER 2026-09-19T11:19:47Z = 0

"Creating collection" events AFTER the restart (same log):
  2026-09-19T12:46:07.762Z  C__Users_yuni_AppData_Local_Temp_gh_clean_45f53389ceae4ec484c191b178999512
  2026-09-19T12:46:11.149Z  C__Users_yuni_AppData_Local_Temp_gh_wt_f84a203f8ad04f939491c7c0e51aeea5
  2026-09-19T17:24:54.098Z  C__Users_yuni_AppData_Local_Temp_gh_clean_6a30e95e1e4a435db3d7d27a495fe3c7
  2026-09-19T17:24:59.944Z  C__Users_yuni_AppData_Local_Temp_gh_wt_537bc8bf3659464ab86185b1bda463d3
  2026-09-19T17:29:18.311Z  C__Users_yuni_AppData_Local_Temp_gh_clean_b227d9b2ca5a497daf10ce89b5f5bd6c
  2026-09-19T17:29:21.854Z  C__Users_yuni_AppData_Local_Temp_gh_wt_5b4ace7bf6c74ebca186ba07fc84fd98
  2026-09-19T17:37:59.023Z  C__Users_yuni_AppData_Local_Temp_gh_clean_2a1186767dc94874a1ac7293f80e7167
  2026-09-19T17:38:07.235Z  C__Users_yuni_AppData_Local_Temp_gh_wt_c62ae31e29db4c1e8fad9f0cd665d656
  2026-09-19T17:42:08.656Z  C__Users_yuni_AppData_Local_Temp_gh_clean_ee1463fc7fd547d0b3e33ddbb93663fd
  2026-09-19T17:42:19.852Z  C__Users_yuni_AppData_Local_Temp_gh_wt_6ae2514614b1482b8f0dab11337a4d4e
  ...
```

Collection creation resumed in bursts (12:46, 17:24, 17:29, 17:37, 17:42 …) and produced **no** optimization-handle timeouts. Collection count is therefore **not sufficient** to produce the warning, and the observed data does not support it as the cause.

## 5. What the data *does* correlate with

Every warning falls in the container lifetime that began with **fresh, empty storage**:

```
2026-09-18T14:22:25.879566Z  INFO storage::content_manager::consensus::persistent: Initializing new raft state at ./storage/raft_state.json
```

versus the second lifetime, which loads state from disk:

```
2026-09-19T11:19:48.849585Z  INFO storage::content_manager::consensus::persistent: Loading raft state from ./storage/raft_state.json
2026-09-19T11:19:48.879787Z  INFO storage::content_manager::toc: Loading collection: C__Users_yuni_AppData_Local_Temp_gh_wt_c0c83c7a88174ba687ccd11f2ac557c0
2026-09-19T11:19:48.917736Z  INFO collection::shards::local_shard: Recovering shard .../0: 0/1 (0%)
2026-09-19T11:19:48.989157Z  INFO collection::shards::local_shard: Recovered collection ...: 1/1 (100%)
```

In lifetime 1 **all 73 collections were created from nothing** (73 `Creating collection` lines) and each was optimized from scratch; the warnings start 3 h 06 m after that lifetime began. In lifetime 2 the collections are loaded and already optimized, so the optimizer has far less to do — and stays quiet despite new creations.

That is a *different* correlate from the bead's hypothesis: not "N collections exist" but "many collections are being (re)optimized from scratch". It is **suggestive, not established** — I cannot distinguish it from "the first lifetime simply ran long enough to hit a rare timeout" with the data available.

## 6. Evidence still missing

1. **The qdrant optimizer timeout value and the queue depth at the moment of each warning.** The log records neither. Without `optimizer` metrics at :16333/metrics sampled at the time, or a reproduction, the mechanism inside `optimization_worker` cannot be pinned.
2. **No reproduction is possible in this wave** — deleting the 70 leftovers is mcpw-0uo's job and is explicitly out of scope here. That deletion is the natural experiment: if the warnings return after it with creation bursts, the empty-collection link is refuted outright; if they never return, it stays unproven but consistent.
3. **Whether any warning was ever accompanied by a user-visible failure.** All 73 collections report `optimizer_status: ok` and the container is `green`; I found no evidence the warnings caused an outage.
