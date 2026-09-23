# MCP-Watchers — curated project notes
Durable facts only. Narrative → daily logs `YYYY-MM-DD.md`. Sandbox/PS/deletion quirks → `~/.workbuddy-ai/MEMORY.md`.
Per-tool + stack detail (Graphiti/Memtrace/Repowise/Heimdall/gm/graft/declick/bd/mnemosyne, Toolport gateway
logs, LLM-proxy routing, extraction history, git-DB recovery, docker/ports) → **`MEMORY-mcp-stack.md`** (~20 KB, read on demand).
**Keep this file small — it truncates at injection past ~10 KB.** Compacted 2026-09-22.

## Watchers: markers, keys, panes
- Markers `%LOCALAPPDATA%\watchers\<key>\`: `.lock`, `.sup`, `.idle` (idle-reaped — must not heal). Panes `C:\Temp\vad-watchers\<key>\panes\`; logs `...\watchers\*.log{,.err}`. Keys VAD=`77442b14`, MCP=`ad90e3fb`.
- Supervisor in `###1...ps1` heals while launcher lives; 5 failed restarts → sleeps 10 min but keeps refreshing `.sup`. "supervised restart pending..." = a live supervisor owns the retry, not stuck.
- Pane exit rule (`watcher_pane_scripts.ps1:806-813`): graphenium/graphify-rs/repowise `deadTicks++`; 60 ticks (~30 s) → "watcher exited - closing pane" + `exit 0`. grepai parks on `[IDLE - WAITING FOR QUERIES]` (:782-795), never exits. heimdall branch ~:872. Unknown labels exit immediately (T18-locked).
- Grid is **3x2**: row1 grepai|graphenium|graphify-rs, row2 repowise|codegraph|**heimdall** (was reserved `empty`). The 6th cell MUST run a BLOCKING tailer or Windows Terminal closes it and the other five re-flow.
- `###1.watchers_for_...bat` has no `cd` → run from the repo you want keyed. Opens Windows Terminal — get go-ahead first.
- **Exactly ONE supervised starter per daemon** (memtrace flap, ~85 s): heal loop + Toolport proxy both re-daemonising = death. Applies to memtrace, graft, repowise, heimdall.
- **heimdall's backend is Graft**, not "graftd" (only Graft's daemon binary). Three "graft" names but only **two** programs (verified 2026-09-22): (1) the npm **`@nanonets/graft` CLI v0.18.0** (Node; `build`/`ask`/`mcp`/…, **no `daemon`**) — this repo's `graft/` dir and the Toolport server id `graft` are *this same program*; (2) **heimdall's backend Graft** — a separate **C/CMake** subtree `vendor/graft/` (fork of NanoNets/Graft, Apache 2.0) that builds `graftd.exe`. Same vendor name, different codebases. Detail → `MEMORY-mcp-stack.md`.

## grepai
- Liveness clock `watch.last_index_time` is written at scan/checkpoint boundaries, not per write → stale clock ≠ dead write path; cross-check a write-side signal.
- Bootstrap reap deadlock fixed `6975699` (`mcpw-3si`): `Get-GrepaiIdleMinutesFromConfig` returns `$null` when `last_index_time` predates watch start. `launcher_grepai_idle_clock_reap.tests.ps1` flipped to "does NOT reap" (5/5) — do not re-flip.
- `Test-GrepaiLockStale` is hand-synced across `watcher_job_helpers.ps1:73` and `watcher_pane_scripts.ps1:615` (pane copy deliberate — generated panes dot-source nothing). Guard: `launcher_grepai_lock_and_spawn.tests.ps1` (12/12).
- Lock dir is **machine-global** (`watcher_job_helpers.ps1:35-40`) → two launcher instances collide. `Get-GrepaiSpawnDecision` (spawn/adopt/backoff, 15s→600s) is tested 30/30 and is now wired in (`mcpw-kwa`, 8837367).
- Ollama **:12134** (not 11434). grepai honours only `.grepai/config.yaml` `embedder.endpoint`.

## Tests
- Sweep 2026-09-19 22:21: **252 of 252 passed, 37 suites** (~7 min). Gate `run_launcher_tests.ps1 -SkipSmoke`: 152/0. Prove no regression by diffing two sweeps, never a remembered number.
- **Never trust a Pester exit code** — count `[-]` lines; pass = `max(summary, unique [+])`. Pester 6.0.0 dies in discovery yet exits 0. Use `dev_tools/run_pester_suite.py`.
- **Pester 6.1.0 removed legacy assertion syntax.** `| Should Match` throws and reads as an ORDINARY failure → suite silently reports N−5. Use `Should -Match` / `Should -Not -Match`.
- Installed version here is **6.0.1**: `-Show` does not exist, `-Output` is ambiguous → call `Invoke-Pester -Path <file>` bare. Pester 3.4.0 suites (e.g. teardown) `Write-Host` results, so `| Out-String` captures **nothing** — read the printed output.
- `tests/launcher_tests.ps1` ~3 m 15 s → `temp/_lt.bat` (`temp/_gate.bat` for the 8 pure suites).
- **`.cmd`/`cmd /c` grandchildren cannot resolve a bare `ping`** here though their PATH is byte-identical to the parent's (79 entries, both System32 forms). Symptom: payload never runs, child exits in ~2 s → `TimedOut` false / PID gone → failure unrelated to what the test proves. Fix: `Join-Path $env:SystemRoot 'System32\ping.exe'`. Applied in `launcher_mcp_provision.tests.ps1:851`, `launch_watcher_for_grepai.tests.ps1`, `launcher_watcher_teardown.tests.ps1` (2 sites).
- **Windows PowerShell (`…\System32\WindowsPowerShell\v1.0`) now on the HKCU Path** (added 2026-09-22, was HKLM-only).
- Python `C:/Users/yuni/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe`; pytest from `tests/` with bare `-c pytest.ini`. VAD needs `./.venv/Scripts/python.exe` (numpy) + `--ignore=.gc` (broken symlink → WinError 1920 aborts collection at rootdir).
- **Loading a `###N` file from Python** — `#` makes it an invalid module name, so `import` can never work: `spec_from_file_location` + `exec_module` + `sys.modules.setdefault`. Pattern: `tests/test_watcher_allocator.py:18-38`.
- **Managed python has no pytest** → `uvx --with pytest --with pyyaml`. The "N passed" line is eaten by `[SAFE_DELETE_FAIL_CLOSED]` noise → **take counts from `--junitxml`**.

