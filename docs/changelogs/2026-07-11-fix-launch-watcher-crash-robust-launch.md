================================================================================
FIX: @@launch watcher for grepai.ps1 crash (robust launch + reliable readiness)
================================================================================
Date/Time : 2026-07-11 (local)
File      : @@launch watcher for grepai.ps1 (+ new @@launch watcher for grepai.bat)
Author    : Hermes agent

--------------------------------------------------------------------------------
SYMPTOM
--------------------------------------------------------------------------------
The standalone grepai watcher launcher crashed under two real conditions:
  1. Launching it a SECOND time while a watcher was already running/initializing:
     grepai refused with a non-zero exit ("Error: timeout waiting for process to
     become ready after 30s" / "Error: watcher is already running (PID N)"). The
     old guard `& grepai watch --background; if ($LASTEXITCODE -ne 0) { throw }`
     treated ANY non-zero exit as fatal and threw -> Write-Error + "Press Enter"
     + exit 1. The whole launcher died instead of reusing the live watcher.
  2. Double-clicking the .ps1 in Explorer: Windows has NO open command registered
     for .ps1 (cmd `ftype Microsoft.PowerShellScript.1` => "not found or no open
     command associated"). Explorer cannot execute it, so the window vanished
     instantly (classic "opens and closes immediately" crash).

--------------------------------------------------------------------------------
ROOT CAUSE
--------------------------------------------------------------------------------
- The same two defects documented in change log 2026-07-10 (DEFECT A = blank/
  non-zero exit-code throw; DEFECT B = readiness gated on the unreliable
  `grepai watch --status` signal) were fixed in the sibling `###1. updater grepai
  graphenium graphify-rs repowise.ps1` but were NEVER ported into this standalone
  launcher. It still used the original `if ($LASTEXITCODE -ne 0) throw` crash path
  and the unreliable `--status` readiness loop (which also lost the log-path parse
  branch that depended on `--status` output).
- No .bat wrapper existed, so double-clicking the .ps1 hit Windows' missing .ps1
  file association and produced an instant silent close.

--------------------------------------------------------------------------------
FIX
--------------------------------------------------------------------------------
- Replaced the crash-prone `& grepai watch --background; if ($LASTEXITCODE -ne 0)
  throw` with the robust launch block (ported from `###1. updater...`):
    * Launch via Start-Process (tracked, redirected output, hidden window).
    * Only a clearly NUMERIC non-zero exit with a NON-recoverable error is a hard
      failure (throw -> "Press Enter" + exit 1).
    * A "already running" / "timeout waiting for process" refusal is RECOVERED:
      if a live `watch` process exists, reuse it; otherwise kill the referenced
      orphan PID + clear the stale *.pid lock, then relaunch once.
- Replaced the `grepai watch --status` readiness loop (unreliable) with a `.ready`
  file + live-process check (grepai writes grepai-worktree-*.ready when serving).
  Log path is now grabbed from the grepai-worktree-*.log glob (no colon-parsing
  dependency on `--status` output).
- Replaced the top-of-script "already running" early-exit guard (which also gated
  on the unreliable `--status`) with the same `.ready`/live-process liveness check,
  eliminating the latent false-negative that could force an unnecessary relaunch.
- Removed the now-dead Invoke-GrepaiSafe function.
- Added @@launch watcher for grepai.bat: a double-click wrapper that calls
  pwsh.exe (fallback powershell.exe) with -ExecutionPolicy Bypass -File, so
  double-clicking always runs the script even under a Restricted/Unrestricted
  policy and even though .ps1 has no Explorer file association.

--------------------------------------------------------------------------------
VERIFICATION (empirical, real execution)
--------------------------------------------------------------------------------
- Parse check on the full file: PARSE_OK (no syntax errors).
- TEST A (fresh launch, no watcher): launcher reaches "grepai watch is RUNNING"
  and stays open tailing the live log (STILL_RUNNING after 25s, not crashed).
- TEST B (watcher already running): second launch detects live watcher via
  .ready/live-process and exits 0 cleanly (no error, no crash).
- TEST C (.bat double-click path): launching via the .bat wrapper brought grepai
  up ("Status: running", new PID) — proves the missing-association crash is fixed.
- Reproduced the ORIGINAL crash before the fix: a second `grepai watch --background`
  while one was initializing exited code 1 with "Error: timeout waiting for process
  to become ready after 30s", which the old `if ($LASTEXITCODE -ne 0) throw` would
  have converted into an immediate launcher crash. After the fix it recovers.

--------------------------------------------------------------------------------
NOTES
--------------------------------------------------------------------------------
- grepai itself recovered cleanly from a simulated stale lock (started a fresh PID),
  so the relaunch-once branch is a belt-and-suspenders safety net, not the hot path.
- The non-watcher grepai.exe false-positive class (a stray `grepai search` matching
  "watch") is avoided: both guards use .ready-file presence OR a `watch`-command-line
  process, not a bare substring on any grepai process.
- Did NOT commit/push (no explicit request). Files are modified/added in the working
  tree; `git status` shows @@launch watcher for grepai.ps1 (renamed, modified) and
  ?? @@launch watcher for grepai.bat (new, untracked).
