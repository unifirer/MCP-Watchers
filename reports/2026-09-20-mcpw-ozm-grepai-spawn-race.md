# mcpw-ozm - grepai cross-instance spawn race: stop retrying against a lock we cannot clear

Date: 2026-09-20 · Branch: `mcpw-sweep-20260920-1305` · Bead: **mcpw-ozm** (P1)
Status: **FIXED in `Modules/watcher_job_helpers.ps1`** · launcher wiring deferred (another agent owns that file this wave)

---

## 1. What was wrong

`grepai watch` refuses to start when another watcher holds a lock. Verbatim, the entire
`C:\Temp\vad-watchers\watchers\grepai-launch.log.err` (47 bytes, mtime 2026-09-20 07:10:14):

```
Error: watcher is already running (PID 65534)
```

PID 65534 is **not** a PID the supervisor had spawned (6228 at 07:10:03, retry 86624 at
07:10:08). It is a different, concurrently-running grepai. The lock directory is
machine-global, so two launcher instances - or a launcher plus a stray grepai - collide.
The supervisor then re-spawned every 2 s against a lock held by a live process, which cannot
work: **retrying does not clear a lock another process holds.** 196 exits + 94 retries = the
290 "restarted grepai" events.

---

## 2. The real lock lifecycle (the crux - verified, not guessed)

Read from grepai v1.19.0 source (`github.com/yoanbernabeu/grepai`, packages `daemon` and
`cli`) and cross-checked against the installed binary's symbol table
(`daemon.WritePIDFile`, `daemon.GetRunningPID`, `daemon.WriteWorktreePIDFile`,
`daemon.GetRunningWorktreePID`, `daemon.StopProcess`, `cli.runWatch`, `cli.startBackgroundWatch`).

| Artifact in `%LOCALAPPDATA%\grepai\logs` | Written by | Cleared by | Durable mutex? |
|---|---|---|---|
| `grepai-watch.pid` | `WritePIDFile` (non-worktree watch) | `RemovePIDFile`; auto-cleared by `GetRunningPID` when the PID is dead | - |
| `grepai-watch.pid.lock` | same | the OS, on process exit | **YES** - `LockFileEx(EXCLUSIVE\|FAIL_IMMEDIATELY)`, held for the process lifetime |
| `grepai-watch.ready` | `WriteReadyFile` (`ready\n<pid>\n`) | refusal path / stop | - |
| `grepai-worktree-<id>.pid` | `WriteWorktreePIDFile` | `RemoveWorktreePIDFile`; auto-cleared when the PID is dead | - |
| `grepai-worktree-<id>.pid.lock` | same | closed **immediately** after the PID write | **NO** - transient only |
| `grepai-worktree-<id>.log` | rewritten on every watch start; first line names the project | - | - |
| `grepai-stop-<pid>` | `StopProcess` (a STOP SENTINEL, not a lock) | the owner, on detect and on its own startup | - |

**The refusal gate.** `cli.runWatch` / `cli.startBackgroundWatch` refuse iff
`daemon.GetRunning*PID()` returns `> 0`, and that helper returns `> 0` **only after**
`IsProcessRunning(pid)` (`OpenProcess`, `PROCESS_QUERY_LIMITED_INFORMATION`) reported the PID
alive. Two consequences that decide the whole fix:

1. **A dead PID never blocks a restart** - grepai clears the PID + ready files itself and
   proceeds. So a genuinely crashed grepai already heals; nothing needed fixing there.
2. **With a non-empty worktree id, `runWatch` checks the worktree PID file first and then
   FALLS BACK to the machine-global `grepai-watch.pid`.** That fallback is the cross-instance
   race: a live watcher anywhere on the box that wrote the global PID file blocks *our*
   worktree watcher, and names a PID we never spawned. Exactly the 6228/86624/65534 evidence.

Note the two lock shapes are **not** symmetric: the non-worktree lock is a real
process-lifetime mutex, while the worktree `.pid.lock` is closed right after the write. The
durable signal in worktree mode is the **PID file content**, which is why the fix classifies
PID files rather than `.lock` files.

---

## 3. Distinguishing a live-held lock from a stale one

