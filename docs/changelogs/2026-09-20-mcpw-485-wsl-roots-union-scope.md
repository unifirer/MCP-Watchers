# mcpw-485 — WSL agent roots now served under the union scope

Date: 2026-09-20
Bead: `mcpw-485` (P3 optional, label `memtrace, optional, wsl`)
Component: `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py` (outside this repo)
Decision: remedy **(b)** — fall back to the union scope for unresolvable roots.

## Problem

WSL-side agents hand the proxy real roots over MCP `roots/list`, e.g.
`/Ubuntu/home/yuni/.gc-vad/agents/bd.dog-1` and `bd.dog-2`. Those roots can
never be members of the Windows union manifest, and the proxy handled them
badly in *two different ways* depending on whether a daemon was up:

- **No daemon listening** — `is_unscopable()` returned True for any POSIX path,
  so `Session.start()` failed fast. 122 occurrences of
  `workspace '…' is outside the union manifest scope; failing fast instead of
  respawning` in `~/.memtrace/cwd-proxy.log` (113 for `bd.dog-1`, 103 for
  `bd.dog-2`). Those sessions got no memtrace at all.
- **Daemon already listening** — `Proxy._on_initialize()` skipped the
  `is_unscopable` guard entirely and called `_attach_mcp()` directly, and
  `normalize_workspace()` found the WSL UNC reachable
  (`os.path.isdir("\\\\wsl.localhost\\Ubuntu\\home\\yuni\\.gc-vad\\agents\\bd.dog-1")`
  is True on this machine), so mcp was spawned with
  `--workspace \\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-1`.
  memtrace then anchored a **nested store inside the WSL filesystem**
  (`\\?\UNC\wsl.localhost\Ubuntu\…\.memdb`) instead of the union store, and
  died on it:

  ```
  ◆  Workspace marker already present at \\?\UNC\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-1  (hard override: MemDB/.memtrace anchor here, ignoring IDE workspace env vars)
  Error: cannot lock store-scope manifest \\?\UNC\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-1\.memdb\.memtrace-store-scope.lock: Incorrect function. (os error 1)
  ```

  (Log lines `04:51:52`, `04:58:57`, `04:59:01`, `05:02:13`, `05:03:37`,
  `05:09:03`, `05:10:18`, `05:11:58`, `05:12:49` show the same anchor being
  created repeatedly.) So the old behaviour was neither "no memtrace" nor "the
  union store" — it silently created WSL-side stores that the union manifest
  exists to prevent. This is also a likely contributor to the nested-store mess
  tracked by `mcpw-uqh`.

## Chosen remedy and why (b)

(a) mapping the WSL roots to a Windows equivalent would be guesswork about
WSL→Windows path translation and would mutate a manifest covering 8 repos.
(c) leaves real agent sessions silently degraded. (b) is contained in the
proxy, and the proxy already pins every memtrace child to `CANONICAL_CWD`, the
union scope root, so serving these sessions under the union scope is coherent —
and, as a side effect, it also removes the nested-store path above.

Safety check before shipping (b): the attach it produces is
`--workspace C:/Users/yuni/.config/memtrace/workspace.toml`, which is exactly
what the real gateway already passes for non-WSL sessions and which is observed
to complete live handshakes. No evidence was found that (b) is unsafe, so it was
implemented rather than escalated.

## Changes

All in `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py`:

| Location | Change |
| --- | --- |
| `is_posix_root()` (line 441) | new: True for `/…` and `\\wsl.localhost\…` / `//wsl…` roots |
| `union_fallback_workspace()` (line 452) | new: returns `UNION_MANIFEST` for POSIX/WSL roots and logs loudly that the session is being served under the union scope; returns `None` for everything else |
| `is_unscopable()` (line 478, manifest check at line 501) | the union manifest path is now recognised as the union scope and is never itself judged out of scope — without this, the fallback value would have been refused by the very next check |
| `Proxy._on_initialize()` (line 1020) | computes `scope_workspace = union_fallback_workspace(workspace) or workspace` once, and uses it for `Session(...)`, `_attach_mcp(...)` and the state log |

