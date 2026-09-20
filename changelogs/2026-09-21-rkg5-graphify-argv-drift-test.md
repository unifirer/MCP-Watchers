# `mcpw-rkg.5` — closing the last provision-coverage gap (commit `eeb099f`)

Audit of the bead's five required coverage items against what already existed:

| # | Required | Where it is covered |
|---|----------|---------------------|
| 1 | Six detection probes TRUE on a synthetic layout, FALSE on an empty dir | `tests/launcher_mcp_detect.tests.ps1` — `reports FALSE with a diagnostic reason on an empty directory`, `reports TRUE on a synthetic initialized layout for every MCP`, plus per-MCP FALSE cases |
| 2 | Idempotence, asserted on the stamp not on timing | `is idempotent: the second run re-runs no build and reports the stamp`, plus the per-repo stamp and corrupt-stamp tests |
| 3 | Missing-binary degradation: warn, keep going, do not throw | `skips (never fails) every initializer when its binary is absent`, `degrades: a tool that exits non-zero is skipped while the other five run` |
| 4 | `memtrace index` carries `--allow-non-git` | already asserted in the command-line test (`'memtrace' = @('index', '--allow-non-git')`) |
| 5 | graphify-rs argv comes from `Get-GraphifyRebuildArgs`, not a hardcoded string | **was missing — added here** |

## Why item 5 needed real work

The existing command-line test asserted only that the graphify-rs argv
*contains* `build` and `--no-llm`. Both the `Get-GraphifyRebuildArgs` path and
the module's hardcoded fallback satisfy that, so the test could not tell them
apart — a future drift back to a hand-synced local copy (exactly the `mcpw-0zj`
failure the bead exists to prevent) would have passed.

Two tests now cover it:

1. **The function is actually called.** `Get-GraphifyRebuildArgs` is stubbed
   *inside* the `It` block — file scope is invisible inside an `It` under
   Pester 6 on this box — with an argv that is deliberately not a subset of the
   fallback (`rebuild --from launcher --no-llm`), and the exact argv is
   asserted.
2. **The fallback is still the documented contract.** With no function present,
   the argv must carry `build`, `--path`, `--update`, `--no-llm` — pinned
   needle-by-needle rather than as an exact literal, so adding a flag on the
   launcher side does not break it. It also asserts the function really is
   absent, so the test cannot pass by accidentally taking the other branch.

Discriminating check run by hand: with the stub the module returns
`rebuild --from launcher --no-llm`; without it, `build --path . --update --no-llm`.

## Verification

```
pester  : 6.1.0  [wrapped (auto-detected)]
Tests Passed: 18, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
VERDICT : passed=18 failed=0   (rc=0, ignored)     0 [-] markers
```

18 = the 16 existing blocks plus the 2 added here.
