# mcpw-rkg.3 - wire the bootstrap module into the ###1 launcher

Date: 2026-09-20
Branch: `mcpw-sweep-20260920-1305`
File changed: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`
Status: edits left DIRTY (not committed, not staged) - another process owns the index.

## What was done

Two edits, nothing else. The launcher parses with 0 errors after both.

### Edit 1 - dot-source the module (lines 81-89)

Inserted into the existing module block, after the `watcher_pane_scripts.ps1`
load and after the `$watchersWorkspaceRoot` assignment (line 23), using the
file's established guarded-load pattern so a MISSING module degrades instead of
aborting the launch:

```powershell
$watcherMcpBootstrapModule = Join-Path $scriptDir 'Modules\watcher_mcp_bootstrap.ps1'
if (Test-Path -LiteralPath $watcherMcpBootstrapModule) { . $watcherMcpBootstrapModule }
```

The module is self-contained: it dot-sources `watcher_mcp_detect.ps1` itself
(module line 97, same guard), so the launcher does not need to load detect first.

### Edit 2 - call it before the first watcher spawns (lines 1319-1356)

Placed immediately before the `if (-not $grepaiOk) {` grepai-watch spawn block.
That spawn (now line ~1409) is the FIRST watcher the launcher starts - verified
by reading the file: the only earlier `Start-Process` is the `ollama serve`
prerequisite, which is not a watcher.

```powershell
if (Get-Command Invoke-McpBootstrapForRepo -ErrorAction SilentlyContinue) {
    Write-Host "[bootstrap] initializing the six watched MCPs for $watchersWorkspaceRoot before any watcher spawns (this can take minutes on a fresh index)..."
    try {
        $mcpBoot = Invoke-McpBootstrapForRepo -Path $watchersWorkspaceRoot
        $mcpRows = @($mcpBoot.Results)
        $mcpTally = ($mcpRows | ForEach-Object { "$($_.Mcp)=$($_.Status)" }) -join ' '
        Write-Host ("[bootstrap] done {0}, stamped {1}, skipped {2} of {3}: {4}" -f `
            $mcpBoot.Done, $mcpBoot.Stamped, $mcpBoot.Skipped, $mcpBoot.Total, $mcpTally)
        foreach ($mcpRow in @($mcpRows | Where-Object { $_.Status -eq 'skipped' })) {
            Write-Host ("[bootstrap] {0} skipped: {1}" -f $mcpRow.Mcp, $mcpRow.Reason)
        }
    } catch {
        Write-Warning "MCP bootstrap failed: $($_.Exception.Message). Continuing - each watcher below degrades on its own."
    }
} else {
    Write-Host "[bootstrap] Modules\watcher_mcp_bootstrap.ps1 not loaded - skipping MCP init (watchers start uninitialized)."
}
```

Hard requirements, each with a test:

| Requirement | How it is satisfied |
| --- | --- |
| init completes before ANY watcher spawns | call at line 1340, first watcher spawn at line ~1409; asserted by line index |
| a failure must not abort | `Get-Command` guard + `try/catch` + no `exit`/`throw` in the block; asserted |
| repo-agnostic | `-Path $watchersWorkspaceRoot`; no `X:\` literal in the block; asserted |
| no refactor beyond two edits | diff is two insertions; nothing else in the file changed |

## Test results

| Suite | Result |
| --- | --- |
| `tests/mcpw_rkg3_launcher_bootstrap.tests.ps1` (new, 8 `It`) | **8 of 8 passed** |
| `tests/mcpw_rkg4_grepai_first_scan.tests.ps1` (new, 9 `It`) | **9 of 9 passed** |
| `tests/launcher_watcher_panes.tests.ps1` | **7 of 7 passed** |
| `tests/launcher_watcher_teardown.tests.ps1` | **14 of 14 passed** |
| `tests/launcher_mcp_bootstrap.tests.ps1` | **13 of 13 passed** |
| `tests/launcher_pane_heal_idle.tests.ps1` (the mcpw-6re suite) | **6 of 6 passed** |

Run with `python dev_tools/run_pester_suite.py <file>`; Pester 6.1.0 for the new
suites, 3.4.0 / file-picked for the legacy ones. No `[-]` lines in any run.

## RISK to hand to the module owner (I must not edit `Modules/`)

**Measured, and it is a real startup regression: the grepai step of
`Invoke-McpBootstrapForRepo` blocks the launcher for the full
`-FirstScanTimeoutMs` (default 900000 ms = 15 minutes) on EVERY launch, and
`.mcpw-bootstrap/state.json` does not exist yet in this repo, so the first
launch after this bead lands WILL pay it.**

Why:

1. `Initialize-GrepaiForRepo` runs `grepai watch --no-ui` in the foreground. A
   foreground `watch` is a DAEMON - it never exits on its own - so
   `$r2.TimedOut` is always true and the step always falls through to the
   status probe.
2. The status probe's predicate is `Files indexed > 0`. **Measured on this repo
   today: `grepai status` reports `Files indexed: 0` while `Total chunks: 1264`
   and the watcher log says `Initial scan complete: 160 files indexed, 1249
   chunks created (took 4m34.08s)`.** The counter is not populated by this
   grepai build, so the predicate can never be satisfied here.
3. So the step returns `skipped`, and **the `skipped` path returns before
   `Set-McpBootstrapStamp`** - no stamp. `Start-McpBootstrapStep` short-circuits
   on the stamp at the top, so with no stamp every launch re-runs the whole
   15-minute scan attempt.

Recommended module diff (for `mcpw-rkg.2`, NOT applied - I do not own the file):

```diff
-        $m = [regex]::Match($text, 'Files indexed\s*:\s*(\d+)')
-        if ($m.Success) { $indexed = [int]$m.Groups[1].Value }
-        if ($indexed -gt 0) {
+        $m = [regex]::Match($text, 'Files indexed\s*:\s*(\d+)')
+        if ($m.Success) { $indexed = [int]$m.Groups[1].Value }
+        # mcpw-rkg.4: `Files indexed` is NOT a usable completion predicate on a
+        # repo where this grepai build never populates it (measured 2026-09-20:
+        # 0 files, 1264 chunks, log "Initial scan complete: 160 files indexed").
+        # grepai's own scan-complete log line is authoritative.
+        $scanComplete = $indexed -gt 0
+        if (-not $scanComplete) {
+            $logDir = Join-Path $env:LOCALAPPDATA 'grepai\logs'
+            foreach ($lg in @(Get-ChildItem -Path $logDir -Filter 'grepai-worktree-*.log' -ErrorAction SilentlyContinue)) {
+                if ($lg.LastWriteTime -lt (Get-Date).AddMinutes(-2)) { continue }
+                if (Select-String -LiteralPath $lg.FullName -Pattern 'Initial scan complete' -Quiet) { $scanComplete = $true; break }
+            }
+        }
+        if ($scanComplete) {
```

With that, the step returns `done` and stamps, so the 15-minute cost is paid
once per repository instead of once per launch. The residual cost - one 15-minute
block on the first launch of a fresh repo - is the module's intended "Phase
'index' - minutes" and is acceptable; bead mcpw-rkg.4 now guarantees that the
scan the WATCHER runs afterwards cannot be killed by the idle TTL.

A second, smaller interaction worth noting: the bootstrap's foreground
`grepai watch` is killed at the timeout by `Invoke-McpBootstrapCommand`, and
grepai's single-instance lock is machine-global. If a stale `.pid`/`.pid.lock`
survives that kill, the launcher's own watcher spawn (mcpw-ozm's lock gate) could
refuse it. The supervisor's `Clear-StaleLocks` recovers, but the module owner
should consider clearing the lock after a timed-out scan step.

## Ordering note

The bootstrap call sits BEFORE the `ollamaGateJob` join (line ~1509). The Ollama
probe/spawn itself runs synchronously earlier, so the embedder has at least been
started, but readiness is not yet confirmed at that point. If the grepai scan
step ever reports an unreachable embedder, that is the reason; it degrades to a
`skipped` row and does not abort the launch.

## Files

- modified: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1` (lines 81-89, 1319-1356)
- new: `tests/mcpw_rkg3_launcher_bootstrap.tests.ps1`
- new: `reports/2026-09-20-mcpw-rkg3-launcher-bootstrap.md`
