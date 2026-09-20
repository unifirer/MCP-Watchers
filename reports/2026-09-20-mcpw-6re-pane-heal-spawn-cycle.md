# mcpw-6re - pane fallback heal re-spawns the watcher after every idle reap

Date: 2026-09-20
Branch: `mcpw-sweep-20260920-1305`
Status: fixed in `Modules/watcher_pane_scripts.ps1`, regression-locked in
`tests/launcher_pane_heal_idle.tests.ps1`. Launcher change deferred (diff below).

## The bug in one line

The pane fallback heal was gated on **"`<lockfile>.idle` exists"**, but that
marker is a *latch* with two writers and no owner, so "marker absent" does not
mean "the watcher crashed" - and the heal acted on that misreading.

## The discriminator I used, and how I verified its lifecycle

`<lockfile>.idle` is written **only** by the supervisor, and only on the
deliberate idle-TTL reap. The supervisor script has exactly three `return`
paths (`###1.watchers_...ps1`):

| line | path | writes `.idle`? |
|------|------|-----------------|
| 1665 | `launcher gone` | no (correct - a dead launcher is a genuine "heal me" case) |
| 1883 | idle, no tracked PID | yes (1879, before the branch) |
| 1888 | idle, tracked PID dead | yes |
| 1895 | idle, watcher reaped | yes |

So `.idle` is written on **every** deliberate stop. Bare existence was still the
wrong test, because the marker is cleared by **two** actors:

1. the supervisor, at its own start (launcher line 1658, "drop that stale marker");
2. **the pane itself** - the live-watcher branch deleted it (old module lines
   884-893, "a live watcher invalidates a stale idle marker").

Actor 2 is the mechanism of the loop. The pane heal (or any other spawn) puts a
watcher up, the pane then wipes the record of the reap that had parked it, that
watcher dies, and the pane sees "no marker, no supervisor" and heals - spawning
the watcher the supervisor had just reaped on purpose.

**The reliable discriminator is the relative order of the two supervisor files**,
which the supervisor's own tick order guarantees. Every tick stamps
`<lockfile>.sup` **first** (launcher 1660, top of the loop); the idle reap writes
`<lockfile>.idle` **later in the same tick** (launcher 1879) and then returns, so
nothing stamps `.sup` again. Therefore at a deliberate reap
`marker-mtime > sup-mtime`, and it stays that way.

Verified against the live state dir (`%LOCALAPPDATA%\watchers\ad90e3fb`), not
just read off the source:

```
###1-launcher.sup   2026-09-20 08:28:57.302
###1-launcher.idle  2026-09-20 08:28:58.674   <- 1.37 s later, same tick
###1-launcher.lock  2026-09-20 07:19:51       <- launcher start, unchanged
```

and the supervisor log agrees:

```
[2026-09-20T08:28:58] grepai idle 20.4 min (TTL 20 min) - reaping watcher, supervisor exiting (no relaunch)
```

Both files then froze (no further `.sup` ticks), confirming the supervisor
returned immediately after writing the marker.

`Test-GrepaiReapPending` therefore returns true only when the marker exists **and**
no supervisor tick has superseded it. If `.sup` is newer than the marker, a
supervisor has ticked since the reap: the marker is an orphan and healing is
allowed again - which also fixes the mirror-image bug (parking forever on a stale
marker, i.e. a genuinely crashed watcher that never heals).

### Is `.idle` reliable on its own? No.

Recorded honestly: bare `.idle` existence is **not** a reliable discriminator,
for the two-writer reason above. The order probe is. What remains
indistinguishable pane-locally is the narrow case "a supervisor reaped, and then
someone started `grepai watch` manually with no supervisor running, and it
crashed": no signal on disk separates that from the reap itself. That case now
parks on IDLE instead of healing; any supervisor start clears the marker and
restores healing. The deferred launcher diff below closes even that gap.

## What changed

