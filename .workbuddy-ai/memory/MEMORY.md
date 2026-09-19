# MCP-Watchers — curated project notes
Only durable facts. Detail lives in daily logs (`YYYY-MM-DD.md`).

## Environment / sandbox
- Ollama 127.0.0.1:**12134** (not 11434). grepai only honours `.grepai/config.yaml` `embedder.endpoint`.
- qdrant-grepai = 16333 REST / 16334 gRPC. Shared `server-qdrant-1` is v1.11.3 vs grepai client v1.19.0 → silent write failures; never point grepai at it.
- HTTP_PROXY=127.0.0.1:6438 breaks localhost → `curl --noproxy '*'` / `no_proxy='*'`.
- `/tmp` unwritable from Git Bash → use `C:/Temp`.
- **`PATHEXT=.CPL` is a SANDBOX INJECTION, not a box fact.** Only the sandboxed *process* gets it; Machine is stock. Inside a sandbox PowerShell cannot resolve `.cmd`/`.exe`, native children leave no side effect and never set `$LASTEXITCODE`. **Measure `Machine` vs `Process` before blaming the code.**
- Session env: Process carries `HTTP_PROXY`/`http_proxy` **and** `HTTPS_PROXY`/`https_proxy` (Machine/User: none) → PS 5.1 `Start-Process -RedirectStandardOutput` throws `Item has already been added… 'https_proxy'`.
- Nested host children return NO captured stdout; tool-spawned processes reaped at ~120 s. Sandbox blocks `Invoke-Expression` → `[scriptblock]::Create()` + dot-source; PS stdout unreliable → `Out-File` then read back.
- A python→`powershell.exe` spawn is NOT the PowerShell tool: different git (2.55.0 vs 2.47.1) plus injected `PATHEXT`. Same code can pass in one, fail in the other.

## Watcher heal ownership
- Supervisor thread in `###1...ps1` heals while the launcher lives; after 5 failed restarts it sleeps 10 min but keeps refreshing `.sup`. `supervised restart pending...` = a live supervisor owns the retry, NOT stuck.
- Markers live in `%LOCALAPPDATA%\watchers\<key>\` (not repo root): `.lock`, `.sup`, `.idle` (idle-reaped — must not heal).
- Best liveness clock: `.grepai/config.yaml` `watch.last_index_time`.

## Tests
- Full sweep **2026-09-19 22:21: 252 passed / 0 failed, 37 suites** (~7 min). Canonical gate `run_launcher_tests.ps1 -SkipSmoke`: 152 pass / 0 fail.
- Prove no regression by **diffing two sweeps** on the same changed files, never against a remembered number.
- Python: `C:/Users/yuni/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe`; run pytest from `tests/` with bare `-c pytest.ini`.
- **Never trust a Pester exit code** — count `[-]` lines. Pass = `max(summary, unique [+])`. Pester 6.0.0 dies in discovery yet exits 0.
- `dev_tools/run_pester_suite.py` imports version/parsing logic from `sweep_pester` — never duplicate it.
- `tests/launcher_tests.ps1` needs ~3 m 15 s → run via `temp/_lt.bat` (`temp/_gate.bat` for the 8 pure suites); do not "fix" it by editing the launcher.

## git / landing
- **Flat branch names only on J:** slash branches are silently discarded (exit 0, no ref). Use `dev_tools\New-VerifiedGitBranch.ps1`.
- `git diff` is silent on `###1...ps1` (`.gitattributes: * -text`) → use `git show HEAD:<f>` / `git log -p`. `git status` is fine.
- Commit takes ~4 min (`.beads/hooks/*`); use `-F <file>` (no `--body-file`).
- Porting a VAD commit: intersect `git -C J:/audio/VAD show --name-only` with `git ls-files` first. VAD commit subjects can lie — verify content.
- **Nested ref writes are a no-op on J:** `git update-ref refs/remotes/...` exits 0 but `git show-ref` shows only `refs/heads/*`; `packed-refs` stays empty. Upstream tracking/pull cannot work — pass explicit URLs. Verify with `git show-ref`.
- `git worktree prune` is **path-dependent within one process** — re-run in a second location before calling it a code bug.
- **Pushing:** plain `git push` always fails. GitHub: `-c credential.helper='!gh auth git-credential'`. GitLab: stored credential REJECTED — use the PAT from `declick describe gitlab` + `store --file=`.
- **Git DB loss recurs** (2026-09-18 22:55, and 2026-09-19 20:29 worse: lost `refs/`, all packs, `worktrees/`). Recovery that worked: back up `.git`; `git clone --no-checkout` from github to `C:\Temp`; `mv` that `.git` in; `git reset --mixed HEAD` (the `--no-checkout` index is EMPTY — without it `git status` shows ~179 fake staged deletions); restore `core.hooksPath=.beads\hooks`, `beads.role`, both remotes. Remotes held `main=e758f6b`.

