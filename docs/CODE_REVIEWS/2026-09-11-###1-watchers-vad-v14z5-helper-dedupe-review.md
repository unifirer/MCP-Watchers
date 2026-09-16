# Code Review: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`

- **Date:** 2026-09-11
- **Reviewer:** TRAE agent (nf:code-review-and-quality)
- **Scope:** commit `32429c2f` "refactor(VAD-v14z.5): dedupe job-scope helpers into a shared module"
  (launcher +70/-107, new `Modules/watcher_job_helpers.ps1`, new
  `tests/test_launcher_job_helpers_dedupe.py`, updated `tests/launcher_remediation.tests.ps1`)
  plus the surrounding state of the 3,897-line artifact.
- **Verdict:** The refactor itself is behavior-preserving and well guarded. But the
  repository acceptance gate is RED (3 of 13 launcher test files fail), and one of
  those failures is a false-green fixture. Two live defects sit in the artifact.

---

## Findings

Ordered by severity. "Verified" means a command in this session produced the evidence.

### P1-1. `tests/launcher_tests.ps1` T8 hard-fails: module resolution needs an unset env var (VERIFIED)
- `tests/test_launcher.py::test_launcher_powershell_suite_passes` fails. T1-T7 pass; T8
  aborts with `watcher_log_tail.ps1 not found next to the launcher or under
  $env:VAD_WORKSPACE_ROOT\Modules`.
- Root cause, proved by isolating the extracted function:
  - `New-WatcherPaneScript` (launcher line 2795) throws when neither candidate resolves.
  - `$env:VAD_WORKSPACE_ROOT` is empty at process, User and Machine level on this box.
  - Probe result: env unset -> `CALL-ENV-UNSET: FAIL`; env set -> `CALL-ENV-SET: OK`.
