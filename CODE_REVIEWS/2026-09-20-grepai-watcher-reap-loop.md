# Debug report: grepai watcher "constantly dying" — the reap loop is fed by a dead qdrant

Date: 2026-09-20 (~05:30–05:40, UTC+12)
Scope: read-only diagnosis. No source file was modified.
Method: process inventory, supervisor/worktree/launch logs, live HTTP and TCP probes.

---

## 1. Verdict

> **CORRECTION (06:12 NZT).** An earlier version of this report said "grepai's
> qdrant store is down" and called that the root cause. **That was wrong** — see
> §2.1 for why, and §2.6 for what is actually happening. The corrected verdict
> follows.

The watcher is not crashing. **It is being killed deliberately by the `###1`
supervisor's idle-TTL reaper**, roughly one minute after every start, and the
pane tailer immediately launches another one. That spawn/reap cycle is the
symptom.

qdrant is **not** the problem. The store grepai uses has been up and
version-compatible since 23:19 NZT last night, and grepai has been writing to
it the whole time I was calling it dead.

The actual mechanism is a **provision deadlock**:

```
fresh `grepai watch` starts
  → begins its initial scan (slow)
  → last_index_time is still stale from before the outage
  → idle TTL sees ~9 h of idleness against a 20 min threshold
  → supervisor reaps the watcher ~1 min after start
  → pane heals, new watcher, scan restarts from zero
  → clock still stale → reaped again
```

Each watcher is killed before it can finish its scan, so the clock never
advances, so the next one is killed too. **The stale clock is both cause and
effect.** The Docker stack restart (§2.5) started it; the idle TTL kept it
alive for 7 more hours against a healthy store; and it ended on its own at 06:09
NZT once one watcher finally survived long enough to finish.

**The fix that matters is `mcpw-0k7`, not anything qdrant-related.**

---

## 2. Evidence chain

### 2.1 WRONG — my "qdrant is down" measurement was a protocol error

This section is kept because the correction matters more than the original
claim. Do not trust the earlier version of this report on this point.

`.grepai/config.yaml` (J:\audio\MCP-Watchers):

```yaml
store:
    backend: qdrant
    qdrant:
        endpoint: localhost
        port: 16334
```

I probed `16334` over HTTP, got `000`, found no `LISTENING` socket and no
`qdrant` process, and concluded the store was dead. **Every one of those
observations was consistent with a healthy server**, and I misread all three:

| Claim | What it actually meant |
|---|---|
| `curl http://…:16334/ → 000` | 16334 is the **gRPC** port (`0.0.0.0:16334->6334/tcp`). HTTP to a gRPC port returns nothing. Expected. |
| no `LISTENING` socket | qdrant runs in Docker; the host listener is Docker's proxy, and my `netstat` filter missed it. |
| `Get-Process qdrant` → nothing | qdrant is a **container**, not a host process. Of course there is no `qdrant.exe`. |

What the correct probes show:

```
GET http://127.0.0.1:16333/   -> {"version":"1.19.1"}   REST of qdrant-grepai  ← the one grepai uses
GET http://127.0.0.1:6333/    -> {"version":"1.11.3"}   REST of server-qdrant-1 (different, older)
collection J__audio_MCP-Watchers on 16333 -> status green, 710 -> 746 points, queue 0
```

**Port map, so nobody repeats this:**

| Port | What it is |
|---|---|
| 16333 | REST of `qdrant-grepai` (v1.19.1) |
| **16334** | **gRPC of `qdrant-grepai`** ← what `config.yaml` uses |
| 6333 / 6334 | REST / gRPC of `server-qdrant-1` (v1.11.3) |

grepai's client is v1.19.0 and `qdrant-grepai` is **1.19.1** — compatible. The
`serverVersion=1.11.3` warning that appears in the launcher logs comes from the
**VAD** workspace, which points at the older server, not from MCP-Watchers.

Ollama was never implicated: `12134` and `11434` both answer `200`.

**Lesson:** I took one reading of one clock (`last_index_time`), saw it was
stale, and concluded "cannot index". A single reading of a liveness clock is not
evidence about a write path. The write-side signal (`points_count`) told a
different story 30 minutes later.

