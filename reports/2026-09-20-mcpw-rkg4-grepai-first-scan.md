# mcpw-rkg.4 - make the grepai first scan survive the supervisor idle-TTL reap

Date: 2026-09-20
Branch: `mcpw-sweep-20260920-1305`
File changed: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`
Status: edits left DIRTY (not committed, not staged) - another process owns the index.
Epic: mcpw-rkg. Parent: mcpw-rkg.3 (the provision wiring, same file).

## The mechanism, measured (not re-derived from the bead)

The idle TTL reaps a watcher when `$idleMin >= $idleTtlMin` (default 20 min).
`$idleMin` is `Get-GrepaiIdleMinutes`, the MINIMUM of two clocks:

- `watch.last_index_time` in `.grepai/config.yaml` (`Get-GrepaiIdleMinutesFromConfig`),
- the newest real-activity line in the newest `grepai-worktree-*.log`
  (`Get-GrepaiIdleMinutesFromLog`, housekeeping filtered by `Test-GrepaiActivityLine`).

**Both are written at scan/checkpoint boundaries, not per write.** A first scan of
a large repository therefore has a stretch longer than the TTL in which neither
clock moves while grepai is in fact busy writing chunks. The supervisor then
reaps a LIVE scanning watcher, the scan restarts from zero, and it can never
complete. The measured fingerprint is exactly the bead's: `grepai status`
reporting `Files indexed: 0` while `Total chunks` climbs (714 at the time of the
bead, 1264 by the time I measured) - the write side is alive, the file counter
never leaves zero.

Write-side cross-check (as the bead instructed), live at 20:13:

```
grepai status   Files indexed: 0   Total chunks: 1264   Watcher: running (PID 35460)
netstat         PID 35460 has 3 ESTABLISHED connections to 127.0.0.1:16334 (qdrant)
worktree log    "Initial scan complete: 160 files indexed, 1249 chunks created,
                 0 files removed, 0 skipped (took 4m34.08s)" at 20:01:47
