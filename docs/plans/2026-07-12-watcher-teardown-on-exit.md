# Watcher Teardown On Exit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee every watcher (grepai, gm/graphenium, graphify-rs, repowise, memtrace) is stopped when the `###1. watchers … .ps1` controller exits — both on Ctrl+C AND on window [X] close — including in-flight grandchildren such as a graphify-rs rebuild spawned by the wrapper.

**Architecture:** Extract all teardown logic into a single dot-sourceable module `modules/watcher_teardown.ps1` that (a) tree-kills a root PID + every CIM descendant, and (b) sweeps known watcher binaries by CommandLine. The launcher replaces its inline `trap` body with a call to `Stop-AllWatchers`, and registers a `PowerShell.Exiting` engine event so a window close also triggers teardown. Tracked root PIDs are persisted to a state file so the Exiting handler (which runs in a separate runspace) can re-run the real teardown with no script-scope access. Behavioral tests spawn a real process tree and assert the grandchild dies.

**Tech Stack:** PowerShell 5.1 / 7 (Windows), Pester 3.4.0 (team harness), Python 3.12 pytest (parse-level assertions), CIM (`Win32_Process`) for process-tree walks.

## Global Constraints

- Every watcher currently killed by the trap MUST remain killed in the new active path (no feature regression): grepai (`grepai watch --stop` + process sweep), gm (`gm.exe` + `watch`), graphify-rs wrapper + its `graphify-rs.exe` rebuild child, repowise (`repowise.exe` + `watch`), memtrace daemon (by pid from `modules/.memdb/daemon-state.json`), and the 4 pane-tailer `powershell.exe` processes (`temp\panes\tail_*`).
- The teardown module must be dot-source-safe: NO top-level side effects (no launches, no writes at import time), so both the launcher and the Pester suite can `.` it.
- `trap` MUST stay (Ctrl+C path) — do NOT remove it in favor of the Exiting handler alone; the two are complementary and both call `Stop-AllWatchers`.
- Powershell 5.1 is the double-click engine (per `AGENTS.md`/existing tests); the module must parse and run under both 5.1 and 7.
- Tests live in `tests/` (AGENTS.md §4.3). Pester files use the team idiom: `Invoke-Pester -Path $MyInvocation.MyCommand.Path` guarded by an env var to prevent Pester 3.x rediscovery loops.
- `Stop-AllWatchers` must be idempotent (dead/unknown PIDs are no-ops) so double-invocation (trap + Exiting) is safe.
- The `Register-EngineEvent` Action runs in a SEPARATE runspace with no access to the launcher's script scope — the module path must be baked into the Action as a literal (use `[scriptblock]::Create()`), and the Action must re-dot-source the module before calling `Stop-AllWatchers`.

---

## Audit (current state — do not regress these)

| Feature | Current location | In new path? |
|---|---|---|
| gm kill | `Stop-WatcherOrphans` @ `###1…ps1:353-371` (called once at launch) + `$childProcs` trap @ `:443` | Replaced by `Stop-AllWatchers` tree + sweep |
| repowise kill | same | same |
| graphify wrapper + rebuild child | wrapper `@ :390-394` (added to `$childProcs`); rebuild child spawned @ `graphify-watch-wrapper.ps1:53` (NOT tracked → leaks) | Tree-kill of wrapper PID catches the child |
| grepai stop | `& grepai watch --stop` @ `:444` (swallowed on failure) | `Stop-AllWatchers` + `grepai.exe watch` sweep backup |
| memtrace daemon | pid from `daemon-state.json` @ `:448-457` | preserved |
| pane tailers | `powershell.exe` + `temp\panes\tail_` sweep @ `:461-468` | preserved in sweep |
| Ctrl+C | `trap` @ `:441-470` | preserved |
| Window [X] close | NONE — orphan leak | NEW: `PowerShell.Exiting` handler |

---

### Task 1: Failing Pester test for the teardown module (RED)

**Files:**
- Create: `tests/launcher_watcher_teardown.tests.ps1`
- Test target: `modules/watcher_teardown.ps1` (does not exist yet — this test goes RED)

**Interfaces:**
- Consumes: none yet (module is new)
- Produces: the contract `Stop-WatcherTree -Pid <int>` (kills PID + all CIM descendants, returns int killed count) and `Stop-AllWatchers` (no required args; reads state file when called with none).

- [ ] **Step 1: Write the failing test**

