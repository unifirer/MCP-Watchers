# Handover Brief — Graphiti Embed Proxy :8003 in ###1 Launcher

**Date:** 2026-09-17
**Commit:** `1da378ed` (on `fix-tests/20260912-180000`, pushed to GitLab)
**Beads:** `vad-jowhw` (closed)

## What Was Done

Added the graphiti embed proxy (`embed_server.py`, port `:8003`, all-MiniLM-L6-v2, 384 dims) to the `###1` watcher launcher as a managed persistent singleton.

### Files Changed

| File | Change |
|------|--------|
| `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1` | +112 lines: persistent-singleton block, start-job handle, supervisor relaunch, duplicate reap |
| `Modules/watcher_patterns.ps1` | +1 line: `Persistent=$true` entry for `python.exe` / `embed_server` |

### Key Implementation Details

- **Pattern:** persistent-singleton (same as cerememory/claude-mcp/mail — NOT added to `$global:WatcherChildren` or teardown)
- **Port dedup:** in-job TCP probe reuses live `:8003` before launching a new process
- **Canonical paths:**
  - Python: `C:\Users\yuni\AppData\Local\Programs\Temp\graphiti-mcp\mcp_server\.venv\Scripts\python.exe`
  - Script: `C:\Users\yuni\AppData\Local\Programs\Temp\graphiti-mcp\mcp_server\embed_server.py`
- **Health endpoint:** `http://127.0.0.1:8003/health` (returns 200)
- **Readiness gate:** 25s timeout, 750ms polling (model load can take time)
- **Supervisor:** `Start-GraphitiEmbedBackend` relaunch function in `$backendSupervisorScript`, plus `Start-BackendSupervisor -Name 'graphiti-embed' -Port 8003` entry
- **Duplicate reap:** kills stale `embed_server.py` processes by command-line token match
- **NOT covered by:** `Exit-IfPortHeldByLauncherDaemon` (python.exe too broad — same as mail/claude-mcp)

## Verification Evidence

- PowerShell parser errors: 0 for both files
- `watcher_patterns.tests.ps1`: all 6 checks `[+]` passed
- `test_launcher_watchers_contract.py`: PASSED 1/1
- Live probe: TCP-OK, `/health` 200, `/v1/models` returns `all-MiniLM-L6-v2`
- Remote confirmed: `git log gitlab/fix-tests/20260912-180000 -1` shows `1da378ed`

## What Was NOT Done

- **`:8002` was NOT added** to the ###1 script. Only `:8003` (the embed proxy) was added. If `:8002` is a separate graphiti MCP server that needs the same treatment, that work is still pending.
- No changes to `watcher_teardown.ps1` (correct — persistent singletons are excluded by design).

## Workspace State

- Branch: `fix-tests/20260912-180000`
- Remote: `gitlab/fix-tests/20260912-180000` (up to date with my commit)
- 7 local-ahead commits exist but are unrelated work from other sessions
- Massive pre-existing staging area (hundreds of files from prior `git add .`) — cleaned up with `git reset HEAD -- .` during this session

## Next Steps (if any)

1. If `:8002` needs auto-start management, add it following the same pattern as `:8003`
2. Run the full `###1` launcher to verify end-to-end supervisor behavior
3. Monitor `graphiti-embed\supervisor.log` for auto-heal events
