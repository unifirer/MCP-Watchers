# Codegraph Watch Implementation Plan

> **SUPERSEDED IN PART 2026-09-20 (mcpw-0sp).** The "no 5th pane / 2x2 grid stays
> intact" decision below was reversed: codegraph now owns the 5th cell of a **3x2**
> grid, and a 6th cell is reserved empty. Everything else in this plan (headless
> detached child, `Start-WatcherDetached`, per-workspace keying, teardown tracking)
> still holds. Lines 18, 179, 302 and 309 below describe the OLD decision; do not
> re-apply them.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in `codegraph watch` supervision to the ###1 launcher so `.codegraph/graph.db` stays fresh without changing the 2x2 pane grid. *(Pane part superseded, see above.)*

**Architecture:** Treat `codegraph build` as the one-time prerequisite and `codegraph watch` as a headless detached child (memtrace precedent, no 5th pane). Launch via the existing `Start-WatcherDetached` raw-byte pump, keyed per-workspace, swept by the shared pattern list, tracked in `teardown-state.json` RootPids.

**Tech Stack:** PowerShell 5.1-compatible `.ps1`, `codegraph` CLI from `@optave/codegraph` (npm `-g`), Pester gate (`tests/run_launcher_tests.ps1`), pytest shims (`tests/pytest.ini`).

