# fix-tests run: every failure is environmental (2026-09-19)

**Run:** `nf-fix-tests` workflow, isolated worktree `J:\audio\MCP-Watchers-wt-fixtests-1907`
**Branch:** `fixtests-20260919-190700`, from `main` @ `e758f6b`
**Outcome:** 0 code defects found. 0 fixes committed. All 19 baseline failures are
caused by two defects injected into this session's process environment.

---

## 1. Baseline (worktree, HEAD, unmodified)

| Harness | Total | Passed | Failed |
|---|---|---|---|
| pytest (`tests/`, `-c pytest.ini`) | 109 | 103 | **1** (+4 skipped, 1 xfail) |
| Pester sweep (`dev_tools/sweep_pester.py`) | 239 | 221 | **18** |

35 Pester suites. The pytest failure is
`test_launcher.py::test_launcher_powershell_suite_passes`.

## 2. Root cause A — case-duplicate proxy variables (7 failures)

The session process carries **four** proxy variables:

```
HTTP_PROXY=http://127.0.0.1:3180     http_proxy=http://127.0.0.1:3180
HTTPS_PROXY=http://127.0.0.1:3180    https_proxy=http://127.0.0.1:3180
```

Machine and User scope have **none** — all four are Process-only, i.e. injected.
Windows PowerShell 5.1 materialises the environment block whenever
`Start-Process` sets `UseShellExecute = false` (any use of
`-RedirectStandardOutput`), and .NET's case-insensitive dictionary then throws.

Reproduced directly (`C:\Temp\sp_repro.ps1`):

| Call | Result |
|---|---|
| A `Start-Process ... -PassThru` (no redirect) | OK |
| B same + `-RedirectStandardOutput` | **THROWS** `Item has already been added. Key in dictionary: 'https_proxy' Key being added: 'HTTPS_PROXY'` |
| C same as B, case-duplicates cleared | OK |

Even `Get-ChildItem env:` throws `An item with the same key has already been added`.

**Removing the uppercase pair fixed 7 failures** (sweep 239 tests, 221P/18F → 228P/11F):
`launcher_gm_semantic_build` (1), `launcher_pane_line_cap` (1),
`launcher_port_autheal` (3), `launcher_remediation` (1), `launcher_watcher_panes` (1).

The pytest failure is the same mechanism: `launcher_tests.ps1:1517` is the only
`Start-Process` in T18 that redirects output.

## 3. Root cause B — `PATHEXT` sandbox injection (10 failures)

| Scope | PATHEXT |
|---|---|
| Machine | `.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PY;.PYW` |
| User | *(empty)* |
| **Process** | **`.CPL`** |

With `PATHEXT=.CPL`, PowerShell cannot resolve `.exe`/`.cmd`, so every native
child either no-ops silently or raises
`Cannot run a document in the middle of a pipeline`.

Proof:

```
Process PATHEXT before : [.CPL]
git --version          -> <empty>
Process PATHEXT after  : [.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PY;.PYW]
git --version          -> git version 2.47.1.windows.2
```

This produced all 10 remaining failures, each showing that exact message:
`git_branch_guard` (3, on `C:\Users\yuni\.declick\bin\git`),
`launcher_native_operand_guard` (1), `repowise_e2e_resolve` (1),
`launcher_worktree_prune_corrupt` (5 — its fixture could not create
`wt-linked`, so `.git` writes failed with `DirectoryNotFound`).

**With both A and B corrected: 238 passed / 1 failed of 239.**

## 4. The one remaining failure — not a code defect

`launcher_worktree_prune_corrupt` →
`keeps Layer 2 (stale index.gob removal) working on a surviving worktree`.

`Invoke-GrepaiWorktreeValidate` reads `git worktree list --porcelain` and deletes
`.grepai/index.gob` when no `config.yaml` exists. Instrumented probe results:

| Context | Result |
|---|---|
| bare harness, base on `C:\Temp` | PASS |
| bare harness, base on J: | PASS |
| bare harness, J: + `GIT_CEILING_DIRECTORIES` | PASS |
| Pester 3.4.0, PowerShell tool | PASS |
| via `run_pester_suite.py` (sweeper spawn path) | **FAIL** |

In the failing context the worktree count returned by `git worktree list` drops
from 2 to 1 after `Invoke-GrepaiWorktreePrune` runs, so Layer 2 never sees the
worktree. A naked `git worktree prune` on a live dirty worktree was then tested
in that same process:

- base `C:\Users\yuni\AppData\Local\Temp\...` → **prune left it registered**
- base `C:\Temp\...` → **prune deregistered a live worktree**
- base `J:\...\temp\...` → **prune deregistered a live worktree**

Same git build (2.55.0.windows.3), same process, three paths, two different
answers. That is not deterministic behaviour a code change can fix, and the
PowerShell tool resolves a *different* git (2.47.1.windows.2), which is why the
same test passes there.

**Verdict: environmental. Do not edit the launcher or the suite.** This matches
the standing rule already recorded for `tests/declick_node24_pin.tests.ps1`:
a sandbox-only failure must be documented, not "fixed" by weakening the test.

## 5. Recommendation

- Treat `PATHEXT=.CPL` and the duplicated proxy pair as session-injected noise.
  Confirm any future sweep by checking `Machine` vs `Process` scope first.
- Verify the Layer 2 case once from a plain shell outside this harness before
  ever attributing it to the launcher.
- `dev_tools/sweep_pester.py` writes every run to the same
  `temp/pester_sweep.txt`, so a second sweep destroys the baseline it is meant to
  be diffed against. Not changed here (out of scope); worth a timestamped
  output path or an `--out` flag.