`Modules/watcher_pane_scripts.ps1` only (+63/-11). All three edits are in the
pane template, so they are regenerated into `C:\Temp\vad-watchers\<key>\panes\`
on the next launcher start; the generated copies are not edited by hand.

1. **New `Test-GrepaiReapPending`** (after `Test-GrepaiIdleMarker`, which stays as
   the raw existence primitive): marker present **and** `marker-mtime >= sup-mtime`
   (or no `.sup` at all -> the marker is the only evidence, treat as authoritative).
2. **The tick-loop heal gate now uses `Test-GrepaiReapPending`** instead of bare
   `Test-GrepaiIdleMarker`. The IDLE park, the IDLE text, the heartbeat and
   `$script:idleShown` are unchanged.
3. **`Invoke-GrepaiHealthCheck` re-checks the discriminator at the point of
   action**, immediately after the `$alive0` early return and before the
   supervisor check / mutex / lock sweep / `Start-Process`. The caller only
   reaches tick 30 (then 60, 90, ...) 15 s+ after it decided the watcher was
   down; a reap landing in that window was invisible to the caller's decision and
   the heal would then clear locks and re-spawn the reaped watcher. This is the
   cheap last line of defence before anything destructive.
4. **The pane no longer deletes `<lockfile>.idle`** when it observes a live
   watcher. Only the supervisor owns that marker. The branch now just resets
   `$script:idleShown` (display state).

Healing is **not** disabled. A watcher that genuinely dies still heals: no
supervisor + no authoritative marker -> the tick-30 heal runs as before.

## Test results

New suite `tests/launcher_pane_heal_idle.tests.ps1` - **6 of 6 passed**, no skips:

| # | test | covers |
|---|------|--------|
| 1 | template defines the order probe and gates the heal branch on it | edit 2 |
| 2 | the heal re-checks the discriminator at the point of action, before spawning | edit 3 (guard index < spawn index) |
| 3 | the pane no longer erases the supervisor reap marker | edit 4 |
| 4 | `Test-GrepaiReapPending` lifecycle (empty path / no marker / reap shape / marker-only / orphan / no marker) | edit 1 |
| 5 | `Invoke-GrepaiHealthCheck` refuses to spawn while a reap is pending | edits 1+3, behavioural |
| 6 | reap-pending pane parks on IDLE past tick 40, keeps heartbeating, never heals, marker survives | end-to-end, 20 s |

**Negative control** (not committed; probe run against
`git show HEAD:Modules/watcher_pane_scripts.ps1` with the same harness, same
fixture): the pre-fix module prints
`[grepai HEALTH] watch daemon down - auto-healing (repair + relaunch)...` and
proceeds to heal, while the fixed module prints
`[grepai HEALTH] deliberate idle reap pending - skipping pane heal (not a crash)`.
Test 5 therefore genuinely fails on the old code and passes on the new.

Regressions:

- `tests/launcher_watcher_teardown.tests.ps1` - **14 of 14 passed** (baseline 14/14).
- `tests/launcher_watcher_panes.tests.ps1` - **5 of 7 passed** (baseline 5/7; the
  2 failures are the known environmental ones - `Get-Command powershell` cannot
  resolve a host by name in this sandbox because `PATHEXT=.CPL`).
- `tests/launcher_pane_exit_qfy.tests.ps1` - **7 of 8 passed**. The 1 failure is
  pre-existing and environmental (`Start-Process` throws
  `Key in dictionary: 'https_proxy' / 'HTTPS_PROXY'` in this sandbox); I measured
  it at 7/8 *before* touching anything, so it is not a regression. The new suite
  launches children through `System.Diagnostics.Process` to dodge exactly this.

**Long-window stability check** (not committed, 60 s = 120 ticks, same fixture as
test 6): `IDLE - WAITING FOR QUERIES` printed, **0** `watcher down` lines,
**0** `auto-check triggered` lines, marker still present at the end.

### Why the bug does not show up on a "clean" fixture (and what it needs)

Running the *pre-fix* module against the same clean fixture also parks stably
(0 heals, marker intact). The old code was only wrong when a **live grepai watch
that this pane did not own** appeared - and `Test-GrepaiWatcherAlive` is a
**machine-wide** probe (`Get-CimInstance Win32_Process` over every `grepai.exe`
whose command line matches `watch`), so a sibling instance, the other launcher's
key, or a manual run all read as "alive". That flipped `$alive` to true, and the
old live-watcher branch then **deleted the supervisor's reap marker**. When that
foreign watcher went away, the pane saw "no marker, no supervisor" and healed -
re-spawning the watcher the supervisor had deliberately reaped. Removing the
deletion is what closes it: the marker now survives the foreign-watcher
interaction, so the pane parks instead. This also explains why the pre-existing
mcpw-qfy RC1 test passed both before and after this change - it only ever
exercised the clean fixture.

I have four stale `%TEMP%\mcpw6re_park_*` artifacts from superseded test fixtures
that show exactly this flip: 1 IDLE line, then 100-620 `watcher down` lines and
repeated heal attempts. They are recorded here as the observed signature of the
pre-fix bug, not as a failure of the current code.

Two more suites that AST-extract or neighbour the code I touched, run for safety:

- `tests/launcher_pane_line_cap.tests.ps1` - **0 of 1 passed**, same
  environmental `Start-Process` / `https_proxy` throw (test line 62). Not related
  to this change; the suite only parses `New-WatcherPaneScript`, which still
  parses (my new suite's tests 1-3 and the generated-pane tests all parse it).
- `tests/launcher_grepai_lock_and_spawn.tests.ps1` - **12 of 12 passed**.
- `tests/launcher_grepai_idle_clock_reap.tests.ps1` - **4 of 5 passed**. The
  failure (`Expected the actual value to be less than 20, but got 540` on
  `Get-GrepaiIdleMinutes`) is launcher-side, in another agent's currently-dirty
  file: that function is not defined in and not referenced by
  `Modules/watcher_pane_scripts.ps1` (grep count 0), so this change cannot have
  caused it.

Safety: no live launcher or watcher was killed, and the behavioural test runs the
heal in a child process with `PATH` stripped of `grepai.exe` and `LOCALAPPDATA`
redirected to a temp dir, so a missing guard could not have spawned anything or
swept the machine-global lock dir.

## Deferred launcher diff (NOT applied - another agent owns this file)

The residual hole is launcher-side: the supervisor clears `.idle` at **startup**
(line 1658), before it has a live watcher. For the whole window "supervisor
started, watcher not yet up, `.sup` still fresh-ish" the reap record is gone, so
if that supervisor then dies without reaping, the pane correctly concludes
"crashed" and heals. The supervisor should clear the marker only once **it** has
a live watcher, not merely because it started.

```diff
--- a/###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
+++ b/###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
@@ -1653,10 +1653,16 @@
         $supStamp = [System.IO.Path]::ChangeExtension($LockFile, '.sup')
