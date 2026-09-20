# Change Log: Fix @@launch watcher for grepai.ps1 Script Crashes and False Positives

**Date:** June 29, 2026  
**Issue:** `@@launch watcher for grepai.ps1` in `J:\audio\VAD` was crashing or exiting unexpectedly/silently on startup under certain conditions.

## Root Cause Analysis
1. **No Directory Context Resolution:** The launch script did not change directory to its own location before executing `grepai watch`. When launched by double-clicking or from other working directories, `grepai` was started in arbitrary/wrong directories (like `C:\Windows\System32`), which could crash/hang/leak memory trying to watch huge system folders.
2. **False Positives with Sibling Process Check:** The script checked for *any* running `grepai` process. Since opencode, editor plugins, and CLI commands run `grepai` for search and indexing, a transient or separate `grepai` process would prevent the watcher from starting, causing the terminal window to exit cleanly with code 0 instantly. To the user, this appeared as if the watcher window opened and closed/crashed immediately without launching the daemon.
3. **Silent Terminal Window Closure on Daemon Crash:** The launcher script started `grepai watch` using a simple `Start-Process`. If `grepai watch` crashed during initialization (e.g. missing dependencies, model path errors, or corrupted DB index), the newly spawned terminal window would immediately close, leaving the user with zero error feedback.
4. **Ollama Default Search Path Fallback:** If Ollama was offline, the script checked if `ollama` was on the PATH. If Ollama was installed in its default Windows path but not yet reload-synced to the current environment PATH, the script would fail to start it and exit with an error.
5. **Non-Robust Stdin Reading on Redirection:** The script used `[void][System.Console]::ReadLine()` to handle pause/exit confirmations. When run inside redirected environments, subagent sessions, or IDEs, this would throw non-catchable IO exceptions and crash the PowerShell script.

## Resolution
1. **Added Path/Directory Resolution:** Added automated script directory resolution via `$PSScriptRoot` and `$MyInvocation` with `Set-Location` to guarantee `grepai watch` is always started inside the correct project root directory.
2. **Refined Sibling Process Detection:** Replaced general `Get-Process -Name "grepai"` with a precise `Get-CimInstance Win32_Process` query that specifically filters for `grepai.exe` processes running with `watch` in their command lines, resolving false positives.
3. **Error Catching and Window Persistence:** Wrapped `grepai watch` with an automated error-handling runner using `powershell.exe -Command "grepai watch; if ($LASTEXITCODE -ne 0) { ... Read-Host }"` so that any startup errors are displayed to the user and require keypress input to close, preventing silent window crashes.
4. **Robust Ollama Path Resolution:** Added fallbacks to check default installation directories (`$env:LocalAppData` and `$env:ProgramFiles`) if `ollama` is not on the user's PATH.
5. **Standardized Input Reading:** Replaced `[void][System.Console]::ReadLine()` with robust native `$null = Read-Host` cmdlets across all launcher scripts (both `@@launch watcher for grepai.ps1` and `@@launch_pyside6_ui.ps1`).

## Tests & Verification
1. Stopped all background `grepai` processes and validated clean start and verification.
2. Ran complete test suite (`pytest`); all 71 tests passed successfully.
