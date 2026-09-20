# mcpw-ajy — orphan sweep misses `node.exe memtrace.js` leaks

Date: 2026-09-20
Bead: mcpw-ajy (P2, BUG)
Branch: `mcpw-sweep-20260920-1305`

## Defect

The mcpw-anw orphan sweep matched only `powershell.exe` / `pwsh.exe` hosts whose
command line named the npm **shim** (`memtrace.ps1`). Current builds launch an
absolute `node.exe` + `memtrace.js`, so the leak shape was invisible to it:
~46 `node.exe ... memtrace.js start --headless --bless-workspace` orphans, one
per 5-minute tick from 2026-09-19 23:19, removed by hand during mcpw-l40.

## Remedy

Matching is now a set of pure, unit-testable functions in
`Modules/watcher_teardown.ps1` (the module the launcher already dot-sources at
its line 61, before the sweep call at its line 3620):

| function | role |
| --- | --- |
| `Test-MemtraceDaemonAnchor` | is one process a member/root of the shared daemon tree? |
| `Test-OrphanedMemtraceHostProcess` | pure matcher over a process snapshot |
| `Get-OrphanedMemtraceHostPids` | snapshot + matcher → victim PIDs |
| `Stop-OrphanedMemtraceHosts` | adds the `:50051` guard, then reaps |
| `Get-MemtraceDaemonProtectedPids` | every daemon binary + the `:50051` owner |

### The live-daemon-tree exclusion (safety requirement)

A candidate is swept only when **all** hold:

1. image name ∈ `powershell.exe` / `pwsh.exe` / `node.exe`, and the command line
   names `memtrace.ps1` **or** `memtrace.js`;
2. the **immediate parent is gone**, with a PID-reuse guard — a "parent" whose
   `CreationDate` is LATER than the child's is a reused PID, not a parent;
3. it is **not inside a live daemon tree**.

Condition 3 uses a **daemon anchor**, defined as either

* a daemon binary — `memcore-server.exe` / `memcortex-daemon.exe` /
  `memtrace.exe`, or
* a `node.exe` naming `memtrace.js` **and** carrying a real `--workspace` token
  (`(^|\s)--workspace(\s|=|-|$)`).

The token regex is what keeps the two launch forms apart: the canonical union
form is `start --headless --workspace <manifest>`, while the leaked legacy form
is `start --headless --bless-workspace` — and `--bless-workspace` does **not**
contain the token `--workspace` (the two dashes are interrupted by `bless`).

A candidate is excluded when it **is** an anchor, when its **live parent is** an
anchor (a daemon ancestor is necessarily that live parent), or when **any
descendant** is an anchor — an orphaned `node.exe` that still owns a live
`memcore-server.exe` subtree *is* the live daemon, and killing it is the outage
this guard exists to prevent. The entry point additionally protects the current
`:50051` LISTEN owner, so the invariant holds even if a daemon binary is
renamed.

Missing `CreationDate` and an unreadable snapshot fail **safe** (treated as not
an orphan → never killed).

## Evidence (measured on this box, 2026-09-20)

`C:/Temp/ajy_proof.txt` — 1047 processes, `:50051` owner 62980:

```
NEW_RULE_victims=0 []
OLD_RULE_victims=0 []                       <- the old rule is blind to the new shape
NAIVE_EXTENSION_victims=4 [22640,70304,80840,83612]   <- parent-gone-only would kill these
  NAIVE-HIT 22640 : node.exe ...\memtrace.js start --headless --workspace C:\Users\yuni\.config\memtrace\workspace.toml
  ... (all four carry --workspace)
ANCHORS=8 [22640,43748,62980,70304,76648,80840,83612,89040]
ANCHOR_INTERSECT_NEW=0
```

The four `NAIVE_EXTENSION` victims had **dead parents**
(34376/37864/61784/66016 all gone) yet are live members of the union daemon
family. This is the trap the guard closes, and it is measured, not assumed.