**Spec:** User request 2026-09-18 ("program here is missing this watch function") + upstream docs: `codegraph build [dir]` creates `.codegraph/graph.db`; `codegraph watch [dir]` debounces file changes and runs incremental `update`; queries (`stats`, `structure`, `triage`, `deps`, `path`, etc.) work without the watcher but go stale; manual `codegraph update [files]` / `codegraph build` refreshes. Caveats: `watch --db/-d` missing in older builds (#984/#987, later fixed); incremental path leaked duplicate edges per run (#979, check installed version).

## Global Constraints

- PS 5.1 compatible: no `??` operator, no `ArgumentList` property assumption (keep the `vad-kk1` join-string fallback in `Start-WatcherDetached`).
- ASCII-only comments and hyphens in all `.ps1` edits (project rule, enforced by pane tests).
- FIRST-WINS single-instance lock stays per-workspace (`watchers\<key>\###1-launcher.lock`); no new global mutex.
- 2x2 WT grid stays intact: `grepai / graphenium / graphify-rs / repowise`. Codegraph runs headless like memtrace (log under `$logsDir`, no pane).
- All process sweeps go through `Modules/watcher_patterns.ps1` (single source of truth); launcher and `Modules/watcher_teardown.ps1` only dot-source it.
- Persisted live state shape unchanged: `teardown-state.json` `{ RootPids[], MemtraceStatePath, RepoRoot, WtWindowName, GrepaiPid }` under `$env:LOCALAPPDATA\watchers\<key>\`.
- `Start-WatcherDetached` spawns via `System.Diagnostics.Process` + `[StreamByteCopy]::StartPumps` raw-byte copy (never `Start-Process -RedirectStandardOutput`, which mojibakes UTF-8).
- Tests: Pester gate is canonical (`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_launcher_tests.ps1`, exit 0). Python shims run from `tests\` via `python -m pytest -c pytest.ini <file> -q`. Never start a real service to make a test pass; missing-binary paths must degrade to warn-and-continue.
- Flat branch names only on J: (e.g. `codegraph-watch-20260918`), never `a/b` (volume silently discards slash branches, mcpw-sr4).

---

## File Map

- Modify: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1` lines 1685-1774 (`Start-WatcherDetached`: add optional `-WorkingDirectory`), lines ~2567-2600 (repowise launch block: insert codegraph block after it), lines ~4335+ (teardown-state persist: no shape change, codegraph PID already covered via `$script:childProcs`/`$global:WatcherChildren`).
- Modify: `Modules/watcher_patterns.ps1` lines 16-32 (add one codegraph sweep entry).
- Modify: `Modules/watcher_pane_scripts.ps1` line ~472 comment only (add `.codegraph` to the excluded-dot-dir comment if touched; behavior already excludes dot-dirs via `-like '.?*'`).
- Modify: `tests/test_launcher_watchers_contract.py` lines 55-79 (extend contract test with codegraph asserts).
- Modify: `tests/watcher_patterns.tests.ps1` (add codegraph sweep-case; create only if missing - check first, reuse existing table test).
- Modify: `README.md` lines 79-86 (add `codegraph` to prerequisites + one-line watch note).

---

### Task 1: Codegraph prerequisite + version guard (build once, warn on buggy watch)

**Files:**
- Modify: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1:2030-2100` (insert `Test-CodegraphReady` function next to `Test-LlmProxyReady`, before first watcher launch)
- Test: `tests/test_launcher_watchers_contract.py` (extend, see Task 4 for the actual asserts; this task's failing test is a standalone probe file deleted after)

**Interfaces:**
- Consumes: `$watchersWorkspaceRoot` (string, repo root), `$logsDir` (string, per-workspace log dir)
- Produces: `Test-CodegraphReady` (no args, returns `$true`/`$false`; writes one `Write-Host`/`Write-Warning` line, no throws)

- [x] **Step 1: Write the failing test**

Create `tests/test_codegraph_ready_probe.py` (throwaway, deleted in Step 5):

```python
import re
from pathlib import Path
LAUNCHER = Path(__file__).parent.parent / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
def test_codegraph_ready_defined():
    src = LAUNCHER.read_text(encoding="utf-8")
    assert "function Test-CodegraphReady" in src
    assert "codegraph" in src and "graph.db" in src
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd tests; python -m pytest -c pytest.ini test_codegraph_ready_probe.py -q`
Expected: FAIL with `assert "function Test-CodegraphReady" in src`

- [x] **Step 3: Write minimal implementation**

Insert after the `Test-LlmProxyReady` function (ends ~line 1802), PS 5.1-safe, ASCII-only:

```powershell
function Test-CodegraphReady {
    # Codegraph prerequisite probe (no throws; warn-and-continue on miss).
    # `codegraph build` creates .codegraph/graph.db once; `codegraph watch`
    # only keeps it fresh. Queries work without the watcher but go stale.
    $cg = Get-Command 'codegraph.exe' -ErrorAction SilentlyContinue
    if (-not $cg) { $cg = Get-Command 'codegraph' -ErrorAction SilentlyContinue }
    if (-not $cg) {
        Write-Warning "codegraph not found on PATH. Skipping codegraph watch (run 'npm install -g @optave/codegraph' and 'codegraph build' to enable)."
        return $false
    }
    $db = Join-Path $watchersWorkspaceRoot '.codegraph\graph.db'
    if (-not (Test-Path -LiteralPath $db)) {
        Write-Host "codegraph graph.db missing - running one-time 'codegraph build'..."
        try {
            $bl = Join-Path $logsDir 'codegraph-build.log'
            $bp = Start-Process -FilePath $cg.Source -ArgumentList @('build', '.') -WorkingDirectory $watchersWorkspaceRoot -WindowStyle Hidden -RedirectStandardOutput $bl -RedirectStandardError "$bl.err" -PassThru
            if ($bp) { $bp.WaitForExit(120000) | Out-Null }
        } catch {
            Write-Warning ("codegraph build failed: " + $_.Exception.Message + ". Continuing without codegraph watch.")
            return $false
        }
        if (-not (Test-Path -LiteralPath $db)) {
            Write-Warning "codegraph build did not produce .codegraph/graph.db. Continuing without codegraph watch."
            return $false
        }
    }
    # Known-buggy range note (#979 duplicate edges, #984/#987 missing watch --db).
    # Non-blocking: warn once so long sessions know to prefer periodic `build`.
    try {
        $v = & $cg.Source --version 2>$null | Out-String
        Write-Host ("codegraph ready (" + $v.Trim() + "). Watch is opt-in freshness only.")
    } catch { Write-Host "codegraph ready. Watch is opt-in freshness only." }
    return $true
}
```

Notes: `Get-Command 'codegraph.exe'` first (mirrors the `gm.exe` alias lesson in `Start-WatcherDetached`); `build` runs once with a 120 s cap; never throws.

- [x] **Step 4: Run test to verify it passes**

Run: `cd tests; python -m pytest -c pytest.ini test_codegraph_ready_probe.py -q`
Expected: PASS (1 passed)

- [x] **Step 5: Commit**

```bash
rm tests/test_codegraph_ready_probe.py
git add "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
git commit -m "feat: add Test-CodegraphReady build prerequisite probe" -m "One-time codegraph build if .codegraph/graph.db missing; warn-and-continue when binary absent."
```

---

### Task 2: Launch codegraph watch headless via Start-WatcherDetached

**Files:**
- Modify: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1:1685-1774` (add optional `[string]$WorkingDirectory = ""` param; use it for `$psi.WorkingDirectory`, default `$scriptDir`)
- Modify: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1:2567-2600` (insert codegraph launch block immediately after the `$script:repowiseProc = ...` line, before the repowise-reindex block)
- Test: `tests/test_launcher_watchers_contract.py:55-79` (asserts added in Task 4; this task verifies with a probe)

**Interfaces:**
- Consumes: `Test-CodegraphReady` (Task 1), `Start-WatcherDetached -ExeName -Label -ArgsList -LogFile [-ExePath] [-WorkingDirectory]`, `$codegraphLog` (new log path under `$logsDir`), `$codegraphExe` (resolved exe path or `""`)
- Produces: `$script:codegraphProc` (Process or `$null` when skipped); PID auto-enters `$script:childProcs` + `$global:WatcherChildren` via `Start-WatcherDetached` (teardown-state RootPids covers it, no shape change)

- [x] **Step 1: Write the failing test**

Create `tests/test_codegraph_watch_probe.py` (throwaway):

```python
from pathlib import Path
LAUNCHER = Path(__file__).parent.parent / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
def test_codegraph_watch_launched():
    src = LAUNCHER.read_text(encoding="utf-8")
    assert 'Start-WatcherDetached "codegraph"' in src
    assert '"watch", "."' in src
    assert "$script:codegraphProc" in src
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd tests; python -m pytest -c pytest.ini test_codegraph_watch_probe.py -q`
Expected: FAIL with `Start-WatcherDetached "codegraph"` missing

- [x] **Step 3: Write minimal implementation**

3a. Extend `Start-WatcherDetached` param block (only change: add one optional param, use it once):

```powershell
    param(
        [string]$ExeName,
        [string]$Label,
        [string[]]$ArgsList,
        [string]$LogFile,
        [string]$ExePath = "",
        [string]$WorkingDirectory = ""
    )
```

and replace the single line `$psi.WorkingDirectory = $scriptDir` with:

```powershell
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory } else { $psi.WorkingDirectory = $scriptDir }
```

3b. Insert after `$script:repowiseProc = Start-WatcherDetached ...` line:

```powershell
# -- codegraph: opt-in freshness watcher (headless, no 5th pane; 2x2 grid intact) --
# `codegraph build` (see Test-CodegraphReady) is the only prerequisite for queries;
# `codegraph watch` just debounces file changes into incremental `update` so the
# graph does not go stale during long sessions. Without it queries still work
# from the last build/update. Memtrace precedent: headless child, log under
# $logsDir, PID tracked for teardown, no WT pane.
$codegraphLog = Join-Path $logsDir 'codegraph.log'
$codegraphExe = ""
try {
    $cgCmd = Get-Command 'codegraph.exe' -ErrorAction SilentlyContinue
    if (-not $cgCmd) { $cgCmd = Get-Command 'codegraph' -ErrorAction SilentlyContinue }
    if ($cgCmd -and $cgCmd.Source) { $codegraphExe = $cgCmd.Source }
} catch { $codegraphExe = "" }
$script:codegraphProc = $null
if (Test-CodegraphReady) {
    # Pass "." (watch the workspace root via WorkingDirectory); do NOT pass
    # --db here: older builds lack watch --db/-d (#984/#987). Running with
    # WorkingDirectory = workspace root makes the default .codegraph/graph.db
    # resolve correctly on every version.
    $script:codegraphProc = Start-WatcherDetached "codegraph" "codegraph" @("watch", ".") $codegraphLog -ExePath $codegraphExe -WorkingDirectory $watchersWorkspaceRoot
    if (-not $script:codegraphProc) { Write-Warning "codegraph watch did not start. Queries still work; run 'codegraph build' manually for fresh data." }
} else {
    Write-Host "codegraph watch skipped (see warning above). Queries still work from the last build."
}
```

Do NOT add `--debounce`, `--db`, or `--index-only`: codegraph has no such flags (those are repowise). Do NOT touch the WT grid section.

- [x] **Step 4: Run test to verify it passes**

Run: `cd tests; python -m pytest -c pytest.ini test_codegraph_watch_probe.py -q`
Expected: PASS (1 passed). Also syntax-check: `pwsh -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1',[ref]$null,[ref]$null)"` exits 0.

