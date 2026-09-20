# mcpw-eyp — graft build: graft/ graph is stale

- **Bead:** mcpw-eyp (P1)
- **Date:** 2026-09-20
- **Repo:** `J:\audio\MCP-Watchers` @ branch `mcpw-sweep-20260920-1305`
- **HEAD:** `a66b380fb2f594180efbbd4e1ca8063d4a82a0c7` (2026-09-20T19:58:07+12:00)
- **Verdict:** **NOT DONE** — action ran clean, but the bead's acceptance criterion (`graft/manifest.json` exists) is **not met**, and cannot be met by a plain `graft build`.

---

## 1. Pre-state (recorded, not re-litigated)

```
graft/.graph/wiring.json   216077 bytes   2026-09-19 09:38
graft/manifest.json        (absent)
graft/INDEX.md              2026-09-19 04:41
graft/.cache/               2026-09-19 09:38
```

`graft` CLI = `/j/Programs/npm-global/graft` → `@nanonets/graft@0.18.0`.

## 2. Command run

```bash
cd /j/audio/MCP-Watchers
graft build                 # plain, $0 no-key tier — NO --deep
```

Exit code **0**, wall time **2.3s**.

Real output:

```
parsing 40/40: tests/test_watcher_allocator.py
✓ wiring: 371 nodes (312 function, 40 file, 15 method, 4 class), 806 edges, 40 cards [javascript, python]
  parsed: 20 of 40 files (20 replayed from cache)
  → J:\audio\MCP-Watchers\graft
  graft/ is git-ignored (added automatically) — a local cache; teammates run `graft build` to get their own.
```

## 3. Post-state — the graph IS now fresh

```
graft/.graph/wiring.json   363365 bytes   2026-09-20 19:59   (was 216077 / 2026-09-19 09:38)
graft/INDEX.md             2026-09-20 19:59
graft/.cache/              2026-09-20 19:59
```

`graft check` now passes:

```
$ graft check
deep layer: not built (run `graft build --deep` for concept nodes) — wiring graph is the source of truth

graph check: OK — the wiring graph is in sync with the code. (meaning tier 0% complete — 371 of 371 node(s) pending ...)
EXIT=0
```

## 4. The acceptance criterion FAILS — `graft/manifest.json` still does not exist

```
$ find . -name "manifest.json" -not -path "./node_modules/*"
./graphenium-out/manifest.json          <-- gm's, not graft's

$ stat -c '%n | size=%s | mtime=%y' graft/manifest.json
stat: cannot stat 'graft/manifest.json': No such file or directory
```

Strongest evidence — the **actual MCP tool referenced by mcpw-rkg.1**, invoked over stdio
(`graft mcp` via a JSON-RPC client), still reports the exact "not initialized" string:

```
---- TOOL graft_check_freshness ----
{
  "result": {
    "content": [{
      "type": "text",
      "text": "graft check: NO GRAPH\n\nNo graft/manifest.json found. Run `graft build --deep` first.\n\ngraph check: OK — the wiring graph is in sync with the code. (meaning tier 0% complete — 371 of 371 node(s) pending: ###2.llm_fallback_proxy.py, ...)"
    }],
    "isError": false
  }
}
```

So the exact condition mcpw-rkg.1 defined as "not initialized" is **still present after the build**.

## 5. Root cause — plain `graft build` cannot produce manifest.json

Verified against the installed source (`@nanonets/graft@0.18.0`):

| Evidence | Location |
|---|---|
| `writeManifest(outDir, manifest)` is called **only** at the end of `buildContext()` | `dist/context/build.js:279` |
| `buildContext()` is the **LLM concept-map pass** (`engine.init()` → one LLM call per file + synthesis batches) | `dist/context/build.js:56`, `dist/engine.js:31` |
| The CLI calls `engine.init()` **only inside `if (deep)`** | `dist/cli.js:398-399` |
| The wiring tier is separate and always runs: "Wiring graph — always; LLM meaning only with --deep." | `dist/cli.js:415-417` |
| `--deep needs a key; without one, degrade to the $0 structural build.` | `dist/cli.js:367-371` |
| The CLI's own `check` treats the missing markdown layer as **informational, not a failure** (`markdownFail = !r.missing && !r.ok`) | `dist/cli.js:565-577` |

`graft/manifest.json` is therefore a **`--deep`-tier artifact**. Plain `graft build` writes
`graft/.graph/wiring.json` + per-file cards + `INDEX.md` and stops there — exactly as observed.

**The bead's prescribed remedy is insufficient by design.** Satisfying the stated criterion
requires `graft build --deep`, which needs an API key and is explicitly out of scope
(mcpw-qxj territory).

## 6. Notes

- `.gitignore` lines 53-54 (`/graft/`) were **not** modified — `git status --short .gitignore` is empty. graft's auto-ignore was a no-op.
- No tracked repo file was edited. `graft/` is gitignored; it is the only repo path written.
- Graph is now fresh: `graft check` → OK, 371 nodes / 806 edges.

## 7. DONE / NOT DONE

**NOT DONE.** The `graft build` action completed successfully (exit 0) and refreshed the wiring
graph to HEAD, but `graft/manifest.json` does not exist and `graft_check_freshness` still reports
`NO GRAPH / No graft/manifest.json found. Run graft build --deep first.` The criterion is only
reachable via `--deep`, which this bead excludes.