Liveness alone is **not** enough, and this is the part a naive "is the PID alive?" check gets
wrong:

> `IsProcessRunning()` only proves that *some* process owns that PID. Windows **recycles**
> PIDs. A `.pid` file naming a recycled, unrelated process is a lock grepai will **never**
> clear (it sees "alive") and that `Clear-StaleLocks` can never clear either (its
> `Get-Process -Id` succeeds for the same reason). That is a permanently wedged lock: grepai
> refuses on every retry, forever.

So `Test-GrepaiPidFileStale` uses **two independent signals** and calls a lock stale only
when they agree:

| liveness | identity (is the PID a live `grepai ... watch`?) | verdict |
|---|---|---|
| dead / absent / unparseable / 0 | - | **stale** - safe to clear |
| alive | **yes** | **LIVE HOLDER** - never clear, never spawn over it |
| alive | no (recycled PID, or a `grepai mcp-serve`) | **stale** - safe to clear; the case nothing else can clear |

Identity is strict: process name must be `grepai(.exe)` **and** the command line must carry
`watch` as a whole argument - the same rule the launcher already uses to tell a watcher from a
`grepai mcp-serve` server (`###1...ps1:943-951`).

**`.lock` files are never touched.** The lock is the OS lock on the open handle, not the
file's existence, so deleting one achieves nothing and deleting a live one is pure risk.

**A crashed grepai still restarts.** Its PID file names a dead PID, which is stale, so the
decision is `spawn`. Healing is not disabled.

---

## 4. What was implemented

All in `Modules/watcher_job_helpers.ps1` (inserted before `Limit-LogSize`), definitions only -
the file's "safe to dot-source" contract is preserved. The grepai supervisor runspace already
dot-sources this module at `###1...ps1:1480`, so no new wiring is needed for these to be in
scope there.

| Function | Role |
|---|---|
| `Get-GrepaiLogDir` | the machine-global log dir, mirroring `daemon.GetDefaultLogDir` |
| `Get-GrepaiProcessInfo` | default process probe (name + command line); `$null` when dead |
| `Test-GrepaiWatcherProcess` | the **identity** half: is this PID a live `grepai ... watch`? |
| `Get-GrepaiPidFileValue` | decimal PID from a PID file, or 0 |
| `Test-GrepaiPidFileStale` | **the crux** - the two-signal safe-to-delete gate |
| `Test-GrepaiPidFileOwnedByProject` | worktree ownership via the sibling log's first line |
| `Get-GrepaiLockInventory` | every lock a fresh `grepai watch` here would consult, classified |
| `Clear-StaleGrepaiSpawnLocks` | deletes only the provably-stale PID files; never a `.lock` |
| `Get-GrepaiSpawnBackoffSeconds` | growing delay (base x 2^(n-1), capped) |
| `Get-GrepaiSpawnDecision` | **pure** pre-spawn verdict: `spawn` / `adopt` / `backoff` |

Every classifier takes an injectable `-ProcessProbe`, so the identity rule is unit-testable
without spawning or killing anything, and an explicit `-LogDir`, so tests never read or sweep
the live lock dir.

### The decision

| Situation | Action | Why |
|---|---|---|
| no live watcher holds a lock we would consult | `spawn` | unchanged behaviour |
| a live watcher holds **our** worktree PID file (sibling log names our root) | `adopt` | track its PID; do not fight it |
| a live watcher we **cannot** attribute holds a lock (in practice the global `grepai-watch.pid` written by another repo) | `backoff` | a respawn would be refused anyway |

`adopt` is deliberately **not** offered for the global PID file. It carries no project key, and
tracking a foreign PID would make this supervisor reap - or `Stop-TrackedGrepaiTree` - someone
else's watcher on teardown. Backing off is the conservative answer, and it converges: when the
holder exits, grepai clears the file and the next tick spawns.

Backoff defaults: base **15 s**, doubling, capped at **600 s**. The cap keeps healing
responsive; the growth is what kills the churn.

---

## 5. Test results

`tests/mcpw-ozm.tests.ps1` (new, 30 tests):

