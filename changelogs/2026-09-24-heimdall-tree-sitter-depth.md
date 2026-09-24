# heimdall's symbol depth: the missing module was `graphify`, not `tree-sitter`

**Bead:** mcpw-qxj.5 (P3 OPTIONAL, child of mcpw-qxj)
**Date:** 2026-09-24
**Verdict:** fixed — heimdall now extracts real symbols for this repo's two languages
(PowerShell and Python). The bead's premise was half stale; the real defect was one
level deeper.

## What the bead said

`heimdall daemon --once --dry-run` printed:

    heimdall-reconciler: depth cap file (tree-sitter not importable - L2/L3 unavailable)

so the task was "install the tree-sitter python bindings into heimdall's venv and
confirm the effective depth rises above file level".

## What was actually true (measured 2026-09-24)

1. **The cap line was already `graph`.** `tree-sitter 0.26.0` was installed and
   importable, so the cap check passed and the daemon reported:

       heimdall-reconciler: depth cap graph (tree-sitter available)

   The `depth cap file` line in the bead is history from 2026-09-20.

2. **Depth was nevertheless file-level, because the extraction bridge was dead.**
   Driving the bridge directly (`bin/lib/heimdall_extract.py`) returned, for both a
   `.py` and a `.ps1` file in this repo:

       {"results": {"<file>": {"nodes": [], "edges": [], "error": "graphify-import: No module named 'graphify'"}}}

   Nodes empty, edges empty, one error. A passing cap check over a dead bridge is
   exactly the "green light over a dark room" shape: the capability probe and the
   capability itself were measured by different code.

3. **Root cause:** the published npm tarball omits `vendor/graphify/`. Its
   `package.json` `files` list ships `vendor/graft/` only, so the Python bridge has
   nothing to import. The PyPI distribution of the same project is named
   **`graphifyy`** (two y's), not `graphify` — which is why a naive
   `pip install graphify` finds the wrong package.

## The interpreter heimdall actually uses

Not assumed — traced through `bin/lib/depth.mjs:30-43`, which resolves in order:
`$HEIMDALL_PYTHON` (unset) → `~/.heimdall/venv/bin/python3` → `python3`.
That shim reports:

    executable C:\Users\yuni\.heimdall\venv\bin\python3
    prefix     C:\Users\yuni\.heimdall\venv
    version    3.10.6

Note the interpreter is **3.10.6**, not the 3.14 that a `pip3.14.exe` in `Scripts/`
suggests — that file is a red herring. The venv is real and lives under
`~/.heimdall/venv` (which is also why the `heimdall-windows-venv-shim` skill exists).

## The fix

Into that venv only (never the system Python, never global; all prebuilt wheels, no
compiler needed):

    python3.exe -m pip install graphifyy
    -> graphifyy-0.9.67, tree-sitter-python-0.25.0, tree-sitter-powershell-0.26.4
       plus 24 other grammar wheels; tree-sitter 0.26.0 -> 0.25.2

## Evidence (re-verified independently of the fixing agent)

Bridge, after — real symbols, not just counts:

| file | nodes | edges | first symbols |
|---|---|---|---|
| `###2.llm_fallback_proxy.py` | 42 | 68 | `_env_int()`, `_env_float()`, `ModelHealthTracker`, `.is_healthy()` |
| `###1.watchers_...repowise.ps1` | 68 | 108 | `Get-WatchersWorkspaceKey()`, `Acquire-LauncherLock()`, `Test-HttpPortAnswering()` |

`error: None` on both, and the edges carry real relations (`imports`, with
`_python_import_module` metadata; `contains`, with `confidence: EXTRACTED`).

**Probe trap worth remembering:** the symbols live under the node key **`label`**, not
`symbol`. A probe that reads `n.get('symbol')` prints `[None, None, ...]` while the
extraction is in fact working — an apparent failure produced by the measuring code.
Assert on `label`.

## Caveats (do not mistake these for regressions)

- **`tree-sitter` was downgraded 0.26.0 → 0.25.2**, because `graphifyy` pins `<0.26`.
  The cap check still passes; no other consumer of that venv is known to depend on the
  newer ABI.
- **A long-running daemon caches `_cachedCap`** (and the interpreter probe). A daemon
  already running before this change keeps reporting its cached capability until it is
  restarted.
- **The daemon reconciles 0 paths** — `~/.heimdall/config.json` has no `roots`
  configured, so `--once` reports `watching 0 root(s)` / `bootstrap scan enqueued 0
  path(s)`. That is a separate concern (watcher provisioning), not this bead.

## Files

No repository source changed: this was an environment fix inside
`C:\Users\yuni\.heimdall\venv`. Working evidence is under
`.bead-work/mcpw-qxj.5/` (before/after captures and the probe scripts).