```powershell
# tests/launcher_watcher_teardown.tests.ps1
# Pester 3.4.0 team idiom.
$repo   = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$module = Join-Path $repo 'modules\watcher_teardown.ps1'

Describe 'watcher_teardown module' {
    It 'module exists and dot-sources with no side effects' {
        Test-Path -LiteralPath $module | Should Be $true
        # Dot-sourcing must NOT throw / launch anything.
        { . $module } | Should Not Throw
    }

    It 'Stop-WatcherTree kills a grandchild spawned by a tracked root' {
        # Spin a REAL process tree: a powershell parent that spawns a long-lived
        # cmd.exe grandchild (ping -n 60). We record the grandchild PID to a file.
        $gcFile = Join-Path $env:TEMP ('gc_' + [guid]::NewGuid().ToString('N') + '.txt')
        $parent = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-Command',
                "& { `$c = Start-Process -FilePath cmd.exe -ArgumentList '/c ping -n 60 127.0.0.1' -PassThru -WindowStyle Hidden; `$c.Id > '$gcFile'; Start-Sleep -Seconds 60 }")
        try {
            # Wait for the grandchild to appear.
            $gchildPid = $null
            for ($i = 0; $i -lt 20; $i++) {
                if (Test-Path -LiteralPath $gcFile) {
                    $gchildPid = [int](Get-Content -LiteralPath $gcFile -Raw).Trim()
                    if ($gchildPid -gt 0) { break }
                }
                Start-Sleep -Milliseconds 200
            }
            $gchildPid | Should BeGreaterThan 0
            # The real shipped function, dot-sourced from the module:
            . $module
            Stop-WatcherTree -Pid $parent.Id | Out-Null
            # Grandchild (the cmd.exe ping) must be dead now.
            $stillAlive = $null
            try { $stillAlive = Get-Process -Id $gchildPid -ErrorAction SilentlyContinue } catch {}
            $stillAlive | Should BeNullOrEmpty
        } finally {
            # Cleanup any survivor.
            try { Stop-WatcherTree -Pid $parent.Id | Out-Null } catch {}
            Remove-Item -LiteralPath $gcFile -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $env:WT_TEARDOWN_TEST_RAN) {
    $env:WT_TEARDOWN_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_teardown.tests.ps1`
Expected: FAIL — `modules/watcher_teardown.ps1` does not exist (`Test-Path` → `$false`).

---

### Task 2: Implement `modules/watcher_teardown.ps1` (GREEN)

**Files:**
- Create: `modules/watcher_teardown.ps1`
- Test: `tests/launcher_watcher_teardown.tests.ps1` (from Task 1)

**Interfaces:**
- Produces:
  - `Stop-WatcherTree -Pid <int>` → `[int]` count of processes terminated.
  - `Stop-AllWatchers [-RootPids <int[]>] [-MemtraceStatePath <string>] [-RepoRoot <string>]` → kills tracked root trees, sweeps watcher binaries by CommandLine, stops grepai, stops memtrace by pid. Idempotent.

- [ ] **Step 1: Write the module**