## MCP stack / Toolport
- "0 tools" in `toolport_status` is contention, not a dead server. **Never kill your own gateway** — WorkBuddy won't respawn it.
- Registry: `C:/Users/yuni/AppData/Roaming/toolport/registry.json` (needs top-level `version`; omitting it → "Corrupt registry", cached-tools only).
- Active gateway = **1.18.0** (`bin/gateway-manifest.json`). All of 1.17/1.18/1.19 carry a **client-side** header set: `Content-Type, Accept: application/json, text/event-stream, MCP-Protocol-Version, Mcp-Session-Id, Authorization` → Toolport does its own session negotiation and parses SSE.
- **Safe way to test a registry change without touching live config:** copy registry, set `TOOLPORT_REGISTRY=<copy>`, spawn `toolport-gateway-1.18.0.exe` with stdin held open (`( sleep 35 ) | ...`). Logs land in the shared `gateway.log`; use a unique server `id` to tell probe lines from the live gateway's.
- HTTP watchdog `MCPHttpWatchdog` (1 min) is the ONLY starter for :8765, :8080, :8004. Do not add a second launcher for the same port.
- Backend-sweep trap: a backend plus its own companion count as two (`cerememory.exe`, `python.exe`/`mcp_agent_mail`); parent/child pairs must collapse.

## Graphiti
- Live server = docker `graphiti-mcp`, image `zepai/knowledge-graph-mcp:latest`, host **:8002** ← container :8000, `restart: always`. Entrypoint `uv run --no-sync main.py`; workdir `/app/mcp`.
- **:8004 `mcp_proxy.py` is RETIRED (2026-09-20).** Toolport 1.18.0 connects **directly** to `http://127.0.0.1:8002/mcp` — isolated probe returned `connected 'graphiti-direct' (13 tools)`; a control run against a dead port failed as expected. The old rule *"never repoint the registry at :8002"* was **stale/wrong**. Registry now points at :8002; the launcher :8004 block + supervisor are deleted; the `MCPHttpWatchdog` 8004 target is removed; `GraphitiProxy8004` is **disabled** (re-enable to roll back). **:8004 had FOUR owners** — launcher, watchdog script, scheduled task, and the running process; missing the watchdog would have resurrected it every 60 s.
- A stateless client hitting :8002 with **no** session id gets **HTTP 400 "Missing session ID"** (the proxy docstring's "404 Session not found" describes an *unknown* id, not a missing one).
- Container *can* run stateless, but **not via env**: `FastMCP.__init__` passes `stateless_http=False`/`json_response=False` explicitly into `Settings`, and pydantic-settings gives init kwargs priority over `FASTMCP_*`. Needs a code patch (lost on image update). Unnecessary anyway — Toolport handles sessions.
- **Live config is the container's `/app/mcp/config/config.yaml`** (`CONFIG_PATH`), model `meituan/longcat-2.0:free`. Local `config-litellm.yaml` is NOT loaded.
- Glue lives in `J:\audio\shared\graphiti\` (not repo-local); launcher precedence shared-first. `Modules/graphiti/` is **deleted from git in both repos** — do not re-vendor. Override `$env:GRAPHITI_SHARED_DIR`.
- **FalkorDB stores one graph per `group_id`.** Searching a group creates an empty graph for it.
- **`add_triplet` is broken by design** (verified 2026-09-19): never calls `_resolve_request_scope` (graphiti.py:1704) → writes miss the group graph. **Use `add_memory`.** LLM enrichment healthy ~20–70 s.

## Skills layout
- `J:\audio\VAD\@skills\` is a **curated subset** (214 dirs) vs 462 in `~/.workbuddy-ai/skills/`. **Editing a shared skill updates only one copy — sync the other by hand.** Canonical copy is `~/.workbuddy-ai/skills/`.
- `@skills/*/scripts/lint-skill.sh` spawns 2 processes per line and **cannot finish** on a 400+ line skill. Use a single-process equivalent.

## declick CLI adapters
- declick 0.7.2 needs **Node 24**; managed Node 22.22.2 fails the gate. Use `C:/nvm4w/nodejs/node.exe`. `declick` is on PATH via `~/.local/bin/declick{,.cmd}`.
- **Every generated launcher called bare `node`.** `declick add`/`build` regenerate them → re-run `python dev_tools/repin_declick_node.py --apply` after either (`--check` reports only). Guarded by `tests/declick_node24_pin.tests.ps1`. No `DECLICK_NODE` override exists.
- Launchers land in `C:\Users\yuni\.declick\bin`, behind mingw64/npm-global/`ProgramData\cerememory`. Most are **shadowed by bare name** — reach via `declick run <name> <verb>`. A `.cmd`/`.bat` source fails `spawn EINVAL`; resolve the shim to its interpreter.
- `declick list` emits **one JSON object**, not JSONL. `describe <name>` — never `run <name> describe`. 31/31 registry servers have adapters (573 verbs).
- **`tests/declick_node24_pin.tests.ps1` is 7 of 7 on the box, 4 of 7 in a sandbox** (the 3 need a native process + captured stdout). Restructuring was tried — identical 4 of 7 — **do not edit the test**. Verify with `repin_declick_node.py --check` (rc=0).
- **Launchers can shadow the tool they wrap.** `codegraph`: shim owned the name until `npm install -g @optave/codegraph` — npm-global is PATH 58 vs declick 95, so **install, do not reorder PATH**, and never `declick build <name>`.
- `Resolve-CodegraphLaunch` (~line 2092) yields `node.exe ...\@optave\codegraph\dist\cli.js watch <root>` → `watcher_patterns.ps1` needs `@{Name='node.exe'; Pattern='codegraph\dist\cli.js watch'}`.
