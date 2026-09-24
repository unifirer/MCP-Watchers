# Graphenium semantic analysis is now a live toggle (epic `mcpw-b81`)

**Bead:** `mcpw-b81.6` (docs) closing out epic `mcpw-b81`.
**Trigger:** operator request — enable/disable graphenium's semantic analysis
without restarting the launcher.

## What changed

Graphenium's semantic analysis (LLM enrichment layered on the AST graph) used to
be hardcoded on. It is now governed by a per-repo switch that is re-read on every
rebuild, so flipping it takes effect from the next rebuild with no restart.

* **Control file:** `<repo>\.mcpw-provision\gm-semantic.mode`, holding `on` or
  `off`. Absent / blank / unparseable ⇒ **off** (AST-only), which preserves the
  historical default.
* **Launch default:** `MCPW_GM_SEMANTIC` supplies the value only when the file is
  absent. It does not override a file that says `off`.
* **Toggle command:** `dev_tools/gm-semantic-toggle.ps1` — it writes the control
  file. The launcher keeps ownership of the `--no-semantic` literal; do not
  hand-edit it.
* **Reader:** `Test-GmSemanticEnabled` in the launcher.
* **Pane:** the graphenium pane prints
  `=== graphenium | semantic: on (LLM enrichment) ===` / `off (AST-only)` at
  startup and on change, so the mode is visible without grepping `gm.log`.

## Why the gate moved

The proxy-readiness gate used to be unconditional: if the fallback proxy was
down, the whole rebuild was skipped. Semantic enrichment is the only part of the
pipeline that needs an LLM, so with semantic **off** the rebuild is pure AST
extraction and needs no proxy at all. Gating it on the proxy anyway meant a
downed proxy silently cost the operator the structural graph too — that is the
bug the conditional gate fixes. With semantic off and the proxy down, AST-only
rebuilds now keep running.

## Cost

Semantic **on** means chat-completion calls through the local fallback proxy
(`###2.llm_fallback_proxy.py`, port 11436). Semantic **off** issues no tokens and
no cloud calls.

Constraint worth restating, because it is the most re-litigated dead end in this
area (`mcpw-96y`): the semantic path is **chat-completions only** and cannot be
served by an embedding model.

## Files touched

| File | Change |
|---|---|
| `###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1` | `Test-GmSemanticEnabled` reader; conditional proxy gate; conditional `--no-semantic`; mode in the `[gm-semantic]` log line |
| `dev_tools/gm-semantic-toggle.ps1` | writes the control file |
| `Modules/watcher_pane_scripts.ps1` | pane status line (`mcpw-b81.10`) |
| `tests/launcher_gm_semantic_toggle.tests.ps1` | 9 of 9 — locks the toggle (`mcpw-b81.5`) |
| `tests/launcher_gm_semantic_pane.tests.ps1` | 4 of 4 — locks the pane line (`mcpw-b81.10`) |
| `tests/launcher_gm_semantic_build.tests.ps1` | rewritten off the retired Nous contract (`mcpw-b81.8`) |
| `tests/test_launcher_gm_wiring.py` | key-leak guard de-inerted (`mcpw-b81.9`) |
| `docs/guides/launchers-and-watchers.md` | "The Graphenium Semantic Toggle" section |

## Note on the tests

Two of the suites in this area were passing for the wrong reason and were
repaired in the same push: `launcher_gm_semantic_build.tests.ps1` asserted
`NOUS_API_KEY` / `NOUS_BASE_URL`, which the launcher no longer consults (one is
only a comment, the other an unread env default), and the key-leak guard in
`test_launcher_gm_wiring.py` matched a log line that does not exist, so it never
executed. Both now assert the live contract and fail loudly if the anchor drifts
again.

## Caveat

The 6-pane Windows Terminal grid was not relaunched to observe the pane line
live; the change is evidenced structurally (module parse-clean, pane-name title
untouched, `launcher_watcher_panes` 7 of 7) rather than by observation.
