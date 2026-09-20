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
`###2.launch_watcher_for_grepai.ps1`, which MCP-Watchers (then a stripped
extraction of VAD) did not ship. The suite threw at load, so the pytest wrapper
failed.

**Fix in repo.** `test_launch_watcher_for_grepai_ps1.py` SKIPs when the target
script is absent. In a checkout that ships it, the suite runs unchanged.

**Status 2026-09-20: this section is now historical.** Tier B was ported from
VAD — `###2.launch_watcher_for_grepai.ps1` and its double-click wrapper
`###2.required_for_launch_watcher_for_grepai.bat` now sit at this repo's root,
so the suite runs here and reports 19 passed, 0 failed instead of exiting 0 with
a SKIP. The guard is deliberately kept: it still protects any checkout that does
not ship the script, and it is what stops a genuinely missing launcher from
being reported as a launcher defect. Do not remove it on the grounds that the
target now exists.

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

## 5. `launcher_tests.ps1` takes longer than the shim allowed

**Symptom.** `test_launcher.py` fails with `subprocess.TimeoutExpired` and
*no output at all* — the printed suite log is empty even though the suite ran
for minutes.

Two separate causes, both fixed:

1. **The ceiling was too low for the loaded case.** Measured 2026-09-19: the
   suite runs 160 s when this module runs alone, but blew a 300 s ceiling
   inside a full `pytest -c pytest.ini -q` run where sibling modules drive the
   same watchers. The ceiling is 900 s.
2. **`capture_output=True` throws away the evidence.** On timeout,
   `subprocess.run` discards the pipe contents, so a slow-but-otherwise-healthy
   run and a hung run look identical. The shim now redirects the suite's stdout
   (and stderr) to a temp file and, on timeout, `pytest.fail`s with the last 40
   lines — which is what tells you *where* it hung.

Do not "fix" a timeout by adding `-SkipSmoke` to the shim: T20/T21 are the only
tests that spawn the real launcher, and they self-skip when a live launcher is
already running.

## 6. `dev_tools/gm-ollama-bridge.ps1` is not in this checkout

**Symptom.** `test_launcher_proxy_wiring.py::test_bridge_upstream_points_to_proxy`
raises `FileNotFoundError` on `dev_tools/gm-ollama-bridge.ps1`.

**Root cause.** MCP-Watchers is a stripped extraction of VAD; the sibling
checkout `J:\audio\VAD\dev_tools` has a large tool tree this one lacks. The
file is absent from git history entirely (`git log --all -- <path>` is empty),
so it was never lost — it was never here.

**Fix in repo.** SKIP when the bridge is absent, matching section 3. A
`FileNotFoundError` on a file the checkout never shipped says nothing about the
launcher.

## 7. Real finding, deliberately NOT auto-fixed: repowise routing

`test_repowise_watch_wired_to_proxy` checks two things. The launcher half
passes (`Ensure-LlmProxyRunning` at offset 150092 precedes
`Start-WatcherDetached "repowise"` at 168492). The config half fails:

```
.repowise/config.yaml has no litellm.base_url
(provider='openai' model='poolside/laguna-xs-2.1:free')
```

`.repowise/config.yaml` is the repowise MCP's own LLM-routing config, and
changing an MCP's LLM endpoint is an operator decision — see the standing
instruction in `AGENTS.md` ("Model Config Stability"). The test therefore
**reports** the gap instead of writing the config, and checks the launcher half
first so a genuine code regression is no longer masked by the config assertion.

Tracked as bead **mcpw-1lr**. This one is expected to stay red until someone
approves adding `litellm.base_url: http://127.0.0.1:11436/v1`.

## Reporting a new failure

Before filing a bead, check which layer failed:

| Layer | Probe |
|-------|-------|
| host spawn | `python -c "import shutil; print(shutil.which('powershell'))"` |
| nested spawn | `$env:PATHEXT` from inside the host |
| collection | `pytest -c pytest.ini --collect-only -q` (aborts => import-time defect) |
| target script | does the `###`-prefixed file exist in this checkout? |
| slow suite | is it >900 s, or did it *hang*? read the tail the shim prints |
| share violation | `Add-Content` on a file a tailer is reading — retry, don't fail |

## Tooling for the two sweeps

Both live in `dev_tools/` and are plain Python 3, no dependencies:

```bash
python dev_tools/sweep_pester.py        # every tests/*.tests.ps1, ~8 min
python dev_tools/scan_stale_anchors.py  # source-wiring anchors that no longer match
```

`sweep_pester.py` **must not** trust exit codes — see the section above on the
self-invoking `Invoke-Pester` pattern. It counts `[-]` lines for failures and
`[+]` lines for passes, de-duplicating both, because the self-invocation runs
every test twice. A suite prints one shape or the other, never both: detailed
output has `[+]` lines but its summary reads `Passed: 0` (the inner summary is
swallowed), while default output has no `[+]` at all but does print
`Tests Passed: N`. The sweeper takes the max of the two sources.

For the Pester version it also mostly keeps its hands off. If a suite contains
`Import-Module Pester`, the sweeper just runs the file and lets it choose.
Only when a suite does NOT import Pester does the sweeper pick, by sniffing for
`Should -` (6.1.0) versus the legacy idiom (3.4.0).

Why it will not wrap a self-importing suite: wrapping means driving the file
through an outer `Invoke-Pester`, which double-runs a self-invoking suite.
`launcher_equal_quarters` passes 15 when executed directly and reports 15
failures when wrapped — identical Pester version, identical machine. The
version is not what broke it; the wrapping is.

**Pester 6.0.0 on this box is a broken install** — any suite run under it dies
in discovery (`Discovery in ...tests.ps1 failed with:`). It exits 0 with
"Passed: 0", so a green result under 6.0.0 means nothing was tested. Use 6.1.0
or 3.4.0.

`scan_stale_anchors.py` finds positive anchors (`IndexOf` / `Contains` /
`-match` / `Should Match`) whose literal no longer appears in the launcher or
`Modules/watcher_pane_scripts.ps1`. It skips negative assertions, where absence
is the passing state. It reports leads, not verdicts — confirm a suite actually
fails before changing anything.

`dev_tools/run_pester_suite.py` runs one suite and prints a VERDICT line.
Prefer it over the sweeper when iterating on a single file:

```bash
python dev_tools/run_pester_suite.py tests/launcher_watcher_teardown.tests.ps1
python dev_tools/run_pester_suite.py tests/t8_isolation.tests.ps1 6.1.0   # override
```

It **imports its version and parsing logic from `sweep_pester.py`**, so the two
tools cannot disagree. They briefly did: the runner reported
`launcher_equal_quarters` as 15 failed while the sweeper reported 15 passed.
The suite is green; the 15 failures came from wrapping a self-invoking suite in
an outer `Invoke-Pester`, which double-runs it — same Pester version, same box.

Passing a version explicitly is honoured but prints a warning when the file
imports Pester itself, because that combination is what manufactures false
failures. Older single-suite runners (`run_pester.py`, `run_pester6.py`,
`run_launcher_suite.py`, `ps_query.py`) were left in `temp/`, which is
gitignored and wiped — recreate from `run_pester_suite.py` if needed.

Current baseline: 35 suites, 234 passed, 2 failed. Both failures are the
`mcpw-lqy` teardown suites, which are red by design pending a decision — see
`docs/changelogs/2026-09-19-pester-sweep.md`.
