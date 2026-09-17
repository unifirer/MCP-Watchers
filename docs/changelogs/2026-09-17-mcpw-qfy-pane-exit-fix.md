# 2026-09-17 - mcpw-qfy: watcher panes stay open (4 pane-exit root causes fixed)

Issue: Windows Terminal panes closed on their own after hours (idle reap,
dead probe, zero grace, heartbeat cascade).

Fix (all in this repo, not VAD):
- RC1: grepai pane parks on `[IDLE - WAITING FOR QUERIES]` on intentional
  idle reap via `<lockfile>.idle` (supervisor writes it, clears it on start).
  No heal (would undo the memory saving), no exit, heartbeat kept.
  Also assigned the template `$LockFile` (was never set, so the pane always
  raced the supervisor heal).
- RC2: `Test-GrapheniumWatcherAlive` probes `gm serve` + launcher lock
  (PID + StartedAt); the old `gm watch` probe could never match. Launcher
  passes `-LockFile` to the graphenium pane.
- RC3: graphenium / graphify-rs / repowise get 60 dead ticks (~30 s) grace
  before `exit 0`. Unknown labels keep the immediate exit (T18-locked).
- RC4: controller `$hbTimeoutSec` 8 s -> 15 s + sleep/resume forgiveness
  (loop gap > 60 s resets the stale-since clock instead of killing daemons).

Files:
- Modules/watcher_pane_scripts.ps1 (pane template)
- ###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
- tests/launcher_tests.ps1 (T19 now asserts grepai persistence + heartbeat)
- tests/launcher_pane_exit_qfy.tests.ps1 (new: 8 regression tests)

Tests: new suite 8/8 pass; T18/T19 standalone 18/18 (2 dynamics skip on
live-watch boxes by design); final_window 6/6; watcher_panes 6/6;
remediation 10/12 (2 pre-existing regex-drift failures, see mcpw-4g3);
full launcher_tests aborts at T10b (missing .grepai fixture, follow-up filed).
