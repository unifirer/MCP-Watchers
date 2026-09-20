================================================================================
FIX: updater kills orphaned watchers, per-pattern throttle, repowise suppression
================================================================================
Date/Time : 2026-07-10 (Fri) local
File      : ###1. updater grepai graphenium graphify-rs repowise.ps1
Author    : Hermes agent

--------------------------------------------------------------------------------
SYMPTOMS (user-reported)
--------------------------------------------------------------------------------
1. "does closing the window kill the orphaned watchers?" - No: a detached child
   outlives its parent window. The launcher's Ctrl+C trap only kills watchers THIS
   run started; orphans from a previous run keep running.
2. "the 2 throttled messages are throttled at different rates" - the two graphify
   WARNS did NOT throttle at 1-in-10 each; one was effectively invisible.
3. repowise prints repetitive "VS Code MCP configured / VS Code extension
   recommended" lines on every change - noise in the combined view.
4. (found during fix) gm watch never launched at all - "graphenium: 0".

--------------------------------------------------------------------------------
ROOT CAUSES
--------------------------------------------------------------------------------
A. Kill-orphans used `CimInstance.Terminate()`, which does NOT exist on this
   PowerShell 7 build -> silently never killed anything -> dedup skipped the
   still-alive orphans -> no fresh logs, "already running" skips.
B. Throttle used ONE shared counter for both WARN patterns. graphify-rs emits
   them in alternating pairs (Large corpus at odd indices, graph too large at
   even); `% 10` only ever matched even indices -> "Large corpus detected" was
   never printed. So they were not 1-in-10 each, one was suppressed.
C. repowise VS Code lines were not filtered.
D. `Get-Command gm` resolves to PowerShell's built-in `Get-Member` ALIAS, not
   `gm.exe` -> `$cmd` was null -> gm launch skipped.
E. grepai's `watch --background` prints NUL-terminated JSON to stdout, polluting
   the launcher's text stream. Also the log-dir paths were defined AFTER the
   grepai launch block, so `Join-Path $logsDir ...` was null -> launch failed.

--------------------------------------------------------------------------------
FIX
--------------------------------------------------------------------------------
- Stop-WatcherOrphans now kills via `Invoke-CimMethod -MethodName Terminate`
  (the API that actually works here), with a 5x retry loop, BEFORE launching,
  then removes temp/watchers/ for fresh logs. Verified: "already running" skips
  drop to 0; all four watchers launch fresh.
- Throttle split into two independent counters ($corpusWarnCount /
  $graphWarnCount) -> each WARN prints 1-in-10. Verified 3+3=6 from 30+30.
- repowise "VS Code MCP configured" and "VS Code extension recommended" lines
  are fully suppressed in the tailer. Verified 0 printed.
- gm resolved via `Get-Command "gm.exe"` (explicit .exe) to dodge the alias.
  Verified gm.log created + gm.exe running.
- grepai launched via Start-Process with its own redirect files
  (grepai-launch.log/.err); log-dir paths moved ABOVE the grepai block.
- Tailer strips NUL/control bytes from every line (-replace '[\x00-\x08\x0B\x0C
  \x0E-\x1F]') so the combined view stays valid text. Verified 0 NUL bytes in
  captured stdout.
- Whole tailer wrapped in try/catch so no stray exception kills the window.

--------------------------------------------------------------------------------
VERIFICATION
--------------------------------------------------------------------------------
- PowerShell parse: PS1 PARSE OK ([System.Management.Automation.Language.Parser]).
- pytest tests/test_launch_watcher.py: 15 passed, 0 failed (18.4s).
- Functional run: 4 watchers fresh (gm + graphify-rs + repowise + grepai),
  0 skips, 0 VS Code lines, 0 NUL bytes; launcher stays open and tails live;
  Ctrl+C trap kills detached watchers + stops grepai.
