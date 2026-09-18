# 2026-09-18 — mcpw-tao: two pytest modules could not run

Summary of the fix and, more importantly, of the diagnosis, because the bead's
original description was wrong.

## What the bead claimed

> Two pytest modules cannot run inside the agent sandbox ... the sandbox
> deliberately blocks spawning the Windows PowerShell host.

Not correct. `powershell.exe` and `pwsh.exe` are both on PATH and both spawn
fine from Python's `subprocess`. The Bash tool refuses commands that *name* a
PS host, which is a different thing.

## What actually happened

1. **Nested host resolution.** `launcher_tests.ps1` runs
   `& powershell -NoProfile -File ...` from inside an already-running host.
   PowerShell resolves a bare executable name through `$env:PATHEXT`. This
   environment exports no PATHEXT, and `$env:PATHEXT` inside the spawned host
   reads `.CPL`, so discovery raised `CommandNotFoundException`. Python's
   `CreateProcess` does not use PATHEXT — hence the asymmetry.
2. **Import-time unlink.** `test_launcher.py` deleted the cross-process lock
   file at module import. Unnecessary (filelock 4.x `WindowsFileLock` uses a
   `LockFileEx` byte-range lock that the OS releases when the holder dies) and
   harmful (it can delete the file out from under a live holder). In sandboxes
   that intercept `unlink` it aborted collection with `INTERNALERROR`.
3. **Missing target script.** `launch_watcher_for_grepai.tests.ps1` exercises
   `###2.launch_watcher_for_grepai.ps1`, which this checkout does not ship.
4. **Unimportable module.** `test_watcher_allocator.py` did
   `from llm_fallback_proxy import ...`; the file is
   `###2.llm_fallback_proxy.py` — the `#` characters make it an invalid
   identifier, so the import aborted collection for the **entire** repo.

Uncovered while verifying, all pre-existing:

5. **`Get-CimInstance Win32Process`** (typo for `Win32_Process`) in T8's
   self-skip probe. The query silently returned nothing, so T8 never skipped
   even with a real launcher running — it competed with the live session and,
   where the WT pane spawn fails, fell into the launcher's interactive
   combined view and hung until Ctrl+C. Two hung hosts were already on the box
   (10:53 and 18:24).
6. **`.grepai/index.gob` assumptions** in T10b/T10d. This install is
   qdrant-backed and ships no `index.gob`, so the "clean index untouched"
   assertions could never pass.
7. **`$watchersWorkspaceRoot` unset** in the harness. The extracted health
   block is workspace-scoped (`mcpw-ybs.7`) and reads that variable; T11/T12
   still pointed `$scriptDir` instead.
8. **T23 fixed-sleep flake.** The truncation-resume assertion killed the tailer
   on a 3s deadline, before the marker was flushed.

## Result

`launcher_tests.ps1 -SkipSmoke` now runs to completion: **PASS=148 FAIL=0**,
exit 0. Before the change it aborted at T2 with exit 1.

## Files changed

- `tests/launcher_tests.ps1` — `Repair-PathExt`, `Resolve-NestedHost`,
  `Invoke-NestedHostScript`, `Assert-Host`; T8 class-name fix; T10b/T10d gob
  snapshot; `$watchersWorkspaceRoot` seeding; T11/T12/T12b workspace scoping;
  T23 poll.
- `tests/run_launcher_tests.ps1` — same host resolution before spawning.
- `tests/test_launcher.py` — no import-time unlink; PATH-resolved host; skip
  when no host.
- `tests/test_launch_watcher_for_grepai_ps1.py` — skip when the target script
  is absent; PATH-resolved host.
- `tests/test_watcher_allocator.py` — `importlib` fallback loader.
- `docs/guides/pytest-environment.md` — new; the diagnosis write-up.
