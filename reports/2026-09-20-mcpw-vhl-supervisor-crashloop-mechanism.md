# mcpw-vhl — mechanism behind "exited immediately after restart" ×92

Date: 2026-09-20 · Branch: mcpw-sweep-20260920-1305 · Read-only investigation
Status: **MECHANISM ESTABLISHED** (the 92/94 flaps are not an in-process crash — they are grepai's own single-instance guard rejecting a respawn)

---

## 1. What the counter actually counts

`C:/Users/yuni/AppData/Local/grepai/logs/supervisor.log`, recounted 2026-09-20 13:1x NZT:

| pattern | count |
|---|---|
| `restarted grepai` (includes `retry restarted grepai`) | **290** |
| `grepai watch exited - restarting in 1s` | **196** |
| `supervisor started` | **108** |
| `exited immediately after restart` | **94** |
| `retry restarted grepai` | **94** |
| `idle ... reaping watcher` | 17 |

Arithmetic: `196 exits + 94 retries = 290 restarts`. So **94 is not an independent failure class.** It is the supervisor's own 2-second post-restart verification failing, and it fires exactly once per "watcher exited" in 94 of the 196 cycles.

Source of the message — `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1:1743`:

```
Start-Sleep 2
$verify = Get-Process -Id $gp.Id -ErrorAction SilentlyContinue
if ($null -eq $verify) {
    Write-SupLog "grepai (PID $($gp.Id)) exited immediately after restart - clearing locks and retrying once"
```

So the assertion "the freshly spawned watcher dies at once" is correct — but *what kills it* is not a crash.

## 2. The kill: grepai's own single-instance guard

`C:\Temp\vad-watchers\watchers\grepai-launch.log.err`, **mtime 2026-09-20 07:10:14**, entire content (47 bytes):

```
Error: watcher is already running (PID 65534)
```

and `C:\Users\yuni\AppData\Local\grepai\logs\fg-err3.log`:

```
Error: watcher is already running in background (PID 93688)
Use 'grepai watch --stop' to stop it
```

Alignment with the supervisor log is exact — the 07:10 crash-restart cycle:

```
[2026-09-20T07:10:01] grepai watch exited - restarting in 1s
[2026-09-20T07:10:03] restarted grepai (PID 6228)
[2026-09-20T07:10:05] grepai (PID 6228) exited immediately after restart - clearing locks and retrying once
[2026-09-20T07:10:08] retry restarted grepai (PID 86624)
[2026-09-20T07:10:30] grepai watch exited - restarting in 1s
```

The refusal lands at **07:10:14**, i.e. between the retry spawn (07:10:08) and its death (07:10:30).

**The named PID is decisive.** At 07:10:14 the supervisor had spawned only `6228` (dead) and `86624` (live). The blocker is `65534` — a **different, concurrently-running grepai instance**. This is not an in-process crash and not a stale-lock artefact that names itself: it is a *cross-instance* lock race.

Why cross-instance is possible here: grepai's lock directory is machine-global. `Modules/watcher_job_helpers.ps1:35-40`:

> `# mcpw-eud: %LOCALAPPDATA%\grepai\logs is MACHINE-GLOBAL - every repository on this box writes there (J:\audio\VAD and J:\audio\MCP-Watchers both do).`

and the second workspace's error log shows one `grepai.exe` serving four projects at once:

```
2026/09/20 05:37:52 Watching project: C:\Users\yuni\.local\share\opencode\worktree\30dc0bcc...\gentle-quokka (backend: gob)
2026/09/20 05:37:52 Watching project: J:\audio\VAD (backend: qdrant)
```

The supervisor's liveness gate is machine-wide (`$watchProcs.Count -gt 0`, launcher line ~1667) but the respawn happens **after** `Clear-StaleLocks` + `Start-Sleep 1` + `Start-Sleep 2` (launcher lines 1710-1745). A sibling launcher or supervisor that spawns inside that window wins the lock and our child exits at once; the retry 2 s later usually wins. That is the loop.

## 3. Confirmation from the retry's own log

The retry at 07:10:08 (PID 86624) is the run that wrote
`C:\Users\yuni\AppData\Local\grepai\logs\grepai-worktree-0882dce4c425.log`:

```
[grepai-watch] 2026/09/20 07:10:15.653012 Starting grepai watch in J:\audio\MCP-Watchers
[grepai-watch] 2026/09/20 07:10:16.718957 Performing initial scan...
[grepai-watch] 2026/09/20 07:10:20.306878 Reused 2 cached embeddings for .mcp.json
```

736 bytes, mtime 07:10, then **nothing** — no `Initial scan complete` line. It died mid-scan at ~07:10:30, matching `[07:10:30] grepai watch exited`. Contrast the healthy current watcher, which does finish
(`C:\Temp\vad-watchers\ad90e3fb\watchers\grepai-launch.log`):

```
Initial scan complete: 107 files indexed, 819 chunks created, 0 files removed, 0 skipped (took 1m39.242s)
```

## 4. What is NOT the mechanism

- **Not the idle TTL** for this counter: only 17 idle reaps vs 196 exits. Confirmed.
- **Not a corrupt index / gob repair**: `Repair-CorruptGobIndex` runs on every restart and the retry still succeeds.
- **Not `Start-WatcherDetached`'s machine-wide dedup** (launcher lines ~2078-2095): grepai is never launched through it. `Stop-WatcherOrphans` is called only as `@("gm", "graphify-rs", "repowise")` (line 2566) — grepai is absent.

## 5. Confirmed secondary defect (stale liveness clock)

The bead's warning is borne out. At `[2026-09-20T08:28:58] grepai idle 20.4 min (TTL 20 min) - reaping watcher` the supervisor reaped a watcher that was **actively writing** every 5 minutes up to 08:26:54:

```
2026/09/20 08:21:53 rpg_full_reconcile_triggered=true project=J:\audio\MCP-Watchers reason=periodic
2026/09/20 08:26:53 rpg_full_reconcile_triggered=true project=J:\audio\MCP-Watchers reason=periodic
2026/09/20 08:26:54 rpg_persist_ms=5 project=J:\audio\MCP-Watchers persist_lag_ms=696
```

while `.grepai/config.yaml` holds `watch.last_index_time: 2026-09-20T08:08:37.2677539+12:00` — an 18-minute lag behind real activity. Same shape at `[05:40:07] grepai idle 530.9 min`. So the write path was alive; only the clock was stale. (This is a reaper-correctness bug, not the dominant churn.)

## 6. Evidence still missing

1. **Whether PID 65534 was live or a stale marker.** I could not resolve it after the fact (no PID history on this box). The message names a PID ≠ the child just spawned, which proves a *competing* holder existed, but not whether grepai liveness-checks that PID before refusing.
2. **Which sibling instance it was** (VAD launcher, a worktree launcher, or a second MCP-Watchers supervisor). `supervisor started` ×108 with a changing adopted PID (05:35:29 → PID 58072, 05:38:32 → PID 66684) shows the launcher itself restarts often, but the correlation is not 1:1.
3. **The initiating death of each tracked watcher** is a *mixture*, not one cause: launcher takeover kills the recorded `GrepaiPid` via `Stop-AllWatchers` by design (launcher lines 306, 419), and the idle TTL contributes its 17.

## 7. Cheapest discriminating test (not run — would require launching watchers)

Instrument the respawn window: log `Get-CimInstance Win32_Process -Filter "Name='grepai.exe'"` (PIDs + CreationDate + ParentProcessId) immediately **before** the restart spawn and again at +2 s, then correlate against `%LOCALAPPDATA%\grepai\logs\grepai-stop-*` / `grepai-worktree-*.pid*`. If a foreign PID appears in the window, the race is proven end-to-end and the fix is a machine-wide spawn mutex (the existing `Global\VAD_Grepai_Heal` is only taken on the *no-watcher* path, not around the spawn).