**Addendum — `mcpw-25p` verification, 05:52–06:20 NZT.** One row of the table
above is still wrong: the missing `LISTENING` socket was **not** a filter
mistake. On this host `netstat -ano` and `Get-NetTCPConnection -State Listen`
report **no** Docker-published port at all — checked for 16333, 16334, 6333,
6334, 7474, 8002, 8400, 3000 and 6379, every one of which answers. Only native
host processes (Ollama, `127.0.0.1:12134`) show up. So `netstat` is **not a
valid liveness probe for any containerised service on this box**; use a TCP
connect or the REST port instead.

Verified state of the store:

| Probe | Result |
|---|---|
| TCP connect `127.0.0.1:16334` | succeeds, `time_connect` 1.2 ms (an HTTP/1.1 GET on it still returns `000` — it is the gRPC port) |
| `GET 127.0.0.1:16333/` | `{"title":"qdrant - vector search engine","version":"1.19.1"}` |
| `docker ps` → `qdrant-grepai` | `qdrant/qdrant:latest`, `0.0.0.0:16333->6333/tcp`, `0.0.0.0:16334->6334/tcp`, Up |
| `docker ps` → `server-qdrant-1` | **`qdrant/qdrant:v1.11.3`** on `6333-6334` — the shared, older instance |
| `qdrant-grepai` container log | still serving at `17:37:59Z` (= 05:37:59 NZT), two minutes after the "no listener" reading |
| grepai initial scan | `Initial scan complete: 100 files indexed, 709 chunks created … (took 1m1.253s)` at 05:52:31; 710 chunks again at 05:56:14 — zero errors |