```powershell
# modules/watcher_teardown.ps1
# Shared watcher teardown. Dot-sourced by:
#   - ###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1
#   - tests/launcher_watcher_teardown.tests.ps1
# SAFE TO DOT-SOURCE: no top-level side effects (no launches, no writes).
#
# The launcher persists tracked root PIDs to a state file so the
# PowerShell.Exiting engine event (which runs in a separate runspace
# without the launcher's script scope) can call Stop-AllWatchers with no
# arguments and still reach the real processes.

# Kill a process tree by root PID using a CIM parent/child walk.
# Returns the number of processes terminated (for test assertions).
function Stop-WatcherTree {
    param([int]$Pid)
    $killed = 0
    try {
        $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        $byParent = @{}
        foreach ($p in $all) {
            if (-not $byParent.ContainsKey($p.ParentProcessId)) {
                $byParent[$p.ParentProcessId] = @()
            }
            $byParent[$p.ParentProcessId] += $p
        }
        $toKill = @()
        $queue = @($Pid)
        $seen = @{}
        while ($queue.Count -gt 0) {
            $cur = $queue[0]
            $queue = $queue[1..($queue.Count - 1)]
            if ($seen.ContainsKey($cur)) { continue }
            $seen[$cur] = $true
            if ($byParent.ContainsKey($cur)) {
                foreach ($child in $byParent[$cur]) {
                    $queue += $child.ProcessId
                }
            }
        }
        # $seen holds root + every descendant.
        foreach ($id in $seen.Keys) {
            $pr = $null
            try { $pr = Get-Process -Id $id -ErrorAction SilentlyContinue } catch {}
            if ($pr) {
                try { $pr.Kill(); $killed++ } catch {}
            }
        }
    } catch {}
    return $killed
}

# Main teardown. Idempotent: unknown/dead PIDs are no-ops.
function Stop-AllWatchers {
    param(
        [int[]]$RootPids = @(),
        [string]$MemtraceStatePath = '',
        [string]$RepoRoot = ''
    )
    # Backing state file written by the launcher (covers the Exiting-event
    # call path that has no script scope).
    $stateFile = Join-Path $env:LOCALAPPDATA 'watchers\teardown-state.json'
    if (($RootPids.Count -eq 0) -and (Test-Path -LiteralPath $stateFile)) {
        try {
            $st = Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($st.RootPids)           { $RootPids = @($st.RootPids) }
            if ($st.MemtraceStatePath)   { $MemtraceStatePath = $st.MemtraceStatePath }
            if ($st.RepoRoot)           { $RepoRoot = $st.RepoRoot }
        } catch {}
    }

    # 1) Tree-kill every tracked root. This catches grandchildren such as an
    #    in-flight `graphify-rs` rebuild spawned by the wrapper powershell.
    foreach ($pid in $RootPids) {
        if ($pid -and $pid -gt 0) { Stop-WatcherTree -Pid $pid | Out-Null }
    }

    # 2) Pattern sweep for any watcher binary still alive (covers processes
    #    spawned AFTER launch that we never recorded a PID for).
    $sweeps = @(
        @{ Name = 'gm.exe';         Pattern = 'watch' },
        @{ Name = 'repowise.exe';   Pattern = 'watch' },
        @{ Name = 'graphify-rs.exe'; Pattern = '' },     # rebuild child has no 'watch' token
        @{ Name = 'grepai.exe';      Pattern = 'watch' },
        @{ Name = 'powershell.exe';  Pattern = 'temp\\panes\\tail_' }
    )
    foreach ($s in $sweeps) {
        try {
            $ps = Get-CimInstance Win32_Process -Filter "Name = '$($s.Name)'" -ErrorAction SilentlyContinue
            foreach ($p in $ps) {
                if (($s.Pattern -eq '') -or ($p.CommandLine -and $p.CommandLine -match [regex]::Escape($s.Pattern))) {
                    try { Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null } catch {}
                }
            }
        } catch {}
    }

    # 3) grepai tracked stop (best-effort; sweep above is the backup).
    try { & grepai watch --stop | Out-Null } catch {}

    # 4) Memtrace daemon by recorded pid (scoped to modules/.memdb).
    try {
        $mtState = if ($MemtraceStatePath) {
            $MemtraceStatePath
        } else {
            if ($RepoRoot) { Join-Path $RepoRoot 'modules\.memdb\daemon-state.json' } else { '' }
        }
        if ($mtState -and (Test-Path -LiteralPath $mtState)) {
            $mst = Get-Content -LiteralPath $mtState -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($mst.status -eq 'healthy' -and $mst.pid) {
                $mp = $null
                try { $mp = Get-Process -Id $mst.pid -ErrorAction SilentlyContinue } catch {}
                if ($mp) { try { $mp.Kill() } catch {} }
            }
        }
    } catch {}
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_teardown.tests.ps1`
Expected: PASS (both `It` blocks). The grandchild `cmd.exe ping` is dead after `Stop-WatcherTree`.

- [ ] **Step 3: Commit**

```bash
git add modules/watcher_teardown.ps1 tests/launcher_watcher_teardown.tests.ps1
git commit -m "feat: add shared watcher teardown module (tree-kill + sweep), with grandchild-kill test"
```

---

### Task 3: Wire the launcher to the module + add window-close handler

**Files:**
- Modify: `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`
  - Add dot-source near the top (after `$scriptDir` is resolved, ~line 8).
  - Replace the `trap` body (lines 441-470) with a `Stop-AllWatchers` call.
  - Add `Register-EngineEvent PowerShell.Exiting` handler (Action re-dot-sources module + calls `Stop-AllWatchers`).
  - Persist tracked root PIDs to the state file before the controller loop.
