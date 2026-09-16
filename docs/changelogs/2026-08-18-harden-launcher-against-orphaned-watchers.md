# 2026-08-18 — Harden ###1 launcher against orphaned watcher processes

## Symptom
10 orphaned `graphify-watch-wrapper.ps1 -WatchMode` powershell.exe processes
(see 2026-08-18-virtual-desktop-slowness change log). Stacked across relaunches
because a hard-killed launcher never ran exit teardown.

## Fix (5 layers)
1. Shared sweep-pattern module `modules/watcher_patterns.ps1` — single list used
   by BOTH Stop-PriorLauncherInstances (startup) and Stop-AllWatchers (exit).
2. Wrapper parent-death guard — the wrapper polls its parent PID and exits ~2s
   after the launcher dies, even on hard kill.
3. Stop-AllWatchers tree-kills sweep-found wrapper hosts by PID before the sweep,
   so an in-flight `graphify-rs.exe build` child (no `watch` token) dies with its host.
4. End-to-end regression `tests/launcher_wrapper_stack.tests.ps1` — N launches
   leave at most one wrapper (proves the startup sweep's idempotency).
5. Systemic scan — T8 auto-start confirmed to spawn the wrapper with
   `-WatchMode`; `Stop-WatcherOrphans`'s per-binary `watch` dedup retained
   (scoped by exe name, not an orphan sweep).

## Verification
- Pester (3.4.0 pinned): watcher_patterns (5), launcher_watcher_teardown (incl. new
  tree-kill It), launcher_watcher_teardown_sweep, launcher_graphify_wiring,
  graphify_watch_wrapper (incl. new parent-death It), launcher_wrapper_stack.
- pytest: test_launcher_watchers_contract.py + test_launch_watcher_teardown.py.
- Manual: 3x hard-killed dummy launcher -> 0 surviving wrappers.

## Files changed
- `modules/watcher_patterns.ps1` (new)
- `Modules/watcher_teardown.ps1`
- `dev_tools/graphify-watch-wrapper.ps1`
- `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`
- `tests/watcher_patterns.tests.ps1` (new)
- `tests/launcher_wrapper_stack.tests.ps1` (new)
- `tests/launcher_watcher_teardown.tests.ps1` (pinned + new tree-kill It)
- `tests/graphify_watch_wrapper.tests.ps1` (pinned + new parent-death It)
- `tests/test_launcher_watchers_contract.py` (new contract tests)
- `tests/test_launch_watcher_teardown.py` (updated regression for shared module)