## git / landing
- **Flat branch names only on J** — nested refs are silently discarded (exit 0, no ref). Use `dev_tools\New-VerifiedGitBranch.ps1`, then verify `.git/refs/heads/<name>` exists.
- `ls -la ###*` lists the whole dir — a bash word starting with `#` opens a comment. Quote: `ls -la "###"*`. `git ls-files` rejects `--pathspec-from-file`. A stale `.git/index.lock` blocks `git rm` — clear it first. `git rm` is SIGTERM-intercepted → `git rm --cached` + `[System.IO.File]::Delete`.
- `git diff` is silent on `###1...ps1` (`.gitattributes: * -text`) → use `git show HEAD:<f>` / `git log -p`.
- Commits take ~4 min (`.beads/hooks/*`) → use `-F <file>`; confirm via **reflog**, not exit code. **Commit subjects can lie — verify tree content.**
- **Concurrent actors** = peer WorkBuddy sessions. Everyone commits as `uni.universefire`, so **authorship identifies nobody** — anchor on a flat branch, re-read shared files before editing. gascity (`omp.exe`) runs no git orders; only reach is Dolt maintenance of the `mcpw` beads DB.
- **Git DB loss recurs** (09-18/19/20) — recovery in `MEMORY-mcp-stack.md`. Porting a VAD commit: intersect `git -C J:/audio/VAD show --name-only` with `git ls-files` first.

### Pushing
- **Plain `git push` ALWAYS fails here.** Both remotes are verified working, but only via the GitHub (`gh auth git-credential`) and GitLab (`get`-only helper script) recipes — full commands moved to **`MEMORY-mcp-stack.md` § "Pushing"**; read that file before pushing.

## Extraction (COMPLETE 2026-09-20)
- **Repo is fully independent** (modules load from `$PSScriptRoot`); the live launcher runs from here, VAD is its *watched* repo; surviving "VAD" hits are legacy identifiers. Plan `docs/plans/2026-09-17-mcp-watchers-extraction-plan.txt`. Ported VAD docs land in `docs/changelogs/` + `docs/plans/` — **not** root `changelogs/`.
- Provision layer renamed bootstrap→provision (`Modules/watcher_mcp_provision.ps1`, state dir `.mcpw-provision`); read side `watcher_mcp_detect.ps1` — **detect/provision** is the matched pair. A stamp no longer authorises a skip alone: `Start-McpProvisionStep:592-599` also asks the matching `Test-<Mcp>Initialized` probe.

## Toolport
- "0 tools" in `toolport_status` = contention, not dead. **Never kill your own gateway** — WorkBuddy won't respawn it.
- Registry `%APPDATA%\toolport/registry.json` needs a top-level `version` or it reads "Corrupt registry". **Gateway is always LATEST — do NOT pin a release.** Safe test: copy registry, `TOOLPORT_REGISTRY=<copy>`, spawn gateway with stdin held open (`( sleep 35 ) | …`); shared `gateway.log`; unique probe `id`.
- HTTP watchdog `MCPHttpWatchdog` (1 min) is the ONLY starter for :8765/:8080 — never add a second launcher for a port.
- **Never conclude a server is up/down from a listing or `gateway.log`** — shared by ~8–9 gateway processes across 3 builds; the fleet mass-fails `initialize` (~21%; retry is the remedy). Make one real call through Toolport with a control (`git__git_status`).

## LLM fallback proxy (`###2.llm_fallback_proxy.py`)
- Chat proxy **:11436** → litellm `http://127.0.0.1:4000/v1/chat/completions` — **the sole upstream**; if litellm is down `/health` still answers but every tier fails.
- **Tier names must equal litellm `model_name`, not `model:`** — a mismatch is a silently dead tier. **Client `model` is discarded** (`_try_candidate` overwrites it). Tier list + routing → `MEMORY-mcp-stack.md`.

## Sub-agents: verify, never trust (learned 2026-09-20/21, repeatedly bitten)
- **Never close a bead on an agent's word.** Two of ~14 reported work done with commit SHAs that did not exist (1d7f153..7a8a51a; 2037606) while the code was untouched. Require `git log --oneline -3` pasted into the report AND a file-level check (`ls` for a new file, `grep -c` for a renamed symbol).
- Other failure modes: work left UNCOMMITTED; two agents in one file; a 429 landing after the work was already finished.
- **4 sub-agents at once triggered HTTP 429** on two (died in ~30 s having done nothing). Stagger spawns, or do the critical path yourself.