`store.qdrant.port` therefore stays **16334**. Repointing it at 6333 would trade
a diagnostic artifact for the documented silent-write-failure mode (grepai client
v1.19.0 against that server's v1.11.3). `.grepai/config.yaml` is gitignored, so
this decision can only live in the config — no commit carries it.

### 2.2 The activity clock is frozen, and the TTL reads it

```
.grepai\config.yaml  watch.last_index_time = 2026-09-19T20:49:12.1473187+12:00
computed idle age at 05:35 on 09-20         = 527.1 minutes
idle_timeout_minutes                        = absent → 20-minute default
```

`Get-GrepaiIdleMinutes` takes the **minimum** of the clocks that can prove
activity. The log clock correctly returns `-1` (its VAD-1ak freshness guard sees
the newest worktree log predates the live watcher, so it is excluded). The config
clock has **no such guard**, so 527 min is the only value left — and 527 ≥ 20.

### 2.3 The smoke test: a one-second-old supervisor reports 182 minutes of idleness

From `C:\Temp\vad-watchers\ad90e3fb\watchers\watchers.log`:

```
[2026-09-19T23:51:10] supervisor started
[2026-09-19T23:51:11] grepai idle TTL reached (182 min >= 20 min) - watcher reaped, supervisor exiting (no restart)
```

An idle age of 182 minutes cannot have been accumulated by a supervisor that has
existed for one second. It is inherited from a dead instance.

### 2.4 The churn is large and still running

From `C:\Users\yuni\AppData\Local\grepai\logs\supervisor.log` (819 lines):

| Event | Count |
|---|---|
| `restarted grepai` | 270 |
| `grepai watch exited` | 178 |
| `supervisor started` | 102 |
| `exited immediately after restart` | 92 |
| `idle … reaping watcher` | 14 |
| `launcher gone … supervisor exiting` | 13 |

Live this morning — four `grepai.exe` processes inside 57 seconds:

```
PID 58072  05:29:13  grepai.exe watch      (parent: tail_grepai.ps1)
PID 41396  05:29:34  grepai.exe mcp-serve
PID 75256  05:29:41  grepai.exe mcp-serve
PID 68168  05:30:10  grepai.exe mcp-serve
```

and `C:\Temp\vad-watchers\77442b14\watchers\grepai-launch.log.err` was rewritten
at **05:37:52** by another freshly spawned watcher. The loop is active now.

### 2.5 Why the heal never stops

After the reap the supervisor `return`s, so it stops refreshing
`<lockfile>.sup`. `Test-SupervisorAlive` (60 s window) therefore goes stale, and
the pane tailer — seeing no live watcher *and* no live supervisor — takes its
documented fallback heal and relaunches `grepai watch`. The `<lockfile>.idle`
marker that is supposed to park the pane on IDLE is written only at the moment of
the reap, and the *next* supervisor startup deletes it before it too reaps a
minute later.

---

### 2.6 The Docker stack restart that started it — and why qdrant was not at fault

`docker logs --timestamps qdrant-grepai` contains **exactly two** startup
banners:

```
2026-09-18T14:22:25Z  Version: 1.19.1   (container created)
…                      last log before the gap: 2026-09-19T08:10:37Z
2026-09-19T11:19:48Z  Version: 1.19.1   (restart)
```

(UTC; NZT = UTC+12 → the gap runs ≈ 20:10 → 23:19 NZT on 2026-09-19. grepai's
last index is 20:49 NZT and its last RPG reconcile 21:09 NZT, so the store
became unavailable to grepai at roughly 21:09 NZT — an outage of ≈ 2 h 10 m.)

It was **not** a qdrant fault. Every container on the host restarted within 25
milliseconds of each other:

| Container | StartedAt (UTC) | RestartCount | Exit | OOM |
|---|---|---|---|---|
| neo4j-atlas-mcp-server | 11:19:47.015933 | 0 | 0 | false |
| qdrant-grepai | 11:19:47.019178 | 0 | 0 | false |
| server-flask-api-1 | 11:19:47.020925 | 0 | 0 | false |
| server-falkordb-1 | 11:19:47.033068 | 0 | 0 | false |
| server-qdrant-1 | 11:19:47.036464 | 0 | 0 | false |
| graphiti-mcp | 11:19:47.040063 | 0 | 0 | false |

All `RestartPolicy=unless-stopped`, all `RestartCount=0`. A qdrant crash would
be isolated and would increment the restart count. Six unrelated containers
starting inside 25 ms is the Docker engine or the host coming back — sleep/resume,
Docker Desktop restart, or a WSL shutdown. Nothing in the container log records
a shutdown: no panic, no OOM, no error. **What caused the ~2 h 10 m gap is still
unknown** (`mcpw-25p`).

### 2.7 It self-healed at 06:09 NZT, which proves where the fault is

Measured at ~06:12 NZT on 2026-09-20:

```
last_index_time   2026-09-19T20:49:12  →  2026-09-20T06:09:07
idle age          527 min              →  1.7 min        (TTL is 20)
points_count      710 (05:59)          →  746 (06:06)    ← writes landing
grepai watch      PID 2744, started 05:54:50, alive ~18 min  (was ~1 min)
supervisor stamp  age 0 s              → supervisor live
```

One watcher survived long enough to finish its initial scan. The clock advanced,
idle dropped below the TTL, and the loop stopped by itself — **with no change to
qdrant, to the network, or to any config**. That is the proof that the sustaining
cause was the reap logic and not the store.

## 3. Secondary defects found on the way

| # | Defect | Evidence |
|---|---|---|
| 1 | Crash-restart retry redirects a **second** grepai child into the **same** `grepai-launch.log` / `.err` pair | `###1…ps1` ~1668 and ~1696, both `-RedirectStandardOutput $LaunchLog`. 92 flaps take this path. Explains the interleaved progress bars in the launch logs. |
| 2 | Stale-lock sweep is unscoped and machine-global | `tail_grepai.ps1:666` deletes `grepai-worktree-*.pid*` from `%LOCALAPPDATA%\grepai\logs`, shared by VAD (`77442b14`) and MCP-Watchers (`ad90e3fb`). Observed: the live watcher (PID 58072) was spawned by the **VAD** pane yet logged `Starting grepai watch in J:\audio\MCP-Watchers`. |
| 3 | One `grepai watch` watches four projects, three of them stale scratch worktrees | `grepai-launch.log.err` 05:37:52 lists `gentle-quokka`, `vad-ws-…-el2lns`, `vad-ws-…-yu6kc9` alongside `J:\audio\VAD`. No per-project isolation — one failure takes down all four. |
| 4 | qdrant client/server version mismatch | `WARN Client version is not compatible with server version … clientVersion=v1.19.0 serverVersion=1.11.3` on every start. |

## 4. Optional fixes

- **Guard the config idle clock like the log clock.** In
  `Get-GrepaiIdleMinutesFromConfig`, return `$null` when `last_index_time` is
  older than `Get-GrepaiWatchStartTime`. Callers already treat "unknown" as
  "do not reap". This would have prevented this outage even with qdrant down —
  the watcher would sit idle instead of being reaped once a minute.
- **Set `watch.idle_timeout_minutes` explicitly** (and consider raising the
  20-minute default). Twenty minutes is aggressive for a repo that goes quiet for
  hours. This changes only the frequency, not the existence, of the loop.

---

## 5. Relation to earlier reports

- `docs/CODE_REVIEWS/2026-09-17-grepai-watcher-dies-debug.md` — diagnosed the
  same reap loop via the **log** clock. VAD-1ak fixed that clock; the loop
  migrated to the config clock. Same symptom, same reaper, new input.
- `docs/CODE_REVIEWS/2026-09-18-grepai-crashloop-autoheal-debug.md` — the
  watcher refused to start because the embedder endpoint was wrong (11434 vs
  12134). Not the current fault: both Ollama ports answer 200 today.

---

## 6. Beads filed

Chain (each blocks the next). Corrected 06:12 — `mcpw-0k7` is the one to fix:

```
mcpw-25p  P0  Docker stack restart knocked qdrant offline ~21:09-23:19 NZT
   │           (TRIGGER only — cause of the gap still unknown; store has been up since)
   └─ blocks ─ mcpw-d5l  P0  initial scan never completes: idle TTL reaps the
        │                    watcher before it finishes (provision deadlock)
        └─ blocks ─ mcpw-0wm  P0  last_index_time frozen at 527 min
             └─ blocks ─ mcpw-0k7  P0  idle TTL reaps a HEALTHY watcher ~1 min after start
                  │                    ← ROOT CAUSE, fix this first
                  └─ blocks ─ mcpw-6re  P1  pane fallback heal → infinite spawn/reap cycle
```

Independent, `relates-to` linked:

```
mcpw-0on  P1  retry redirects a second child into the same launch log/err files   ↔ mcpw-6re
mcpw-eud  P2  unscoped global stale-lock sweep crosses workspaces                  ↔ mcpw-6re
mcpw-gox  P2  one watch process watches 4 projects incl. 3 stale worktrees          ↔ mcpw-6re
mcpw-kss  P2  qdrant v1.19.0 vs 1.11.3 compat warning — VAD-side, NOT MCP-Watchers ↔ mcpw-25p
mcpw-0uo  P2  52 of 54 qdrant collections are orphaned gh_clean_*/gh_wt_* leftovers ↔ mcpw-25p
mcpw-3jm  P3  recurring qdrant optimization-handle timeout warnings                 ↔ mcpw-25p, mcpw-0uo
mcpw-3si  P3  OPTIONAL: guard the config idle clock like the log clock              ↔ mcpw-0k7
mcpw-zc3  P3  OPTIONAL: set idle_timeout_minutes explicitly, raise the default      ↔ mcpw-0k7
```

`bd sync` run: exit 0. No Dolt remote is configured, so the push step was
skipped; issues are held locally in `.beads/`. Note: `bd dolt status` reports the
Dolt server is **not running** (expected port 43413), so auto-commit is operating
against the local store only.

---

## 7. Suggested order of work

*(Rewritten 06:12 — the original ordering was built on the wrong root cause.)*

1. **`mcpw-0k7` — stop the reaper from firing on a clock it did not measure.**
   This is the fix. Minimum viable change: do not apply the idle TTL to a
   watcher that has not yet advanced the clock it is judged by — either exempt
   any watcher younger than the TTL, or suppress the reap while an initial scan
   is in progress. Without this, any future backend blip re-enters the deadlock
   even after the backend recovers.
2. **`mcpw-3si` (optional but cheap)** — guard the config clock the way the log
   clock is already guarded. Belt and braces: turns the next such outage into
   "idle" instead of "thrashing".
3. **`mcpw-25p`** — explain the ≈2 h 10 m gap (host event log, Docker Desktop
   log, WSL). Worth knowing, but the stack is healthy now and this is not what
   stops the churn.
4. **P1/P2 hygiene** — `mcpw-6re`, `mcpw-0on`, `mcpw-eud`, `mcpw-gox`, then the
   qdrant-side items `mcpw-0uo` (52 orphaned collections) and `mcpw-3jm`.

Note `mcpw-kss` should be actioned against the **VAD** repo's config, not this
one — MCP-Watchers points at the compatible v1.19.1 server.