```
VERDICT : passed=30 failed=0   (rc=0, ignored)
Tests Passed: 30, Failed: 0   |   `[-]` lines: 0
```

**30 of 30 tests passed.**

Regression re-run, `tests/launcher_grepai_lock_and_spawn.tests.ps1` (known-good 12 of 12):

```
VERDICT : passed=12 failed=0
Tests Passed: 12, Failed: 0   |   `[-]` lines: 0
```

**12 of 12 tests passed.** `Test-GrepaiLockStale` was deliberately left byte-identical, so the
hand-synced pane copy at `Modules/watcher_pane_scripts.ps1:615` did **not** need updating and
the drift guard still passes. `Clear-StaleLocks` is also unchanged.

### Live read-only sanity check (no state touched)

* Real machine state: no grepai PID files present -> `Action = spawn`. No false blocking.
* A PID file naming a real live PID that is not a grepai watcher (this shell, 73012) ->
  `Action = spawn`, and `Clear-StaleGrepaiSpawnLocks` removed exactly 1 file. This is the
  recycled-PID path exercised against a real live process.

---

## 6. Deferred launcher diff - `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`

Not applied: another agent owns that file this wave. Four hunks.

### Hunk A - declare the blocked counter (after line 1587, `$grepaiSpawnAttempt = 1`)

```powershell
+        # mcpw-ozm: consecutive respawns skipped because a LIVE grepai watcher
+        # holds a lock this workspace would consult. Feeds
+        # Get-GrepaiSpawnBackoffSeconds so the wait grows; reset to 0 whenever a
+        # spawn actually happens.
+        $consecutiveBlockedSpawns = 0
```

### Hunk B - gate the crash-restart spawn (lines 1711-1714)

BEFORE:

```powershell
                    Clear-StaleLocks -ProjectRoot $RepoRoot
                    Repair-CorruptGobIndex -ProjectRoot $RepoRoot
                    Start-Sleep 1
                    # mcpw-0on: this restart gets its OWN redirect pair, so it can
```

AFTER:

```powershell
                    Clear-StaleLocks -ProjectRoot $RepoRoot
                    # mcpw-ozm: Clear-StaleLocks only knows the worktree/stop
                    # shapes and gates on OWNERSHIP. This one also covers the
                    # machine-global grepai-watch.pid and gates on IDENTITY,
                    # which is what catches a PID file naming a RECYCLED PID -
                    # the one lock grepai can never clear by itself.
                    $null = Clear-StaleGrepaiSpawnLocks
                    Repair-CorruptGobIndex -ProjectRoot $RepoRoot
                    Start-Sleep 1
                    # mcpw-ozm: decide BEFORE spawning. grepai refuses with
                    # "watcher is already running (PID n)" whenever a live
                    # watcher holds a lock, and retrying cannot clear a lock
                    # another live process holds - that is the 92-flap churn.
                    $spawnDecision = Get-GrepaiSpawnDecision -ProjectRoot $RepoRoot -ConsecutiveBlocked $consecutiveBlockedSpawns
                    if ($spawnDecision.Action -ne 'spawn') {
                        if ($spawnDecision.Action -eq 'adopt') {
                            $trackedGrepaiPid = [int]$spawnDecision.BlockerPid
                            $trackedGrepaiStart = Get-Date
                            $consecutiveRestarts = 0
                            $consecutiveBlockedSpawns = 0
                            Write-SupLog "adopted live grepai watcher PID $($spawnDecision.BlockerPid) instead of respawning - $($spawnDecision.Reason)"
                            Write-WatchersLog "grepai watcher adopted (PID $($spawnDecision.BlockerPid)) - no respawn needed"
                        } else {
                            $consecutiveBlockedSpawns++
                            Write-SupLog "respawn blocked: $($spawnDecision.Reason) - backing off $($spawnDecision.DelaySeconds)s"
                            Write-WatchersLog "grepai respawn blocked by a live watcher (PID $($spawnDecision.BlockerPid)) - waiting $($spawnDecision.DelaySeconds)s instead of retrying against a lock we cannot clear"
                            Start-Sleep -Seconds $spawnDecision.DelaySeconds
                        }
                        # `continue` inside the surrounding try/finally still runs
                        # the finally (heal mutex released) and re-ticks the loop,
                        # so the lock is re-tested after the wait.
                        continue
                    }
                    $consecutiveBlockedSpawns = 0
                    # mcpw-0on: this restart gets its OWN redirect pair, so it can
```