```

Two things follow. First, `Files indexed: 0` is NOT evidence of a dead write
path - the log says a scan completed with 160 files, and chunks are growing.
Second, `Files indexed` is a broken predicate in this grepai build (relevant to
mcpw-rkg.3; see that report).

## What I rejected, and why

**Rejected: "run the initial scan outside the supervisor's reap window
entirely."** This is the option mcpw-rkg.3 was supposed to deliver - the
provision runs `grepai watch` in the foreground BEFORE the watcher spawns - but
it cannot be relied on here: `grepai watch` never exits on its own, so that step
always times out, and its completion predicate (`Files indexed > 0`) is the
broken counter above, so it returns `skipped` and never stamps. Worse, taking the
scan out of the supervisor's window means the supervisor is not running during
it: `<lockfile>.sup` goes stale, the pane's `Test-SupervisorAlive` fails, and the
pane fallback heal spawns a SECOND watcher on top of the scanning one. That is
the mcpw-6re bug class, so this option is actively dangerous. Rejected.

**Rejected: "do not start the idle TTL clock until the first scan finishes",
read as "hold until the first checkpoint".** Tempting, because it is the same
shape as the existing `mcpw-3si` freshness guard. But it does not fix the bug:
`last_index_time` IS written during a first scan at an early checkpoint, so the
hold lifts within minutes and the long silent tail of the scan still trips the
TTL. The clock is checkpoint-granular; gating on the clock cannot fix a bug
caused by clock granularity. Rejected.

## What I chose

**Treat "first scan in progress" as never-idle, keyed on grepai's OWN first-scan
completion event rather than on a timestamp.**

`Test-GrepaiFirstScanInProgress -LogDir <dir> -WatcherPid <pid>` (launcher line
1730, inside the grepai supervisor scriptblock) returns `$true` - "hold the
reap" - while no `grepai-worktree-*.ready` names the PID this supervisor tracks.
The reap is gated at line 1985/1989:

```powershell
$firstScanRunning = Test-GrepaiFirstScanInProgress -LogDir (Join-Path $env:LOCALAPPDATA 'grepai\logs') -WatcherPid $trackedGrepaiPid
if ($firstScanRunning -and $idleMin -ge $idleTtlMin) {
    Write-SupLog "grepai idle $idleMin min (TTL $idleTtlMin min) but the FIRST scan is still running (no .ready for PID $trackedGrepaiPid) - reap deferred, supervisor staying (mcpw-rkg.4)"
}
if ((-not $firstScanRunning) -and $idleMin -ge $idleTtlMin) {
    ... the existing reap body, byte-for-byte unchanged ...
```

Why `.ready`, measured on this box 2026-09-20:

```
<worktree>.ready   mtime 20:01:52.628   content "ready" + newline + "35460"
log line           "Initial scan complete: ..." at 20:01:47.487
process start      19:56:23.819
```

So `.ready` is written 5 s AFTER the scan completes - it is a POST-scan
readiness marker, not a daemon-start marker - and it NAMES the watcher PID. A
`.ready` naming the tracked PID is therefore positive proof that the watcher
running NOW has finished its first scan. A `.ready` left by a previous instance
names a different PID and cannot lift the hold: the same freshness rule mcpw-3si
applies to `last_index_time`, expressed as an identity match instead of a
timestamp.

Matching on the PID (not the file mtime, not a derived worktree id) also makes it
repo-agnostic: a sibling repository's marker can never lift OUR hold, and no
worktree-id derivation is needed. The digit-boundary regex
(`(?<![0-9])<pid>(?![0-9])`) means a marker naming 3546 never answers for 35460.

Why this keeps the steady state: the hold ends exactly when the first scan ends,
because that is when `.ready` appears. After that the TTL behaves exactly as
before - same knob (`watch.idle_timeout_minutes`), same clocks, same
PID-scoped `Stop-TrackedGrepaiTree`, same log lines. The memory saving is not
weakened, only delayed past the one window in which the watcher is provably busy.

Degradation: no `.ready` anywhere (a grepai build that writes none), a missing
log dir, or a PID of 0 returns `$false`, leaving the TTL exactly as it was before
this bead. The function never throws - "unknown" must not silently disable the
memory saving.

## mcpw-6re invariant: PRESERVED - explicitly

`Test-GrepaiReapPending` (module line 169) decides "deliberately reaped" vs "died
unexpectedly" from `<lockfile>.idle` being NEWER than `<lockfile>.sup`, which
holds only because the supervisor stamps `.sup` at the top of a tick and writes
`.idle` later in the SAME tick, then returns.

My change touches none of that:

- It writes **no** `.idle` and **no** `.sup`. Verified structurally in the test
  suite: the deferral branch contains no `Set-Content`, no `.idle`, no `return`,
  no `exit` - only a `Write-SupLog`.
- The deferral does **not** return, so the supervisor keeps ticking and `.sup`
  keeps refreshing. The pane sees a live supervisor and no reap marker, i.e.
  exactly what it sees today for a healthy watcher.
- The deliberate reap body is unchanged, so a real reap still writes `.idle`
  AFTER the `.sup` stamp of the same tick. Line order in the file is unchanged:
  `.sup` at 1760 (and 1931 in the cooldown loop), `.idle` at 1995.

The test asserts both the branch contents and the relative order
(`IndexOf('.sup' stamp) < IndexOf('.idle' write)`). `tests/launcher_pane_heal_idle.tests.ps1`
(the mcpw-6re suite) still passes 6 of 6.

One point in the other direction: the old behaviour could write a MISLEADING
`.idle` - a "deliberately reaped" marker for a watcher that was actually busy
scanning - which parked the pane on IDLE while the index never built. Removing
that case makes the marker's meaning strictly more accurate.

## Residual risks (honest list)

1. **PID reuse.** `.ready` carries no start time, so if a dead watcher's PID were
   recycled by a new watcher on the same worktree, the stale marker would falsely
   release the hold and the trap would return for that instance. Low probability,
   and the failure direction is "behaves as before this bead", not data loss.
2. **A build that never writes `.ready`** keeps today's behaviour (trap not
   fixed) rather than disabling the memory saving. That is the deliberate safe
   direction, but it means the fix is only as good as the marker's presence. The
   measured build writes it, and the launcher already relied on `.ready` for
   readiness detection before this bead.
3. **A wedged-but-alive watcher** that never finishes its first scan is never
   reaped. The TTL was never designed to handle that case (the crash path handles
   a DEAD watcher); noted, not fixed.
4. **Deferral log volume**: the deferral logs once per minute while a first scan
   runs and the TTL is exceeded. `Write-SupLog` calls `Limit-LogSize` first, so
   it is bounded.

## Test results

| Suite | Result |
| --- | --- |
| `tests/mcpw_rkg4_grepai_first_scan.tests.ps1` (new, 9 `It`) | **9 of 9 passed** |
| `tests/mcpw_rkg3_launcher_provision.tests.ps1` (new, 8 `It`) | **8 of 8 passed** |
| `tests/launcher_pane_heal_idle.tests.ps1` (the mcpw-6re suite) | **6 of 6 passed** |
| `tests/launcher_watcher_panes.tests.ps1` | **7 of 7 passed** |
| `tests/launcher_watcher_teardown.tests.ps1` | **14 of 14 passed** |
| `tests/launcher_mcp_provision.tests.ps1` | **13 of 13 passed** |

The new suite covers: hold on a foreign-PID `.ready`, release on our own PID
(both the measured two-line shape and a space-separated variant), digit-boundary
non-matching, all four degradation paths, that the passed `-LogDir` is the one
consulted (so the live `%LOCALAPPDATA%\grepai\logs` is never touched), that the
old ungated condition is gone rather than duplicated, and the mcpw-6re invariant.

No test indexes anything and no test reads or writes the real machine-global
grepai log dir - the predicate takes an explicit `-LogDir` and `-WatcherPid`,
mirroring `tests/mcpw-ozm.tests.ps1`.

## Files

- modified: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1` (helper at 1730; gate at 1985-1992)
- new: `tests/mcpw_rkg4_grepai_first_scan.tests.ps1`
- new: `reports/2026-09-20-mcpw-rkg4-grepai-first-scan.md`

No `Modules/` file was edited. The module-side change this bead would benefit from
(correct the `Files indexed` completion predicate so the provision stops paying
15 minutes per launch) is written as an exact diff in
`reports/2026-09-20-mcpw-rkg3-launcher-provision.md` for the module owner.