Deliberately narrow: **only** POSIX/WSL roots are remapped. A native Windows
path outside every manifest member (`C:\Users\yuni\SomeOtherRepo`) still returns
`None` from the fallback and still fails fast via `is_unscopable`, so a genuine
scope mistake is never silently swallowed.

## Verification (real output)

Unit checks — `C:/Temp/unit_485.py`, 16/16:

```
ok   is_posix_root('/Ubuntu/home/yuni/.gc-vad/agents/bd.dog-1') -> True
ok   is_posix_root('\\\\wsl.localhost\\Ubuntu\\home\\yuni\\x') -> True
ok   is_posix_root('J:\\audio\\MCP-Watchers') -> False
ok   fallback('/Ubuntu/home/yuni/.gc-vad/agents/bd.dog-2') -> 'C:\\Users\\yuni\\.config\\memtrace\\workspace.toml'
ok   fallback('J:\\audio\\MCP-Watchers') -> None
ok   fallback('C:\\Users\\yuni\\SomeOtherRepo') -> None        # native, out of scope: not swallowed
ok   is_unscopable('C:\\Users\\yuni\\.config\\memtrace\\workspace.toml') -> False
ok   is_unscopable('C:\\Users\\yuni\\SomeOtherRepo') -> True   # still fails fast
ok   is_unscopable('/Ubuntu/home/yuni/.gc-vad/agents/bd.dog-1') -> True
RESULT: PASS
```

End-to-end, same harness, same machine, a real MCP `roots/list` answering with
`file:///Ubuntu/home/yuni/.gc-vad/agents/bd.dog-1` (`C:/Temp/verify_485.py`):

| Proxy build | `mcp attached` line |
| --- | --- |
| pre-fix `.bak-20260920-0514` | `workspace=\\wsl.localhost\Ubuntu\home\yuni\.gc-vad\agents\bd.dog-1` → nested WSL store, then `cannot lock store-scope manifest …\.memdb\.memtrace-store-scope.lock` |
| fixed | `workspace=C:\Users\yuni\.config\memtrace\workspace.toml` → union scope, no `wsl.localhost` anywhere |

Live deployment after the change, from `~/.memtrace/cwd-proxy.log`:

```
05:15:47 workspace '/Ubuntu/home/yuni/.gc-vad/agents/bd.dog-1' is a POSIX/WSL root that cannot be a member of C:\Users\yuni\.config\memtrace\workspace.toml; serving this session under the union scope instead
05:15:47 mcp attached, pid=7876 workspace=C:\Users\yuni\.config\memtrace\workspace.toml cwd=C:\Users\yuni\.config\memtrace
...
05:16:30 mcp: [memtrace] MemDB ready
05:16:30 tool schemas loaded: 90 tools, 61 repo-scoped
05:18:24 mcp: [memtrace] MemDB ready
05:18:24 tool schemas loaded: 90 tools, 61 repo-scoped
```

Six live handshakes since 05:15, and no `\\wsl.localhost\…` attach after
05:15:30 (that one was the pre-fix backup under the harness).

## Unverified / noted

- One harness-driven session still fails with
  `could not acquire runtime owner lock at \\?\C:\Users\yuni\.config\memtrace\.memdb\daemon.pid: Access is denied. (os error 5)`.
  This is the same environment-specific failure reported for `mcpw-e7v`; it
  reproduces for non-WSL workspaces too, the real gateway attaches to the same
  daemon concurrently and succeeds, and the cause is **unverified**. It is not
  caused by this change — mcp now resolves the union store and reaches the
  owner-lock step, which is the intended behaviour.
- WSL sessions served under the union scope get `repo_id = None` (no
  `J:/…` or `C:\…` repo matches `/Ubuntu/…`), so no repo_id injection happens.
  That was equally true before this change and is not addressed here.

## Rollback

- `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py.bak-20260920-0514`
  — pre-`mcpw-485` state, i.e. after the `mcpw-e7v` fix
  (md5 of the edited file before this change: `22e894952ac77c961e1f71098469a3ef`)
- `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py.bak-20260920-0502`
  — the original pre-`mcpw-e7v` file
- `C:/Users/yuni/.local/bin/memtrace_mcp_cwd_proxy.py.bak-20260918-100705`
  — earlier backup from the previous change