- [x] **Step 5: Commit**

```bash
rm tests/test_codegraph_watch_probe.py
git add "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
git commit -m "feat: launch codegraph watch headless via Start-WatcherDetached" -m "WorkingDirectory=workspace root avoids watch --db bug; no pane grid change; PID tracked for teardown."
```

---

### Task 3: Sweep pattern + liveness so codegraph never orphans

**Files:**
- Modify: `Modules/watcher_patterns.ps1:16-32` (add one entry to `$script:WatcherSweepPatterns`)
- Modify: `Modules/watcher_teardown.ps1` (no edit needed - it already iterates `$script:WatcherSweepPatterns`; verify by reading, do not duplicate the list)
- Test: `tests/watcher_patterns.tests.ps1` (add codegraph case to the existing table; if the file has no table, append one `It` block matching its style)

**Interfaces:**
- Consumes: `$script:WatcherSweepPatterns` (array of `@{Name; Pattern[; Persistent]}`)
- Produces: codegraph entries swept on startup (`Stop-PriorLauncherInstances`) and exit (`Stop-AllWatchers`) with zero new functions

- [x] **Step 1: Write the failing test**

Append to `tests/watcher_patterns.tests.ps1` (read the file first, match its `Describe/It` style):

```powershell
It 'sweeps codegraph watch processes' {
    $pats = $script:WatcherSweepPatterns | Where-Object { $_.Name -like 'codegraph*' }
    $pats.Count | Should -BeGreaterThan 0
    ($pats | Where-Object { $_.Pattern -eq 'watch' }).Count | Should -BeGreaterThan 0
}
```

