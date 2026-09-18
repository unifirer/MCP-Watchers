# 2026-09-19 — Pester sweep: 35 suites, 5 red, none of them a launcher defect

Swept every `tests/*.tests.ps1` (35 files) with `temp/sweep_pester.py`. Five
came back red. All five are test-side defects or environment mismatches; none
is a launcher regression. Four are fixed here, one is a runner artifact that is
now documented.

## Pester versions on this box (affects how you read any sweep)

```
Pester 6.1.0  C:\Users\yuni\Documents\WindowsPowerShell\Modules\Pester\6.1.0
Pester 6.0.0  C:\Users\yuni\Documents\WindowsPowerShell\Modules\Pester\6.0.0
Pester 3.4.0  C:\Program Files\WindowsPowerShell\Modules\Pester\3.4.0
```

Most suites are written in the legacy Pester 3 idiom (`Should Be`,
`Should BeNullOrEmpty`) and pin 3.4.0 themselves.
`tests/t8_isolation.tests.ps1` is written for Pester 6: it uses `Should -Be`
and its header documents a Pester 6 two-phase-discovery workaround. Pester 6
also dropped `-EnableExit` (use `-PassThru` / `-CI`).

**A sweep that pins 3.4.0 reports t8_isolation as failing on
`'-Be' is not a valid Should operator`. That is the runner's fault, not the
suite's.** Run it under 6.1.0.

## 1. `launch_watcher_for_grepai.tests.ps1` — thrown at file scope

`throw "launcher not found: ...\###2.launch_watcher_for_grepai.ps1"`. Same
checkout gap as the pytest-side skip: the file is absent here and absent from
git history. Now prints SKIP and exits 0, matching
`tests/test_launch_watcher_for_grepai_ps1.py`, which already skipped on this.

## 2. `launcher_repowise_wiring.tests.ps1` — 2 failures, stale target file

`Show-ChangedFiles -Label` and `Show-ChangedFiles -Label .*-Line ` were grepped
from the launcher only. The tailer TEMPLATE moved to
`Modules/watcher_pane_scripts.ps1` (it is there at lines 588 and 724), so both
assertions were searching a file that no longer holds the code. The suite now
searches launcher + module, the same dual-location rule `launcher_tests.ps1`
already uses in `Get-TailerTemplateBody`. The "old graphify-rs-only branch is
gone" assertion was strengthened the same way: it could never have failed while
it only read the launcher.

## 3. `launcher_workspace_root.tests.ps1` — stale count (3/1, actual 6/0)

