# mcpw-a2j — repowise init: MCP entry is not registered

- **Bead:** mcpw-a2j (P1)
- **Date:** 2026-09-20
- **Repo:** `J:\audio\MCP-Watchers` @ branch `mcpw-sweep-20260920-1305`
- **Verdict:** **DONE** — the Claude Code MCP entry is registered with the real binary's absolute path, and `repowise doctor` confirms it.

---

## 1. Binary used

The bare `repowise` on PATH is the **declick shim** and must not be used:

```
$ which repowise
/c/Users/yuni/.local/bin/repowise          <-- declick MCP engine shim (no `update` verb)

$ ls -la "$APPDATA/uv/tools/repowise/Scripts/repowise.exe"
-rwxr-xr-x 1 yuni 197121 46080 Sep  8 22:48 .../uv/tools/repowise/Scripts/repowise.exe   <-- the real CLI
```

Every command below invokes the **absolute path**:

```bash
RP="$APPDATA/uv/tools/repowise/Scripts/repowise.exe"
```

This matters by design — repowise pins the *running* install's script dir, never PATH
(`cli/mcp_config.py:51-75`): *"Registrations that store the bare command name are resolved via
PATH at session start, so any shadow install (conda, old pip, pipx, uv tool) silently hijacks
the MCP server."*

## 2. Pre-state — doctor BEFORE

```
$ "$RP" doctor
│ .repowise/ directory  │ OK     │ J:\audio\MCP-Watchers\.repowise
│ Database              │ OK     │ 64 pages
│ Claude Code MCP entry │ OK     │ not registered (repowise init registers it)      <-- the defect
│ MCP server responds   │ OK     │ not registered - nothing to launch               <-- the defect
│ Agent: claude-code    │ OK     │ repowise is not registered with Claude Code.     <-- the defect
```

## 3. Which config file — identified before touching anything

The doctor check reads the **global** Claude Code settings, not the repo's `.mcp.json`.
From `repowise/cli/commands/doctor_cmd/repo_checks.py:973-990`:

> *"The global `~/.claude/settings.json` entry can end up pointing at a directory that no longer
> exists …"* → `_registered_mcp_entry()` → `claude_config._claude_code_settings_path()`

And `repowise/cli/editor_integrations/claude_config.py:35-37`:

```python
def _claude_code_settings_path() -> Path:
    """Return the global Claude Code settings path (~/.claude/settings.json)."""
    return Path.home() / ".claude" / "settings.json"
```

→ target = **`C:\Users\yuni\.claude\settings.json`**.

The repo-local `.mcp.json` (tracked, already contained a `repowise` entry using the **bare**
`repowise` command — i.e. the shadow) is **not** what doctor checks and was **left untouched**.

## 4. Backup (taken before modification)

```bash
cp "C:/Users/yuni/.claude/settings.json" C:/Temp/claude_settings.json.preinit.bak

# BEFORE
sha256sum C:/Users/yuni/.claude/settings.json
f5286c49b8f1776722753eb63159d6b0a648d127ffff5d12749922e7f4f398ae
stat: 15779 bytes | mtime 2026-09-20 20:01:00 +1200
top-level keys: enabledPlugins, env, extraKnownMarketplaces, footerLinksRegexes, hooks,
                mcpServers, model, permissions, skipDangerousModePermissionPrompt,
                statusLine, subagentStatusLine
"mcpServers": {}          <-- empty at line 483: the gap
```

## 5. Command run

```bash
cd /j/audio/MCP-Watchers
"$RP" agents add --target=claude-code --scope user -y --format json
```

(`repowise init` itself is wiki generation, not MCP wiring; `agents add` is the registration path.
`--scope user` matches the file doctor reads.)

Real output:

```json
{
  "action": "add",
  "repo": "J:\\audio\\MCP-Watchers",
  "scope": "user",
  "changed": true,
  "agents": [
    {
      "id": "claude-code",
      "display_name": "Claude Code",
      "method": "direct",
      "skips": {},
      "writes": {
        "user": {
          "files": [
            { "path": "C:\\Users\\yuni\\.claude\\settings.json", "action": "updated", "reason": null },
            { "path": "C:\\Users\\yuni\\AppData\\Roaming\\Claude\\claude_desktop_config.json",
              "action": "updated", "reason": null }
          ],
          "notes": []
        }
      }
    }
  ]
}
```

Exit code **0**.

## 6. Exactly what changed

