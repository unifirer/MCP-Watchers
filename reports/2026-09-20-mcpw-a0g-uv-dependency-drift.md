# mcpw-a0g — uv tool venv dependency drift is silent

- **Bead:** mcpw-a0g (P2 bug)
- **Date:** 2026-09-20
- **Branch:** `mcpw-sweep-20260920-1305`

---

## 1. The defect

The uv-tool venv at `%APPDATA%\uv\tools\repowise` (repowise 0.49.0) lost four
declared core dependencies — `sqlalchemy[asyncio]`, `alembic`, `uvicorn`,
`litellm` — plus the transitive `greenlet`. `repowise --version` still printed
`0.49.0` because it never imports them, so the install looked healthy while
`watch`, `update` and `reindex` were all dead at import time:

- `watch` → `repowise/core/workspace/registry.py:19`
- `update` → `repowise/core/analysis/test_reachability.py:155`

## 2. Why the mcpw-qzm guard could not see it

mcpw-qzm added a `Test-Path` sentinel over the four **direct** dependency names.
It fails in two independent ways, and both were measured rather than assumed:

**(a) A half-uninstalled package still imports.** A `site-packages/sqlalchemy`
directory whose `__init__.py` has been removed still resolves — Python treats it
as a **namespace package**, so `import sqlalchemy` succeeds and returns an empty
module. The failure only surfaces deeper:

```
ImportError: cannot import name 'ColumnElement' from 'sqlalchemy' (unknown location)
  repowise/core/workspace/registry.py:19
```

A `Test-Path` sentinel is TRUE throughout that. Presence is not importability.

**(b) Four names missed the transitive closure.** `greenlet` (via
`sqlalchemy[asyncio]`) and `aiosqlite` are needed by the same import chain and
were never checked.

## 3. What the guard does now

Replaced in `###1.watchers_for_..._repowise.ps1`, inside the test-extracted
region bounded by `# >>>>> mcpw-a0g repowise dependency guard >>>>>` /
`# <<<<< ... <<<<<`:

| Function | Role |
|---|---|
| `Invoke-ToolVenvDependencyProbe` | Runs the probe in the tool's **own** interpreter. Returns `.Probed`, `.Ok`, `.Missing`, `.Error`. |
| `Get-ToolVenvDependencyRepairCommand` | Builds the exact repair command. |
| `Get-ToolVenvDependencyWarning` | One-line warning naming the broken dependency and the repair command. |
| `Repair-ToolVenvDependencies` | Executes the repair, opt-in only. |

The probe verifies in two passes:

1. **Real imports** of the modules the watcher's import graph actually needs
   (`sqlalchemy`, `sqlalchemy.ext.asyncio`, `alembic`, `uvicorn`, `greenlet`,
   `aiosqlite`) — cheap set, ~3 s.
2. **The full declared requirement closure** of the installed `repowise` dist
   via `importlib.metadata`, checked for presence and for a locatable top-level
   module (`find_spec`, not executed).

`litellm` is deliberately **not** imported by default: measured ~12 s on this box
against ~3 s for everything else, and pass 2 still covers its presence. Set
`MCPW_REPOWISE_DEEP_PROBE=1` to add it.

An absent interpreter is reported as `interpreter not found`, never as a pass.

## 4. Warn vs auto-repair — decision

**Default: warn loudly with the exact repair command. Auto-repair is opt-in**
(`MCPW_REPOWISE_AUTOREPAIR=1`).

Reasoning: repair mutates a tool install **outside this repo**, over the network,
in a venv other tooling shares. It also **cannot succeed while `repowise watch`
is live** — the running interpreter holds sqlalchemy's C-extension `.pyd`, so uv
fails with `Access is denied (os error 5)` *after* already uninstalling part of
the package. That is measured, not theoretical: it is exactly how sqlalchemy's
dist-info was lost in the first place. A default-on repair would therefore be
capable of making the venv strictly worse, at a moment chosen by the launcher
rather than by the operator.

The repair command uses `--reinstall-package`, not a bare `--reinstall`: a bare
`--reinstall` re-resolves the whole closure and was measured to upgrade
`websockets 16.1.1 → 17.1` as a side effect.

## 5. repowise restored — evidence

Repair ran 2026-09-20 15:30–15:38. Verified after:

```
$ %APPDATA%\uv\tools\repowise\Scripts\python.exe -c "import ..."
OK   sqlalchemy
OK   sqlalchemy.ext.asyncio
OK   alembic
OK   uvicorn
OK   litellm
OK   greenlet
OK   aiosqlite
```

`repowise.exe --version` → `repowise, version 0.49.0`.
`repowise doctor` **runs** — which is the real proof, since it exercises the
`sqlalchemy.ext.asyncio` path at `registry.py:19` that was dead:

```
Git repository         OK   J:\audio\MCP-Watchers
.repowise/ directory   OK
Database               OK   47 pages
Store format           OK   Current
```

Still open after the repair, and **not** this bead's scope:

| Doctor check | State | Owner |
|---|---|---|
| Stale pages (1) | FAIL | needs `repowise update --full` |
| SQL ↔ Vector Store (46 missing) | FAIL | mcpw-4w4 |
| SQL ↔ FTS Index (2 missing) | FAIL | mcpw-4w4 |
| Coordinator drift 97.9% | FAIL | mcpw-4w4 |
| Claude Code MCP entry not registered | — | mcpw-a2j |

## 6. Tests

`tests/launcher_uv_dependency_guard.tests.ps1` — **7 of 7 passed**.

Two failures found on first run and fixed before commit: the suite mixed legacy
Pester 4/5 assertions (`| Should Match`, `| Should Not Match`) with Pester 6
idiom. Pester 6.1.0 removed the legacy form, so every one of the five affected
`It` blocks died in `ParameterBindingException` — *silently*, because Pester
reports it as a test failure rather than a discovery error. Converted to
`Should -Match` / `Should -Not -Match`.

Regressions: `launcher_watcher_panes` 7 of 7, `launcher_watcher_teardown` 14 of 14,
`launcher_watcher_teardown_sweep` 3 of 3, `launcher_memtrace_orphan_sweep` 14 of 14.
All three changed `.ps1` files pass `Parser::ParseFile` with zero errors.
