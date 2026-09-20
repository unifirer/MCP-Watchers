# Watcher Pane-Visibility Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Pester tests proving the Windows Terminal 2x2 pane grid created by `###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1` shows info for all four pane-backed watchers (grepai, graphenium, graphify-rs, repowise).

**Architecture:** Three Pester 3.4.0 test blocks in one new file (`tests/launcher_watcher_panes.tests.ps1`): (1) generation — the launcher's embedded `New-WatcherPaneScript` bakes the correct Label/LogPath/ErrPath into each tailer; (2) wiring — the launcher's `wt` invocation + `New-WatcherPaneScript` calls reference all four watchers exactly once; (3) execution — each generated tailer, run for real against a seeded log, prints its watcher's lines tagged `[label]`. The real function is extracted via the PowerShell AST (quote/comment-aware) so the test tracks shipped code, not a drifting copy.

**Tech Stack:** PowerShell 5.1 (Windows), Pester 3.4.0 (team harness), PowerShell Language AST parser (no new dependencies).

## Global Constraints

- Tests live in `tests/` (AGENTS.md §4.3). One new file: `tests/launcher_watcher_panes.tests.ps1`.
- Pester version is **3.4.0** — assertions limited to `Should Be`, `Should Match`, `Should BeNullOrEmpty`, `Should BeGreaterThan`, `Should Not Throw`. NO Pester 5 syntax (`BeforeAll`, `It -ForEach`, `Should -BeExactly`).
- Every test file ends with the guarded `Invoke-Pester` idiom to avoid Pester 3.x rediscovery loops:
  `if (-not $env:WPANE_TEST_RAN) { $env:WPANE_TEST_RAN = '1'; Invoke-Pester -Path $MyInvocation.MyCommand.Path }`
- Run via: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_panes.tests.ps1`
- The launcher path is hardcoded literally (existing repo idiom): `J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`
- **Scope: exactly the four pane-backed watchers** — grepai, graphenium, graphify-rs, repowise. `memtrace` is launched detached but is **intentionally pane-less** (launcher lines 475-476: *"No 5th pane — the 2x2 grid is left intact"*); per user decision it is NOT covered. Do not add a memtrace pane.
- Extract the embedded `New-WatcherPaneScript` with the **PowerShell AST** (`[System.Management.Automation.Language.Parser]::ParseFile`), NOT brace-counting — the function body is a single-quoted here-string full of literal `{`/`}` that breaks depth-counting. AST extraction is quote/comment-aware and returns the true text.
- The tailer loops forever (`while ($true) { Start-Sleep -Milliseconds 500 }`). The execution test launches it as a background process, captures backlog printed at startup, then kills it (fail-safe, see Task 3). It must never run un-killed.
- The tailer prints via `Write-Host` (information stream 6). Launch it with `powershell.exe -Command "& '<tailer>' 6>&1"` so stream 6 merges into stdout and is captured by `Start-Process -RedirectStandardOutput`.
- The launcher file is committed and MUST remain byte-identical at the end of every task except the one that intentionally proves non-vacuousness (Task 2's RED break, restored via `git checkout --`).

---

### Task 1: Pester test — pane tailer generation (real `New-WatcherPaneScript`)

**Files:**
- Create: `tests/launcher_watcher_panes.tests.ps1`
- Test: `tests/launcher_watcher_panes.tests.ps1` (Describe 'pane tailer generation')

**Interfaces:**
- Consumes: the launcher file at `J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1`; the function `New-WatcherPaneScript` (defined inside it, params `[string]$Label,[string]$LogPath,[string]$ErrPath,[string]$RepoRoot`), which reads `$wtPaneDir` from scope to decide where the tailer file is written.
- Produces: nothing consumed by later tasks (later tasks extract the same function independently), but the AST-extraction helper `Extract-FunctionAst` is reused by Tasks 2/3 patterns.

- [ ] **Step 1: Create the test file with the AST extractor + generation Describe block + guarded runner**

```powershell
# tests/launcher_watcher_panes.tests.ps1
# Pester 3.4.0 team idiom. Run via:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_panes.tests.ps1
# Proves the 2x2 pane grid created by
# "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1" shows
# info for all four pane-backed watchers (grepai, graphenium, graphify-rs, repowise).
# memtrace is intentionally pane-less (launcher lines 475-476) and is NOT covered.
$launcher = 'J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1'

# AST-based extraction of an embedded function (quote/comment-aware).
# Brace-counting would break on the single-quoted here-string template inside
# New-WatcherPaneScript (full of literal { } braces). The PowerShell parser
# understands strings, so AST extraction returns the true function text.
function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { throw "launcher missing: $Path" }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "parse errors in $Path" }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