- Test: `tests/launcher_graphify_wiring.tests.ps1` (extend with teardown-wiring assertions) AND `tests/test_launch_watcher_teardown.py` (new, Python parse-style).

**Interfaces:**
- Consumes: `Stop-AllWatchers` / `Stop-WatcherTree` from `modules/watcher_teardown.ps1` (Task 2).
- Produces: launcher now stops all watchers on both Ctrl+C and window close.

- [ ] **Step 1: Write the failing tests (static wiring)**

Append to `tests/launcher_graphify_wiring.tests.ps1` (inside the existing `Describe` or a new one):

```powershell
Describe 'watcher teardown wiring' {
    It 'launcher dot-sources the shared teardown module' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'modules\\watcher_teardown\.ps1'
    }
    It 'trap calls Stop-AllWatchers (no longer inlines the per-process kill list)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'trap\s*\{'
        $c | Should Match 'Stop-AllWatchers'
        # The old inline foreach over $childProcs must be gone from the trap.
        ($c -split "`n" | Where-Object { $_ -match 'foreach \(\$p in \$childProcs\)' }) | Should BeNullOrEmpty
    }
    It 'registers a PowerShell.Exiting handler so window [X] close also tears down' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'Register-EngineEvent'
        $c | Should Match 'PowerShell\.Exiting'
    }
    It 'persists tracked root PIDs to the teardown state file' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'teardown-state\.json'
    }
}
```

New `tests/test_launch_watcher_teardown.py` (mirrors `tests/test_launch_watcher_standalone.py` style):

```python
"""Parse-level checks that the ###1 watcher launcher wires teardown correctly.

Behavioral (process-tree) teardown is covered by the Pester suite
(tests/launcher_watcher_teardown.tests.ps1) against the real shared module.
These Python tests guard the LAUNCHER's wiring only.
"""
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent
LAUNCHER = ROOT / "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"


def test_launcher_file_exists():
    assert LAUNCHER.exists(), "The watcher launcher script must exist."


def test_launcher_dot_sources_teardown_module():
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "modules\\watcher_teardown.ps1" in content, (
        "Launcher must dot-source the shared teardown module."
    )


def test_launcher_trap_calls_stop_all_watchers():
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "Stop-AllWatchers" in content, (
        "trap must call Stop-AllWatchers (the shared teardown)."
    )
    assert "Register-EngineEvent" in content, (
        "Launcher must register a PowerShell.Exiting handler for window-close teardown."
    )
    assert "PowerShell.Exiting" in content, (
        "Engine event must be PowerShell.Exiting (fires on window [X] close)."
    )


def test_launcher_persists_teardown_state():
    content = LAUNCHER.read_text(encoding="utf-8")
    assert "teardown-state.json" in content, (
        "Launcher must persist tracked root PIDs to teardown-state.json "
        "so the Exiting handler (separate runspace) can reach the processes."
    )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_graphify_wiring.tests.ps1`
Run: `venv\Scripts\python.exe -m pytest tests/test_launch_watcher_teardown.py -o addopts="" -v`
Expected: both FAIL (launcher not yet wired).

- [ ] **Step 3: Edit the launcher**

Add dot-source right after the `$scriptDir` resolve block (after line 8):

```powershell
# Shared watcher teardown (tree-kill + sweep). Safe to dot-source: no
# top-level side effects. Provides Stop-WatcherTree / Stop-AllWatchers.
$teardownModule = Join-Path $scriptDir 'modules\watcher_teardown.ps1'
if (Test-Path -LiteralPath $teardownModule) { . $teardownModule }
```

Replace the `trap` block (lines 441-470) with:

```powershell
# Ctrl+C (and any terminating error) triggers teardown. The PowerShell.Exiting
# handler below covers the window [X] close case. Both call the SAME shared
# Stop-AllWatchers, which is idempotent.
trap {
    Write-Host "`nStopping all watchers (Ctrl+C)..."
    try { Stop-AllWatchers } catch {}
    break
}