### 6a. `C:\Users\yuni\.claude\settings.json` (the file doctor checks) — backed up

Only one semantic change: the `mcpServers` block.

```diff
-  "mcpServers": {},
+  "mcpServers": {
+    "repowise": {
+      "command": "C:/Users/yuni/AppData/Roaming/uv/tools/repowise/Scripts/repowise.exe",
+      "args": [
+        "mcp",
+        "J:/audio/MCP-Watchers",
+        "--transport",
+        "stdio"
+      ],
+      "description": "repowise: codebase intelligence — docs, graph, git signals, dead code, decisions"
+    }
+  },
```

Note the `command` is the **absolute path to the real binary** — not the bare shadowed name.
`args[1]` is the repo path, which is what the doctor's `_registration_target()` expects.

`diff -u` reports the whole file as changed, but that is **line-ending/normalisation churn only**
(the writer re-serialised the file). Semantic check against the backup:

```
model before: DeepSeek-V4-Flash-Vision-Exp
model after : DeepSeek-V4-Flash-Vision-Exp
model UNCHANGED: True
keys added: set() | keys removed: set()
non-mcpServers keys identical: True
```

```
# AFTER
sha256sum  bd4025d0cf0ca5732b952b0e78561bce5e1003a0e8f0486a049a05efb2054c98
stat:      16702 bytes | mtime 2026-09-20 20:04:29 +1200   (was 15779)
```

**No model was changed** — `model` is byte-identical. No key added or removed.

### 6b. `C:\Users\yuni\AppData\Roaming\Claude\claude_desktop_config.json` — also updated

Written by the same command as a side effect. **Disclosure:** I backed up `settings.json` but not
this file before the run, so only its post-state is recorded. Its `mcpServers.repowise` entry is
identical in shape to 6a:

```json
{
  "command": "C:/Users/yuni/AppData/Roaming/uv/tools/repowise/Scripts/repowise.exe",
  "args": ["mcp", "J:/audio/MCP-Watchers", "--transport", "stdio"],
  "description": "repowise: codebase intelligence — docs, graph, git signals, dead code, decisions"
}
```

### 6c. Repo-local `.mcp.json` — untouched

Still holds the pre-existing entry with the bare `repowise` command. Not in scope for this bead
(doctor does not read it), and it is a tracked file I must not edit. **Flagged for follow-up:** it
still points at the shadowed PATH name.

## 7. Verification — doctor AFTER

```
$ "$RP" doctor
│ Claude Code MCP entry │ OK     │ J:/audio/MCP-Watchers
│ MCP server responds   │ OK     │ repowise initialised in 3843ms
│ Agent: claude-code    │ OK     │ wired up
```

The bead's required line, quoted exactly:

```
│ Claude Code MCP entry │ OK     │ J:/audio/MCP-Watchers
```

(was `not registered (repowise init registers it)`). The smoke check also flipped from
`not registered - nothing to launch` to `repowise initialised in 3843ms` — the server now
actually launches and completes its handshake.

## 8. Still outstanding — NOT this bead (mcpw-4w4)

Store drift remains, exactly as the bead predicted. Not touched here:

```
│ Stale pages           │ FAIL │ 1 stale — pages whose content lags the code ... `repowise update --full` regenerates them
│ SQL ↔ Vector Store    │ FAIL │ 63 missing, 0 orphaned
│ SQL ↔ FTS Index       │ FAIL │ 2 missing, 0 orphaned
│ Coordinator drift     │ FAIL │ SQL=64, Vector=1, Drift=98.4%
```

Also noted (pre-existing, unrelated): `CLI version WARN current 0.49.0, latest 0.51.0, path
C:\Users\yuni\.local\bin\repowise.EXE, running C:\Users\yuni\AppData\Roaming\uv\tools\repowise\Scripts\repowise`
— i.e. the shadow on PATH reports 0.49.0 while the real tool runs 0.51.0. Reinforces the
absolute-path requirement.

## 9. DONE / NOT DONE

**DONE.** Registered at user scope in `C:\Users\yuni\.claude\settings.json` (backed up first at
`C:/Temp/claude_settings.json.preinit.bak`); the entry pins the real binary's absolute path.
`repowise doctor` now reports `Claude Code MCP entry │ OK │ J:/audio/MCP-Watchers` and
`MCP server responds │ OK │ repowise initialised in 3843ms`. No model configuration was changed.
Store drift (63 vector / 2 FTS / 98.4% coordinator) is mcpw-4w4 and remains outstanding.