Expected 3 × `-RepoRoot $watchersWorkspaceRoot` and 1 × `-RepoRoot $scriptDir`;
actual is 6 and 0. mcpw-ybs.1 originally sent only the three non-grepai tailers
to the workspace and pinned grepai's to `$scriptDir`. Grepai's heal then moved
to its index dir (commit `020c191`, "fix(grepai-pane): heal at index dir, not
workspace root"), after which grepai's pane tailer takes the workspace root too.

The invariant the test protects — panes open at the workspace, never at the
launcher folder — is intact and now stronger. Changed to count
`New-WatcherPaneScript` lines carrying `-RepoRoot $watchersWorkspaceRoot`
(exactly 4) and assert no `-RepoRoot $scriptDir` remains (0). Counting every
occurrence was what made it brittle: two unrelated uses in the worktree-validate
path inflate the number.

## 4. `launcher_gm_semantic_threadjob.tests.ps1` — lock silently asserted nothing

`Get-ScriptBlockArg` only recognised an inline `-ScriptBlock { ... }`. Since
VAD-k9fix (2026-09-07) the gm-semantic scriptblock is defined once as
`$gmSemScriptBlock` and reused for `Start-ThreadJob` and the `Start-Job`
fallback, so `-ScriptBlock` binds a *variable*. The helper returned `$null` and
the whole "param() must be FIRST" lock failed on `$sb | Should Not Be $null`
instead of on the property it exists to protect. It now resolves the variable
back through its assignment in the AST.

One wrinkle worth recording: `$x = { ... }` does **not** parse with a
`ScriptBlockExpressionAst` on the right. It parses as a
`CommandExpressionAst` wrapping one (checked against the real launcher:
`RightType=CommandExpressionAst`), so the lookup has to unwrap before
type-checking. The first attempt at this fix still failed for exactly that
reason.

Worth stating plainly: the invariant was never broken — `param($State, $BuildSrc,
$ProbeSrc, $BuildDir, $RunLog)` is still the first statement at launcher line
2752. This fix restores the guard; it does not repair a regression.

## 5. `t8_isolation.tests.ps1` — malformed regex (real bug, fixed)

Under Pester 6.1.0 it fails with:

```
ArgumentException: parsing "vad-watchers\[0-9a-f]{8}\panes\tail_"
                   - Malformed \p{X} character escape.
```

The header's `[char]92` trick keeps `\p` out of the *source*, but the runtime
pattern still contains a single backslash before `panes`, which .NET reads as
the start of a Unicode property escape. Now builds the matcher with a doubled
backslash (`$BSre`).

Note this suite is a deliberate RED/GREEN gate ("RED: still shared"), but its
isolation assertions at lines 67-68 now pass — the only thing left failing was
the malformed live matcher, and with that fixed the suite is GREEN.

## Verification (2026-09-19 02:35 NZST)

- `launch_watcher_for_grepai.tests.ps1` → SKIP, exit 0 (was: throw, exit 1).
- `launcher_workspace_root.tests.ps1` → 6 passed, 0 failed (was 5 passed, 1 failed).
- `launcher_repowise_wiring.tests.ps1` → 4 passed, 0 failed (was 2 passed, 2 failed).
- `launcher_gm_semantic_threadjob.tests.ps1` → 5 passed, 0 failed (was 4/1).
- `t8_isolation.tests.ps1` under Pester 6.1.0 → 1 passed, 0 failed
  (was: ArgumentException on the malformed pattern).

All five red suites are now green or explicitly skipped. Re-sweeping under a
3.4.0 pin will still report t8_isolation red on `'-Be'`; see the version note
above.

## Correction: the first sweep under-reported, because it trusted exit codes

The first sweep (results above) used `-EnableExit` and trusted `rc`. That is
unsound for this repo: most suites end with a self-invoking
`Invoke-Pester -Path $MyInvocation.MyCommand.Path` guarded by an env var, so the
OUTER run reports "Passed: 0 Failed: 0" and exits 0 while the INNER run's
failures never reach the exit code. `launcher_proxy_wiring.tests.ps1` was green
on `rc=0` while actually failing.

Re-swept counting `[-]` lines instead (and de-duplicating, since the
self-invoking pattern runs every test twice). That surfaced a different set:

| Suite | Failure | Disposition |
|---|---|---|
| `launcher_proxy_wiring` | `proxy gate runs before gm semantic warm-up` | FIXED — stale anchor |
| `launcher_gm_semantic_build_concurrency` | named mutex serializes two concurrent processes | flaky under load; passes alone |
| `launcher_watcher_teardown` | kills a wrapper host found only by the sweep | filed as `mcpw-lqy` |
| `launcher_watcher_teardown_sweep` | kills a live pane-tailer | filed as `mcpw-lqy` |
| `t8_isolation` | `'-Be' is not a valid Should operator` | runner artifact, Pester 3 pin |

**`launcher_proxy_wiring` (fixed).** It anchored on
`Invoke-GmSemanticBuild -Mode "full"`, but that parameter no longer exists: the
"full" warm-up was replaced by the incremental daemon, which calls
`Invoke-GmSemanticBuild -BuildDir ...` (launcher line 2795). `$warmIdx` was -1,
so the test failed on a string that is gone rather than on the ordering it
locks. Re-anchored on `-BuildDir`.

**The two teardown suites (filed, not fixed).** Both call `Stop-AllWatchers`
with no `RootPids` and no teardown-state.json. `Stop-AllWatchers` is now
PID-scoped — `$ourPids = Get-DescendantPidSet -RootPids $RootPids`, and both the
wrapper-host tree-kill (step 1b) and the pattern sweep (step 2) are gated on
`$ourPids.Count -gt 0`. With no scope, nothing is killed. Probed directly:
`Get-DescendantPidSet -RootPids @()` returns 0 and the state file does not
exist. `launcher_watcher_teardown_sweep.tests.ps1:44` still documents the old
contract ("Empty RootPids -> the tree-kill loop does nothing; only the pattern
sweep can kill this process"). The scoping is deliberate — it is what stops one
launcher killing another's watchers — so the tests are stale, not the module.
Any repair changes what a safety-critical kill path asserts, and the obvious
rewrite would make the process die in step 1 rather than the sweep, i.e. green
but weaker. Needs a decision: bead `mcpw-lqy`.

## Final state

35 suites: 33 green or explicitly skipped, 2 red on `mcpw-lqy`, 1
(`t8_isolation`) red only under a Pester 3 pin.
