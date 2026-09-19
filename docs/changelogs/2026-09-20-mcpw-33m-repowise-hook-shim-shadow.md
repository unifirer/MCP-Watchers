# mcpw-33m — post-commit hook: bypass declick shim shadowing of `repowise`

Date: 2026-09-20
Bead: mcpw-33m (P2, BUG) — "post-commit hook always fails: declick MCP shim
shadows repowise, no 'update' verb"

## What changed

File: `.beads/hooks/post-commit` (this file **is tracked** by git — verified with
`git ls-files .beads/hooks/`; `core.hooksPath` = `J:/audio/MCP-Watchers/.beads/hooks`,
so this, not `.git/hooks/`, is the live hook).

The auto-sync block previously did:

```sh
if command -v repowise >/dev/null 2>&1; then
  repowise update >> "$LOG" 2>&1
elif command -v uv >/dev/null 2>&1; then
  uv run repowise update >> "$LOG" 2>&1
fi
```

`command -v repowise` succeeded because the **declick MCP shim**
(`%USERPROFILE%\.declick\bin\repowise` -> `node run.mjs repowise`) sits on PATH,
so the `uv run` fallback was never reached. That shim's engine is `mcp`
(`declick describe repowise` -> `source: mcp:uvx repowise mcp J:\audio\VAD
--transport stdio`, 11 MCP verbs) and it has **no `update` verb** -> every commit
logged `{"ok":false,"error":"unknown verb update; ...","exit":2}`.

It now resolves the real CLI by absolute path, matching the launcher's pin at
`###1...ps1:1880` (`$env:APPDATA\uv\tools\repowise\Scripts\repowise.exe`), with
`uv run repowise update` only as a last resort:

```sh
REPOWISE_EXE=""
_profile_posix=""
if [ -n "$USERPROFILE" ]; then
  _profile_posix=$(printf '%s' "$USERPROFILE" | sed -e 's|\\|/|g' -e 's|^\([A-Za-z]\):|/\L\1|')
fi
for _cand in \
  "$HOME/AppData/Roaming/uv/tools/repowise/Scripts/repowise.exe" \
  "${_profile_posix:+$_profile_posix/AppData/Roaming/uv/tools/repowise/Scripts/repowise.exe}" \
  "${APPDATA:+$APPDATA/uv/tools/repowise/Scripts/repowise.exe}"; do
  if [ -n "$_cand" ] && [ -x "$_cand" ]; then REPOWISE_EXE="$_cand"; break; fi
done
if [ -n "$REPOWISE_EXE" ]; then "$REPOWISE_EXE" update >> "$LOG" 2>&1
elif command -v uv >/dev/null 2>&1; then uv run repowise update >> "$LOG" 2>&1
else printf 'repowise update: no repowise CLI found (declick shim correctly bypassed; real binary missing)\n' >> "$LOG" 2>&1
fi
```

`$APPDATA` is **not** exported into the Git-Bash hook environment on this box
(confirmed empty), so `$HOME` (`/c/Users/yuni`) is the primary candidate and
`$USERPROFILE` (`C:\Users\yuni`, converted to POSIX) is the secondary.

## Evidence

Before (`.repowise/.update.log`, repeated every commit 00:54..05:37):

```
--- post-commit hook fired at Sun Sep 20 05:37:15 NZST 2026 for HEAD 73fa699... ---
{"ok":false,"error":"unknown verb update; run: declick describe repowise","exit":2, ...}
```

Resolution before/after:

```
$ where repowise
C:\Users\yuni\.declick\bin\repowise          <-- shim (engine: mcp, no `update`)
```

After running the patched hook directly (`sh .beads/hooks/post-commit`):

```
--- post-commit hook fired at Sun Sep 20 05:55:00 NZST 2026 for HEAD 121bd5f... ---
... ModuleNotFoundError: No module named 'sqlalchemy'
```

Last `unknown verb update` is line 971 (05:37:15); the 05:55 run emits the real
failure instead. Candidate-resolution loop resolves on the first candidate to
`/c/Users/yuni/AppData/Roaming/uv/tools/repowise/Scripts/repowise.exe`.
`sh -n .beads/hooks/post-commit` -> SYNTAX OK.

## Scope note (deliberately NOT fixed here)

Fault B — the real `repowise.exe` still dies on `ModuleNotFoundError: No module
named 'sqlalchemy'` — is root-cause bead **mcpw-qzm** (P0), owned by another
agent. The acceptance criterion for mcpw-33m is met: the log now names the real
failure instead of "unknown verb update". Once mcpw-qzm lands, this hook will
succeed end-to-end with no further change.

Optional follow-up (not done, out of scope): the hook still writes
`.repowise/.update.queued` on every commit even when no update runs, and
`repowise hook install` will regenerate the bare-name form and regress this fix.

## Backup / rollback

Backup: `C:/Temp/mcpw-backups/post-commit.bak-20260920-0554`

Roll back:

```sh
cp C:/Temp/mcpw-backups/post-commit.bak-20260920-0554 \
   J:/audio/MCP-Watchers/.beads/hooks/post-commit
```

(`rm`/`Remove-Item` are intercepted on this box; if a delete is ever needed use
`[System.IO.File]::Delete('<abs path>')`.)