# Window [X] close: the console host raises PowerShell.Exiting even when the
# window is closed by the user (the trap does NOT fire then). This Action runs
# in a SEPARATE runspace with no script scope, so it must re-dot-source the
# module and call Stop-AllWatchers with no args (which reads the persisted
# state file). Bake the literal module path into the scriptblock.
$teardownAction = [scriptblock]::Create(". '$teardownModule'; Stop-AllWatchers")
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $teardownAction | Out-Null
```

Persist tracked root PIDs to the state file. Insert just BEFORE the controller `while ($true) { Start-Sleep -Seconds 1 }` loop (the final loop at line 797), and after all watchers have been launched:

```powershell
# Persist tracked root PIDs so the PowerShell.Exiting handler (separate
# runspace, no script scope) can tree-kill them on window [X] close.
try {
    $tdState = @{
        RootPids           = @($script:childProcs | ForEach-Object { $_.Id })
        MemtraceStatePath  = $script:memtraceStateFile
        RepoRoot           = $scriptDir
    } | ConvertTo-Json -Compress
    $tdDir  = Join-Path $env:LOCALAPPDATA 'watchers'
    $tdFile = Join-Path $tdDir 'teardown-state.json'
    New-Item -ItemType Directory -Path $tdDir -Force | Out-Null
    Set-Content -LiteralPath $tdFile -Value $tdState -Encoding UTF8
} catch {}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_graphify_wiring.tests.ps1`
Run: `venv\Scripts\python.exe -m pytest tests/test_launch_watcher_teardown.py -o addopts="" -v`
Expected: PASS.

Also re-run the existing teardown behavioral Pester (Task 2) to confirm no regression:
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_teardown.tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1" tests/launcher_graphify_wiring.tests.ps1 tests/test_launch_watcher_teardown.py
git commit -m "feat: wire launcher teardown to shared module + add window-close (PowerShell.Exiting) handler"
```

---

### Task 4: Full suite + verification

**Files:** none new — run everything.

- [ ] **Step 1: Run the full watcher-related test set**

Run (Pester):
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_teardown.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_graphify_wiring.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_gm_semantic_build.tests.ps1
```
Run (pytest):
```
venv\Scripts\python.exe -m pytest tests/test_launch_watcher_teardown.py tests/test_launch_watcher_standalone.py -o addopts="" -v
```
Expected: all PASS.

- [ ] **Step 2: Manual smoke (optional, on user's machine)**

Launch `###1. watchers … .ps1`, confirm the 4-pane window opens, then CLOSE THE WINDOW via [X] (not Ctrl+C). Verify in Task Manager / `Get-CimInstance Win32_Process` that `gm.exe`, `repowise.exe`, `graphify-rs.exe`, `grepai.exe` (watch), and the `temp\panes\tail_*` powershells are all gone, and `modules/.memdb` daemon is stopped.

- [ ] **Step 3: Commit (if any polish from smoke)**

```bash
git add -A
git commit -m "chore: verify watcher teardown on Ctrl+C and window close"
```
(Only if Step 2 surfaced a fix — otherwise skip.)

---

## Self-Review

1. **Spec coverage:** All five watchers covered (grepai/gm/graphify/repowise/memtrace) + pane tailers + grandchild graphify-rs. Both exit paths (Ctrl+C + window [X]) addressed. Grepai `--stop` failure no longer silently swallows (sweep backup). ✓
2. **Placeholders:** No TBD/TODO; every step has concrete code. ✓
3. **Type consistency:** `Stop-WatcherTree -Pid <int>`, `Stop-AllWatchers` signature stable across Task 2 (impl) and Task 3 (consume). State-file shape (`RootPids`/`MemtraceStatePath`/`RepoRoot`) matches between writer (Task 3) and reader (Task 2 module). ✓
4. **Escape/literal consistency:**
   - `temp\\panes\\tail_` is a CIM `CommandLine -match` regex in the module → matches literal `temp\panes\tail_` in the real CommandLine (the launcher builds pane scripts under `temp\panes\tail_*.ps1`, confirmed at `###1…ps1:472,485`). ✓
   - `[regex]::Escape($s.Pattern)` used for the `watch`/`tail_` patterns so the literal substring matches. ✓
   - `'PowerShell.Exiting'` / `'Register-EngineEvent'` are literal string matches in the static tests against launcher text. ✓
   - The `[scriptblock]::Create(". '$teardownModule'; Stop-AllWatchers")` embeds the resolved absolute path as a literal — correct, since the Action runspace can't see `$teardownModule`. ✓
   - Pester grandchild test: `cmd /c ping -n 60 127.0.0.1` is a long-lived grandchild; `Stop-WatcherTree -Pid $parent.Id` walks CIM descendants and kills it. PID read from a file avoids cross-runspace variable issues. ✓
