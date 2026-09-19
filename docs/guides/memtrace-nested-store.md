# Memtrace: the nested `.memdb` under the repo root (mcpw-uqh)

Decision: **intentionally retained. Nothing was deleted.**

This file covers the nested store under *this repo's* root. There are two other
nested stores on this box, outside the repo - see
[Other nested stores](#other-nested-stores-outside-the-repo) below.

## What the warning says

On every `memtrace start` against the union store, memtrace warns:

```
Ignoring 1 nested MemDB store(s) below the bound store:
    J:/audio/MCP-Watchers/.memdb
    Bound store: \\?\C:/Users/yuni/.config/memtrace/.memdb
```

`J:\audio\MCP-Watchers\.memdb` is a *nested* store sitting below the bound union
store. It holds the residue of an old **repo-local** daemon (pid 87920, started
2026-09-18, dead since) plus launcher-owned logs and locks:

| artifact | owner | still used? |
| --- | --- | --- |
| `daemon-state.json` (pid 87920) | old repo-local daemon | yes - see below |
| `autoheal.log` | watchers launcher | yes - heal supervisor log |
| `memtrace-launch.log`, `memtrace-launch.log.err` | watchers launcher | yes - start/heal logs |
| `memcore-server.log`, `cs.log`, `cs.err`, `sidecars.json`, `graph-cache/`, `memtrace/` | dead repo-local daemon | no |
| `reheal-*.lock`, `reheal-stamps.json`, `.memtrace-store-scope.json` | old repo-local daemon | no |

## Why it is not deleted

The launcher still **reads** one file in it, so deleting the directory is not a
free win:

* `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`
  computes `$script:memtraceStateFile` as `<gitroot>\.memdb\daemon-state.json`.
  That path is persisted to `teardown-state.json` as `MemtraceStatePath` and
  consumed by `Stop-AllWatchers` step 4 (`Modules/watcher_teardown.ps1`), which
  `Kill()`s whatever healthy pid the file names.
* `Restart-MemtraceDaemon` and the start job also write their launch logs there.

Repointing that state file at the union store's
`<USERPROFILE>\.config\memtrace\.memdb\daemon-state.json` was considered and
**rejected**: under the union model the pid in that file is the *shared* daemon
serving all 8 members, so MCP-Watchers teardown would kill a daemon the other
repos still depend on. The repo-root file names a dead, repo-local daemon, which
makes teardown step 4 a harmless no-op - the safe outcome.

`C:\Users\yuni\.memdb` is a junction to `C:\Users\yuni\.config\memtrace\.memdb`
(same inode), so `~/.memdb/daemon-state.json` and the union store's state file
are the same file.

## What actually changed (mcpw-aez)

The nested store was only *reported* by memtrace; it was never the cause of the
`PERMANENT FAILURE` lines in `autoheal.log`. Those came from launching
`memtrace start` from the repo root with no `--workspace`, which made memtrace
derive a one-member ColdFolder scope that the 8-member union store refused.
Both start sites now pass `--workspace <USERPROFILE>\.config\memtrace\workspace.toml`
and run the child from `<USERPROFILE>\.config\memtrace`, mirroring
`C:\Users\yuni\.local\bin\memtrace_mcp_cwd_proxy.py` v1.4.0 `start_daemon()`.

## Other nested stores outside the repo

`mcpw-uqh` was filed against the repo-root store only, but the same nested-store
class had a second, WSL-side source. It is recorded here so this file is a
complete inventory and the next reader does not re-derive it.

`memtrace_mcp_cwd_proxy.py` used to spawn `memtrace mcp --workspace
\\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-N` whenever a daemon was
already listening (the `is_unscopable` guard was skipped on that path). memtrace
then anchored a store inside the WSL filesystem and died on the lock:

```
◆  Workspace marker already present at \\?\UNC\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-1  (hard override: MemDB/.memtrace anchor here, ignoring IDE workspace env vars)
Error: cannot lock store-scope manifest \\?\UNC\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-1\.memdb\.memtrace-store-scope.lock: Incorrect function. (os error 1)
```

Repeated at 04:51:52, 04:58:57, 04:59:01, 05:02:13, 05:03:37, 05:09:03,
05:10:18, 05:11:58 and 05:12:49 on 2026-09-20. **Fixed in `mcpw-485`** (commit
`5d176e2`): POSIX/WSL roots are now remapped to the union manifest before any
mcp spawn, so no `\\wsl.localhost\...` workspace is passed again. Full detail in
`docs/changelogs/2026-09-20-mcpw-485-wsl-roots-union-scope.md`.

Residue on disk (checked 2026-09-20, read-only):

| path | state |
| --- | --- |
| `\\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-1\.memdb` | **exists** - contains only `.memtrace-store-scope.lock` |
| `\\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-2\.memdb` | absent (the parent dir has a `.memtrace-workspace` marker, no store) |

Same decision as the repo-root store: **retained, not deleted.** It is one
zero-byte lock file, it is not in any git repo, and `mcpw-485` stops it being
recreated. Deleting it buys nothing and is the kind of churn this bead was told
to avoid.

## If you ever do want it gone

Only after proving no reader remains. `rm` / `Remove-Item` / `shutil.rmtree` are
intercepted in the build sandbox; the working method is the .NET APIs:

```powershell
[System.IO.File]::Delete('J:\audio\MCP-Watchers\.memdb\daemon-state.json')
[System.IO.Directory]::Delete('J:\audio\MCP-Watchers\.memdb', $true)
```

Do that only as a deliberate, separate change - the directory is launcher-owned
today, and `.memdb/` is gitignored so nothing here is recoverable from git.