`C:/Temp/ajy_e2e.txt` — real-process end-to-end (a probe `node.exe` running a
harmless file literally named `memtrace.js`, orphaned by an intermediary that
exits):

```
probeHostPid=85084 parentAlive=False
sweepFindsProbe=True  totalVictims=1 [85084]
anchorIntersectVictims=0  anchors=8
reaped=1
probeStillAlive=False
daemon50051Before=62980  daemon50051After=62980  sameOwner=True
daemonOwnerStillAlive=True
```

## Test results

`python dev_tools/run_pester_suite.py tests/launcher_memtrace_orphan_sweep.tests.ps1`
→ **14 of 14 tests passed**.

Regression suites re-run (all green):

| suite | result |
| --- | --- |
| `tests/launcher_memtrace_orphan_sweep.tests.ps1` (new) | 14 of 14 |
| `tests/launcher_memtrace_heal.tests.ps1` | 5 of 5 |
| `tests/launcher_watcher_teardown.tests.ps1` | 14 of 14 |
| `tests/launcher_watcher_teardown_sweep.tests.ps1` | 3 of 3 |

Note: `launcher_memtrace_heal.tests.ps1` dot-sources the module at its line 49,
**after** extracting the launcher's inline copies, so the module definitions now
back that suite (its log line reads `mcpw-ajy: reaped 1 orphaned memtrace
host(s)`). That is intended — it is the same sweep, relocated.

## DEFERRED launcher diff (not applied — mcpw-gsj file ownership)

File: `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`
Owner this wave: another agent. The launcher defines both functions **locally**,
which shadows the module's versions, so the fix does not take effect until the
local copies are deleted.

**Delete lines 3569–3615 inclusive** (the `# mcpw-anw (2026-09-18):` comment
block at 3569–3584, `function Get-OrphanedMemtraceHostPids { ... }` at
3585–3602, and `function Stop-OrphanedMemtraceHosts { ... }` at 3604–3615),
leaving the blank line 3616.

Before (line 3604):
```powershell
function Stop-OrphanedMemtraceHosts {
    param([string]$ShimPattern = 'memtrace\.ps1')
    $victims = @(Get-OrphanedMemtraceHostPids -ShimPattern $ShimPattern)
    ...
}
```

After: *the block is removed*; the module's `Stop-OrphanedMemtraceHosts` is
found because `Modules\watcher_teardown.ps1` is dot-sourced at line 61.

**The call site needs no change.** Line 3620 stays exactly:

```powershell
Stop-OrphanedMemtraceHosts | Out-Null
```

`Stop-OrphanedMemtraceHosts` keeps the same name and the no-argument call shape.
Its old `-ShimPattern` parameter is replaced by `-ShimPatterns` (array,
defaulting to both `memtrace\.ps1` and `memtrace\.js`); the only caller passes
no arguments, so nothing else breaks.

Follow-up for that wave: `tests/launcher_memtrace_heal.tests.ps1` lines 44–45
call `Get-LauncherFunctionText -Name 'Get-OrphanedMemtraceHostPids'` /
`'Stop-OrphanedMemtraceHosts'`, which throws "expected exactly 1 definition"
once the launcher copies are gone. Those two lines become redundant (the module
is already dot-sourced at line 49) and should be deleted in the same change.

## Changed paths

* `Modules/watcher_teardown.ps1` — modified (append-only; 5 new functions)
* `tests/launcher_memtrace_orphan_sweep.tests.ps1` — new
* `reports/2026-09-20-mcpw-ajy-orphan-sweep-nodejs.md` — new (this file)

Nothing else was edited. No `git add` / `git commit` / `git checkout` was run;
the tree is left dirty.

## Note on the git index casing

The bead flagged `modules/watcher_teardown.ps1` lower-case vs its `Modules/`
siblings. `git ls-files -s` shows a single entry `Modules/watcher_teardown.ps1`
and `core.ignorecase=true`, so there is no case-duplicate in the index; only the
in-file header comment (line 1) is lower-case. No action needed.
