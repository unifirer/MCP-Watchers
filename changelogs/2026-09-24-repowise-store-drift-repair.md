# `mcpw-4w4` — repowise store drift repaired, and why the repair silently failed first

Closing the OPTIONAL repowise-store bead (child of epic `mcpw-rkg`).

## Before

`repowise doctor` on MCP-Watchers, 2026-09-24 (CLI 0.49.0):

| Check | Status | Detail |
|---|---|---|
| Stale pages | OK | 0 stale (the bead's original "1 stale" had since cleared) |
| SQL ↔ Vector Store | **FAIL** | 81 missing, 0 orphaned |
| SQL ↔ FTS Index | **FAIL** | 2 missing, 0 orphaned |
| Coordinator drift | **FAIL** | SQL=94, Vector=13, **Drift=86.2%** |

The bead recorded 97.9% drift on 2026-09-20; it had grown to 94 pages while
only 13 carried a vector.

## The trap: the repair ran, reported success-shaped output, and indexed nothing

`repowise reindex` is the correct verb (`--repair` is a flag on `doctor`, not a
top-level option — the bead's wording predates this CLI). The first run:

```
Using gemini embedder
Found 94 wiki pages and 2 decision records to index.
  Warning: failed to embed ...: The read operation timed out     (x96)
Done! Indexed 0 items (96 failed)
```

Every single embed timed out. The cause is **not** the network and **not** the
embedder choice:

* `GEMINI_API_KEY` is set (39 chars) and a direct `embedContent` call with it
  returns a 3072-dim vector — the key is good.
* The environment also carries `GOOGLE_GENAI_USE_VERTEXAI=true`,
  `GOOGLE_CLOUD_PROJECT=sulliproject`, `GOOGLE_CLOUD_LOCATION=global`.
* There is **no** `~/.config/gcloud/application_default_credentials.json` and no
  `gcloud` on PATH.

So the Gemini SDK was routed down the Vertex AI path with no credentials to
authenticate it, and every request hung until the read timeout. `reindex`
reported this as 96 per-item warnings and still exited 0 — the failure mode is
"success-shaped", which is why the drift survived.

**Fix (auth plumbing only — no model changed):** unset the Vertex variables for
the reindex process so the SDK uses the API key that is already present.

```
env -u GOOGLE_GENAI_USE_VERTEXAI -u GOOGLE_CLOUD_PROJECT -u GOOGLE_CLOUD_LOCATION \
    repowise reindex --batch-size 4
```

This is deliberately process-scoped, not a global environment change: other
tools on this box may legitimately want the Vertex path, and the standing
operator constraint forbids changing which models an MCP uses. The embedder
stays `gemini`; only the credential path moved.

## Second trap: the free tier answers 429, so one pass is never enough

With auth fixed the embeds actually ran, and 58 of 96 immediately returned
`429 RESOURCE_EXHAUSTED` (Gemini API free-tier quota). The quota is
per-minute-ish, so repeated passes converge — the observed sequence over
consecutive runs was 38, 38, 38, 72, 65 indexed. Looping until the missing
count stops moving is what got it to zero.

## Result

```
repowise doctor --repair --no-workspace
  Repairing store mismatches...
  Repaired 2 entries.

repowise doctor --no-workspace
  Stale pages           OK    0 stale
  SQL ↔ Vector Store    OK    in sync
  SQL ↔ FTS Index       OK    in sync
  Coordinator drift     OK    SQL=96, Vector=96, Drift=0.0%
  All checks passed!
```

Drift **97.9% → 0.0%**; vector store in sync. The last 2 FTS entries were fixed
by `doctor --repair`, not by `reindex` — worth knowing, because `reindex`
reports "already up to date" for that gap and `update --index-only` changes
nothing.

Independently confirmed that FTS is functionally working rather than merely
counter-clean: `repowise search watcher_mcp_provision` returns ranked hits with
snippets.

## Not done

The bead's optional extra — upgrading CLI 0.49.0 → 0.52.0 — was explicitly
conditional on "only if the drift survives a repair on the current version". It
did not survive, so no upgrade was made.

`.repowise/lancedb/` is untracked and is not ignored; the repaired vector store
is local state, not a committed artifact. The tracked `.repowise/*.json` and
`*.pkl` caches churn continuously and were already dirty from other sessions, so
they were deliberately left unstaged rather than swept into this change.