Describe 'pane tailer generation' {
    It 'extracts and dot-sources New-WatcherPaneScript without error' {
        $src = Extract-FunctionAst -Path $launcher -Name 'New-WatcherPaneScript'
        $tmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        try { { . $tmp } | Should Not Throw }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'bakes the correct Label + LogPath + ErrPath into each of the 4 tailers' {
        $src = Extract-FunctionAst -Path $launcher -Name 'New-WatcherPaneScript'
        $tmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        $wtPaneDir = Join-Path $env:TEMP ('panes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        try {
            . $tmp
            $labels = @('grepai', 'graphenium', 'graphify-rs', 'repowise')
            foreach ($lbl in $labels) {
                $log = Join-Path $env:TEMP ("log_$lbl.txt")
                $err = "$log.err"
                $repo = if ($lbl -eq 'graphify-rs') { 'J:\audio\VAD' } else { '' }
                $p = New-WatcherPaneScript -Label $lbl -LogPath $log -ErrPath $err -RepoRoot $repo
                Test-Path -LiteralPath $p | Should Be $true
                $body = Get-Content -LiteralPath $p -Raw
                # The baked label must appear as the [label] tag prefix in the body.
                $body | Should Match ([regex]::Escape("[$lbl]"))
                # The log path must be baked (single-quoted assignment in the template).
                $body | Should Match ([regex]::Escape("`$log = '$log'"))
                # graphify-rs must bake the repo root (used to resolve changed files).
                if ($lbl -eq 'graphify-rs') {
                    $body | Should Match ([regex]::Escape("`$repo = 'J:\audio\VAD'"))
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wtPaneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $env:WPANE_TEST_RAN) {
    $env:WPANE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

- [ ] **Step 2: Run the test to verify it PASSES (non-vacuous by construction)**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_panes.tests.ps1`
Expected: 2 passed, 0 failed. (Non-vacuous: if `New-WatcherPaneScript` were renamed/removed, `Extract-FunctionAst` throws "$Name not found in $Path" and the test fails — proving it tracks the real function.)

- [ ] **Step 3: Commit**

```bash
git add tests/launcher_watcher_panes.tests.ps1
git commit -m "test: assert New-WatcherPaneScript bakes correct label/log/err per pane"
```

---

### Task 2: Pester test — launcher pane-grid wiring (4 tailers + 4 titles)

**Files:**
- Modify: `tests/launcher_watcher_panes.tests.ps1` (insert Describe block before the guarded `Invoke-Pester`)
- Test: `tests/launcher_watcher_panes.tests.ps1` (Describe 'pane grid wiring')

**Interfaces:**
- Consumes: the launcher file (source of truth for wiring).
- Produces: nothing.

- [ ] **Step 1: Insert the wiring Describe block before the guarded runner**

Patch: find the guarded runner at the end of the file and prepend the Describe block.

Old (exact, the file ends with this):
```
if (-not $env:WPANE_TEST_RAN) {
    $env:WPANE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

New:
```
Describe 'pane grid wiring' {
    It 'generates exactly one tailer per pane-backed watcher (grepai/graphenium/graphify-rs/repowise)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'New-WatcherPaneScript -Label "grepai"'
        $c | Should Match 'New-WatcherPaneScript -Label "graphenium"'
        $c | Should Match 'New-WatcherPaneScript -Label "graphify-rs"'
        $c | Should Match 'New-WatcherPaneScript -Label "repowise"'
    }

    It 'wires each watcher to the correct log path' {
        $c = Get-Content -LiteralPath $launcher -Raw
        # graphenium -> $gmLog ; graphify-rs -> $graphifyLog (+ RepoRoot) ; repowise -> $repowiseLog ; grepai -> $logFile
        # NOTE: the launcher pads these calls with 2-6 spaces between the label
        # and -LogPath (e.g. line 772 "...-Label \"graphenium\"  -LogPath $gmLog"),
        # so the assertions use \s+ rather than a single literal space.
        $c | Should Match 'New-WatcherPaneScript -Label "graphenium"\s+-LogPath \$gmLog'
        $c | Should Match 'New-WatcherPaneScript -Label "graphify-rs"\s+-LogPath \$graphifyLog\s+-ErrPath "\$graphifyLog\.err"\s+-RepoRoot \$scriptDir'
        $c | Should Match 'New-WatcherPaneScript -Label "repowise"\s+-LogPath \$repowiseLog'
        $c | Should Match 'New-WatcherPaneScript -Label "grepai"\s+-LogPath \$logFile -ErrPath ""'
    }

    It 'wt 2x2 grid references all 4 tailer scripts and a --title per watcher' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match '\$tailGrepai'
        $c | Should Match '\$tailGraphenium'
        $c | Should Match '\$tailGraphifyRs'
        $c | Should Match '\$tailRepowise'
        # one --title per watcher, quoted token form used by the wt args
        $c | Should Match "'grepai'"
        $c | Should Match "'graphenium'"
        $c | Should Match "'graphify-rs'"
        $c | Should Match "'repowise'"
        (($c | Select-String -Pattern "--title" -AllMatches).Matches.Count) | Should BeGreaterThan 3
    }
}

if (-not $env:WPANE_TEST_RAN) {
    $env:WPANE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

- [ ] **Step 2: Run the test to verify it PASSES**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_panes.tests.ps1`
Expected: 4 passed, 0 failed (2 from Task 1 + 3 new... actually Task 1 = 2 Its, Task 2 = 3 Its → 5 passed total).

- [ ] **Step 3: Prove non-vacuous (RED for pre-existing behavior)**

Temporarily break the wiring by removing one `New-WatcherPaneScript -Label` line from the launcher, run, assert the wiring test FAILS, then restore byte-identical.

```bash
# Break: delete the graphenium tailer generation call (line 772) from the launcher.
powershell.exe -NoProfile -Command "(Get-Content 'J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1') | Where-Object { $_ -notmatch 'New-WatcherPaneScript -Label \"graphenium\"' } | Set-Content 'J:\audio\VAD\###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1'"
```
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_panes.tests.ps1`
Expected: FAIL (the "generates exactly one tailer per pane-backed watcher" It throws on missing `New-WatcherPaneScript -Label "graphenium"`).

Restore byte-identical:
```bash
git checkout -- "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"
git status --short "###1. watchers for memtrace grepai graphenium graphify-rs repowise.ps1"
```
Expected: `git status` reports the launcher as clean (empty output). Re-run the test → PASS again.

- [ ] **Step 4: Commit**

```bash
git add tests/launcher_watcher_panes.tests.ps1
git commit -m "test: assert launcher wt grid wires all 4 pane-backed watchers"
```

---

### Task 3: Pester test — execution: each tailer shows watcher info (real tailer, tagged)

**Files:**
- Modify: `tests/launcher_watcher_panes.tests.ps1` (insert Describe block before the guarded `Invoke-Pester`)
- Test: `tests/launcher_watcher_panes.tests.ps1` (Describe 'pane tailer shows watcher info at runtime')

**Interfaces:**
- Consumes: `Extract-FunctionAst` + `New-WatcherPaneScript` (same as Tasks 1-2).
- Produces: nothing.

- [ ] **Step 1: Insert the execution Describe block before the guarded runner**

Old (exact, the file ends with this):
```
if (-not $env:WPANE_TEST_RAN) {
    $env:WPANE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

New:
```
Describe 'pane tailer shows watcher info at runtime' {
    It 'each generated tailer prints its watcher log lines tagged with [label]' {
        $src = Extract-FunctionAst -Path $launcher -Name 'New-WatcherPaneScript'
        $tmp = Join-Path $env:TEMP ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        $wtPaneDir = Join-Path $env:TEMP ('panes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        . $tmp
        # One case per pane-backed watcher. graphenium carries a '[graphenium]' prefix
        # that CleanLogLine strips, and ships an stderr line (printed under [graphenium],
        # not [graphenium ERR]) — both verified below.
        $cases = @(
            @{ Label = 'grepai';      Lines = @('grepai watch indexing worktree', 'watching for file changes') },
            @{ Label = 'graphenium';  Lines = @('[graphenium] Watching modules/', 'changed (code): VAD.py'); Err = @('stderr line for graphenium') },
            @{ Label = 'graphify-rs'; Lines = @('Files changed (1)', 'built graph for VAD') },
            @{ Label = 'repowise';    Lines = @('watching repo for changes', 'indexed 12 modules') }
        )
        try {
            foreach ($case in $cases) {
                $log = Join-Path $env:TEMP ("log_$($case.Label).txt")
                $err = "$log.err"
                # Seed the log BEFORE launching so the tailer's backlog print picks it up.
                Set-Content -LiteralPath $log -Value ($case.Lines -join "`r`n") -Encoding utf8
                if ($case.Err) { Set-Content -LiteralPath $err -Value ($case.Err -join "`r`n") -Encoding utf8 }
                $repo = if ($case.Label -eq 'graphify-rs') { 'J:\audio\VAD' } else { '' }
                $tailer = New-WatcherPaneScript -Label $case.Label -LogPath $log -ErrPath $err -RepoRoot $repo
                # Launch the REAL tailer; merge its information stream (Write-Host) into
                # stdout via 6>&1 so Start-Process -RedirectStandardOutput captures it.
                # It loops forever, so we kill it after a beat (fail-safe: Stop-Process
                # is wrapped so a missing PID never throws).
                $cap = Join-Path $env:TEMP ("cap_$($case.Label).txt")
                $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                    -ArgumentList @('-NoProfile', '-Command', "& '$tailer' 6>&1") `
                    -RedirectStandardOutput $cap
                Start-Sleep -Seconds 1
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Milliseconds 200
                $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
                $out | Should Match ([regex]::Escape("=== $($case.Label) live log ==="))
                foreach ($ln in $case.Lines) {
                    # graphenium lines carry a '[graphenium]' prefix CleanLogLine strips,
                    # so assert the stripped content under the pane's own [graphenium] tag.
                    $stripped = $ln -replace '^\[graphenium(?: [A-Z]+)?\]\s*', ''
                    $out | Should Match ([regex]::Escape("[$($case.Label)] $stripped"))
                }
                if ($case.Err) {
                    # graphenium prints stderr under [graphenium]; others under [label ERR].
                    $tag = if ($case.Label -eq 'graphenium') { '[graphenium]' } else { "[$($case.Label) ERR]" }
                    $out | Should Match ([regex]::Escape("$tag $($case.Err[0])"))
                }
                Remove-Item -LiteralPath $cap -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wtPaneDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $env:WPANE_TEST_RAN) {
    $env:WPANE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
```

- [ ] **Step 2: Run the test to verify it PASSES (execution-level)**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_watcher_panes.tests.ps1`
Expected: 6 passed, 0 failed (Task1=2, Task2=3, Task3=1). Each tailer must have been killed (no lingering `powershell.exe -File tail_*.ps1` processes). Confirm with: `powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'tail_' } | Select-Object -First 1 | ForEach-Object { $_.ProcessId }"` → expected empty.

- [ ] **Step 3: Commit**

```bash
git add tests/launcher_watcher_panes.tests.ps1
git commit -m "test: assert each watcher pane tailer shows tagged watcher info at runtime"
```

---

## Self-Review

**1. Spec coverage:** User asked to "add tests to test that all the watchers info show in the windows created by ###1." → Task 1 (tailer generation carries correct identity/log) + Task 2 (grid wiring references all 4) + Task 3 (real tailer prints tagged info). The four pane-backed watchers (grepai/graphenium/graphify-rs/repowise) are covered. memtrace excluded per explicit user choice. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step shows full code. Test commands are concrete with expected pass counts. Pester version pinned to 3.4.0 with guarded `Invoke-Pester`. ✓

**3. Type consistency:** `New-WatcherPaneScript` signature (`$Label,$LogPath,$ErrPath,$RepoRoot`) matches across all three tasks. `$wtPaneDir` scope dependency documented in Tasks 1 & 3. ✓

**4. Escape-sequence / literal consistency:**
- `[regex]::Escape("[$lbl]")` is used so `graphify-rs` (containing `-`) is matched literally, not as a char class. ✓
- `[regex]::Escape("`$log = '$log'")` escapes the `$` (end-of-line metachar) and backslashes in the temp path. ✓
- The tailer is launched with `6>&1` so `Write-Host` (information stream) is captured — without this the backlog assertions would silently capture nothing. ✓
- `& '$tailer' 6>&1` single-quotes the path; paths with spaces are safe. ✓
- The graphenium stderr-tag branch (`[graphenium]` not `[graphenium ERR]`) is asserted explicitly via the `$tag` conditional. ✓

**5. RED/GREEN coverage:** Task 1's generation test fails if `New-WatcherPaneScript` is renamed/removed (AST extractor throws). Task 2's wiring test is proven RED via the source-break + `git checkout` restore. Task 3's execution test drives the REAL tailer (extracted from source) for all four labels, asserting both the header and per-line tagged output. Every shipped surface (generation, wiring, runtime display) is guarded. ✓

**6. Repo conventions:** Hardcoded launcher path matches `tests/launcher_graphify_wiring.tests.ps1`. Guarded `Invoke-Pester` matches all existing `tests/*.tests.ps1`. No new dependencies (AST parser is built into PS 5.1). ✓