If the harness runs via `tests/run_launcher_tests.ps1`, that is the runner (no pytest here).

- [x] **Step 2: Run test to verify it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_launcher_tests.ps1`
Expected: FAIL on `sweeps codegraph watch processes` (pattern count 0). If the full gate is slow, run the single file with `Invoke-Pester -Path tests/watcher_patterns.tests.ps1` and expect the same single failure.

- [x] **Step 3: Write minimal implementation**

In `Modules/watcher_patterns.ps1`, add one line after the `repowise.exe` entry (keep alignment, ASCII-only):

```powershell
    @{ Name = 'codegraph.exe';   Pattern = 'watch' },
```

Full context after edit:

```powershell
$script:WatcherSweepPatterns = @(
    @{ Name = 'gm.exe';          Pattern = 'watch' },
    @{ Name = 'repowise.exe';    Pattern = 'watch' },
    @{ Name = 'codegraph.exe';   Pattern = 'watch' },
    ...
```

No `Persistent = $true` (codegraph is a killable watcher, not a backend singleton). No pane-tailer liveness function: headless children need no `Test-CodegraphWatcherAlive` probe because there is no pane to self-close; the controller owns the PID via `$global:WatcherChildren`. If a reviewer asks for a pane later, add the probe then (YAGNI now).

- [x] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_launcher_tests.ps1`
Expected: PASS, exit code 0. At minimum the `watcher_patterns` suite passes and no other suite regresses.

- [x] **Step 5: Commit**

```bash
git add Modules/watcher_patterns.ps1 tests/watcher_patterns.tests.ps1
git commit -m "feat: sweep codegraph watch on startup and teardown" -m "One shared-pattern entry; teardown module needs no change."
```

---

### Task 4: Lock the contract (tests + README + full gate)

**Files:**
- Modify: `tests/test_launcher_watchers_contract.py:55-79` (extend `test_launcher_launches_every_watcher_except_destructive_gm_watch`)
- Modify: `README.md:79-86` (prerequisites list)
- Test: full gate `tests/run_launcher_tests.ps1` + `tests/test_launcher_watchers_contract.py`

**Interfaces:**
- Consumes: Tasks 1-3 outputs (`Test-CodegraphReady`, `$script:codegraphProc`, sweep entry)
- Produces: contract asserts that fail loudly if codegraph launch is dropped; README documents the opt-in model

- [x] **Step 1: Write the failing test**

In `tests/test_launcher_watchers_contract.py`, append to `test_launcher_launches_every_watcher_except_destructive_gm_watch` (these asserts FAIL on pre-Task-1-3 code, PASS now - if they already pass, the lock works; to prove red-green, `git stash` the Task 2 hunk, run, expect FAIL, `git stash pop`):

```python
    # codegraph: opt-in freshness watcher (headless, 2x2 grid intact).
    assert 'Start-WatcherDetached "codegraph"' in src, "codegraph launch missing."
    assert '"watch", "."' in src, "codegraph must watch the workspace root."
    assert "Test-CodegraphReady" in src, "codegraph build prerequisite probe missing."
    assert "graph.db" in src, "codegraph must reference .codegraph/graph.db."
    # No 5th pane: codegraph stays headless like memtrace.
    assert 'New-WatcherPaneScript -Label "codegraph"' not in src, (
        "codegraph must NOT take a WT pane (2x2 grid intact)."
    )
```

- [x] **Step 2: Run test to verify it fails on old code**

Run: `cd tests; python -m pytest -c pytest.ini test_launcher_watchers_contract.py -q`
Expected on old code: FAIL with `codegraph launch missing`. On current code: PASS. Prove the red step once via `git stash -- "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"` then run (FAIL), then `git stash pop` (PASS again).

- [x] **Step 3: Write minimal implementation**

README `## Prerequisites` edit (add `codegraph` to the PATH list + one note, nothing else):

```markdown
`memtrace`, `grepai`, `gm` (graphenium), `repowise`, `codegraph`, `litellm`, `cerememory`,
`ollama`, `node`, `python`, and Windows Terminal (`wt.exe`).
```

plus after that block:

```markdown
`codegraph watch` is opt-in freshness only: `codegraph build` creates
`.codegraph/graph.db` once and every query works without the watcher (data just
goes stale). The launcher runs `codegraph watch .` headless when `codegraph` is
on PATH; otherwise it warns and continues. If the graph looks stale, run
`codegraph build` (or `codegraph update <files>`) manually.
```

No other docs changes (YAGNI: no new guide page).

- [x] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_launcher_tests.ps1`
Expected: exit code 0 (all Pester suites pass).
Run: `cd tests; python -m pytest -c pytest.ini test_launcher_watchers_contract.py test_launcher.py -q`
Expected: PASS (all selected tests pass; unrelated skips for non-running services are by design).

- [x] **Step 5: Commit**

```bash
git add tests/test_launcher_watchers_contract.py README.md
git commit -m "test: lock codegraph watch contract and document opt-in model" -m "Asserts launch, root arg, build probe, graph.db, no 5th pane; README prerequisite note."
```

---

## Self-Review

- [x] Spec coverage: `build`-once prerequisite (Task 1) / `watch` debounced incremental freshness (Task 2) / queries work stale without watcher + manual `update`/`build` fallback (Task 2 warnings + Task 4 README) / `watch --db` bug avoided via `WorkingDirectory` (Task 2) / duplicate-edge risk surfaced as version note + periodic-`build` guidance (Task 1 + README) - every spec sentence has a task.
- [x] Placeholder scan: no TBD/TODO/appropriate-handling/similar-to phrasing; every code step has literal code, every test step has a literal command and expected string.
- [x] Type consistency: `Test-CodegraphReady` (bool, no args) / `$script:codegraphProc` (Process-or-null) / `$codegraphLog`/`$codegraphExe` (strings) / sweep entry `@{Name='codegraph.exe'; Pattern='watch'}` named identically in Tasks 2-4; `New-WatcherPaneScript -Label "codegraph"` consistently ABSENT by design.

---

## Outcome (executed 2026-09-19)

All four tasks landed, plus two commits the plan did not anticipate. The plan's
spec was written assuming a `codegraph` CLI with `build`/`watch` subcommands.
That was **not true when the plan was written** and only became true partway
through execution, so the task list above describes the intent, not the final
shape. What actually shipped:

| commit | what |
|---|---|
| `70a004b` | T1 `Test-CodegraphReady` |
| `97313cf` | T2 launch via `Start-WatcherDetached` (+ `-WorkingDirectory`) |
| `9c370cc` | T3 sweep entry |
| `a82fef3` | T4 contract asserts + README |
| `8f6ce56` | checkboxes ticked |
| `fc3e695` | shim-aware launch + watch-verb gate |
| `f403c7f` | npm-shim branch + `node.exe` sweep token |

### The part the plan got wrong

`codegraph` is not a Windows executable. Two install shapes exist and both are
shell shims, which `Start-WatcherDetached` cannot spawn directly
(`UseShellExecute = $false` needs a PE image):

- **declick adapter** - `node <...>\declick\bin\run.mjs codegraph ...`. Exposes
  35 MCP query verbs and **none** of `watch`/`build`/`update`. `codegraph watch`
  returned `unknown verb watch` and exited 2, so the verb gate refuses it.
- **npm `@optave/codegraph` 3.17.0** - `"%_prog%"  "%dp0%\node_modules\@optave\codegraph\dist\cli.js" %*`.
  This is the real CLI and does have `build`/`watch`/`stats`/`embed`.

`Resolve-CodegraphLaunch` parses both and re-expresses them as
`node.exe <entrypoint> [adapter] <args>`, the same node+entrypoint idiom the
launcher already uses for memtrace. npm-global is PATH 58 and declick's bin is
95, so npm wins on a box that has both.

Two traps, both verified live rather than assumed:

- The sweep token is the two-word `codegraph\dist\cli.js watch`. A bare
  `codegraph` token is unsafe: the codegraph MCP backend runs the same
  `cli.js` with the `mcp` verb and would be swept.
- `ArgumentList` leaves space-free arguments **unquoted**, so the command line
  really is `"...node.exe" J:\...\cli.js watch <root>` - that is why a token
  spanning the argument boundary matches. Confirmed against a live process.

The watch target is the **absolute** workspace root, not `"."` as the plan
specified: the command line then carries the root, so
`Stop-PriorLauncherInstances` can attribute a stale watcher to this workspace
before killing it.

### Verification

Full Pester sweep **252 passed / 0 failed, 0 of 37 suites failing**. Canonical
gate `run_launcher_tests.ps1 -SkipSmoke`: PASS=152 FAIL=0, exit 0. The watcher
was spawned for real and stayed alive (the declick shape died in under a
second), and the sweep matched its live command line.
