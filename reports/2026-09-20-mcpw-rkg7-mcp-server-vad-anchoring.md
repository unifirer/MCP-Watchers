# mcpw-rkg.7 — 3 of 6 MCP servers anchored to `J:/audio/VAD`, not the launched repo

- **Bead:** mcpw-rkg.7 (P0 BLOCKER)
- **Date:** 2026-09-20
- **Branch:** `mcpw-sweep-20260920-1305`
- **Verdict:** **Genuinely fixable, and fixed** — but the fix belongs in the
  **Toolport registry**, not in the launcher. The launcher was never the
  anchor and is already path-generic.

---

## 1. Mechanism — where the VAD anchoring actually comes from

The launcher and the MCP servers are two disjoint spawn paths. Only one of them
is the launcher's.

| | Spawned by | Workspace resolution |
|---|---|---|
| **Watchers** (`grepai watch`, `graphify-rs watch`, `repowise watch`, gm rebuild daemon) | the launcher | `$watchersWorkspaceRoot = (Get-Location).ProviderPath` (launcher line 21) — **correct** |
| **MCP servers** (`graphenium`, `graphify`, `repowise`, `grepai`, `memtrace`, `graft`) | the **Toolport gateway** | `%APPDATA%\toolport\registry.json` server entries |

The launcher never reads or writes the registry — the only match for
`registry.json` in the 320 KB script is a comment at line 4040. Every watcher
spawn is anchored correctly:

- `Start-WatcherDetached` (line 2046) defaults `$psi.WorkingDirectory` to
  `$scriptDir` and callers pass `-WorkingDirectory $watchersWorkspaceRoot`
  (lines 3097, 3140);
- grepai watch is spawned with `-WorkingDirectory $watchersWorkspaceRoot` (line 1317);
- the gm rebuild daemon is handed `$watchersWorkspaceRoot` (lines 3081/3083);
- the graphify wrapper gets `-Repo "$watchersWorkspaceRoot"` (line 3096).

So the anchor is entirely in the registry. Three entries carried **absolute
`J:\audio\VAD` paths frozen into `args`** at the time they were authored
(`"source": "manual"`):

```
graphenium  gm.exe         serve --graph J:\audio\VAD\graphenium-out\graph.json --watch
graphify    graphify-rs.exe serve --graph C:\Users\yuni\.graphify-rs\VAD-499645c0501b9e90\graph.json
repowise    uvx            repowise mcp J:\audio\VAD --transport stdio
```

The gateway itself is **not** the problem: it resolves a per-session *project
root* from the client's `ProcessCwd` (gateway.log: `toolport: project root from
ProcessCwd (j:\audio\MCP-Watchers)`) and uses it as the **default child cwd**.
These three entries simply overrode that default with a hardcoded path.

### "Our setup" vs "the tool's design"

- **Our setup (fixable):** the absolute path arguments. Nothing in the tools
  requires them — all three resolve their workspace from cwd when the argument
  is omitted or relative.
- **The tool's design (not a bug):** all three are single-workspace servers —
  one graph / one workspace per process. They cannot *follow* the repo at
  runtime; they must be **spawned with the right cwd**, which is exactly what
  the gateway now does once the hardcoded args are gone.

## 2. Gateway behaviour, verified empirically

Rather than guess, I ran a **throwaway isolated gateway** (separate
`TOOLPORT_REGISTRY`, separate `TOOLPORT_DATA_DIR`, port 8799) with two probe
server entries that wrote their `argv` + `os.getcwd()` to a file. The live
gateway was never touched. Result (gateway 1.19.0):

```json
{"cwd": "J:\\audio\\MCP-Watchers", "argv": ["root_probe.py", "argA", "${ROOT}"], "env_ROOT": null}
{"cwd": "J:\\audio\\MCP-Watchers", "argv": ["root_probe.py", "argB"],          "env_ROOT": null}
```

Three conclusions:

1. **Default child cwd IS the project root.** The entry with *no* `cwd` field
   still started in `J:\audio\MCP-Watchers`. This is why `grepai` and `graft`
   (no path args) were already correctly anchored — confirming the bead's
   "believed correctly anchored" for the cwd-inherited servers.
2. **`${ROOT}` expands in `cwd`** — the entry with `"cwd": "${ROOT}"` resolved
   to the project root.
3. **`${ROOT}` does NOT expand in `args`** — it reaches the child as the literal
   string `"${ROOT}"`. (Registry schema confirmed from the binary string table:
   `… transport command args env cwd source …`, plus
   `configured working directory {x} expanded to {y}, but that directory does not exist`.)

## 3. What I changed

### 3.1 `%APPDATA%\toolport\registry.json` (the actual fix)

All three entries now resolve relative to the project root; `cwd: "${ROOT}"` is
set explicitly so the anchoring is declared rather than inherited from an
undocumented default. **The `version` key is untouched (`version: 1`)** and no
release is pinned.

| Server | `args` before | `args` after | `cwd` |
|---|---|---|---|
| graphenium | `serve --graph J:\audio\VAD\graphenium-out\graph.json --watch` | `serve --watch` | `${ROOT}` |
| graphify | `serve --graph C:\Users\yuni\.graphify-rs\VAD-…\graph.json` | `serve` | `${ROOT}` |
| repowise | `repowise mcp J:\audio\VAD --transport stdio` | `repowise mcp . --transport stdio` | `${ROOT}` |

No LLM model configuration was touched anywhere — only `args`/`cwd` of these
three entries. `env` blocks (including repowise's `DO_NOT_TRACK` /
`REPOWISE_TELEMETRY_DISABLED`) are unchanged.

Backup written next to it: `registry.json.bak-mcpw-rkg7-<timestamp>`.

Each new arg set was executed with `cwd` = this repo and verified end-to-end:

- `gm serve --watch` → `Project root: J:/audio/MCP-Watchers`
- `graphify-rs serve` → MCP-Watchers graph (623 nodes; the repo has no `graphify-out/`)
- `repowise mcp .` → `Repository Overview: MCP-Watchers`

### 3.2 `dev_tools/check_mcp_server_anchor.py` (new file)

A checker that reads the registry, compares each of the six watched servers
against a target repo root, and reports PASS/FAIL. It also flags `${ROOT}` used
inside `args` (which never expands) as a hard error. Verified both ways:

```
# fixed registry  -> all OK, exit 0
# original registry -> FAIL graphenium / graphify / repowise, exit 1
```

### 3.3 Important caveat: the fix is dormant until the gateway restarts

The gateway loads the registry at **startup** and does **not** hot-reload server
entries — confirmed: entries added while it was running were never spawned. The
standing rule is **never kill the gateway**, so I did not. The corrected entries
take effect the next time the gateway starts (e.g. next WorkBuddy session). The
three servers will keep serving VAD until then.

## 4. Left for a later wave (launcher edit — not mine to make)

`###1.watchers_…ps1` is owned by another agent (mcpw-gsj), so I did **not** edit
it. The honest in-launcher fix is **detection + loud warning**, not a silent
"fix": the launcher can read the registry and refuse to claim health when a
watched server is pinned elsewhere. Exact diff, ready to apply:

**Insert after line 915** (`# === grepai health check (end) ===`), before
`# Prerequisites Check: grepai executable is on PATH.` at line 917:

```powershell
# mcpw-rkg.7: the six MCP servers are spawned by the Toolport gateway from
# registry.json, NOT by this launcher, so a registry entry can pin a server to a
# different repo. The launcher's watchers would then report healthy while the
# MCP tools answer from another repository. Detect and warn loudly.
function Test-McpServerAnchoring {
    param([string]$RepoRoot, [string[]]$ServerIds = @('graphenium','graphify','repowise'))
    $regPath = if ($env:TOOLPORT_REGISTRY) { $env:TOOLPORT_REGISTRY }
               else { Join-Path $env:APPDATA 'toolport\registry.json' }
    if (-not (Test-Path -LiteralPath $regPath)) { return }
    try { $reg = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Warning "mcpw-rkg.7: registry unreadable ($regPath): $($_.Exception.Message)"; return }
    $root = $RepoRoot.TrimEnd('\','/')
    foreach ($s in @($reg.servers)) {
        if ($ServerIds -notcontains $s.id) { continue }
        foreach ($a in @($s.args)) {
            if ($a -isnot [string]) { continue }
            if ($a -match '^[A-Za-z]:[\\/]' -and -not $a.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning ("mcpw-rkg.7: MCP server '$($s.id)' is anchored OUTSIDE this repo " +
                    "('$a'); its tools will answer from another repository until the gateway restarts " +
                    "with a corrected registry entry.")
            }
            if ($a -like '*${ROOT}*') {
                Write-Warning ("mcpw-rkg.7: MCP server '$($s.id)' uses `${ROOT} inside args, which the " +
                    "gateway does NOT expand. Use a relative path with cwd=`${ROOT} instead.")
            }
        }
    }
}
Test-McpServerAnchoring -RepoRoot $watchersWorkspaceRoot
```

Related anchor for a later wave, no change needed today: `Start-WatcherDetached`
line **2123** (`if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
else { $psi.WorkingDirectory = $scriptDir }`) is the watcher-side cwd rule and is
already correct for every caller.

## 5. The other three servers

| Server | Status | Why |
|---|---|---|
| `memtrace` | **correct by design** | registry runs `memtrace_mcp_cwd_proxy.py`, which does an MCP `roots` handshake per session and starts a daemon for the caller's workspace |
| `grepai` | **correct** | `mcp-serve` with no path; inherits the gateway's default child cwd = project root (verified above) |
| `graft` | **correct** | `mcp` with no path; same cwd inheritance |

`grepai`, `memtrace` and `graft` currently expose 0 tools in `toolport_status`
(contention / still connecting), which is why they could not be probed directly
through the gateway — the cwd inheritance above is the verified explanation for
why they are nonetheless anchored correctly.

## 6. Not changed (deliberately)

- **Launcher** (`###1.watchers_…ps1`), `Modules/`, `tests/` — owned by other
  agents. The diff is specified above instead.
- **`filesystem` server** still lists `J:\audio\VAD` among its allowed
  directories. It is not one of the six watched servers, and it is an *allowlist*
  (an additive root), not a workspace anchor — so it does not mis-serve another
  repo. Flagged for awareness only.
- **Gateway** — never killed. `toolport_status` reporting 0 tools for a server
  is contention, not death.

## 7. Reproduction

```bash
# detect anchoring for any repo
python dev_tools/check_mcp_server_anchor.py --repo /j/audio/MCP-Watchers

# prove a server resolves per-cwd (no absolute args)
cd /j/audio/MCP-Watchers
gm serve --watch            # -> Project root: J:/audio/MCP-Watchers
graphify-rs serve           # -> MCP-Watchers graph
repowise mcp . --transport stdio
```

## 8. Bottom line

- The mechanism is **registry `args` with absolute paths**, not the launcher.
- The fix is **in the registry**, applied and verified per-server; it activates
  at the next gateway start.
- The launcher needs only a **detection/warning** addition, specified above as an
  exact diff for a later wave.
- **No model configuration was touched; the gateway was never killed.**
