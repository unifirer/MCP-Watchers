# graphify-rs Ignore-Aware Watcher (Option B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace graphify-rs's built-in `watch` (which fires a rebuild on changes under ignored paths like `graphenium-out`) with an external, ignore-aware PowerShell watcher that only rebuilds on real source edits, using only existing tooling (`graphify-rs`, `git`, PowerShell) — adding zero new binaries so a graphify-rs update cannot break it.

**Architecture:** A new `dev_tools/graphify-watch-wrapper.ps1` runs a `System.IO.FileSystemWatcher` on the repo root. Its event handler gates every change through `git check-ignore` (with a regex fallback to `.gitignore`/`.graphifyignore`) and, only for non-ignored changes, runs `graphify-rs build --path . --update --no-llm` — the same CLI AGENTS.md §3.3.3 already mandates. The launcher stops calling `Start-WatcherDetached … "watch" "--path" "."` for graphify-rs and instead launches the wrapper detached. The wrapper's own command line contains the token `watch` so the launcher's existing `Stop-WatcherOrphans`/dedup `CommandLine -match 'watch'` teardown (lines 363-374, 401-407) still kills it. Log output continues to `$graphifyLog` (outside the repo), so the 4-pane tailer needs no change.

**Tech Stack:** PowerShell 7 (pwsh.exe), .NET `System.IO.FileSystemWatcher`, `git check-ignore`, `graphify-rs build --update`. No new dependencies.

## Global Constraints