### Hunk C - gate the 2 s retry (lines 1745-1748) - this is the 94-flap path

BEFORE:

```powershell
                        $consecutiveRestarts++
                        Clear-StaleLocks -ProjectRoot $RepoRoot
                        Repair-CorruptGobIndex -ProjectRoot $RepoRoot
                        Start-Sleep 1
```

AFTER:

```powershell
                        $consecutiveRestarts++
                        Clear-StaleLocks -ProjectRoot $RepoRoot
                        $null = Clear-StaleGrepaiSpawnLocks
                        Repair-CorruptGobIndex -ProjectRoot $RepoRoot
                        Start-Sleep 1
                        # mcpw-ozm: the retry is equally doomed against a lock a
                        # live watcher holds - this is the path that produced the
                        # 94 "exited immediately after restart" events.
                        $retryDecision = Get-GrepaiSpawnDecision -ProjectRoot $RepoRoot -ConsecutiveBlocked $consecutiveBlockedSpawns
                        if ($retryDecision.Action -ne 'spawn') {
                            if ($retryDecision.Action -eq 'adopt') {
                                $trackedGrepaiPid = [int]$retryDecision.BlockerPid
                                $trackedGrepaiStart = Get-Date
                                $consecutiveBlockedSpawns = 0
                                Write-SupLog "adopted live grepai watcher PID $($retryDecision.BlockerPid) on the retry path - $($retryDecision.Reason)"
                                Write-WatchersLog "grepai watcher adopted (PID $($retryDecision.BlockerPid)) - retry skipped"
                            } else {
                                $consecutiveBlockedSpawns++
                                Write-SupLog "retry blocked: $($retryDecision.Reason) - backing off $($retryDecision.DelaySeconds)s"
                                Write-WatchersLog "grepai retry blocked by a live watcher (PID $($retryDecision.BlockerPid)) - waiting $($retryDecision.DelaySeconds)s"
                                Start-Sleep -Seconds $retryDecision.DelaySeconds
                            }
                            continue
                        }
                        $consecutiveBlockedSpawns = 0
```

### Hunk D - STOP killing the PID grepai named (lines 1349-1352) - highest blast radius

The initial-launch recovery path reads `PID (\d+)` out of the error text and **kills it**:

```powershell
            if ($errText -match 'already running' -and $errText -match 'PID (\d+)') {
                $op = Get-Process -Id $Matches[1] -ErrorAction SilentlyContinue
                if ($op) { try { $op.Kill() } catch { ... } }
            }
```

That PID is the **blocker, not our child** - the lock is machine-global, so it is usually a
**live watcher belonging to a different repository** (the evidence named 65534 while the
supervisor had spawned 6228/86624). Killing it is the mcpw-eud bug class with a worse blast
radius, and if the PID was recycled the victim is an unrelated process.

BEFORE:

```powershell
            if ($errText -match 'already running' -and $errText -match 'PID (\d+)') {
                $op = Get-Process -Id $Matches[1] -ErrorAction SilentlyContinue
                if ($op) { try { $op.Kill() } catch { Write-Warning "Failed to kill stale grepai PID $($op.Id): $($_.Exception.Message)" } }
            }
```

AFTER:

```powershell
            # mcpw-ozm: do NOT kill the PID grepai named. See the report: that PID
            # is the BLOCKER, not our child - the lock is machine-global, so the
            # name is usually a LIVE watcher owned by a DIFFERENT repository.
            # Ask the gate instead: adopt only our own live watcher, otherwise
            # back off and leave the holder alone.
            $launchDecision = Get-GrepaiSpawnDecision -ProjectRoot $watchersWorkspaceRoot
            if ($launchDecision.Action -eq 'adopt') {
                $script:GrepaiPid = [int]$launchDecision.BlockerPid
                $grepaiOk = $true
                Write-Warning "grepai watcher for this project is already live (PID $($launchDecision.BlockerPid)) - adopting it instead of killing and relaunching."
            } elseif ($launchDecision.Action -eq 'backoff') {
                Write-Warning "grepai refused to start: $($launchDecision.Reason). Not killing PID $($launchDecision.BlockerPid) and not relaunching."
            }
```

