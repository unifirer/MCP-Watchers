# 2026-08-18 — Virtual-desktop switching slowness: orphaned graphify-rs watcher stack

## Symptom
Virtual-desktop switching (Task View / `Win+Tab` / `Ctrl+Win+D`) is extremely
slow. A single switch can take several seconds and stutters the whole desktop.

## Root cause (verified against live processes)
The slideshow/display-picture fix from session 2026-08-07 was a red herring.
Live investigation showed:

- The scheduled task `ReapplyDesktopSlideshow` is **Disabled** and last ran
  14/08/2026. It is not firing at logon or on a timer.
- The `###1` watcher does **not** invoke the slideshow script.
- 10 orphaned `powershell.exe -WatchMode -Repo "J:\audio\VAD"
  ...\graphify-watch-wrapper.ps1` processes were alive, all with exited parent
  PIDs (orphans), ranging 53–374 MB each and thousands of handles. One earlier
  sibling held 50,296 CPU-seconds (~14 h of CPU).

`Stop-AllWatchers` (modules/watcher_teardown.ps1) already had a sweep entry for
`graphify-watch-wrapper` (lines 102–108) and a regression test
(launcher_watcher_teardown.tests.ps1) locking the dedicated-literal-pattern
contract. But that sweep only runs at **exit** (Ctrl+C trap / PowerShell.Exiting
/ WT-tab heartbeat). When a prior `###1` was hard-killed or crashed before the
trap fired, its detached wrapper children survived. The next clean `###1`
launch recovered prior instances via `Stop-PriorLauncherInstances` — which
matched **only** the `###1` launcher token and never the graphify wrappers — so
each relaunch stacked one more orphaned wrapper. Ten stacked wrappers, each
running a `FileSystemWatcher` over the whole repo and spawning a full
graphify-rs rebuild on every file change, saturated the disk and CPU. Windows
virtual-desktop switching (an Explorer/dwm animation + thumbnail cache)
stuttered under the contention.

## Fix
Extended `Stop-PriorLauncherInstances` in
`###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1` to
sweep orphaned `graphify-watch-wrapper` processes at STARTUP, using the SAME
dedicated `'graphify-watch-wrapper'` literal pattern as `Stop-AllWatchers`
(and `Invoke-CimMethod -MethodName Terminate`, since `CimInstance` has no
`.Terminate()` method on this host). This closes the gap where a hard-killed
prior launcher left wrappers alive until the next clean exit.

## Verification
- 10 orphaned wrapper processes terminated (verified 0 remaining via
  `Get-CimInstance Win32_Process` command-line fingerprint).
- `###1` launcher + `modules/watcher_teardown.ps1` + `graphify-watch-wrapper.ps1`
  all parse clean (no PowerShell syntax errors).
- `tests/test_launch_watcher_teardown.py` — 7 passed, including new regression
  test `test_stop_prior_launcher_instances_sweeps_orphaned_graphify_wrappers`.
- `tests/launcher_watcher_teardown.tests.ps1` (Pester 3.4.0) — 11 passed,
  including the existing `watcher teardown sweep matches graphify wrapper`
  contract test.

## Files changed
- `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`
  — added graphify-wrapper sweep to Stop-PriorLauncherInstances at startup.
- `tests/test_launch_watcher_teardown.py` — added regression test.