- **No new binaries:** the fix must use only `graphify-rs`, `git`, `powershell` — all already required by the launcher. (User's explicit requirement: a graphify-rs update must not break it; Option A `watchexec` was rejected for adding a second version surface.)
- **Use the mandated CLI:** rebuild via `graphify-rs build --path . --update --no-llm` (per AGENTS.md §3.3.3). The `Get-GraphifyRebuildArgs` helper returns this; a `--update` guard falls back to `graphify-rs build --path . --no-llm` if a future graphify-rs drops `--update`.
- **Output/log location unchanged:** graphify-rs output dir stays default `graphify-rs-out` (watcher auto-excludes it); the wrapper log stays at `$graphifyLog` = `$env:USERPROFILE\.graphify-rs\graphify-rs-watch.log` (already outside the repo, lines 289-291).
- **Teardown compatibility:** the wrapper process's CommandLine MUST contain the literal token `watch` so the existing kill filters (`$p.CommandLine -match 'watch'`, lines 366/403) still match it. Launch as `powershell -NoProfile -WindowStyle Hidden -File <wrapper> -WatchMode`.
- **Self-explanatory naming (user preference):** functions/vars use plain-English names; keep techie terms (stderr pipe, NUL) in code comments only.
- **Tests live in `tests/` (AGENTS.md §4.3);** plan saved to `docs/superpowers/plans/`.
- **Debounce:** coalesce bursts (e.g. an editor writing many files) into one rebuild per ~1.5s window, matching graphify-rs's prior 3s debounce behavior.
- **Pester version:** environment has **Pester 3.4.0**, NOT v5. Test files end with a guarded `Invoke-Pester` (env-var re-entrancy guard) and are run via `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/<file>.ps1`. Do NOT use `-EnableExit`, positional `-Path`, `BeforeAll`/`AfterAll`, or `InModuleScope`.

---

### Task 1: Extract and unit-test the ignore-gate decision  [COMPLETE — commit 590b837]

**Files:**
- Create: `modules/graphify_ignore_gate.ps1` (done)
- Create: `tests/graphify_ignore_gate.tests.ps1` (done)
- Test: `tests/graphify_ignore_gate.tests.ps1` (done, 4/4 passing)

**Interfaces (frozen — later tasks depend on these exact names/signatures):**
- `Test-PathIgnoredByGraphify -Repo <string> -RelativePath <string> [-GitExe <string>] -> <bool>` — `$true` if the path should be excluded from a rebuild.
- `Get-GraphifyRebuildArgs [-NoLlm] -> <string[]>` — returns `@('build','--path','.','--update','--no-llm')` on graphify-rs 0.8.1; falls back to `@('build','--path','.','--no-llm')` if `--update` unsupported.

Status: DONE. Review: SPEC ✅ / QUALITY approved.

---

### Task 2: Build the external watcher wrapper with debounced rebuild

**Files:**
- Create: `dev_tools/graphify-watch-wrapper.ps1`
- Test: `tests/graphify_watch_wrapper.tests.ps1`

**Interfaces:**
- Consumes: `Test-PathIgnoredByGraphify`, `Get-GraphifyRebuildArgs` (dot-sourced from `modules/graphify_ignore_gate.ps1`).
- Produces: a detached long-running process that writes rebuild lines to stdout (captured by `$graphifyLog`); CommandLine contains `-WatchMode` so teardown matches.

- [ ] **Step 1: Write the failing test** (Pester 3.4.0 idiom — ends with guarded `Invoke-Pester`; run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/graphify_watch_wrapper.tests.ps1`)

```powershell
# tests/graphify_watch_wrapper.tests.ps1
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\..\modules\graphify_ignore_gate.ps1"
. "$here\..\dev_tools\graphify-watch-wrapper.ps1" -ExportOnly   # defines funcs, does NOT start watcher

Describe 'Invoke-GraphifyChangeHandler' {
    AfterEach { if ($repo) { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue } }
    It 'triggers rebuild for a real source edit' {
        $repo = Join-Path $env:TEMP ("gf_wrap_test_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        $recorder = Join-Path $repo "rebuilds.log"; Set-Content -Path $recorder -Value ""
        Invoke-GraphifyChangeHandler -Repo $repo -ChangedPath (Join-Path $repo "src_real.py") -RecordTo $recorder
        (Get-Content $recorder).Count | Should BeGreaterThan 0
    }
    It 'skips rebuild for a change under graphenium-out' {
        $repo = Join-Path $env:TEMP ("gf_wrap_test_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "graphenium-out") -Force | Out-Null
        $r2 = Join-Path $repo "rebuilds2.log"; Set-Content -Path $r2 -Value ""
        Invoke-GraphifyChangeHandler -Repo $repo -ChangedPath (Join-Path $repo "graphenium-out\foo.txt") -RecordTo $r2
        (Get-Content $r2).Count | Should Be 0
    }
}

if (-not $env:GF_WRAP_TEST_RAN) { $env:GF_WRAP_TEST_RAN = '1'; Invoke-Pester }
```

- [ ] **Step 2: Run test to verify it fails**
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File J:\audio\VAD\tests\graphify_watch_wrapper.tests.ps1`
Expected: FAIL — `Invoke-GraphifyChangeHandler` not defined (wrapper not written yet).

- [ ] **Step 3: Write minimal implementation**

```powershell
# dev_tools/graphify-watch-wrapper.ps1
[CmdletBinding()]
param(
    [string] $Repo = $PSScriptRoot,
    [int]    $DebounceMs = 1500,
    [switch] $WatchMode,     # present -> actually start the FileSystemWatcher loop
    [switch] $ExportOnly     # present -> define functions, do NOT start watcher (for tests)
)
. (Join-Path $PSScriptRoot "..\modules\graphify_ignore_gate.ps1")

$script:graphifyLog = Join-Path $env:USERPROFILE ".graphify-rs\graphify-rs-watch.log"

# Records a rebuild decision; in WatchMode this actually calls graphify-rs.
function Invoke-GraphifyChangeHandler {
    param([string]$Repo, [string]$ChangedPath, [string]$RecordTo)
    $rel = $ChangedPath
    if ($rel.StartsWith($Repo)) { $rel = $rel.Substring($Repo.Length).TrimStart('\','/') }
    if (Test-PathIgnoredByGraphify -Repo $Repo -RelativePath $rel) {
        return   # ignored path: do NOT rebuild
    }
    if ($RecordTo) { Add-Content -LiteralPath $RecordTo -Value "REBUILD $rel" }
    if ($script:WatchMode) {
        $args = Get-GraphifyRebuildArgs -NoLlm
        & graphify-rs @args 2>&1 | Out-File -Append -LiteralPath $script:graphifyLog
    }
}

function Start-GraphifyWatchLoop {
    param([string]$Repo, [int]$DebounceMs)
    $last = $null
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $Repo
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::FileName
    $action = {
        $p = $Event.SourceEventArgs.FullPath
        $now = Get-Date
        if ($null -eq $script:last -or (($now - $script:last).TotalMilliseconds -ge $DebounceMs)) {
            $script:last = $now
            Invoke-GraphifyChangeHandler -Repo $Repo -ChangedPath $p
        }
    }
    Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $action | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action | Out-Null
    $watcher.EnableRaisingEvents = $true
    Add-Content -LiteralPath $script:graphifyLog -Value "Watching $Repo for changes (ignore-aware)..."
    while ($true) { Start-Sleep -Seconds 1 }   # keep the detached process alive
}

if ($WatchMode -and -not $ExportOnly) {
    Start-GraphifyWatchLoop -Repo $Repo -DebounceMs $DebounceMs
}
```

- [ ] **Step 4: Run test to verify it passes**
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File J:\audio\VAD\tests\graphify_watch_wrapper.tests.ps1`
Expected: PASS (2 passed) — source edit records a rebuild; `graphenium-out` edit records nothing.

- [ ] **Step 5: Commit**
```bash
git add dev_tools/graphify-watch-wrapper.ps1 tests/graphify_watch_wrapper.tests.ps1
git commit -m "feat(graphify): add ignore-aware FileSystemWatcher wrapper with debounce + tests"
```
(Note: git commit is slow here due to a hook — use a long timeout; the commit lands even if the first attempt's output is swallowed by a 60s timeout.)

---

### Task 3: Wire the wrapper into the launcher (replace `watch`)

**Files:**
- Modify: `###1. updater grepai graphenium graphify-rs repowise.ps1:557` (graphify-rs launch line)
- Test: `tests/launcher_graphify_wiring.tests.ps1` (headless: grep the launcher file)

**Interfaces:**
- Consumes: `dev_tools/graphify-watch-wrapper.ps1` (launched detached).
- Produces: graphify-rs now rebuilds only on non-ignored changes; teardown still kills it via the `watch` token.

- [ ] **Step 1: Write the failing test** (Pester 3.4.0 idiom — ends with guarded `Invoke-Pester`; run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_graphify_wiring.tests.ps1`)

```powershell
# tests/launcher_graphify_wiring.tests.ps1
$launcher = 'J:\audio\VAD\###1. updater grepai graphenium graphify-rs repowise.ps1'

Describe 'graphify-rs launch wiring' {
    It 'no longer launches graphify-rs with the bare "watch" subcommand' {
        $c = Get-Content -LiteralPath $launcher
        ($c | Where-Object { $_ -match 'Start-WatcherDetached.*graphify-rs.*"watch"' }) | Should BeNullOrEmpty
    }
    It 'launches the wrapper with -WatchMode (so teardown -match "watch" still matches)' {
        $c = Get-Content -LiteralPath $launcher
        ($c | Where-Object { $_ -match 'graphify-watch-wrapper.ps1' -and $_ -match '-WatchMode' }) | Should -Not BeNullOrEmpty
    }
}

if (-not $env:GF_WIRE_TEST_RAN) { $env:GF_WIRE_TEST_RAN = '1'; Invoke-Pester }
```

- [ ] **Step 2: Run test to verify it fails**
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File J:\audio\VAD\tests\launcher_graphify_wiring.tests.ps1`
Expected: FAIL — line 557 still calls `Start-WatcherDetached … "watch"`.

- [ ] **Step 3: Write minimal implementation** — replace line 557:

```powershell
# OLD: Start-WatcherDetached "graphify-rs" "graphify-rs" @("watch", "--path", ".")          $graphifyLog
# NEW: external ignore-aware watcher (replaces graphify-rs's own `watch`, which fired rebuilds
# on ignored paths like graphenium-out). The wrapper's CommandLine carries -WatchMode so the
# existing Stop-WatcherOrphans / dedup `CommandLine -match 'watch'` teardown still kills it.
$graphifyWrapper = Join-Path $scriptDir "dev_tools\graphify-watch-wrapper.ps1"
if (Test-Path -LiteralPath $graphifyWrapper) {
    Write-Host "Starting graphify-rs ignore-aware watcher (detached, logging to $graphifyLog)..."
    $wp = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-File", "`"$graphifyWrapper`"", "-WatchMode", "-Repo", "`"$scriptDir`"") `
        -WorkingDirectory $scriptDir -WindowStyle Hidden `
        -RedirectStandardOutput $graphifyLog -RedirectStandardError "$graphifyLog.err" -PassThru
    if ($wp) { $script:childProcs += $wp }
    Write-Host "graphify-rs ignore-aware watcher launched (detached, log only)."
} else {
    Write-Warning "graphify-watch-wrapper.ps1 not found; falling back to graphify-rs watch."
    Start-WatcherDetached "graphify-rs" "graphify-rs" @("watch", "--path", ".") $graphifyLog
}
```
Also update the stale comment at line 560 (`# (graphify-rs watch is launched detached + logged above…)`) → `# (graphify-rs ignore-aware wrapper is launched detached + logged above, replacing graphify-rs watch)`.

- [ ] **Step 4: Run test to verify it passes**
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File J:\audio\VAD\tests\launcher_graphify_wiring.tests.ps1`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**
```bash
git add '###1. updater grepai graphenium graphify-rs repowise.ps1'
git commit -m "feat(launcher): replace graphify-rs watch with ignore-aware wrapper"
```

---

### Task 4: End-to-end verification against a scratch repo

**Files:**
- Test: `tests/graphify_e2e.tests.ps1` (spins up the real wrapper detached on a scratch repo, edits two files, asserts only the source edit produces a rebuild line in the log; uses a stubbed `graphify-rs` on PATH that appends to a marker file).

**Interfaces:**
- Consumes: `dev_tools/graphify-watch-wrapper.ps1`, `modules/graphify_ignore_gate.ps1`.

- [ ] **Step 1: Write the failing test** (Pester 3.4.0 idiom — ends with guarded `Invoke-Pester`)

```powershell
# tests/graphify_e2e.tests.ps1
$repo = $null; $stubDir = $null; $marker = $null; $wrapLog = $null
Describe 'e2e ignore-aware watcher' {
    AfterEach {
        if ($repo)    { Remove-Item -LiteralPath $repo    -Recurse -Force -ErrorAction SilentlyContinue }
        if ($stubDir) { Remove-Item -LiteralPath $stubDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'rebuilds on real source edit, NOT on graphenium-out edit' {
        $repo = Join-Path $env:TEMP ("gf_e2e_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo "graphenium-out") -Force | Out-Null
        $stubDir = Join-Path $env:TEMP ("gf_stub_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
        $marker = Join-Path $stubDir "invoked.log"
        Set-Content -Path (Join-Path $stubDir "graphify-rs.cmd") -Value "@echo off`necho %* >> `"$marker`""
        $wrapLog = Join-Path $env:TEMP ("gf_wraplog_" + [guid]::NewGuid().ToString("N") + ".log")
        $env:PATH = "$stubDir;$env:PATH"   # stub graphify-rs shadows the real one for this process tree

        $psi = Start-Process -FilePath "powershell.exe" -PassThru -WindowStyle Hidden `
            -ArgumentList @("-NoProfile","-File","""J:\audio\VAD\dev_tools\graphify-watch-wrapper.ps1""","-WatchMode","-Repo","""$repo""")
        Start-Sleep -Seconds 2
        Set-Content -Path (Join-Path $repo "real.py") -Value "x"
        Start-Sleep -Seconds 3
        Set-Content -Path (Join-Path $repo "graphenium-out\foo.txt") -Value "y"
        Start-Sleep -Seconds 3
        $psi | Stop-Process -Force -ErrorAction SilentlyContinue

        $builds = (Get-Content $marker -ErrorAction SilentlyContinue | Where-Object { $_ -match 'build' }).Count
        $builds | Should BeGreaterThan 0
        (Get-Content $marker | Where-Object { $_ -match 'graphenium-out' }) | Should BeNullOrEmpty
    }
}

if (-not $env:GF_E2E_TEST_RAN) { $env:GF_E2E_TEST_RAN = '1'; Invoke-Pester }
```

- [ ] **Step 2: Run test to verify it fails (before wiring)**
The e2e only passes once Task 3 wired the real wrapper with `-WatchMode`; run after Task 3.

- [ ] **Step 3: Run test to verify it passes**
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File J:\audio\VAD\tests\graphify_e2e.tests.ps1`
Expected: PASS — `build` invoked ≥1 time, and zero invocations reference `graphenium-out`.

- [ ] **Step 4: Commit (if any fixture tweaks were needed)**
```bash
git add tests/graphify_e2e.tests.ps1
git commit -m "test(graphify): e2e proves ignore-aware rebuild (no graphenium-out rebuild)"
```

---

## Self-Review

**1. Spec coverage:** Goal (ignore-aware watcher, no new binary) → Tasks 1-3. Tests → all four tasks have execution-level Pester tests (gate unit, handler logic, launcher wiring grep, e2e with stubbed graphify-rs). Teardown compatibility (`watch` token) → Task 3 step 3 + wiring test. Debounce → Task 2. `--update` fallback guard → Task 1 `Get-GraphifyRebuildArgs`. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; test commands are concrete with expected PASS/FAIL. Pester version pinned to 3.4.0 with guarded `Invoke-Pester`. ✓

**3. Type consistency:** `Test-PathIgnoredByGraphify -Repo -RelativePath` (Task 1) matches its use in Task 2 `Invoke-GraphifyChangeHandler`; `Get-GraphifyRebuildArgs -NoLlm` matches Task 2/3; `Invoke-GraphifyChangeHandler -Repo -ChangedPath -RecordTo` matches Task 2 test. Wrapper launch uses `-WatchMode`/`ExportOnly` params consistently. ✓

**4. Feature-parity audit:** Existing graphify behavior preserved — rebuild still writes to `$graphifyLog` (outside repo), 4-pane tailer untouched (same log path), dedup/teardown still functions via `watch` token. `Resolve-ChangedFiles` (lines 698-735) remains for the tailer's *display* of user files; it was never the rebuild trigger, so no regression. ✓
