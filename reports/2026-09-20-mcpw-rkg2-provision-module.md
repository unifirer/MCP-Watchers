# Provision module — `Modules/watcher_mcp_provision.ps1`

- **Bead:** mcpw-rkg.2 (P1)
- **Epic:** mcpw-rkg — "Launcher must provision all six MCPs in ANY repo it is launched from."
- **Prerequisite consumed:** `Modules/watcher_mcp_detect.ps1` (mcpw-rkg.1) — read, not rewritten.
- **Date:** 2026-09-20
- **Wave:** `mcpw-sweep-20260920-1305`

---

## 1. What was built

`Modules/watcher_mcp_provision.ps1` is the WRITE side of the pair whose READ side
is the detection module: detection answers *"is this repo already initialized?"*,
provision answers *"then make it so, or say why it cannot be."*

### Surface

| Function | Purpose |
| --- | --- |
| `Invoke-McpProvisionForRepo -Path <root> [-StateDir] [-ToolPaths] [-Only] [-Force] [-TimeoutMs] [-FirstScanTimeoutMs]` | Runs the six steps in plan order; returns the summary object the launcher logs. Never throws. |
| `Initialize-MemtraceForRepo -Path <root> [...]` | `memtrace index <root> --allow-non-git` |
| `Initialize-GrepaiForRepo -Path <root> [...]` | config-if-absent, then the bounded first scan |
| `Initialize-GrapheniumForRepo -Path <root> [...]` | `gm init <root>` |
| `Initialize-GraphifyRsForRepo -Path <root> [...]` | `graphify-rs build --path . --update --no-llm` (OPTIONAL) |
| `Initialize-RepowiseForRepo -Path <root> [...]` | `repowise agents add <root> --target claude-code --scope project --yes` |
| `Initialize-GraftForRepo -Path <root> [...]` | `graft build <root>` ($0 tier, never `--deep`) |
| `Get-McpProvisionPlan` | the six steps in execution order, with `Phase` and `Optional` |
| `Get-McpProvisionArgv -Mcp -Path [-Step]` | the one place every command line lives (so flags are assertable) |
| `Test-McpProvisionStamp` / `Set-McpProvisionStamp` | the idempotence stamp |
| `Get-McpProvisionStateDir` | stamp location resolution |
| `Invoke-McpProvisionCommand` | the bounded, stdin-closed, shim-aware process runner |

Each `Initialize-<Mcp>ForRepo` is callable alone with just `-Path`; the tests use
that. Every one returns a single row and never throws.

### Summary object

```
.Path .StateDir .Started .Finished .Total .Done .Stamped .Skipped
.Results[] -> .Mcp .Status .Reason .Tool .Stamp .Optional .Phase
```

`.Status` has exactly three values, and there is deliberately **no `failed`**:

- `done` — the step ran and exited 0
- `stamped` — nothing to do (already initialized per detection, or a stamp exists)
- `skipped` — did not run: binary absent, optional input missing, launch failure,
  timeout, non-zero exit, or the initializer threw. The reason says which.

### Ordering (cheap-first — the mcpw-rkg.3 contract)

| # | MCP | Phase | Optional |
| --- | --- | --- | --- |
| 1 | graphenium | config | no |
| 2 | repowise | config | no |
| 3 | graphify-rs | build | **yes** |
| 4 | graft | build | no |
| 5 | memtrace | index | no |
| 6 | grepai | index | no |

`Get-McpProvisionPlan` is the single source of this order; the aggregate iterates
it, and a test asserts the phase rank is non-decreasing (no expensive index step
can run before a cheap config step).

---

## 2. Idempotence — how it is stamped

**Stamp file:** `<repo>/.MCPWDIRKEEP/state.json` (one key per MCP).

```json
{
  "graft": { "At": "2026-09-20T...", "Tool": "...\\graft.cmd", "Detail": "build completed" }
}
```