and then gate the recovery relaunch (lines 1363-1382) on the same verdict - skip the retry
entirely when the action is not `spawn`:

```powershell
            Start-Sleep -Seconds 1
+           if ($launchDecision.Action -ne 'spawn') { return }   # or skip the retry block
            try {
                $recoveryLog = Get-GrepaiSpawnLogPair ...
```

---

## 7. Findings, risks, open questions

1. **The kill at line 1349-1352 is the destructive half of the race** and is not covered by any
   existing test. Hunk D is the highest-value launcher change; it is also the one that needs
   the most care, since it changes behaviour on the *initial* launch path, not just healing.
2. **`Test-GrepaiLockStale`'s worktree branch gates on ownership, not liveness.** For
   `grepai-worktree-<id>.pid` it returns `$true` whenever the sibling log names `$ProjectRoot`,
   **even if the PID names a live watcher** - so `Clear-StaleLocks` can delete our own live
   watcher's PID file, after which grepai falls back to the global PID file and may start a
   second watcher for the same worktree. I deliberately did **not** change it:
   `tests/launcher_grepai_lock_and_spawn.tests.ps1` pins that behaviour, the pane copy is
   hand-synced, and the function's own doc comment defines the worktree branch as an ownership
   rule for "older-build" locks. Worth a separate bead. `Clear-StaleGrepaiSpawnLocks` does not
   have this gap (identity-first), so wiring it in as in Hunk B/C is strictly safer.
3. **Message-string discrepancy (open).** The 47-byte evidence matches
   `cli.startBackgroundWatch`'s `"watcher is already running (PID %d)"`, while the foreground
   `cli.runWatch` emits the two-line `"watcher is already running in background (PID %d)\nUse
   'grepai watch --stop' to stop it"`. Neither launcher in this repo passes `--background`
   (both avoid it deliberately, `###1...ps1:1299-1307`, `###2...ps1:17-20`). So the 47-byte file
   likely came from a different (older, or VAD-harness) spawn path. This does not change the
   fix: both gates reduce to `GetRunning*PID() > 0`, which is exactly what the decision
   function models.
4. **PID 65534 remains unexplained as a real PID.** Windows PIDs are normally multiples of 4,
   and 65534 is not. If it was never a valid PID then `IsProcessRunning` would have returned
   false and grepai would have cleared the file rather than refusing - so the refusal implies
   the value *was* treated as alive. Not resolvable after the fact (no PID history); noted so
   nobody treats 65534 as established. The fix does not depend on it.
5. **The identity check is stricter than the supervisor's.** `Get-GrepaiSpawnDecision` requires
   `watch` as a whole argument, while the supervisor's `$watchProcs` filter
   (`###1...ps1:1667-1668`, `:1393-1394`) uses a loose `-match 'watch'`. A grepai process whose
   *path* contains "watch" would count as a watcher to the supervisor but not to the gate. That
   only ever makes the gate more willing to spawn, and grepai's own gate remains the backstop.
6. **Test hygiene.** `tests/mcpw-ozm.tests.ps1` is new and therefore untracked;
   `dev_tools/check_test_hygiene.py` will report it until it is staged. Staging is out of scope
   this wave (one shared git index, mcpw-gsj), so it needs an entry in `PENDING_STAGING` or an
   explicit `git add` by whoever owns the index.

---

## 8. Changed paths

| Path | Change |
|---|---|
| `Modules/watcher_job_helpers.ps1` | +10 functions (spawn-time lock gate). `Clear-StaleLocks` and `Test-GrepaiLockStale` untouched. |
| `tests/mcpw-ozm.tests.ps1` | NEW - 30 tests. |
| `reports/2026-09-20-mcpw-ozm-grepai-spawn-race.md` | NEW - this report. |

Nothing committed; edits left dirty as instructed.
