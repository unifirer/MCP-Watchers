# Debug report: grepai watcher dies repeatedly under `###1`

Date: 2026-09-17
Scope: read-only diagnosis. No file was modified.
Reporter note: all timestamps are local (UTC+12).

---

## 1. Verdict

The watcher is not crashing. **The `###1` supervisor kills it deliberately.**

The idle-TTL reaper in `###1` measures "idle" from a grepai worktree log that the
live watcher never writes. The log is stale. The reaper reads a stale timestamp,
computes a huge idle age, passes the 20-minute TTL, and terminates a watcher that
is demonstrably active. A pane tailer then relaunches it. That cycle is the
"constantly dying" symptom.

---

## 2. Evidence chain

### 2.1 The watcher is alive and active right now

| Fact | Value |
|---|---|
| Process | PID 34484, `grepai.exe watch` |
| Started | 2026-09-16 23:22:21 |
| Parent | PID 97016 = `powershell -File C:\Temp\vad-watchers\panes\tail_grepai.ps1` |
| RSS | 2.3 GB - 4.6 GB (observed fluctuating within 6 minutes) |
| `.grepai/config.yaml` `watch.last_index_time` | `2026-09-17T03:46:15` |

`last_index_time` was 4 minutes old at measurement time. The watcher is working.

### 2.2 The supervisor killed the previous watcher

From `C:\Users\yuni\AppData\Local\grepai\logs\supervisor.log`:

```
[2026-09-16T23:19:01] supervisor started (enhanced: auto-heal + stale-lock cleanup)
[2026-09-16T23:19:01] grepai idle TTL armed: 20 minute(s) (0 = disabled)
[2026-09-16T23:19:03] tracking grepai watch PID 51864 (adopted single live watcher)
[2026-09-16T23:20:43] grepai idle 156.8 min (TTL 20 min) - reaping watcher, supervisor exiting (no relaunch)
```

The supervisor adopted PID 51864 and terminated it 100 seconds later.

### 2.3 The idle number is derived from a dead log file

Newest file matching the pattern the idle clock reads
(`%LOCALAPPDATA%\grepai\logs\grepai-worktree-*.log`):

- `grepai-worktree-88bc7aee8890.log`
- Last write: **2026-09-16 20:43:53** (7 hours stale at measurement)
- Last non-housekeeping line: `[grepai-watch] 2026/09/16 20:43:53.465485 RPG graph built for J:\audio\VAD: 45095 nodes, 36513 edges`

Arithmetic that proves the link:

```
23:20:43 (reap)  -  20:43:53 (log stamp)  =  156.83 min
supervisor reported                       =  156.8  min
```

Exact match. The reaper read that file and nothing else.

At measurement time (03:50:55) the same computation yields **427 minutes idle**
against a 20-minute TTL. Any supervisor start now reaps instantly.

### 2.4 Why the live watcher never refreshes that file

The launcher starts grepai with redirected output:

- `###2.launch_watcher_for_grepai.ps1` lines 297-299 and 328-330
  `-RedirectStandardOutput C:\Temp\vad-watchers\watchers\grepai-launch.log`
  `-RedirectStandardError  C:\Temp\vad-watchers\watchers\grepai-launch.log.err`

Those two files are live and growing (12 MB stdout, 24 KB stderr). The
`grepai-worktree-*.log` files under `%LOCALAPPDATA%` are not written by a
redirected instance. So the file the idle clock depends on is only ever produced
by un-redirected runs - the last one was 2026-09-16 20:43.

This makes the failure self-perpetuating: every reap is followed by a redirected
relaunch, which leaves the stale log stale, which guarantees the next reap.

### 2.5 Why the "unknown" guard does not fire

`Modules\watcher_job_helpers.ps1`, `Get-GrepaiIdleMinutes` (lines 310-334):

- Returns `-1` (do not reap) when there is no log, or the timestamp cannot be parsed.
- The log here **exists and parses**. It is only *stale*.
- There is no freshness check on the log file itself.

The guard covers "cannot measure". It does not cover "measured the wrong clock".

### 2.6 Reap history confirms a long-running pattern

Repeated identical events, each about 1-2 minutes after a supervisor start:

```
2026-09-15T23:48:04  idle 276.4 min - reaping watcher
2026-09-16T00:07:04  idle 295.4 min - reaping watcher
2026-09-16T00:58:03  idle 346.4 min - reaping watcher
2026-09-16T04:56:02  idle 584.3 min - reaping watcher
2026-09-16T06:24:26  idle  20.2 min - reaping watcher
2026-09-16T06:35:15  idle  31.0 min - reaping watcher
2026-09-16T18:22:14  idle  47.1 min - reaping watcher
2026-09-16T23:20:43  idle 156.8 min - reaping watcher
```

Eight confirmed reaps in 24 hours. The age is always measured against a log
untouched since some earlier run - never against the running watcher.

---

## 3. Code locations

