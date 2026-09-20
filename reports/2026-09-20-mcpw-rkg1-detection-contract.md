# mcpw-rkg.1 — per-MCP "is it initialized?" detection contract

- **Bead:** mcpw-rkg.1 (P1), parent epic **mcpw-rkg** ("Launcher must bootstrap
  all six MCPs in ANY repo it is launched from")
- **Date:** 2026-09-20
- **Branch:** `mcpw-sweep-20260920-1305`
- **Scope:** the **detection layer only**. No init, build, index or repair code
  lives here — that is mcpw-rkg.2.
- **Verdict:** six probes implemented and **verified live against this repo**;
  every verdict matches the state measured earlier the same day.

---

## 1. The contract

```powershell
Test-<Mcp>Initialized -Path <repoRoot> [-Reason ([ref]$s)] [-ProbeOutput <text>]
```

| Aspect | Decision |
|---|---|
| **Return** | `[bool]`. `$true` = initialized, the caller may skip the build. `$false` = not initialized *or* cannot tell, so bootstrap runs. |
| **Reason** | `-Reason` out variable. `$r = ''; Test-X -Path $p -Reason ([ref]$r)`. One line, written for the launcher log. |
| **Signature uniformity** | All six probes take the same three parameters in the same order, return the same type, and expose the reason the same way. |
| **Aggregate** | `Get-McpInitializationReport -Path <root>` returns one object per MCP with `.Mcp`, `.Ok`, `.Reason` in a fixed order. This is the shape mcpw-rkg.2 should consume. |

### The three rules every probe obeys

1. **Rooted at `-Path`.** No absolute repository path, no assumption about which
   repository this is. Verified by running the suite against a synthetic layout
   under `%TEMP%`.
2. **A missing binary is a normal answer, never an exception** — `$false` with
   reason `binary not found: <name>`. The binary check runs **first**, so a probe
   answers "can this repo be initialized for that tool at all?" before it looks
   at any artifact. No probe throws.
3. **A non-git directory is fine.** Nothing in the module shells out to git, and
   no probe requires a `.git` directory.

### Reason vocabulary

`binary not found: <name>` · `path not found: <path>` · `scope file missing:` ·
`scope file unreadable:` · `scope file has no members[]` · `repo path is not a
member of the memtrace store scope` · `config missing:` · `grepai status reports
Files indexed: 0` · `workspace config missing: .graphenium/` · `graph missing:` ·
`output dir missing: graphify-out/` · `graphify-out/ exists but holds no built
graph:` · `store missing: .repowise/` · `... Claude Code MCP entry is not
registered` · `manifest missing: graft/manifest.json`

A bare `$false` with an empty reason is a defect, not a verdict — the test suite
asserts the reason is non-empty and inside this vocabulary.

---

## 2. The six signals, and why each one

| MCP | Signal (all rooted at `-Path`) | Measured counter-example that forced the signal |
|---|---|---|
| **memtrace** | `.memdb/.memtrace-store-scope.json` exists, parses, and one of its `members[].path` entries equals the repo path (normalised: absolute, forward slashes, lowercase). | `memtrace status` **cannot** confirm this — it prints `Graph counts: not loaded (status never opens a local MemDB store)`. A live node count needs `memcore-server.exe`, whose MCP call timed out (mcpw-rkg.7). The scope file is written by memtrace itself and is the authoritative membership record. |
| **grepai** | `.grepai/config.yaml` exists **AND** `grepai status` reports `Files indexed` > 0. | Config was already right (ollama `nomic-embed-text` at 127.0.0.1:12134, qdrant backend `localhost:16334`) and status still said **`Files indexed: 0` / `Total chunks: 892`**. A correct config with an empty index is not initialized — there is nothing to search. |
| **graphenium** (`gm`) | `.graphenium/` workspace config dir exists **AND** `graphenium-out/graph.json` exists. | The graph was present (241 nodes, from an earlier `gm run`) with **no `.graphenium/`** — `gm init` had never run. Config is checked first so the reason names it. |
| **graphify-rs** | `graphify-out/graph.json` exists. | `graphify-out/` is the build output dir (this repo's `.gitignore` entry, and the dir the ignore gate keeps out of rebuild triggers). `graph.json` is what the mandated rebuild writes — `graphify-rs build --path . --update --no-llm` (`Get-GraphifyRebuildArgs`, `Modules/graphify_ignore_gate.ps1:155`) — and what `graphify-rs serve --graph <...>` loads. Confirmed on the sibling repo: `J:/audio/VAD/graphify-out/` holds `graph.json` (2.4 MB) next to `graph.graphml` / `graph.html` / `.graphify_manifest.json`. An **empty** `graphify-out/` is not initialized (a build that died partway leaves the dir behind). |
| **repowise** | `.repowise/` store exists **AND** `repowise doctor` does not report the *Claude Code MCP entry* as `not registered`. | Store was fine (**47 pages**) while doctor printed `Claude Code MCP entry \| OK \| not registered (repowise init registers it)` and separately `MCP server responds \| OK \| not registered - nothing to launch`. `repowise init` is what registers the entry, so an unregistered store is not initialized. |
| **graft** | `graft/manifest.json` exists. | `graft_check_freshness` reported `No graft/manifest.json found. Run graft build --deep first` — the manifest can be **missing entirely**, not merely stale. `graft/.graph/wiring.json` existed at that moment and is **not** sufficient: it is the wiring cache, not the graph. |

### Signals deliberately NOT used

- **`memtrace status` / a live node count.** It never opens a local MemDB store,
  so it cannot confirm membership; the live path times out. Best-effort only, and
  deliberately not required.
- **grepai's liveness clock (`watch.last_index_time`).** It is written at
  scan/checkpoint boundaries, not per write, so a **stale** clock is not proof of
  a dead write path — and the inverse is also true. The live capture below shows
  a **fresh** clock (`Last updated: 2026-09-20 14:31:22`) with `Files indexed: 0`.
  Only the file count decides.
- **grepai config validity.** See the counter-example above.
- **`graft/.graph/wiring.json`.** Wiring cache, not a graph.
- **`.repowise/` alone.** 47 pages and still unregistered.
- **`graphenium-out/graph.json` alone.** 241 nodes and still unconfigured.
- **`graphify-rs`'s machine-global store** (`%USERPROFILE%\.graphify-rs\<Repo>-<hash>\graph.json`).
  That store is created by `graphify-rs serve`, not by the launcher's rebuild, so
  it is not evidence that the *repo's* build output exists.

---

## 3. Live verification against this repo

`Get-McpInitializationReport -Path J:\audio\MCP-Watchers`, run 2026-09-20. This
exercised the real filesystem **and** live `grepai status --no-ui` and
`repowise doctor` calls (not injected text):

```
memtrace     True   repo is a member of the memtrace store scope (1 member(s))
grepai       False  grepai status reports Files indexed: 0 (config present, index empty)
graphenium   False  workspace config missing: .graphenium/ (gm init never ran)
graphify-rs  False  output dir missing: graphify-out/ (no graphify-out/graph.json)
repowise     False  .repowise/ store present but the Claude Code MCP entry is not registered
graft        False  manifest missing: graft/manifest.json (graft/.graph/wiring.json alone is not a graph)
```

Every line matches the state measured earlier on 2026-09-20 — including the one
`$true`, which is the important one: memtrace is the only MCP already
initialized here, so it is the only build the launcher may skip.

### Raw captures used to shape the parsers

`grepai status --no-ui` (this repo, 2026-09-20):

```
grepai index status
Files indexed: 0
Total chunks: 892
Index size: N/A
Last updated: 2026-09-20 14:31:22
Provider: ollama (nomic-embed-text)
Watcher: not running
```

`repowise doctor` (this repo, 2026-09-20), relevant rows only:

```
│ Claude Code MCP entry │ OK     │ not registered (repowise init registers it) │
│ MCP server responds   │ OK     │ not registered - nothing to launch          │
│ Agent: claude-code    │ OK     │ repowise is not registered with Claude Code.│
```

Two parser traps this capture pinned down:

- The doctor **status column says `OK`** for the unregistered row — the state is
  in the **detail** column. The probe therefore tests the whole *line* that names
  `Claude Code MCP entry`, not the status.
- The `Agent: claude-code` row also contains the words "not registered" and must
  not be mistaken for it — hence the line filter is anchored on the exact check
  name rather than on the phrase.
- `repowise doctor` **exits 0** while reporting FAILing checks, so the exit code
  is never consulted; the text is the signal.

---

## 4. Return-shape decision (and a PowerShell trap worth knowing)

`-Reason` is an out variable **plus** `Get-McpInitializationReport` returning
`.Ok`/`.Reason` objects. mcpw-rkg.2 should prefer the aggregate.

`Set-McpDetectReason` is **typed `[object]` and must be called positionally**.
This was measured, not guessed, on Pester 6.1.0 / Windows PowerShell 5.1:

| Call shape | Result |
|---|---|
| `[object]` param + **positional** `([ref]$x)` | ref survives, the write lands ✅ |
| `[object]` param + **named** `-R ([ref]$x)` | PowerShell **unwraps** the ref; the callee sees a plain `String` and the reason is **silently dropped** ❌ |
| `[object]` param + omitted / `$null` | skipped, no throw ✅ |
| `[ref]` param + omitted | skipped ✅ |
| `[ref]` param + explicit `$null` | **throws** at binding, before any probe code runs ❌ |

A `[ref]`-typed parameter would survive named binding, but it throws when a probe
forwards its own possibly-`$null` `-Reason`. `[object]` + positional is the only
shape correct in all cases. The probe's own `-Reason` **is** typed `[ref]` (that
is the public, idiomatic form); only the internal helper is `[object]`.

**Caller note:** pass `([ref]$s)` or omit `-Reason` entirely. Do **not** pass a
literal `$null` — that is rejected at binding time and is a caller bug, not a
probe bug.

---

## 5. Tests

`tests/launcher_mcp_detect.tests.ps1` — 11 tests, Pester 6.1.0.

```
python dev_tools/run_pester_suite.py tests/launcher_mcp_detect.tests.ps1
VERDICT : passed=11 failed=0   (rc=0, ignored)
```

**11 of 11 tests passed.**

Coverage:

1. dot-sources cleanly and exposes all six probes (+ the aggregate);
2. `FALSE` with a reason from the vocabulary on an empty directory (all six);
3. `TRUE` on a synthetic initialized layout for every MCP — the layout is built
   under `%TEMP%`, and each MCP asserts `TRUE` when its CLI is on PATH or the
   `binary not found` verdict otherwise, so the suite is honest on a box without
   the tools rather than silently passing;
4. `FALSE` + exactly `binary not found: <name>` for all six with the tool removed
   from `PATH` (proves the binary check runs **first** — a layout-first probe
   would have reported a missing artifact instead);
5–10. one test per **measured partial signal**, each asserting `FALSE`:
   grepai with a correct config and `Files indexed: 0`; graphenium with a graph
   but no `.graphenium/`; graft with only `.graph/wiring.json`; memtrace with a
   well-formed scope file naming a *different* repo; graphify-rs with an empty
   `graphify-out/`; repowise with a store and an unregistered MCP entry;
11. `Get-McpInitializationReport` returns six rows in a fixed order.

### Two Pester 6 constraints this suite had to be shaped around

Both were measured directly; both cost a debug cycle, so they are recorded here
for the next agent writing a suite in this repo:

1. **Nothing defined at file scope is visible inside an `It` block.** File-scope
   variables (plain, `$script:`-qualified, literal and computed) all read back
   **empty**; a function defined at file scope, a function arriving from a
   dot-sourced `.ps1`, and a scriptblock held in a file-scope variable are all
   unusable. The **only** survivors are `$PSScriptRoot` and `$PSCommandPath`. So
   every `It` re-derives the module path from `$PSScriptRoot` and dot-sources the
   module itself. Do not "tidy" that into a file-scope helper.
2. **A file-scope dot-source inside a `Should -Not -Throw` scriptblock is a
   no-op** for the rest of the test: the scriptblock runs in a child scope, so
   the functions it defines vanish. Dot-source directly.
3. The file must not **import Pester itself**, not even inside a comment —
   `run_pester_suite.py`'s sniff is a plain substring test, and a false positive
   makes the runner execute the file directly instead of wrapping it, which turns
   a `Should -Be` suite into a discovery-failure retry loop.

---

## 6. Left for mcpw-rkg.2 (not done here — deliberately)

- No probe builds, indexes, repairs, registers or spawns anything persistent.
- No launcher wiring: `###1.watchers_...ps1` was **not** touched (owned by
  mcpw-gsj / the mcpw-rkg.3 wave).
- Consume `Get-McpInitializationReport -Path $watchersWorkspaceRoot` and, for each
  `Ok = $false`, warn and skip — a foreign repo legitimately lacks some tools.
- Reuse `-ProbeOutput` when a capture is already in hand (the bootstrap will run
  `grepai status` anyway), so no tool is spawned twice.
- Nothing here detects whether an MCP **server process** is bound to the right
  repo. That is a separate, real problem (mcpw-rkg.7): a pane can look healthy
  while the server answers from another repository.

---

## 7. Changed paths

```
Modules/watcher_mcp_detect.ps1                       (new)
tests/launcher_mcp_detect.tests.ps1                  (new)
reports/2026-09-20-mcpw-rkg1-detection-contract.md   (new, this file)
```

Nothing else was modified. `###1.watchers_...ps1`, the other `Modules/*.ps1`,
`AGENTS.md` and `README.md` are untouched. Paths claimed with
`python dev_tools/claim_paths.py claim --owner mcpw-rkg.1 --wave 20260920-1305`.
