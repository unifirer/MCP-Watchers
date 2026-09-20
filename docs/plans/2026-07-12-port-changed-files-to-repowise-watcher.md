# Port "changed files" resolution to the Repowise watcher

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repowise pane (like the graphify-rs pane already does) resolve and print the actual file path(s) when repowise reports a count-only change line (`Detected N changed file(s)`), by porting the existing `Resolve-ChangedFiles`/`Show-ChangedFiles` logic out of the graphify-rs-only branch.

**Architecture:** The changed-file resolver (`Resolve-ChangedFiles` + `Show-ChangedFiles`) currently lives inside the `New-WatcherPaneScript` pane template and is only invoked for the `graphify-rs` label. We make `Show-ChangedFiles` **label-aware** (it already resolves paths for graphify-rs's count-only `Files changed (N)` line; we add repowise's count-only `Detected N changed file(s)` line; gm/grepai already print the path inline so they stay no-op), call it unconditionally from every label's loop, and pass `-RepoRoot $scriptDir` to the repowise pane so the resolver has a repo root to diff against. Tests extract the REAL generated tailer via AST (the functions live inside a here-string template, so they must be exercised through the generated file, not copied).

**Tech Stack:** PowerShell 5.1 (Windows), Pester 3.4.0 test idiom, AST-based function extraction, the launcher `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`.

## Global Constraints

- All tests live in `tests/` (AGENTS.md §4.3). Test files are `*.tests.ps1` run headless via `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/<name>.tests.ps1`, and MUST carry the Pester 3.x re-discovery guard (`if (-not $env:<UNIQUE>_TEST_RAN) { $env:<UNIQUE>_TEST_RAN='1'; Invoke-Pester -Path $MyInvocation.MyCommand.Path }`).
- Every edit touches ONLY the repo root launcher `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1` and `tests/`; no new dependencies (per user preference: zero-new-dependency fixes only).
- The resolver must keep its existing exclusions (dot-directories + scratch dirs `temp/panes/graphenium-out/graphify-out/!!!AUTO SCRIPTS!!!/node_modules/target/dist/build`) so it never reports tool-state churn instead of the user's edit.
- Change/feature summaries go in `changelogs/` (AGENTS.md §4.4). Commit only my files (launcher + test + change log); do NOT commit unrelated working-tree changes.
- The `-Label` call sites and the `Show-ChangedFiles` function are inside a single-quoted here-string template (`$template = @'...'@`) inside `New-WatcherPaneScript`, so the functions cannot be AST-extracted directly from the launcher — they MUST be exercised through the REAL generated tailer file (produced by calling the real `New-WatcherPaneScript`).

---

### Task 1: Tests for the repowise changed-files port (RED)

**Files:**
- Create: `tests/repowise_changed_files.tests.ps1`
- Create: `tests/launcher_repowise_wiring.tests.ps1`
- Test: both files above

**Interfaces:**
- Consumes (real, shipped): function `New-WatcherPaneScript` (top-level, params `[string]$Label,[string]$LogPath,[string]$ErrPath,[string]$RepoRoot`) defined in the launcher file `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`; it reads `$wtPaneDir` from scope to decide where the tailer file is written. The generated tailer contains top-level `Show-ChangedFiles` (currently `param([string]$Line)`) and `Resolve-ChangedFiles` (`param([int]$MaxFiles=1)`).
- Produces: a helper that generates a real tailer for a given label and returns its path; the RED tests below that must fail until Task 2 implements the port.

- [ ] **Step 1: Write the failing unit + wiring tests**

`tests/repowise_changed_files.tests.ps1`:

```powershell
# tests/repowise_changed_files.tests.ps1
# Pester 3.4.0 idiom. Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/repowise_changed_files.tests.ps1
# Exercises the REAL generated tailer: New-WatcherPaneScript (top-level in the
# launcher) is AST-extracted and dot-sourced, then called to GENERATE a tailer
# file. Show-ChangedFiles / Resolve-ChangedFiles live INSIDE the template
# here-string, so they only exist as real functions inside the generated file.
# We AST-extract them from the generated file and dot-source them, then assert
# the changed-file resolution behavior. This tracks the shipped code (no copy).
$launcher = 'J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1'
$ErrorActionPreference = 'SilentlyContinue'

function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { throw "file missing: $Path" }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "parse errors in $Path" }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

Describe 'repowise changed-files resolution (ported from graphify-rs)' {
    BeforeEach {
        $script:scratch = Join-Path $env:TEMP ('rp_cf_test_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null
        # distractor under an excluded scratch dir (must NEVER be reported)
        New-Item -ItemType Directory -Path (Join-Path $script:scratch 'temp') -Force | Out-Null
        Set-Content -Path (Join-Path $script:scratch 'temp\distractor.txt') -Value 'x'
        # the real source edit we expect to be reported
        Set-Content -Path (Join-Path $script:scratch 'real_src.py') -Value 'def a(): pass'
        (Get-ChildItem (Join-Path $script:scratch 'real_src.py')).LastWriteTime = (Get-Date)

        # Generate a REAL repowise tailer via the shipped New-WatcherPaneScript.
        $genDir = Join-Path $env:TEMP ('rp_gen_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $genDir -Force | Out-Null
        $wtPaneDir = Join-Path $genDir 'panes'
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        # Extract New-WatcherPaneScript (top-level fn in launcher) + dot-source.
        $nsTmp = Join-Path $genDir ('ns_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $nsTmp -Value (Extract-FunctionAst $launcher 'New-WatcherPaneScript') -Encoding UTF8
        . $nsTmp
        $script:tailer = New-WatcherPaneScript -Label 'repowise' -LogPath (Join-Path $genDir 'rep.log') -ErrPath (Join-Path $genDir 'rep.log.err') -RepoRoot $script:scratch
        if (-not (Test-Path -LiteralPath $script:tailer)) { throw "tailer not generated: $script:tailer" }
        # Extract the REAL Show-ChangedFiles + Resolve-ChangedFiles from the generated tailer.
        $fnTmp = Join-Path $genDir ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $fnTmp -Value ((Extract-FunctionAst $script:tailer 'Show-ChangedFiles') + "`n" + (Extract-FunctionAst $script:tailer 'Resolve-ChangedFiles')) -Encoding UTF8
        . $fnTmp
        # Resolver scope state (dot-sourcing shares scope, so $script: here == caller).
        $script:changedBaseline = @{}
        $script:lastEventTime = (Get-Date).AddSeconds(-10)
        $repo = $script:scratch
    }
    AfterEach {
        if ($script:scratch) { Remove-Item -LiteralPath $script:scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'resolves a repowise count-only line to the changed file path' {
        $captured = & { Show-ChangedFiles -Label 'repowise' 'Detected 1 changed file(s), updating...' } 6>&1 | Out-String
        $captured | Should Match 'changed file:'
        $captured | Should Match 'real_src\.py'
        $captured | Should Not Match 'distractor\.txt'
    }
    It 'graphify-rs still resolves (regression guard)' {
        $captured = & { Show-ChangedFiles -Label 'graphify-rs' 'Files changed (1), triggering incremental rebuild...' } 6>&1 | Out-String
        $captured | Should Match 'changed file:'
        $captured | Should Match 'real_src\.py'
    }
    It 'gm/graphenium inline-path line is a no-op (would mis-fire the resolver)' {
        $captured = & { Show-ChangedFiles -Label 'graphenium' 'changed (code): J:\audio\VAD\.\real_src.py' } 6>&1 | Out-String
        $captured | Should Not Match 'changed file:'
    }
    It 'grepai inline-path line is a no-op (would mis-fire the resolver)' {
        $captured = & { Show-ChangedFiles -Label 'grepai' 'Indexed real_src.py (0 chunks)' } 6>&1 | Out-String
        $captured | Should Not Match 'changed file:'
    }
}

if (-not $env:RP_CF_TEST_RAN) {
    $env:RP_CF_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

`tests/launcher_repowise_wiring.tests.ps1`:

```powershell
# tests/launcher_repowise_wiring.tests.ps1
# Pester 3.4.0 idiom. Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_repowise_wiring.tests.ps1
# Source-wiring assertions that the repowise pane now (a) carries -RepoRoot so
# the resolver has a repo to diff, and (b) the tailer calls Show-ChangedFiles
# label-aware (unconditionally) instead of the old graphify-rs-only branch.
$launcher = 'J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1'

Describe 'repowise pane wiring' {
    It 'repowise pane call now passes -RepoRoot $scriptDir' {
        $c = Get-Content -LiteralPath $launcher
        ($c | Where-Object { $_ -match '-Label "repowise"' -and $_ -match '-RepoRoot \$scriptDir' }) | Should Not BeNullOrEmpty
    }
    It 'tailer calls Show-ChangedFiles label-aware (unconditional)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'Show-ChangedFiles -Label'
    }
    It 'old graphify-rs-only branch guard is gone (now label-aware)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        ($c -split "`n" | Where-Object { $_ -match "if \('__LABEL__' -eq 'graphify-rs'\) \{ Show-ChangedFiles" }) | Should BeNullOrEmpty
    }
}

if (-not $env:RP_WIRING_TEST_RAN) {
    $env:RP_WIRING_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

- [ ] **Step 2: Run the tests to verify they FAIL (RED)**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "J:\audio\VAD\tests\repowise_changed_files.tests.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "J:\audio\VAD\tests\launcher_repowise_wiring.tests.ps1"
```
Expected: `repowise_changed_files.tests.ps1` FAILS — `Show-ChangedFiles` is generated with `param([string]$Line)` (no `-Label`), so `Show-ChangedFiles -Label 'repowise' ...` throws "parameter name 'Label' cannot be found" and the It errors → red. The graphify-rs regression It and the gm/grepai no-op Its also red for the same reason. `launcher_repowise_wiring.tests.ps1` FAILS — the repowise call has no `-RepoRoot $scriptDir` and there is no `Show-ChangedFiles -Label` token yet.

- [ ] **Step 3: (implementation deferred to Task 2 — leave tests failing here)**

Do NOT implement yet. Confirm RED is genuine (failure is because the feature is absent, not a typo in the test). If a test errors for an unrelated reason, fix the test.

- [ ] **Step 4: Commit the (failing) tests**

```bash
git add tests/repowise_changed_files.tests.ps1 tests/launcher_repowise_wiring.tests.ps1
git commit -m "test: add repowise changed-files resolution tests (RED)"
```

---

### Task 2: Implement the port in the launcher (GREEN)

**Files:**
- Modify: `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`
  - `Show-ChangedFiles` (currently lines ~672-682, inside the `New-WatcherPaneScript` template here-string)
  - its two call sites (currently `if ('__LABEL__' -eq 'graphify-rs') { Show-ChangedFiles $all[$i] }` at ~line 717 and `if ('__LABEL__' -eq 'graphify-rs') { Show-ChangedFiles $l[$i] }` at ~line 745)
  - the repowise pane call (currently `$tailRepowise = New-WatcherPaneScript -Label "repowise" -LogPath $repowiseLog -ErrPath "$repowiseLog.err"` at ~line 774)

**Interfaces:**
- Produces: `Show-ChangedFiles -Label <string> -Line <string>` (label-aware); the resolved path is printed as `[<Label>]   -> changed file: <path>`. `Resolve-ChangedFiles -MaxFiles <int>` unchanged in signature/behavior. The generated tailer now calls `Show-ChangedFiles -Label '__LABEL__' $line` unconditionally from both the seed and live loops.

- [ ] **Step 1: Make `Show-ChangedFiles` label-aware**

Replace the function body (inside the template here-string) with:

```powershell
function Show-ChangedFiles {
    param([string]$Label, [string]$Line)
    # Only count-only change lines need path resolution. gm/graphenium already
    # prints the path inline ("changed (code): <path>"); grepai prints it inline
    # ("Indexed <file>"). graphify-rs and repowise emit ONLY a COUNT
    # ("Files changed (N)" / "Detected N changed file(s)"), so we resolve paths
    # for those two only. Any other label -> no-op (safe to call unconditionally
    # from every label's loop now that this is label-aware).
    $pattern = $null
    if ($Label -eq 'graphify-rs') { $pattern = 'Files changed \((\d+)\)' }
    elseif ($Label -eq 'repowise') { $pattern = 'Detected (\d+) changed' }
    else { return }
    $m = [regex]::Match($Line, $pattern)
    if ($m.Success) {
        $n = [int]$m.Groups[1].Value
        if ($n -lt 5) {
            $files = Resolve-ChangedFiles -MaxFiles $n
            foreach ($f in $files) { Write-Host ("[$Label]   -> changed file: " + $f) }
        }
    }
}
```

- [ ] **Step 2: Replace the two call sites (seed loop + live loop)**

Seed loop (around line 714-718), change:
```powershell
            $fl = CleanLogLine $all[$i] '__LABEL__'
            if ($null -ne $fl) {
                Write-Host ("[__LABEL__] " + $fl)
                if ('__LABEL__' -eq 'graphify-rs') { Show-ChangedFiles $all[$i] }
            }
```
to:
```powershell
            $fl = CleanLogLine $all[$i] '__LABEL__'
            if ($null -ne $fl) {
                Write-Host ("[__LABEL__] " + $fl)
                Show-ChangedFiles -Label '__LABEL__' $all[$i]
            }
```

Live loop (around line 742-746), change:
```powershell
                    $fl = CleanLogLine $l[$i] '__LABEL__'
                    if ($null -ne $fl) {
                        Write-Host ("[__LABEL__] " + $fl)
                        if ('__LABEL__' -eq 'graphify-rs') { Show-ChangedFiles $l[$i] }
                    }
```
to:
```powershell
                    $fl = CleanLogLine $l[$i] '__LABEL__'
                    if ($null -ne $fl) {
                        Write-Host ("[__LABEL__] " + $fl)
                        Show-ChangedFiles -Label '__LABEL__' $l[$i]
                    }
```

- [ ] **Step 3: Pass `-RepoRoot $scriptDir` to the repowise pane**

Change (around line 774):
```powershell
$tailRepowise    = New-WatcherPaneScript -Label "repowise"    -LogPath $repowiseLog        -ErrPath "$repowiseLog.err"
```
to:
```powershell
$tailRepowise    = New-WatcherPaneScript -Label "repowise"    -LogPath $repowiseLog        -ErrPath "$repowiseLog.err" -RepoRoot $scriptDir
```

- [ ] **Step 4: Run the Task 1 tests to verify they PASS (GREEN)**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "J:\audio\VAD\tests\repowise_changed_files.tests.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "J:\audio\VAD\tests\launcher_repowise_wiring.tests.ps1"
```
Expected: all 4 Its in `repowise_changed_files.tests.ps1` PASS (repowise resolves; graphify-rs regression holds; gm/grepai no-op). All 3 Its in `launcher_repowise_wiring.tests.ps1` PASS.

- [ ] **Step 5: Prove non-vacuous (source-patch RED on the graphify-rs branch, then restore)**

Temporarily break the shipped source so the graphify-rs regression test would fail, to prove that test actually guards the real code:
```bash
git stash list   # note: do NOT commit yet
```
In the launcher, temporarily change the graphify-rs pattern line inside `Show-ChangedFiles` from:
```powershell
    if ($Label -eq 'graphify-rs') { $pattern = 'Files changed \((\d+)\)' }
```
to:
```powershell
    if ($Label -eq 'graphify-rs') { $pattern = 'FILES_CHANGED_NEVER_MATCHES_XYZ' }
```
Run `repowise_changed_files.tests.ps1` → the graphify-rs regression It now FAILS (no path resolved). Restore byte-identical:
```bash
git checkout -- "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"
```
Re-run → all PASS. Confirm `git status --short "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"` is empty.

- [ ] **Step 6: Commit**

```bash
git add "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"
git commit -m "feat: port changed-files resolution to repowise pane (label-aware Show-ChangedFiles)"
```

---

### Task 3: End-to-end execution test of the generated repowise tailer (RED/GREEN)

**Files:**
- Create: `tests/launcher_repowise_e2e.tests.ps1`
- Test: `tests/launcher_repowise_e2e.tests.ps1`

**Interfaces:**
- Consumes: the real `New-WatcherPaneScript` (top-level in the launcher) — AST-extracted and dot-sourced, exactly as in Task 1; the generated `tail_repowise.ps1` file.
- Produces: proof that the REAL generated repowise tailer, when fed a `Detected N changed file(s)` log line plus a real changed file in the repo root, prints `-> changed file: <path>` — exercising the whole shipped code path (template fill + generated tailer + resolver), not just the unit-level function.

- [ ] **Step 1: Write the failing e2e test**

`tests/launcher_repowise_e2e.tests.ps1`:

```powershell
# tests/launcher_repowise_e2e.tests.ps1
# Pester 3.4.0 idiom. Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_repowise_e2e.tests.ps1
# EXECUTION test: generates the REAL repowise tailer via the shipped
# New-WatcherPaneScript, runs it headless against a prepopulated repowise.log
# (containing a "Detected N changed file(s)" line) plus a real changed file in
# the repo root, and asserts the tailer prints "-> changed file: <path>".
# Per safe-gate ref 6b, the tailer is launched via -Command "& '<tailer>' 6>&1"
# so Write-Host (info stream 6) is captured to stdout; it is killed fail-safe
# after a short capture window.
$launcher = 'J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1'
$ErrorActionPreference = 'SilentlyContinue'

function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { throw "file missing: $Path" }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "parse errors in $Path" }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

Describe 'repowise tailer shows changed files end-to-end' {
    It 'prints the resolved changed file for a Detected N changed line' {
        $root = Join-Path $env:TEMP ('rp_e2e_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            # Repo root with one real source file (added AFTER tailer start so it
            # is not in the seeded baseline -> resolver reports it as changed).
            # Distractor under an excluded dir must never appear.
            New-Item -ItemType Directory -Path (Join-Path $root 'temp') -Force | Out-Null
            Set-Content -Path (Join-Path $root 'temp\distractor.txt') -Value 'x'

            # Generate the REAL repowise tailer.
            $wtPaneDir = Join-Path $root 'panes'
            New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
            $nsTmp = Join-Path $root ('ns_' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $nsTmp -Value (Extract-FunctionAst $launcher 'New-WatcherPaneScript') -Encoding UTF8
            . $nsTmp
            $repolog = Join-Path $root 'repowise.log'
            $tailer = New-WatcherPaneScript -Label 'repowise' -LogPath $repolog -ErrPath "$repolog.err" -RepoRoot $root

            # Pre-seed the log with the change line (before we add the file, so it
            # is in the backlog the tailer reads on open). Then add the file so the
            # resolver sees it as changed vs the seeded baseline.
            Set-Content -LiteralPath $repolog -Value 'Watching J:\repo... Ctrl+C to stop' -Encoding UTF8
            Add-Content -LiteralPath $repolog -Value 'Detected 1 changed file(s), updating...' -Encoding UTF8

            $cap = Join-Path $root 'cap.txt'
            $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-Command', "& '$tailer' 6>&1") `
                -RedirectStandardOutput $cap
            # Add the real source file AFTER start (not in seeded baseline).
            Start-Sleep -Milliseconds 400
            Set-Content -Path (Join-Path $root 'real_src.py') -Value 'def a(): pass'
            (Get-ChildItem (Join-Path $root 'real_src.py')).LastWriteTime = (Get-Date)
            Start-Sleep -Seconds 2
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

            $out = Get-Content -LiteralPath $cap -ErrorAction SilentlyContinue -Raw
            $out | Should Match 'changed file:'
            $out | Should Match 'real_src\.py'
            $out | Should Not Match 'distractor\.txt'
        }
        finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

if (-not $env:RP_E2E_TEST_RAN) {
    $env:RP_E2E_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

- [ ] **Step 2: Run the e2e test to verify it PASSES (GREEN)**

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "J:\audio\VAD\tests\launcher_repowise_e2e.tests.ps1"
```
Expected: PASS (real generated tailer prints `-> changed file:` with `real_src.py`, never `distractor.txt`).

- [ ] **Step 3: Prove non-vacuous (source-patch RED: revert the call-site, then restore)**

Temporarily revert the live-loop call site in the launcher back to the OLD graphify-rs-only branch:
```powershell
                        Show-ChangedFiles -Label '__LABEL__' $l[$i]
```
back to:
```powershell
                        if ('__LABEL__' -eq 'graphify-rs') { Show-ChangedFiles $l[$i] }
```
Run `launcher_repowise_e2e.tests.ps1` → FAILS (generated repowise tailer never calls `Show-ChangedFiles` for the repowise line, so no `-> changed file:` appears). Restore byte-identical:
```bash
git checkout -- "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"
```
Re-run → PASS. Confirm `git status --short "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"` is empty.

- [ ] **Step 4: Commit**

```bash
git add tests/launcher_repowise_e2e.tests.ps1
git commit -m "test: e2e proof repowise pane shows changed files via real generated tailer"
```

---

### Task 4: Change log entry

**Files:**
- Create: `changelogs/repowise-show-changed-files-2026-07-12.txt`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Write the change log**

`changelogs/repowise-show-changed-files-2026-07-12.txt`:

```text
# Change log: repowise pane shows changed files for N < 5

Date: 2026-07-12

## Feature
The repowise pane tailer now prints the resolved file path(s) when repowise
reports `Detected N changed file(s), updating...` with N < 5 — the same
behavior graphify-rs already had for its `Files changed (N)` line.

## Why
repowise's `watch` mode logs only a COUNT of changed files, never the paths
(unlike gm/graphenium which prints `changed (code): <path>` and grepai which
prints `Indexed <file>`). So for a single changed file the user could not tell
which file triggered the wiki rebuild. graphify-rs already had this resolver;
this ports it to repowise.

## What changed (in `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`, inside `New-WatcherPaneScript`)
- `Show-ChangedFiles` is now label-aware: `param([string]$Label,[string]$Line)`;
  it resolves paths for `graphify-rs` (`Files changed (\d+)`) and `repowise`
  (`Detected (\d+) changed`) only. gm/graphenium and grepai already name the
  file inline, so they are a deliberate no-op (running the count-resolver on
  them would mis-fire — e.g. grepai's `Indexed X (0 chunks)` would show a
  phantom "changed file").
- Both the seed loop and the live loop now call `Show-ChangedFiles -Label
  '__LABEL__' <line>` unconditionally (the old `if ('__LABEL__' -eq
  'graphify-rs')` special-case is gone).
- The repowise pane call now passes `-RepoRoot $scriptDir` so the resolver has
  the repo root to diff against.

## Verification
- Unit tests (tests/repowise_changed_files.tests.ps1): repowise resolves to the
  changed file; graphify-rs regression holds; gm/grepai lines are no-ops.
- Wiring tests (tests/launcher_repowise_wiring.tests.ps1): repowise pane carries
  -RepoRoot; call site is label-aware; old graphify-rs-only branch gone.
- E2E (tests/launcher_repowise_e2e.tests.ps1): the REAL generated repowise
  tailer prints `-> changed file: <path>` for a `Detected 1 changed` line,
  excluding scratch-dir distractors.
All cases PASS.
```

- [ ] **Step 2: Commit**

```bash
git add "changelogs/repowise-show-changed-files-2026-07-12.txt"
git commit -m "docs: change log for repowise changed-files port"
```

---

## Self-Review (against spec)

1. **Spec coverage:** The user asked to port the graphify-rs "show changed files paths" function to the other watchers. The plan identifies repowise as the only other COUNT-only watcher (gm/grepai already name the file inline), makes `Show-ChangedFiles` label-aware to cover repowise, calls it unconditionally, and passes `-RepoRoot` to the repowise pane. gm/grepai are explicitly documented as no-op (would mis-fire). Covered.
2. **Placeholder scan:** No TBD/TODO. Every step has exact code and exact run commands with expected output.
3. **Type consistency:** `Show-ChangedFiles -Label <str> -Line <str>` is used consistently in impl (call sites) and in all three test files. `New-WatcherPaneScript -Label -LogPath -ErrPath -RepoRoot` signature matches across launcher and tests. `Resolve-ChangedFiles -MaxFiles <int>` unchanged.
4. **Escape-sequence / literal consistency:**
   - Regex literals are inside the single-quoted template here-string. `Files changed \((\d+)\)` and `Detected (\d+) changed` are written with literal `\(` `\)` — correct regex escaping, and a single-quoted here-string does NOT collapse backslashes, which is what we want (these are regex escapes, not path backslashes). Verified: the OLD code already used `'\[graphenium(?: [A-Z]+)?\]\s*'` inside the same here-string and works.
   - The message `"[$Label]   -> changed file: "` uses `[$Label]` (a literal `[` then variable) — correct; the old code used `"[__LABEL__]   -> changed file: "` and worked.
   - Test assertions use `[regex]::Match`-style `-match` with escaped dots (`real_src\.py`) inside Pester `Should Match` (regex) — correct.
   - Wiring assertion uses token-independent `-match` per pitfall #5/#6 (matches `-Label "repowise"` and `-RepoRoot \$scriptDir` separately), not a single-spaced regex. The negative assertion greps for the exact old `if ('__LABEL__' -eq 'graphify-rs') { Show-ChangedFiles` form.
5. **RED/GREEN coverage:** Every public function introduced/changed is covered: `Show-ChangedFiles` (repowise + graphify-rs regression + gm/grepai no-op units, plus e2e), the call-site change (wiring + e2e RED), and `-RepoRoot` wiring. Both source-patch REDs (graphify-rs branch, call-site revert) prove the tests are non-vacuous and restore byte-identical.
6. **Real-function testing:** All function-level tests AST-extract the REAL `New-WatcherPaneScript` from the launcher, generate the REAL tailer, then AST-extract `Show-ChangedFiles`/`Resolve-ChangedFiles` from the generated file — no hand-copied body that can drift. The e2e runs the REAL generated tailer headless (per safe-gate ref 6b, `6>&1`) rather than parsing only.
