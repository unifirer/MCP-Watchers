# Defect: launcher is workspace-keyed but script-rooted

**Found:** 2026-09-18 08:35
**Launcher:** `J:\audio\MCP-Watchers\###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`
**Severity:** blocks the stated requirement "the script must be able to run in multiple repos
simultaneously". Locks/windows/sweeps are correctly keyed; repository rooting is NOT.

## Symptom (observed, not inferred)

Launched the MCP-Watchers script with `-WorkingDirectory J:\audio\VAD` (PID 80120).

Result written to `%LOCALAPPDATA%\watchers\77442b14\teardown-state.json`:

```json
{"RootPids":[75652,14952,57980],"RepoRoot":"J:/audio/MCP-Watchers",
 "MemtraceStatePath":"J:\\audio\\MCP-Watchers\\.memdb\\daemon-state.json",
 "WtWindowName":"vadwatchers-77442b14","GrepaiPid":40548}
```

- `WtWindowName` = `vadwatchers-77442b14` → **correct**, VAD key derived from cwd.
- `RepoRoot` = `J:/audio/MCP-Watchers` → **WRONG**, should be `J:/audio/VAD`.
- `MemtraceStatePath` → **WRONG**, points at MCP-Watchers' `.memdb`.

Corroboration: `J:\audio\MCP-Watchers\.memdb\autoheal.log` has mtime `Sep 18 08:30` —
written by that run. `J:\audio\VAD\.memdb\autoheal.log` last changed `07:27`.

So a run that identifies as the VAD workspace nonetheless watches, heals and records
against MCP-Watchers.

## Root cause

Line 2631:
```powershell
$script:memtraceGitRoot = git -C "$scriptDir" rev-parse --show-toplevel 2>$null
if (-not $script:memtraceGitRoot) { $script:memtraceGitRoot = $scriptDir }
```
`$scriptDir` = folder holding the .ps1. `$watchersWorkspaceRoot` = operator's cwd.
The line uses the former where the latter is meant.

`$script:memtraceStateFile` (line 2633) derives from it, and `teardown-state.json`
carries both (lines 4236-4237).

## Scale

50 references to `$scriptDir` in the launcher. Legitimate uses are module/asset paths
that MUST come from the script folder:

- 32, 61, 69, 72, 78 — `Join-Path $scriptDir 'Modules\...'`
- 2549, 2553 — `dev_tools\graphify-watch-wrapper.ps1` (the wrapper script itself)
- 587, 1823 — default parameter values

Repository-scoped uses that should be `$watchersWorkspaceRoot`:

| Line | Use |
|---|---|
| 645, 792 | `.grepai` dir discovery (grepai index) |
| 752, 968, 989 | `git rev-parse` repo detection |
| 1080, 1119, 1754 | `-WorkingDirectory` for spawned children |
| 1573, 1577 | supervisor `ArgumentList` (grepai) |
| 2062 | `litellm_config.yaml` |
| 2356 | `.env` import |
| 2440 | `$script:gmFsw.Path` (filesystem watcher root) |
| 2538, 2540 | gm semantic build `ArgumentList` |
| 2554 | graphify wrapper `-WorkingDirectory` |
| 2631, 2632 | `memtraceGitRoot` — **the confirmed defect** |
| 2865, 2867 | memtrace daemon job |
| 3082, 3084 | cerememory job |
| 3237, 3239 | claude-mcp job |
| 3330, 3332 | mail-mcp job |

Not all are certainly wrong: the persistent singletons (:8420, :8080, :8765) are
machine-wide by design, so passing `$scriptDir` to them may be harmless. Each needs
individual review. The memtrace/`.grepai`/`gmFsw`/`env` ones are clearly repository-scoped.

## What PASSES (verified)

- Deterministic gate: 158 pass, 0 fail, 8/8 suites EXIT=0.
- Key derivation from cwd: VAD cwd → `77442b14`, MCP cwd → `ad90e3fb`.
- Simultaneous run: PID 80120 (VAD cwd) + PID 89424 (MCP cwd) both alive at once,
  separate keyed lock files, neither killed the other.
- Teardown isolation: killing MCP (89424) left VAD (80120) alive with its lock intact.

## Shortcut defect (separate, same class)

`J:\audio\VAD\###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1 - Shortcut.lnk`

```
TargetPath       : J:\audio\MCP-Watchers\###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
WorkingDirectory : J:\audio\MCP-Watchers      <-- should be J:\audio\VAD
```

Target is correct; **Start-in is wrong**. As configured it would derive the MCP key and
watch MCP-Watchers — VAD never watched, while appearing to succeed.

## Live run log — three further findings

The stage-1 run captured full stdout (`temp\repotest-vad-out-2026-09-18.txt`, 3626 b).
It completed a real launch: lock gate cleared, grepai/litellm/graphenium/graphify-rs/
repowise started, all supervisors spawned, 4-pane grid opened.

Keying is threaded correctly (proven by the log path):
```
Starting litellm watch (... C:\Temp\vad-watchers\77442b14\watchers\litellm-proxy.log)
```
`77442b14` = VAD key, in the log path. ✅

### Finding 1 — defect confirmed in the run log (line 22)
```
Memtrace auto-heal supervisor spawned (job 22) - log: J:\audio\MCP-Watchers\.memdb\autoheal.log
```
Launched from VAD, the memtrace supervisor logged into **MCP-Watchers'** `.memdb`.
Independent confirmation of the `$scriptDir` defect.