-        # mcpw-qfy RC1: a previous supervisor run may have parked the grepai
-        # pane on IDLE via <lockfile>.idle. This supervisor owns healing
-        # again, so drop that stale marker at startup.
-        try { $staleIdle = [System.IO.Path]::ChangeExtension($LockFile, '.idle'); if (Test-Path -LiteralPath $staleIdle) { Remove-Item -LiteralPath $staleIdle -Force -ErrorAction SilentlyContinue } } catch { }
+        # mcpw-qfy RC1 / mcpw-6re: a previous supervisor run may have parked the
+        # grepai pane on IDLE via <lockfile>.idle. Do NOT drop it here. The pane
+        # reads that marker (order-vs-.sup) to tell a deliberate idle reap from a
+        # crash, so clearing it at startup opens a window - supervisor up, watcher
+        # not yet live, .sup still fresh - in which the pane would heal the reaped
+        # watcher and restart the spawn/reap cycle. Clear it only once THIS
+        # supervisor has a live watcher.
+        $staleIdle = [System.IO.Path]::ChangeExtension($LockFile, '.idle')
         while ($true) {
@@ -1680,6 +1686,9 @@
                 $alive = $watchProcs.Count -gt 0
+                # mcpw-6re: this supervisor now owns healing, so the reap record
+                # it inherited is spent.
+                if ($alive) { try { if (Test-Path -LiteralPath $staleIdle) { Remove-Item -LiteralPath $staleIdle -Force -ErrorAction SilentlyContinue } } catch { } }
                 if (-not $alive) {
```

Note the second hunk must land **after** the `$alive = $watchProcs.Count -gt 0`
assignment (launcher 1683) and before the `if (-not $alive)` heal block, so a
restart tick that brings the watcher up in the same iteration also clears the
marker.

## Residual / known limits

- The pane parks on IDLE indefinitely while an authoritative marker exists. If
  the launcher is killed right after a reap (marker written, launcher gone before
  its supervisor notices), the pane waits instead of healing. Recoverable by
  starting the launcher; strictly better than the loop.
- A reap followed by a *manual* `grepai watch` that then crashes parks on IDLE
  rather than healing - see "Is `.idle` reliable on its own? No." above. Closed by
  the deferred launcher diff.
- The 270 `restarted grepai` / 92 `exited immediately after restart` churn in
  `%LOCALAPPDATA%\grepai\logs\supervisor.log` is dominated by the separate
  cross-instance spawn race ("watcher is already running (PID X)") covered by a
  different bead. This change removes the pane's contribution to it; it does not
  address that race.

## Changed paths

- `Modules/watcher_pane_scripts.ps1` (modified, +63/-11)
- `tests/launcher_pane_heal_idle.tests.ps1` (new, 6 tests)
- `reports/2026-09-20-mcpw-6re-pane-heal-spawn-cycle.md` (new, this file)

No other file was touched. `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`
was already dirty when this bead started and remains another agent's work.
Nothing was committed.
