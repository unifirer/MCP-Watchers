# Sweep gate fixes — 2026-09-21 (two red guards turned green)

Two defects surfaced while verifying the cerememory strip (`mcpw-418`,
`changelogs/2026-09-21-cerememory-removal.md`). Both predate that change — each
was reproduced against the unmodified HEAD launcher — and both are fixed here.

## `mcpw-d8a` — hardcoded `C:\Users\yuni` in the launcher (commit `2f479a0`, +2 / −2)

Two comment lines in the memtrace block named the developer's home directory
literally:

- the `memtrace_mcp_cwd_proxy.py v1.4.0 start_daemon()` reference (~line 3760)
- the union-store junction note — `<USERPROFILE>\.config\memtrace\.memdb`
  "(C:\Users\yuni\.memdb is a junction to that same directory)" (~line 3788)

Both now read `<USERPROFILE>`, the form the surrounding paragraphs already use.
Comments only, so no behaviour change — but
`test_launcher_portable_paths.py::test_no_hardcoded_user_home` and
`::test_no_generic_user_profile_path` were permanently red because of them, and
a guard that is red by default stops being a guard.

Verified: `py -3.14 -m pytest test_launcher_portable_paths.py
test_launch_watcher_teardown.py test_teardown_grepai_pid_scoped.py` →
**21 passed, 0 failed** (was 19 passed, 2 failed). The guard also covers
`Modules\watcher_pane_scripts.ps1`, which was already clean.

## `mcpw-8ue` — T6/T7 must not run against a live launcher session (commit `3b3c1e1`, +20 / −2)

`tests\launcher_tests.ps1` T6/T7 terminate **every** `grepai.exe` machine-wide
(once at the top of the `try`, again in the `finally`) and delete the
machine-global `%LOCALAPPDATA%\grepai\logs\grepai-worktree-*` lock files. With
the user's real `###1` launcher session up, that kills another repository's live
watcher — the `mcpw-eud` blast radius — and the suite then died at
`Remove-Item: missing path operand`, so T7–T25 never ran at all.

They already skipped when grepai was absent; the missing case was "grepai is
running because the user's launcher owns it". Added the same live-session probe
T8/T20 use (`$launcherSessionActive`), computed before T6 because T6/T7 precede
T8, and both now skip with a stated reason and `PASS++`.

Verified: before, `-SkipSmoke` aborted at T6; after, T6 and T7 both print SKIP
and the suite runs on through T1–T12a with **0 `[-]` markers**.

## Full suite, after both fixes

```
=== T10 summary: PASS=155 FAIL=0 ===   ($LASTEXITCODE = 0, ~2m50s)
```

That run also covers T25, whose block-end anchor moved as part of the
cerememory strip — all five T25 assertions pass.

## Correction — `mcpw-ok6` closed as no-repro

I filed `mcpw-ok6` claiming the suite was truncated at ~2 min and that its exit
code masked failures. Both claims were wrong. Three runs stopping at ~2m02s was
**my harness cutting them off**, not the suite; the run above was allowed to
finish and printed `PASS=155 FAIL=0` with exit 0 — the exit code was 0 because
FAIL was 0, which is correct behaviour. The "exit code is always 0 regardless
of failures" caveat that survives from the 2026-09-17 HANDOVER applies to the
Pester 3.4.0 suites (whose `-PassThru` counts print 0/0), not to this runner.

Evidence: `temp\launcher_tests_exit.txt` (191 lines) and
`temp\launcher_tests_out.txt` (the truncated 115-line capture).

## Two more permanently-red gates, found by the full pytest run

The full `tests/` pytest run surfaced two failures. Neither came from this
branch — both reproduce against `d5f6422~1`, the commit the sweep branched
from — and both were stale *assertions*, not broken code.

### `mcpw-b7z` — supervisor reap assertion predates `mcpw-rkg.4` (commit `187c129`)

`tests/test_launcher_job_helpers_dedupe.py::
test_grepai_supervisor_reaps_on_idle_and_never_relaunches` asserted the
launcher's idle gate with `re.search(r"if \(\$idleMin -ge \$idleTtlMin\)")`.
`mcpw-rkg.4` (commit `7417211`) made the first grepai scan survive the idle TTL
by splitting that gate in two:

```powershell
if ($firstScanRunning -and $idleMin -ge $idleTtlMin) { … reap deferred … }
if ((-not $firstScanRunning) -and $idleMin -ge $idleTtlMin) { … reap … }
```

The plain form no longer exists anywhere in the supervisor, so the regex
matched nothing. Proof it predates the sweep: at `d5f6422~1` the plain form
occurs **0** times and the compound form **2** times; the test file's last
commit (`1807d6c`) is older than `7417211`.

Fix: assert **both** branches. Locking the deferral as well as the reap means
dropping `rkg.4` now fails the test instead of silently reverting it.

### `mcpw-9n1` — the `PENDING_STAGING` ratchet was red from birth (commit `573d458`)

`dev_tools/check_test_hygiene.py` queued five test files as "known-untracked,
awaiting `git add`", and `check()` reports *"PENDING_STAGING entry is now
tracked — prune it"* for any entry that has since been staged. All five were
already staged — four by `03fe566`, the very commit that added the ratchet, and
`tests/launcher_memtrace_orphan_sweep.tests.ps1` by `1f6ffc7` — and the queue
was never pruned, so the tool returned **5 violations on every run since it
landed** and `test_test_hygiene.py::
test_no_test_file_is_untracked_or_pins_a_bug_unmarked` had never passed.

Fix: prune the queue to `()` and rewrite the comment, which still described the
2026-09-20 sweep as if the entries were current. The tool now exits 0 with
`OK    74 test file(s) tracked or queued; none pins a bug unmarked`. Empty is
the healthy state for a ratchet; new untracked test files are still caught.

### A third failure that was not a failure

`test_launcher_watchers_contract.py::
test_launcher_launches_every_watcher_except_destructive_gm_watch` failed
mid-run on `New-WatcherPaneScript -Label "empty"`. Another session landed
`6487022` (`mcpw-qxj.4` + `mcpw-qxj.8`, heimdall as the 6th watcher) while the
suite was running, which replaced the reserved-empty cell with heimdall and
updated the same assertion. By the time I looked, the test passed. No change
was needed from me.
