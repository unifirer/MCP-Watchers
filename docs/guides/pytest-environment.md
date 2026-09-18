# pytest in this repo: environment failure modes

Audience: anyone whose pytest run fails here and wonders whether the launcher
is broken. None of the failures below is a launcher defect. They are all
environment gaps, and each one now has a deterministic behaviour: SKIP, not
FAIL, when the environment cannot support the check.

Run the suite from the tests directory with the bare ini name:

```bash
cd J:\audio\MCP-Watchers\tests
python -m pytest -c pytest.ini -q
```

`-c tests/pytest.ini` double-resolves to `tests/tests/pytest.ini` and fails
with `FileNotFoundError`.

## 1. Nested PowerShell host: `CommandNotFoundException`

**Symptom.** `launcher_tests.ps1` gets through T1/T2's static checks, then dies:

```
& : The term 'powershell' is not recognized as the name of a cmdlet, function,
script file, or operable program.
```

**Root cause.** PowerShell resolves a *bare* executable name using
`$env:PATHEXT`. When PATHEXT is unset or truncated, discovery fails even though
`C:\WINDOWS\System32\WindowsPowerShell\v1.0` is on `PATH` and the binary is
perfectly spawnable. Observed on this box (2026-09-18): `os.environ["PATHEXT"]`
was absent for the agent's shell, and `$env:PATHEXT` inside the spawned host
read literally `.CPL`.

Confirm in one line from inside the affected host:

```powershell
$env:PATHEXT                 # '.CPL' -> broken
(Get-Command powershell).Source
```

Note that `subprocess.run(["powershell", ...])` from Python still works in that
state, because `CreateProcess` does not use PATHEXT. That asymmetry is why the
outer host started fine while the nested `& powershell` inside it did not.

**Fix in repo.** `launcher_tests.ps1` calls `Repair-PathExt` (restores the
standard extension list) and then resolves the host through `PATH` with
`Get-Command`. Nested-host assertions go through `Assert-Host`, which reports
`[SKIP]` when no host is reachable. `run_launcher_tests.ps1` does the same
before spawning. Nothing hardcodes a `System32` path.

## 2. Import-time unlink aborts collection: `INTERNALERROR`

**Symptom.** pytest dies during *collection*, before any test runs.

**Root cause.** `test_launcher.py` used to delete the cross-process lock file at
module import:

```python
if _GREPAI_LOCK_PATH.exists():
    try:
        _GREPAI_LOCK_PATH.unlink()
    except OSError:
        pass
```

The delete was unnecessary *and* wrong. `filelock` 4.x `WindowsFileLock` guards
with a `LockFileEx` byte-range lock, which the OS releases when the holder dies,
and it unlinks the file itself on release. A leftover file therefore cannot
block acquisition, while deleting it at import time can drop it out from under
a **live** holder in a concurrent run. In sandboxes that intercept `unlink`
(the safe-delete shim raises `SystemExit`, which `except OSError` does not
catch) the delete aborted the whole run.

**Fix in repo.** The delete is gone. `test_launcher.py` never mutates the lock
file.

## 3. Missing target script: `launcher not found`

**Symptom.**

```
Exception: ...launcher not found: J:\audio\MCP-Watchers\###2.launch_watcher_for_grepai.ps1
```

**Root cause.** `tests/launch_watcher_for_grepai.tests.ps1` exercises
`###2.launch_watcher_for_grepai.ps1`, which MCP-Watchers (a stripped extraction
of VAD) does not ship. The suite throws at load, so the pytest wrapper failed.

**Fix in repo.** `test_launch_watcher_for_grepai_ps1.py` SKIPs when the target
script is absent. In a checkout that ships it, the suite runs unchanged.

## 4. `import llm_fallback_proxy` aborts the whole run

**Symptom.**

```
ModuleNotFoundError: No module named 'llm_fallback_proxy'
!!!! Interrupted: 1 error during collection !!!!
```

**Root cause.** The module ships as `###2.llm_fallback_proxy.py` at the repo
root. The leading `#` characters make it an invalid Python identifier, so no
`sys.path` entry can ever reach it — the old `sys.path.insert(0, dev_tools)`
could not help. Because the failure happens at import, it aborts collection and
**no test in the repo runs at all**.

**Fix in repo.** `test_watcher_allocator.py` falls back to
`importlib.util.spec_from_file_location` when the plain import cannot find it.

## Reporting a new failure

Before filing a bead, check which layer failed:

| Layer | Probe |
|-------|-------|
| host spawn | `python -c "import shutil; print(shutil.which('powershell'))"` |
| nested spawn | `$env:PATHEXT` from inside the host |
| collection | `pytest -c pytest.ini --collect-only -q` (aborts => import-time defect) |
| target script | does the `###`-prefixed file exist in this checkout? |
