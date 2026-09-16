# Watcher stack memory/CPU leak fixes (2026-09-06)

Beads: VAD-iuyp. Plan: plans/2026-09-06-watcher-leak-fixes.txt

## Measured problem

Two watcher processes reached ~4.3 GB each with climbing thread counts and
constant CPU burn after 8 h of mostly idle watching (last real work 6+ h
before the readings):

- `graphify-watch-wrapper.ps1` (PID 209416): 4.3 GB, 65 threads, 34,505
  CPU-s (avg ~1.2 cores).
- `tail_graphify-rs.ps1` pane tailer (PID 162592): 4.25 GB, 44 threads,
  10,438 CPU-s (avg ~0.36 core).

Fresh instances of the same scripts already showed the same trend (threads
33/37 at 5 min; tailer private memory 129 -> 155 MB in 30 min). The repo
filesystem was quiet (0 events in a 20 s window) while both processes kept
burning CPU.

## Root causes

1. Wrapper: `$pending` was a `Queue[string]` that stored EVERY FileSystemWatcher
   event, and every event restarted the 1500 ms debounce timer. During
   sustained churn (rebuild cascades write graphify-rs's multi-MB outputs in
   small chunks) the timer never fired and the queue grew without bound. The
   flush then spawned one `git check-ignore` subprocess per queued path.
2. Pane tailers: re-read the ENTIRE log with `Get-Content` every 500 ms tick
   (~173k full reads/day of large-array churn), and `$global:recentChanges`
   was never pruned.

## Fixes

- NEW `Modules/watcher_log_tail.ps1` - `Read-WatcherLogTail`: incremental
  byte-offset log reader (UTF-8, BOM-aware, rotation/shrink re-seat).
  Display semantics match the old whole-file reader exactly, including
  surfacing an unterminated trailing line (the repowise no-EOL regression).
- Launcher template (`New-WatcherPaneScript`): embeds the reader module into
  every generated pane (generation-time `__TAIL_MODULE__` injection, with a
  fallback path chain because harnesses dot-source the extracted function
  with an empty `$PSScriptRoot`); the per-tick loop now reads only new bytes;
  `$global:recentChanges` is pruned to the newest 500 entries; obsolete
  `Get-CompleteLineCount` removed. All four panes (grepai, graphenium,
  graphify-rs, repowise) get the fix on next launcher run.
- `Modules/graphify_ignore_gate.ps1`: new `Test-PathsIgnoredByGraphify`
  batches the ignore check - one `git check-ignore` call per ~200-path chunk
  instead of one subprocess per path. Paths are passed as ARGUMENTS, not via
  `--stdin`: PowerShell 5.1 pipes CRLF-terminated text to native stdin and
  git treats the trailing CR as part of the path (nothing ever matched).
- `dev_tools/graphify-watch-wrapper.ps1`: `$pending` is now a Dictionary
  (path -> last-seen) so a cascade collapses to ONE entry per distinct file;
  cheap enqueue-time filter drops `.git` internals and the always-excluded
  output dirs before they enter the queue; staleness flush (oldest entry
  older than 30 s) plus a 5000-entry hard cap bound the set even during
  sustained churn; flush logic extracted into testable
  `Invoke-GraphifyPendingFlush` / `Test-GraphifyWatchShouldFlush`.

## Deliberate deviations / parity notes

- Parent-liveness poll stays at 1 s (plan suggested 5 s): the existing
  parent-death regression test budget depends on it and the 1 s poll is not
  a measurable CPU factor.
- Rebuild-on-tool-state-churn behavior is UNCHANGED (only `.git` and the
  safe-list dirs are newly filtered at enqueue; other dot-dirs still pass,
  exactly as before).
- The wrapper suite's parent-death timing test is flaky under heavy parallel
  load (passed 5/6 runs; failure reproduced at ~3 s margin during back-to-back
  suite runs).

## Test impact

- New: `tests/watcher_log_tail.tests.ps1` (8 tests: offsets, no-EOL line,
  CRLF, BOM, multi-byte UTF-8, rotation).
- Extended: `tests/graphify_watch_wrapper.tests.ps1` (+7: enqueue filter,
  flush decision, dedupe/clear), `tests/graphify_ignore_gate.tests.ps1`
  (+2: batch/per-path parity in a real git repo, empty input).
- Harness updates: `repowise_changed_files` / `repowise_e2e_resolve` now
  extract `Read-WatcherLogTail` (the removed `Get-CompleteLineCount` is gone);
  `launcher_graphenium_autofix` pins updated to the new `foreach ($line ...)`
  loop shape; four harnesses that lacked the Pester 3.4 pin got the standard
  pin header (they otherwise auto-load Pester 6.x standalone, where legacy
  `Should` cannot bind).
- All affected suites green. Remaining failures (`jcode_cwd_wt_reuse`,
  `launcher_gm_semantic_build` ###5 test, `launcher_watcher_teardown*`,
  `t8_isolation` RED) reproduce on the pre-change code via git stash baseline
  and are pre-existing.