### Finding 2 — MCP-Watchers is MISSING a file VAD has
```
WARNING: graphify-watch-wrapper.ps1 not found; falling back to graphify-rs watch.
```
- `J:\audio\VAD\dev_tools\graphify-watch-wrapper.ps1` — exists, 17,090 b (Sep 6)
- `J:\audio\MCP-Watchers\dev_tools\` — **directory does not exist**

The launcher degrades silently to plain `graphify-rs watch`, losing ignore-aware
watching. **This corrects the earlier "VAD holds no newer fixes" conclusion: it holds at
least this one asset, and MCP-Watchers lacks it.**

Broader: MCP-Watchers is a stripped extraction. Top-level dirs present in VAD but absent
from MCP-Watchers include `dev_tools/`, `UI/`, `@skills`, `!!!AUTO_SCRIPTS!!!`,
`!!!IMPORTANT PATCHES!!!`, plus `ARCHITECTURE.md`, `GLOBAL_ARCH.md`, `QUICK_START.md`,
`Setup_Dependencies.bat`.

### Finding 3 — auto-heal killed machine-wide persistent singletons
```
[cerememory AUTO-HEAL] killing stale daemon PID 44604 (cerememory holding port 8420...)
[claude-mcp-server AUTO-HEAL] killing stale daemon PID 88400 (node holding port 8080...)
```

| Port | PID before | State now | New PID |
|---|---|---|---|
| :8080 | 88400 | killed, relaunched | 92004 |
| :8420 | 44604 | killed, relaunched | 100732 |
| :8765 | 75788 | killed, relaunched | 104328 |

`watcher_patterns.ps1` marks these `Persistent = $true` with the comment
"backend singleton family, **never swept on takeover**". The auto-heal path does not
honour that marker — it swept them anyway.

Net effect was self-correcting (all three came back on the same ports), but it is a
transient outage of **machine-wide services shared with any other repo mid-session**.

Also observed: `:8003` is held by THREE PIDs (93596, 30052, 103144) — duplicate embed
proxies that should not coexist.

### Finding 4 — grid-probe warning
```
WARNING: [grid-probe] UNEQUAL QUARTERS detected - check these panes:
  grepai (50% x 50%), graphenium (50% x 50%), graphify-rs (50% x 50%), repowise (50% x 50%)
```
All four panes report the SAME 50% x 50%, yet the probe calls them unequal. Likely a
probe false positive, but it fires on every launch and will train operators to ignore it.

## FIX APPLIED — 2026-09-18 08:40

### Changed to `$watchersWorkspaceRoot`
`.grepai` config read; `.grepai` dir; grepai index-health git root + dirs; worktree
validate/prune; both grepai `watch` spawns; `litellm_config.yaml` fallback; `.env` import;
`$script:gmFsw.Path`; gm semantic build repo arg (both job arms); graphify wrapper `-Repo`
and `-WorkingDirectory`; `$script:memtraceGitRoot` + fallback; memtrace job arg;
grepai crash-restart supervisor arg; `$tailGrepai -RepoRoot`.

`$tailGrepai` was the extra find: its three siblings already used the workspace root, so
the earlier "4/4 use `$watchersWorkspaceRoot`" claim was **wrong** — it was 3/4.

### Deliberately left on `$scriptDir`
`Modules\` dot-sources and asset paths; `dev_tools\graphify-watch-wrapper.ps1` (the wrapper
script location); cerememory / claude-mcp / mail job args (machine-wide ports
:8420/:8080/:8765 by design); graphiti-embed job; backend supervisor helper; the generic
spawner's `$psi.WorkingDirectory`; `$memtraceJobScript`'s internal `$ScriptDir` parameter.

### Wrapper restored
`dev_tools/graphify-watch-wrapper.ps1` copied from VAD into MCP-Watchers.
sha256 `6629c37b...7466fee` — byte-identical to source.

## VERIFICATION

| Check | Result |
|---|---|
| Parse check | PASS |
| 6 repository-scoped patterns use workspace root | all OK |
| Repository-scoped `$scriptDir` remaining | CLEAN |
| Deterministic gate re-run | **158 pass, 0 fail, 8/8 EXIT=0** |
| Live run from VAD — memtrace log path | `J:\audio\VAD\.memdb\autoheal.log` ✅ (was MCP's) |
| Live run from VAD — graphify wrapper | `Starting graphify-rs ignore-aware watcher` ✅ (was fallback) |

**Defect proven fixed** by the live memtrace log path, which before the fix wrote into
MCP-Watchers' `.memdb` and after the fix writes into VAD's.

Caveat stated plainly: no fresh `teardown-state.json` appeared within 120 s, so `RepoRoot`
was not *directly* re-observed. The `.memdb` log path is the evidence relied on.

## Still outstanding (not mine to change)
1. `J:\audio\VAD\###1.watchers... - Shortcut.lnk` — **WorkingDirectory is
   `J:\audio\MCP-Watchers`**, must become `J:\audio\VAD`. One field. Outside the repo.
2. The fix is **uncommitted**.
3. Pre-existing: hundreds of orphaned `pwsh.exe` from 17/09; auto-heal ignoring
   `Persistent=$true`; triple-bound `:8003`; grid-probe false positive.

## Verdict

The epic's literal acceptance criteria (keyed locks, distinct windows, no cross-repo
kill) are met and now have live proof. But the requirement "run in multiple repos
simultaneously" is NOT met end-to-end, because the repositories being watched, indexed,
healed and env-loaded still resolve from the script's own folder.

Fix belongs in the launcher: repository-scoped paths must resolve from
`$watchersWorkspaceRoot`, matching the key.