| What | Where |
|---|---|
| TTL armed, default 20 min | `###1...ps1` lines 1198-1209 |
| Idle probe + PID-scoped reap | `###1...ps1` lines 1392-1421 |
| Actual kill | `###1...ps1` line 1416, `Stop-TrackedGrepaiTree` |
| Idle clock (stale-log read) | `Modules\watcher_job_helpers.ps1` lines 306-334 |
| Activity-line filter | `Modules\watcher_job_helpers.ps1` lines 297-304 |
| TTL knob reader | `Modules\watcher_job_helpers.ps1` lines 340-351 |
| Relaunch after each reap | `C:\Temp\vad-watchers\panes\tail_grepai.ps1` lines 759-763, 666 |

`idle_timeout_minutes` is **absent** from `.grepai/config.yaml`, so the 20-minute
default applies.

---

## 4. Contributing issues found (secondary)

1. **Worktree watcher churn.** `grepai-launch.log` holds 46 `Initial scan complete`
   lines but only 1 `Starting grepai watch`. The live process re-scans repeatedly.
   `grepai-launch.log.err` shows 44 `Watching project:` restarts, always the same
   two ephemeral worktrees under
   `%LOCALAPPDATA%\..\Roaming\pi-desktop\worktrees\vad\`. Restarts occur every
   roughly 2 to 5 minutes. Cause not proven; these paths are outside the repo and
   are managed by another tool.

2. **Memory growth.** PID 34484 moved 2.4 GB to 4.6 GB in six minutes. A future
   OOM kill is plausible and would be an independent death cause.

3. **Transient disk error.** `2026/09/17 03:20:22 Warning: failed to persist index
   for J:\audio\VAD: ... Insufficient quota to complete the requested service.`
   J: reports 72.2 GB free of 644 GB. Not the death cause; worth watching.

4. **No lock files.** No `grepai-worktree-*.pid` files exist in the grepai logs
   directory, so stale-lock recovery paths have nothing to clean.

---

## 5. Proposed fixes (NOT applied - debug only)

Ordered by confidence.

1. **Disable the TTL immediately.** Add `idle_timeout_minutes: 0` under `watch:`
   in `.grepai/config.yaml`. Stops all reaping at once. Lowest risk.

2. **Fix the idle clock source.** Have `Get-GrepaiIdleMinutes` read
   `watch.last_index_time` from `<repo>\.grepai\config.yaml`. grepai writes it
   itself on every index operation, so it is authoritative and always current.
   This removes the dependency on log redirection entirely.

3. **Add a freshness guard.** If the newest `grepai-worktree-*.log` is older than
   the current watcher process start time, return `-1` instead of an age computed
   from a previous run's log.

4. **Include the redirect logs in the candidate set.** Let the idle clock also
   scan `C:\Temp\vad-watchers\watchers\grepai-launch.log.err`.

5. **Decide on the pi-desktop worktrees.** If they are not meant to be indexed,
   exclude them; otherwise the re-scan churn continues regardless of the TTL fix.

---

## 5b. Addendum — post-restart re-verification (03:50:55)

Re-measured after a WorkBuddy restart. Every figure in sections 2 and 3
reconfirmed: PID 34484 alive, stale log `grepai-worktree-88bc7aee8890.log`
mtime 2026-09-16 20:43:53, computed idle **427 min** vs TTL 20 min,
`watch.last_index_time` = `2026-09-17T03:46:15`. No change to the verdict.

Three additional findings:

1. **Index content anomaly.** Every scan reports
   `Initial scan complete: 5 files indexed, 0 chunks created, 2365 skipped`
   and `Symbol index built: 0 symbols extracted`, yet
   `J:\audio\VAD\.grepai\index.gob` is 206,156,138 bytes. The index is
   near-empty in content but 206 MB on disk. Separate issue from the death
   loop; worth its own investigation.

2. **Orphan/parent risk.** PID 34484's parent is the pane tailer
   (`tail_grepai.ps1`, PID 97016), not the launcher and not the supervisor.
   Closing that Windows Terminal pane ends the watcher regardless of any
   TTL fix. The parent-death job in `###1` does not cover this instance
   because the pane spawned it.

3. **Relevant config block** (`.grepai/config.yaml`, no
   `idle_timeout_minutes` key present, so the 20-minute default applies):

   ```yaml
   watch:
       debounce_ms: 500
       last_index_time: 2026-09-17T03:46:15.6924979+12:00
       rpg_persist_interval_ms: 60000
       rpg_derived_debounce_ms: 300
       rpg_full_reconcile_interval_sec: 300
       rpg_max_dirty_files_per_batch: 128
   ```

---

## 6. Verification commands (read-only)

```powershell
# current idle age the supervisor would compute
$nw = Get-ChildItem "$env:LOCALAPPDATA\grepai\logs" -Filter 'grepai-worktree-*.log' |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
$nw.Name; $nw.LastWriteTime; ((Get-Date) - $nw.LastWriteTime).TotalMinutes

# true activity clock, written by grepai itself
Select-String -Path 'J:\audio\VAD\.grepai\config.yaml' -Pattern 'last_index_time'

# reap history
Get-Content "$env:LOCALAPPDATA\grepai\logs\supervisor.log" -Tail 20
```

---

## 7. Status

Root cause identified and proven. No changes made, per instruction.
Fix 1 is a one-line config change and requires approval before applying.