Resolution order for the state dir: explicit `-StateDir` → `MCPW_BOOTSTRAP_STATE_DIR`
→ `<repo>/.MCPWDIRKEEP`. Rooting it at `-Path` means the stamp travels with
the repository it describes and two repos on one machine can never share one
(a test asserts that repo B is untouched by repo A's stamp).

**Semantics.** Every initializer's prologue checks the stamp FIRST — before
resolving a binary and before running any detection probe — so the second run
costs one file read and spawns nothing. A successful run (or a step that
detection already considers initialized) writes the stamp; a `skipped` step
writes nothing, so it is retried next launch. `-Force` ignores the stamp.

The stamp is written temp-then-move so a crash mid-write cannot leave a
half-parsed file. A truncated/corrupt stamp reads as "not initialized" (one safe
extra run) and never throws — tested.

**Asserted on the stamp, not on timing.** The idempotence test runs the aggregate
twice against fake tools that append every argv to a log, then asserts the stamp
file exists with all six keys, that run 2 reports `Stamped = 6 / Done = 0`, and
that the call log is **byte-identical in length** to run 1 — i.e. not one tool
was spawned again. `-Force` is then asserted to grow the log.

---

## 3. Non-interactive — three layers, no prompt can block

1. **stdin is redirected and closed immediately** for every child. This is the
   universal guarantee: a tool that decides to prompt reads EOF and exits instead
   of hanging a launcher that has no window to type into. A test proves it with a
   `.cmd` that does `set /p` — it must return, not hit the timeout.
2. **The documented suppress flag per tool**, in `Get-McpProvisionArgv`:
   `grepai init --yes`, `grepai watch --no-ui`, `grepai status --no-ui`,
   `repowise agents add --yes`, `graphify-rs build --no-llm`.
3. **`CreateNoWindow` + a hard timeout + kill on timeout.** A test runs a 60-second
   child with a 2.5 s timeout and asserts `TimedOut = $true` and elapsed < 30 s.

A test also asserts the module's *code* (comments stripped) contains none of
`Read-Host`, `PromptForChoice`, `-Confirm`, `Get-Credential`.

---

## 4. Degradation — what turns into a `skipped` row

| Condition | Result |
| --- | --- |
| binary not on PATH / pinned path missing | `skipped`, reason `binary not found: <name|path>` |
| repo path absent, or is a file | `skipped`, reason `path not found: <path>` |
| optional input missing (graphify-rs.toml) | `skipped`, reason `optional: ...` |
| child could not start | `skipped`, reason `... could not be launched: <err>` |
| child overran the timeout | `skipped`, reason `... timed out after <n>ms` |
| child exited non-zero | `skipped`, reason `... exited <code>: <first stderr/stdout line>` |
| initializer threw | caught in the aggregate → `skipped`, reason `initializer threw: ...` |
| detection probe unavailable/threw | treated as not-initialized (safe direction) |

The aggregate wraps every step in `try/catch` and substitutes a row if an
initializer returns nothing, so `Invoke-McpProvisionForRepo` cannot abort the
launcher. A test runs four hostile inputs (empty repo, missing path, a *file* as
`-Path`, a *directory* as a tool path) and asserts six rows come back each time.
A second test makes `graft` exit 7 and asserts `graft = skipped` while the other
five are `done`, and that `graft` wrote no stamp while `memtrace` did.

---

## 5. Measured facts encoded (not re-derived)

- **memtrace** — no `build` verb; `memtrace index [PATH] --allow-non-git` is what
  runs. `memtrace start` is never invoked (from a member cwd it fails permanently:
  1-member scope vs 8 stored) and `memtrace mcp` is never invoked (kill-on-job-close
  can take the shared daemon down for all 8 workspaces). No `--workspace` is
  passed: the union manifest is a machine-global path, and indexing by `PATH` is
  the repo-agnostic form. A test asserts `start`/`mcp` are absent from the argv.
- **grepai** — no `index` verb (confirmed via `grepai --help`). `grepai init --yes`
  runs **only when `.grepai/config.yaml` is absent**, because the config measured
  here is already correct and `init` would replace it with defaults. The first
  scan is finished by a bounded foreground `grepai watch --no-ui`; if it is still
  running at the timeout it is stopped and `grepai status --no-ui` is asked once
  whether `Files indexed > 0`. Daemon survivability across the supervisor's
  idle-TTL reap is **not** attempted — that is mcpw-rkg.4 — and nothing here keeps
  a process alive after the step returns.
- **gm / graphenium** — no `.graphenium/` exists; `gm init` defaults to `"."`, so
  the root is always passed explicitly. `gm init` writes the config only, so the
  row's reason says the graph is `gm run`, owned by the launcher's watcher.
- **graphify-rs** — `graphify-rs.toml` is missing (mcpw-01g, P3) ⇒ the step skips
  as OPTIONAL rather than inventing a config. Rebuild argv is taken from the
  launcher's own `Get-GraphifyRebuildArgs` when that module is loaded, so the two
  cannot drift (`--update --no-llm`).
- **repowise** — the store exists but the Claude Code MCP entry is not registered,
  and that registration is what detection keys on. The real binary is invoked by
  absolute path `%APPDATA%\uv\tools\repowise\Scripts\repowise.exe` (the PATH
  `repowise` is a declick shim with no `agents` verb), and a missing pin is a
  `skipped` row — never a PATH fallback. `repowise init` is deliberately NOT used:
  it regenerates the wiki with a model and can prompt for a key; `agents add
  --target claude-code --scope project --yes` is the targeted, cheap,
  non-interactive write.
- **graft** — `graft/manifest.json` can be missing entirely; plain `graft build
  <dir>` is the $0 no-key tier. `--deep` is never passed (needs an LLM key), and a
  test asserts it is absent from the argv.

No LLM model configuration was touched anywhere.

---

## 6. Test results

```
suite   : tests/launcher_mcp_provision.tests.ps1
pester  : 6.1.0  [wrapped (auto-detected)]
[+] tests/launcher_mcp_provision.tests.ps1 10.51s (13 tests)
Tests Passed: 13, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
VERDICT : passed=13 failed=0
```

Verified by counting `[-]` lines rather than trusting the exit code:
`[-] = 0`, unique `[+] = 1`, summary = 13 → **13 of 13 tests passed**.

Run with:

```
python dev_tools/run_pester_suite.py tests/launcher_mcp_provision.tests.ps1
```

Coverage: module surface; plan order + non-decreasing phase cost; the exact
non-interactive argv per MCP (and the forbidden flags); comment-stripped
prompt-cmdlet scan; every initializer skipped-not-failed with no binary; six-row
summary for four hostile inputs; **idempotence via the stamp** (twice-run, call
log unchanged, `-Force` re-runs); one-tool-exits-7 degradation; graphify-rs
optional; per-repo stamp isolation and default state dir; repo-agnostic source
scan; stamp read/write/corruption tolerance; stdin closed; timeout kill.

The suite is hermetic: synthetic layouts and fake `.cmd` tools in a temp dir, all
six injected through `-ToolPaths`. No real build, index, scan or `init` was run
against this repo or any other.

### Two real findings from the implementation

1. **`[pscustomobject]@{ ... = @($genericList) }` throws.** Measured on Windows
   PowerShell 5.1 *and* pwsh 7.6.6: casting a hashtable literal to
   `[pscustomobject]` when a value is `@($someGenericList)` raises
   `System.ArgumentException: Argument types do not match`. `$rows.ToArray()`
   returns the identical array without the bug. Commented in the module so nobody
   re-introduces it.
2. **The repowise pin makes provision non-hermetic on a box that has repowise.**
   Emptying `PATH` does *not* hide it — that is the point of the pin — so a test
   that wants "no tools at all" must override the pin too. This is correct
   production behaviour, but it is worth knowing before writing a clean-room test.

---

## 7. Left for other beads (not done here)

- **mcpw-rkg.3** (launcher wiring) owns calling
  `Invoke-McpProvisionForRepo -Path $watchersWorkspaceRoot` before any watcher
  spawns, and logging the summary. This module is not wired into the launcher yet.
- **mcpw-rkg.4** owns grepai daemon survivability across the supervisor's idle-TTL
  reap. This module deliberately does not keep a process alive after its step
  returns.
- **Housekeeping:** `<repo>/.MCPWDIRKEEP/` is not in `.gitignore`. Adding it is
  a one-line follow-up for whoever owns that file — `.gitignore` was outside this
  bead's claim. The directory is written at most once per repo (provision runs
  before any watcher spawns, and every later run is stamp-short-circuited), so the
  watcher-churn risk is nil.

---

## 8. Changed paths

```
Modules/watcher_mcp_provision.ps1                    (new)
tests/launcher_mcp_provision.tests.ps1               (new)
reports/2026-09-20-mcpw-rkg2-provision-module.md     (new, this file)
```

Nothing else was modified. `###1.watchers_...ps1`, the other `Modules/*.ps1`,
`Modules/watcher_mcp_detect.ps1`, `README.md` are untouched. (`AGENTS.md` was
already dirty before this bead started and was not touched by it.) Paths claimed
with `python dev_tools/claim_paths.py claim --owner mcpw-rkg.2 --wave
20260920-1305`. Nothing was committed, staged or checked out — the edits are left
dirty for the process that owns the git index.