- The code comment at line 2787 claims `$PSScriptRoot` is EMPTY in that harness shape.
  That claim is false. The probe showed `PSScriptRoot = J:\audio\VAD\temp` (non-empty,
  and without a `Modules\` child), so the only remaining candidate is the unset variable.
- Pre-existing: `HEAD~1` has the same throw and the same env fallback. This is not a
  regression of `32429c2f`. It is still the end-to-end pane-grid gate, so it blocks a
  "gates green" claim.
- Fix (pick one): resolve the module relative to the launcher path (for example
  `$MyInvocation.MyCommand.Path` or a baked literal), or set `VAD_WORKSPACE_ROOT` in the
  harness and CI. `tests/test_launcher_portable_paths.py` and
  `tests/test_launcher_job_helpers_dedupe.py` pin the env-derived literal, so keep it or
  update both tests.

### P1-2. Teardown-state contract drift: stale fixture gives a false green (VERIFIED)
- `tests/test_launcher_teardown_state_live.py::test_real_teardown_state_file_has_contract_keys`
  fails: the live file has 5 keys, the assertion pins exactly 4.
- The extra key is `GrepaiPid`, written at launcher line 3894.
- `Modules/watcher_teardown.ps1` REQUIRES that key (lines 110, 121, 183-189). The
  launcher is correct; the test is stale.
- `tests/_write_teardown_state.ps1` claims to be a "faithful reproduction of the
  teardown-state.json writer embedded in ###1 (lines ~1596-1607)". Both claims are now
  false: the writer moved to ~3889 and it emits 5 keys, not 4. The first test therefore
  passes against a fixture that no longer matches production.
- Fix: add `GrepaiPid` to the fixture and to both key-set assertions (lines 60 and 84),
  or assert a superset contract.

### P1-3. Stale proxy-port assertion contradicts the current bridge (VERIFIED)
- `tests/test_launcher_proxy_wiring.py::test_bridge_upstream_points_to_proxy` fails. It
  requires `127.0.0.1:13000` and forbids `127.0.0.1:11436`.
- `dev_tools/gm-ollama-bridge.ps1` line 47 is `UPSTREAM = "http://127.0.0.1:11436"`,
  per the 2026-09-05 proxy move. The reviewed launcher uses 11436 everywhere.
- Fix: invert the assertion (require 11436, forbid 13000). The other two tests in that
  file, which inspect the launcher, pass.

### P2-4. `$pid = 0` makes the memtrace window-hiding backstop a silent no-op (VERIFIED)
- Launcher lines 2193-2195, inside the `EnumWindows` delegate of `Hide-MemtraceWindows`:
  ```powershell
  $pid = 0
  [void][Win32.MemtraceWin]::GetWindowThreadProcessId($hwnd, [ref]$pid)
  ```
- `$PID` is a Constant, AllScope automatic variable. Probe output:
  `PID options: Constant, AllScope` and
  `SCOPE-ASSIGN-FAIL: SessionStateUnauthorizedAccessException :: Cannot overwrite
  variable PID because it is read-only or constant.` The `[ref]$pid` binding fails the
  same way.
- Effect: the delegate throws on the first callback, so no daemon window is ever hidden.
  Both call sites (lines 2208, 2226) swallow the error with `catch {}`.
- Fix: rename the local to `$ownerPid` (the same bug class was already fixed elsewhere;
  `Test-PortHeldByLauncherDaemon` correctly uses `$ownerPid`).
- Note: the two `Add-Type -MemberDefinition` blocks with nested structs and a delegate
  DO compile on PS 5.1 (probe: `ADDTYPE-STRUCT-OK`, `ADDTYPE-DELEGATE-OK`). No finding
  there.

### P2-5. The refactor turned a previously-inline helper into a fatal top-level dependency
- Line 979: `if (-not $jobHelpersModule) { throw 'watcher_job_helpers.ps1 not found ...' }`.
- Before this commit, `Limit-LogSize` and `Clear-StaleLocks` were defined in the parent
  scope, so the launcher could still run. Now a missing or renamed module kills the
  launcher at line 979, after `grepai watch` is already launched (line 866) and before
  the `Press Enter to exit` convention used for the missing-grepai case (lines 606-611).
  A double-click of the `.bat` therefore loses the console with no message.
- The sibling dot-sources at lines 12-16 use `Test-Path` guards. The policy is
  inconsistent for the same class of dependency.
- Fix: guard with a warning plus inline fallback, or route through the same
  "hold the console" convention.

### P2-6. FIRST-WINS `exit 0` gates run after five watchers are launched
- `Exit-IfPortHeldByLauncherDaemon` can `exit 0` at line 358. Three gates do this:
  memtrace :50051 (line 2244), cerememory :8420 (line 2460), claude-mcp-server :8080
  (line 2570).
- By line 2244 the launcher has already spawned, detached: litellm (1623), gm watch
  (1817), graphify-rs wrapper (1985), repowise (1999), plus grepai watch (866).
- `teardown-state.json` is written at line 3889 and the `PowerShell.Exiting` handler is
  registered at line 2733. Neither is reached on this path. So no PID-scoped teardown
  runs and five processes are orphaned.
- Likelihood is low: it needs `-AutoHeal` to fail to free the port. The orphan class is
  still the one the file documents as unacceptable.
- Fix: move the three port gates before the first `Start-WatcherDetached`, or call
  `Stop-AllWatchers` before `exit 0`.

### P2-7. Dead user-facing notification: the semantic-build popup can never fire
- `Invoke-GmSemanticBuild` guards the popup with `$State` (lines 1448-1462), and the
  comment at lines 1841-1843 says `PopupShown` gates it to one per session.
- The only production call site (line 1956) omits `-State`. The default
  `$global:gmSemState` then evaluates inside the thread-job runspace, where it is `$null`.
  The branch is unreachable.
- Fix: pass the shared state through the job argument list into the call, or delete the
  branch and its comments.

### P3-8. `$script:GrepaiOllamaHostPort` is write-only
Written at lines 464 and 517. The comment at line 588 says the auto-start uses it, but
the auto-start reads `$env:OLLAMA_HOST`. Delete it or read it.

### P3-9. No drift guard on the deliberately pinned copies
The commit keeps byte-identical inline `Clear-StaleLocks` and `Test-LauncherAlive` in the
grepai supervisor (comments at lines 1007-1010 and 1077-1080). I compared both bodies
against the module: they match today. But
`tests/test_launcher_job_helpers_dedupe.py` only COUNTS definitions. Nothing asserts body
equality, so the exact drift class this refactor exists to remove can return silently.
Add a body-equality assertion between the module and the inline copies.

### P3-10. Dead parameters in `Show-ChangedFiles`
`-Lines` and `-Index` (lines 3203-3204) are never read, yet both call sites pass them
(lines 3265, 3401). Remove them or use them.

### P3-11. Heartbeat comment and code disagree
The comment at line 3434 says "~30 dead ticks @ 500ms ~= 15s". The code keeps the grepai
pane alive until 60 ticks (`$script:deadTicks -lt 60`, line 3465), about 30 s.

### P3-12. In-repo log writes contradict the off-repo log policy
Lines 814-822 explain that watcher logs live outside the repo, because in-repo scratch
triggers gm/graphify-rs/repowise rebuild churn. Two writers still write inside the repo:
`logs/llm_fallback_proxy_restarts.log` (line 1736) and `logs/llm_fallback_proxy.log`
(line 1773). Move them to `$logsDir` or accept and document the churn.

### P3-13. Case-inconsistent module paths
Lines 12 and 15 use `modules\...`; lines 974, 2790 and 3820 use `Modules\...`. Harmless on
Windows, broken on a case-sensitive filesystem.

---

## Verification Reviewed

Commands run in this session (2026-09-11, `Pacific/Auckland`):

1. `python run_tests_isolated.py` over 13 launcher test files
   (`test_launcher*.py`, `test_launch_watcher*.py`, `test_teardown_grepai_pid_scoped.py`,
   `test_grepai_heal_single_healer.py`).
   Result: **10 passed, 3 failed**.
   - PASS: `test_launcher_watchers_contract.py`, `test_launcher_gm_wiring.py`,
     `test_launcher_worktree_quoting.py`, `test_launcher_job_helpers_dedupe.py`,
     `test_launcher_portable_paths.py`, `test_launcher_double_click_bat.py`,
     `test_launch_watcher.py`, `test_launch_watcher_teardown.py`,
     `test_teardown_grepai_pid_scoped.py`, `test_grepai_heal_single_healer.py`.
   - FAIL: `test_launcher.py` (T8), `test_launcher_teardown_state_live.py`,
     `test_launcher_proxy_wiring.py`.
2. PowerShell 5.1 AST parse of the launcher: **0 parse errors, 38 functions**.
3. `$PID` constant-variable probe: confirmed `Constant, AllScope` and the throw.
4. `Add-Type -MemberDefinition` probes (nested struct, delegate): both OK.
5. Isolated `New-WatcherPaneScript` probe: env unset FAIL, env set OK.
6. Diff of the reviewed commit and of `tests/launcher_remediation.tests.ps1`.

Test-side changes in the commit are legitimate. `tests/launcher_remediation.tests.ps1`
replaces a "at least 3 copies of Limit-LogSize" assertion with a single-source-of-truth
assertion. That is a correct update for this refactor, not a weakened gate.

Not run, therefore unverified: Pester tests after T8 (`launcher_tests.ps1` stops at the
T8 failure, so T9-T22 never executed), the other Pester files
(`launcher_equal_quarters`, `launcher_watcher_panes`, `repowise_*`, and others), and any
live end-to-end launcher run.

Side effect handled: the failing T8 run auto-started a `grepai.exe watch` (PID 78488,
16:44:41) that outlived the aborted suite. I terminated it. The watcher count is back
to 0. All probe files in `temp/` were deleted.

---

## Residual Risks

- A live end-to-end run was not performed. The pane grid, teardown and heartbeat paths
  are only covered by static and harness tests.
- Pester T9-T22 and the remaining Pester files are unverified in this session.
- `gm.log`, `repowise.log` and `graphify-rs-watch.log` are pump-held FileStreams, so
  `Limit-LogSize` must not rotate them (documented at `Modules/watcher_job_helpers.ps1`
  lines 52-56). A multi-day session still grows them without bound.
- `Test-LauncherAlive` semantics changed for the litellm and memtrace supervisors. They
  now get the strict version with the `StartedAt` and `Launcher` guards, where they
  previously had a PID-only check. This is a strengthening and is probably correct, but
  the commit message does not call it out and no test covers the new guard on those two
  paths.
- The grepai supervisor's backoff resets `$consecutiveRestarts` after a 10-minute
  cooldown (lines 1174-1179), so a permanently broken grepai still churns once per 10
  minutes forever.

---

## Merge Recommendation

**NOT READY** for a merge that claims green gates.

- The refactor itself is sound. It is verified by the new static suite, the parse check,
  and a manual body comparison of the pinned copies. Do not revert it.
- Blocking items are small and test-side: P1-1 (T8 module resolution), P1-2 (fixture and
  key-set drift), P1-3 (inverted port assertion).
- Two live defects in the artifact should be fixed in the same change, because they are
  small: P2-4 (`$pid` rename) and P2-5 (fatal dependency plus lost error message).
- Route P2-6 and P2-7 to follow-up issues. Route the P3 list to the readability backlog.

### Suggested order of work
1. P1-2 and P1-3: fix the two stale tests and the fixture. They are false greens.
2. P1-1: make module resolution harness-safe, then re-run the full Pester suite.
3. P2-4: rename `$pid` to `$ownerPid`.
4. P2-5: soften the module-missing failure into the existing console-hold convention.
5. P3-9: add the body-equality drift guard that this refactor was meant to provide.
