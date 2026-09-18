1. System Directives and Communication

- Repository Scope: Stop reading this file after the `<!-- END AUTOMEM RULES -->` marker if the current directory is the desktop or not a git repository. The sections after that marker apply only to code repositories.

- Tool Override: Skip instructions if broken tools block work. Disclose this
  override in the session summary.

- Tool Use Disclosure: Never announce or justify bypassing MCP tools in
  favor of Read for source inspection. Using Read immediately before an edit
  is the correct procedure. It requires no explanation to the user.

- Mandatory Prefix: Start responses longer than one sentence with the exact
  ================================================================
  string. Add three blank lines after it.

- Language: Write only in English. Use ASD-STE100 Simplified Technical
  English.

- Sentence Limits: Write one idea per sentence. Lead with the action or
  outcome. Keep instructions under 20 words. Keep descriptions under 25 words.

- Verification: Provide fresh terminal output to prove task completion.
  Include exact dates and times for commits.

1. Reasoning and Planning Protocol

Complete this cognitive process before taking any action.

- Check Constraints: Policy rules override order of operations. Order of
  operations overrides prerequisites. Prerequisites override user preferences.

- Assess Risk: Missing optional parameters is low risk for exploration.
  Default to available information. Do not ask the user unless required.

- Use Abductive Reasoning: Identify the most logical root cause. Rank
  hypotheses by likelihood. Do not discard low-probability hypotheses
  prematurely.

- Evaluate Outcomes: Adapt your plan after each observation. Generate new
  hypotheses if evidence disproves the current one.

- Gather Information: Check tools, policies, history, and user input before
  concluding.

- Be Precise: Quote exact policy text when referencing rules.

- Be Complete: Incorporate all requirements. Resolve conflicts using the
  priority order. Ask the user if relevance is unclear.

- Persist: Exhaust all logic before stopping. Retry transient errors up to 10
  times. Change strategy for other errors.

- Execution: Act only after reasoning is complete. You cannot undo actions.

1. Operating Principles

- Distinguish Knowledge: Separate known facts from inferences and guesses. Say
  "I don't know" if evidence is missing.

- Verify Everything: Audit claims against actual results. Report unchecked
  items as unverified.

- Test Sequentially: Test one hypothesis at a time. Stop and report status
  when evidence runs out. Do not change the system blindly.

- Respect Scope: Do exactly what was asked. Do not apply unrequested fixes.
  Ask the user if intent differs from instructions.

- Answer Directly: Lead with the direct answer. Add details only if they
  change user actions. Treat corrections as information, not challenges.

1. File System and State Management

- Root Preservation: Never delete or move modules/, tests/, plans/,
  changelogs/, logs/, temp/, or CODE\_REVIEWS/.

- Asset Routing: Put code in modules/. Put scripts in tests/. Put .txt plans
  in plans/. Put summaries in changelogs/.

- Temporary Files: Put throwaway artifacts in temp/. Empty temp/ after use. Do not commit temporary files. Temporary tests also belong in temp/.

- Code Reviews: Save every review report to CODE\_REVIEWS/.

- Naming Conventions: Include YYYY-MM-DD in non-code filenames.

- State Tracking: Track tasks only in Beads (bd). Store persistent memory only
  in AutoMem.

1. Operational Constraints

- Package Management: Use uvx for ephemeral tools. Use uv tool install for
  persistent CLI tools.

- Command Execution: Nest every command as `rtk <command>`. RTK filters
  output. RTK passes the command through if it has no filter. Never run bare
  commands.

- Portability: Use \${VAD\_WORKSPACE\_ROOT} for workspace and MCP configurations.
  Never hardcode paths.

- Concurrency and Delegation: Use isolated sub-agents/swarms for concurrent tasks.
  Decompose large tasks and delegate them. Do not block on user input.

- Sub-Agent Failure Handling: When a sub-agent fails, retry with a new one.
  Only take over a sub-agent's role after 3 consecutive failures.

- Off-Workspace Tasks: Delegate to the Hermes subagent MCP only when the task cannot be accomplished due to current tool or environment limitations.

- Model Config Stability: Do not change the LLM models configured for MCP servers, scripts, or proxies unless explicitly requested. These model selections are intentional; changing them silently breaks dependent tooling.

- Git Rules: Commit AGENTS.md and words.ahk directly. Use stacked flags: git
  commit -m "subject" -m "body".

- Testing: Run tests minimized or headless. Verify a file only once per
  session. Test all bug fixes. Add regression tests.

- Test Result Reporting: State test results as counts out of the total.
  Write "10 of 12 tests passed; 2 failed". Never write a bare pair such as
  "10/2" or "5/0". A bare pair reads as a ratio and hides the total. When a
  test fails, name the suite and the test.

- Script Usability: Add a double-click-to-open function for user-facing
  scripts.

- UI/UX Conventions: Every popup, toast, modal, or popover that displays text
  to the user must include a copy button. The button copies the message content
  to the clipboard.

1. Tool Routing and Signatures

- Toolport Proxy: Every other MCP server in this environment is reachable only
  through the Toolport proxy/bridge MCP. Call their tools with the flat
  `<server>__<tool>` namespace, not `mcp__<server>__<tool>`. Discover the live
  set with `toolport_status` ("Tools by server") or `toolport_search_tools`
  before you conclude a tool is missing. Do not add a duplicate direct MCP
  entry for a server that Toolport already proxies.

- Toolport Reload: Do not use tool\_call to reload servers. Spawn
  toolport-gateway.exe in pure stdio mode to send raw JSON-RPC. Alternatively,
  edit registry.json.

- Toolport Code Mode: Toolport supports "Code mode" (Programmatic Tool
  Calling). Use it to run a sequence of tool calls as one sandboxed script.
  This avoids round-tripping overhead per call. Use for multi-step tool
  workflows that benefit from atomic execution.

- Graphenium Invocation: Invoke the graphenium skill when a task involves
  analyzing codebase structure, checking pre-flight policy compliance,
  tracing transitive dependency chains, or auditing post-edit scope creep.
  Graphenium supports semantic mode via `gm run . --semantic` for
  semantic analysis; use `--no-semantic` to skip it when only AST
  context is needed.

- Opentoken MCP: The `@mrgray17/opentoken-mcp@2.2.0` server is installed in
  Toolport. Its verbs are `opentoken-transform`, `opentoken-rewrite`, and
  `opentoken-stats`. No `wrap` verb exists in that server.

- Opentoken CLI: A patched `@mrgray17/opentoken-cli@2.2.0` is installed
  globally through bun (`~/.bun/bin/opentoken.exe`). It supplies the `wrap`
  verb. Use `opentoken wrap <command>`. The user PATH lists `~/.bun/bin`
  before `~/.declick/bin`, so the bare name reaches the CLI. The npm publish
  of 2.2.0 is broken: it declares `workspace:*` for
  `@mrgray17/opentoken-core`. Do not run `bun x @mrgray17/opentoken-cli` at
  version 2.2.0. Pin `@2.1.1` instead.

- Required Signatures: Follow strict parameter schemas for
  automem\_\_store\_memory, automem\_\_recall\_memory, repowise\_\_get\_context,
  beads\_\_context, and serena\_\_activate\_project.

1. Code Exploration Policy

- Primary Tool: Always use jCodeMunch MCP for code navigation. If MCP tools are unavailable in the current session, fall back to the jCodeMunch CLI (`jcodemunch route`, `jcodemunch order`, `jcodemunch menu`).

- Prohibited Tools: Never use Read, Grep, Glob, or Bash for exploration.

- Exception: Use Read only immediately before editing a file.

- Initialization: Run resolve\_repo or index\_folder at session start. Announce
  your model via announce\_model.

- Navigation: Use order for known actions. Use route for known goals. Use menu
  to see options. Use jcodemunch\_guide for the catalogue.

- Result Interpretation: no\_implementation\_found means the code is absent.
  degraded means absence is not proven.

- Post-Edit: Run register\_edit after editing files if PostToolUse hooks are
  absent.


1. Standard Operating Procedures (SOP)

- Phase 1 (Pre-Coding): Write the plan to plans/. Set the workspace via Beads.
  Claim the task. Run AutoMem recall. Delegate to Hermes only when the task
  cannot be accomplished due to current limitations.

- Phase 2 (Implementation): Execute tests strictly using python
  run\_tests\_isolated.py.

- Phase 3 (Post-Coding): Output a fix summary. Store decisions in AutoMem.
  Commit the code. Close the task in Beads. Terminate background processes.

## Appendix: MCP-Generated Instruction Blocks

> The owning setup tool manages its own block. Do not hand-edit inside the markers.

### Engineering-Craft Refreshers

- Reference folder for engineering-craft refreshers: `###swe-books-md`.

- Before a non-trivial task, refresh relevant knowledge from this folder.


### Ponytail, lazy senior dev mode

You are a lazy senior developer. Lazy means efficient, not careless. The best code is the code never written.

Before writing any code, stop at the first rung that holds:

1. Does this need to be built at all? (YAGNI)
2. Does it already exist in this codebase? Reuse the helper, util, or pattern that's already here.
3. Does the standard library already do this? Use it.
4. Does a native platform feature cover it? Use it.
5. Does an already-installed dependency solve it? Use it.
6. Can this be one line? Make it one line.
7. Only then: write the minimum code that works.

The ladder runs after you understand the problem, not instead of it: read the task and the code it touches, trace the real flow end to end, then climb.

Bug fix = root cause, not symptom: a report names a symptom. Grep every caller of the function you touch and fix the shared function once.

Rules:
- No abstractions that weren't explicitly requested.
- No new dependency if it can be avoided.
- No boilerplate nobody asked for.
- Deletion over addition. Boring over clever. Fewest files possible.
- Shortest working diff wins, but only once you understand the problem.
- Mark deliberate simplifications with a `ponytail:` comment naming the ceiling and upgrade path.

Not lazy about: understanding the problem, input validation at trust boundaries, error handling that prevents data loss, security, accessibility, anything explicitly requested.

Commands: /ponytail lite|full|ultra|off


### RTK Token-Optimized Commands

**Golden Rule:** always prefix commands with `rtk`. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged — RTK is always safe to use.

- RTK location: installed at `%USERPROFILE%\.local\bin\rtk.exe`. If `rtk` is not on PATH, use the full path or add `%USERPROFILE%\.local\bin` to PATH.

- PATH verification: both `%USERPROFILE%\.declick\bin` and `%USERPROFILE%\.local\bin` are on PATH. Bare `rtk` resolves by name. If a shell reports `rtk` as not found, that shell's PATH is missing `.local/bin` — the install is fine.

- PATH position: `.local/bin` is the **last** PATH entry. A shadowing `rtk` earlier in PATH would win. Check with `type rtk` if behavior looks wrong.

- Passthrough: RTK falls back to direct exec when it cannot resolve a target. A line like `rtk: Failed to resolve 'echo' via PATH` is expected for shell builtins. Exit code is preserved. The rule stays satisfied.

- Shell scope: verified in **both** Git Bash **and** Windows PowerShell on 2026-09-18. `C:\Users\yuni\.local\bin` appears in both the process PATH and the user PATH. The claim that the rtk rule is unsatisfiable is **false** in both shells.

- PowerShell stdout: the PowerShell tool in this environment can return exit code 0 with **empty stdout**. Redirect output to a file and read the file instead. Do not conclude "not on PATH" from empty PowerShell output.

> **Important:** even in command chains with `&&`, use `rtk` on every command.
>
> ```bash
> # Wrong
> git add . && git commit -m "msg" && git push
>
> # Correct
> rtk git add . && rtk git commit -m "msg" && rtk git push
> ```

**RTK Commands by Workflow**

*Build & Compile (80–90% savings)*

```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

*Test (60–99% savings)*

```bash
rtk cargo test          # Cargo test failures only (90%)
rtk go test              # Go test failures only (90%)
rtk jest                # Jest failures only (99.5%)
rtk vitest               # Vitest failures only (99.5%)
rtk playwright test      # Playwright failures only (94%)
rtk pytest               # Python test failures only (90%)
rtk rake test             # Ruby test failures only (90%)
rtk rspec                # RSpec test failures only (60%)
rtk test <cmd>           # Generic test wrapper — failures only
```

*Git (59–80% savings)*

```bash
rtk git status           # Compact status
rtk git log              # Compact log (works with all git flags)
rtk git diff             # Compact diff (80%)
rtk git show             # Compact show (80%)
rtk git add              # Ultra-compact confirmations (59%)
rtk git commit           # Ultra-compact confirmations (59%)
rtk git push             # Ultra-compact confirmations
rtk git pull             # Ultra-compact confirmations
rtk git branch           # Compact branch list
rtk git fetch            # Compact fetch
rtk git stash            # Compact stash
rtk git worktree         # Compact worktree
```

> Git passthrough works for ALL subcommands, even those not explicitly listed.

*GitHub (26–87% savings)*

```bash
rtk gh pr view <num>     # Compact PR view (87%)
rtk gh pr checks         # Compact PR checks (79%)
rtk gh run list          # Compact workflow runs (82%)
rtk gh issue list        # Compact issue list (80%)
rtk gh api               # Compact API responses (26%)
```

*JavaScript/TypeScript Tooling (70–90% savings)*

```bash
rtk pnpm list            # Compact dependency tree (70%)
rtk pnpm outdated        # Compact outdated packages (80%)
rtk pnpm install         # Compact install output (90%)
rtk npm run <script>     # Compact npm script output
rtk npx <cmd>            # Compact npx command output
rtk prisma               # Prisma without ASCII art (88%)
```

*Files & Search (60–75% savings)*

```bash
rtk ls <path>            # Tree format, compact (65%)
rtk read <file>          # Code reading with filtering (60%)
rtk grep <pattern>       # Search grouped by file (75%). Format flags (-c, -l, -L, -o, -Z) run raw.
rtk find <pattern>       # Find grouped by directory (70%)
```

*Analysis & Debug (70–90% savings)*

```bash
rtk err <cmd>            # Filter errors only from any command
rtk log <file>           # Deduplicated logs with counts
rtk json <file>          # JSON structure without values
rtk deps                 # Dependency overview
rtk env                  # Environment variables compact
rtk summary <cmd>        # Smart summary of command output
rtk diff                 # Ultra-compact diffs
```

*Infrastructure (85% savings)*

```bash
rtk docker ps            # Compact container list
rtk docker images        # Compact image list
rtk docker logs <c>      # Deduplicated logs
rtk kubectl get          # Compact resource list
rtk kubectl logs         # Deduplicated pod logs
```

*Network (65–70% savings)*

```bash
rtk curl <url>           # Compact HTTP responses (70%)
rtk wget <url>           # Compact download output (65%)
```

*Meta Commands*

```bash
rtk gain                 # View token savings statistics
rtk gain --history       # View command history with savings
rtk discover              # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>          # Run command without filtering (for debugging)
rtk init                 # Add RTK instructions to CLAUDE.md
rtk init --global        # Add RTK to ~/.claude/CLAUDE.md
```

**Token Savings Overview**

| Category         | Commands                       | Typical Savings |
| ---------------- | ------------------------------ | --------------- |
| Tests            | vitest, playwright, cargo test | 90–99%          |
| Build            | next, tsc, lint, prettier      | 70–87%          |
| Git              | status, log, diff, add, commit | 59–80%          |
| GitHub           | gh pr, gh run, gh issue        | 26–87%          |
| Package Managers | pnpm, npm, npx                 | 70–90%          |
| Files            | ls, read, grep, find           | 60–75%          |
| Infrastructure   | docker, kubectl                | 85%             |
| Network          | curl, wget                     | 65–70%          |

*Overall average: 60–90% token reduction on common development operations.*



<!-- graft:start -->
## Graft — repo context graph

This repo is indexed in `graft/`: small linked markdown nodes that explain each
system and carry exact file:line spans, kept in sync with the code through git.

For ANY task here — understanding how something works, finding where code lives,
or scoping a change — get context from the graph before grepping or opening
source files. Re-ask freely (it's cheap) and reuse literal identifiers you
already have (symbol, error string, file name) as the query. New to this repo?
Run `graft map` first — a token-budgeted orientation (dir clusters, hubs,
hotspots), no LLM, no key.

- Run `graft ask "<your question>" --source` → ranked nodes with the relevant
  code spans inlined (each hit's ≤8-line crux by default; `--full` for whole
  definitions when the crux isn't enough). Match the tool to the task shape:
  for understanding or editing, the top node IS the answer — cite its
  `covers:` file:line spans and edit straight from `--source`. For
  exhaustive tasks ("every occurrence / every caller of this pattern"), ranked
  results are top-N, not complete — run `graft grep "<literal>"` instead
  (exhaustive over indexed files, grouped by enclosing symbol), falling back
  to raw `grep -rn` only for unindexed files.
- `graft skeleton <file>` → every definition's signature + span, ~10× cheaper
  than reading the file; use it to skim an API surface.
- `graft callers <symbol>` gives precomputed, exact edges — who calls this.
  Add `--direction out` for what it calls, or `--depth N` to walk
  transitively for the full blast radius. For structural questions, skip
  ranking and use this directly.
- Or browse: `graft/INDEX.md` lists every node; follow the links.
- Monorepos and folders of multiple repos rank fairly across sub-projects —
  hits carry `[scope/]` labels naming which one they're from. Narrow with
  `graft ask "<task>" --in <scope>/` once you know where you're working.

If a returned span is truncated ("+N more lines"), open the file at that exact
range before finalizing. Only open source files when a node genuinely lacks a
needed detail, and then at the exact file:line the node points to — never
re-read whole files.

After big code changes, refresh the graph with `graft build` (deterministic,
no API key, $0).
<!-- graft:end -->


### AutoMem Persistent Memory Rules


<!-- BEGIN AUTOMEM RULES -->

**Memory — AutoMem (persistent context)**

This project has an AutoMem MCP memory service ([verygoodplugins/mcp-automem](https://github.com/verygoodplugins/mcp-automem), backed by the AutoMem FalkorDB+Qdrant service) providing durable, relational memory across sessions. The MCP tool namespace is derived from the server key in your MCP config (`"mcpServers": { "<key>": {...} }`), not fixed by the package — verify against your actual tool list. Known examples:

- This install: server key `automem` → `mcp__automem__*`

- verygoodplugins' own default manual/CLI docs use server key `memory` → `mcp__memory__*`

- Claude Code plugin install → `mcp__plugin_automem_memory__*`

This section assumes tools named `recall_memory`, `store_memory`, `associate_memories`, `update_memory`, `delete_memory`, `check_database_health`, prefixed `mcp__automem__` for this install (6 tools total; `search_by_tag` was removed in v0.2.0 — use `recall_memory` with `tags` instead).

**Toolport users** — the prefix now matches. AutoMem's Toolport id was corrected from `npx` → `automem` (see §3.1.1), so under Toolport its tools use the `automem__` prefix: `automem__recall_memory`, `automem__store_memory`, `automem__associate_memories`, `automem__update_memory`, `automem__delete_memory`, `automem__check_database_health`. Verify with `toolport_status` → "Tools by server" (`automem`: 6 tool(s)). The `mcp__automem__*` names above apply to Codex/Claude-style clients that key MCP servers by their config server name; under Toolport the live namespace is `automem__*`.

Set `PROJECT_TAG` once to a short, unambiguous slug for this project (e.g. the repo name). Use it everywhere `<PROJECT_TAG>` appears below.

This section is the fallback for any agent program that reads this file — CLI agents, IDE assistants, whatever loads it. If your program also has a separate hook/plugin system that already injects this guidance automatically, don't run both — hooks take priority and this file's rules should not cause a duplicate recall every turn.

**Tool's real behavior (validated against production corpus)**

- Tags are a hard gate — memories without matching tags are excluded before scoring, not just deprioritized. Use tags for stable categories like `preference` and `bugfix`; do not invent topic tags on the fly.

- One good query beats `queries[]` + `auto_decompose` for focused tasks. Use `queries[]` only for genuinely multi-topic questions.

- `limit` caps at 50. Routine recall should use enough budget to be useful (don't default to small limits).

- Default text format shows content previews with created/updated timestamps and importance. `detailed` format adds type/confidence/metadata — reach for it when deciding whether to `update_memory` an existing record vs. store a new one. Responses are token-budgeted (default \~18k estimated tokens, override via `AUTOMEM_RECALL_TOKEN_BUDGET`) to stay under MCP client caps — long content is summary-first and relations collapse to `{id, type, strength, summary}` stubs. `format: "json"` and ID fetches (`memory_id`) keep full per-field passthrough; use `recall_memory({ memory_id })` to pull a complete record.

- `store_memory` can silently fail. Verify important stores by recalling a distinctive phrase from the content; retry once if it's missing.

- Bare tag convention — use `<PROJECT_TAG>`, not `project/<PROJECT_TAG>`; no `lang/` prefixes, platform tags, or date-stamped tags. `entity:*:*` tags are server-injected — don't create them manually.

- Slug-collision rule — if `<PROJECT_TAG>` collides with a common topic word (e.g. `api`, `app`, `test`, `video`), drop the tag gate for that recall and rely on the semantic query alone.

- Tag matching defaults — server-side, `tag_mode=any` and `tag_match=prefix` (prefix matching supports namespaced tags like `slack:*`). Pass `tag_mode="all"` to require every tag, or `tag_match="exact"` for strict matches. `exclude_tags` filters out unwanted scopes from a ranked recall.

**Session start — two-phase recall (run in parallel, once per session)**

Preferences (tag-only):

```js
recall_memory({ tags: ["preference"], limit: 20, sort: "updated_desc" })
```

Task context (one semantic query built from the user's actual nouns — products, people, files, error strings, tools, specific topics):

```js
recall_memory({
  query: "<proper nouns, product names, people, tools, specific topics from the user's message>",
  tags: ["<PROJECT_TAG>"],      // drop if slug collides with a common word
  time_query: "last 90 days",
  limit: 30,
  language: "<optional: typescript|python|go|rust|...>"
})
```

Skip task-context recall for pure syntax questions, trivial edits, one-off calculations, direct factual queries about current files, or casual openings.

Always recall for: project-context questions (architecture, tooling, deployment); architecture discussions or decisions; user preferences and code style; debugging issues (search for similar past problems); refactoring (understand why current structure exists); integration or API work (check past implementations); performance-optimization discussions.

Skip recall for: pure syntax questions; trivial edits (typos, formatting, simple renames); direct factual queries about current code; file-content requests answerable by reading.

Debug context — only when actively investigating a concrete symptom, and with no tag gate (bugfix/solution tagging is incomplete; a hard gate hides cross-corpus fixes):

```js
recall_memory({ query: "<exact error symptom or message>", limit: 20 })
```

Don't re-recall mid-conversation unless the topic genuinely shifts, a new proper noun enters, or active debugging starts.

**When recall misses**

- Too broad — add a tag gate (a stable category like `preference`/`bugfix`, or `<PROJECT_TAG>`) and tighten the query to the real nouns.

- Empty — drop the time window first (the topic may be dormant but still relevant), then broaden the query.

- Sparse under a tag gate — drop the gate and rely on the semantic query alone; older memories may use legacy `project/<slug>` prefixes, so gated queries can miss historical content.

- Need graph traversal — use `expand_relations: true`; add `expand_respect_tags: true` when traversal must stay inside the tag gate, or leave it off when broader graph context is useful.

- Need multi-hop entity reasoning (different from graph traversal above, e.g. "what is Amanda's sister's career?") — use `expand_entities: true` to follow entity links to related memories.

**Storage discipline**

Store only durable decisions, corrections, explicit preferences, bug-fix root causes, and articulated reusable patterns. Never store secrets, credentials, tokens, PII, session summaries, progress reports, confirmations, speculative context, or attentiveness notes.

Don't wait for session end — when a durable trigger fires, run the full ritual in the same turn. Don't over-store either: one store per genuinely new trigger, not one per turn.

```js
store_memory({
  content: "Brief title. Context + reasoning. Outcome.",
  type: "Decision",
  tags: ["<category>", "<PROJECT_TAG>", "<language>"],  // bare strings only
  importance: 0.85,
  confidence: 0.9
})
```

Keep content to \~150–300 chars where possible; put file paths, metrics, exit codes, and other structured detail in `metadata`. For facts with a shelf life, use `t_valid`/`t_invalid` instead of date tags. If you set a timestamp explicitly, use a single top-level `timestamp` (ISO 8601 UTC) — don't duplicate it into `metadata.timestamp` or encode it as a tag.

**Quick storage patterns**

Copy-paste templates. Use bare tags only (no platform/date prefixes). Prefer `update_memory` over a near-duplicate store when a fact changed in place.

*Decision* — `[CHOICE] over [ALTERNATIVES]. [REASON]. Impact: [OUTCOME].`

```js
store_memory({
  content: "[CHOICE] over [ALTERNATIVES]. [REASON]. Impact: [OUTCOME].",
  type: "Decision", importance: 0.9, confidence: 0.9,
  tags: ["decision", "<project>", "<component>"],
  metadata: { alternatives_considered: ["alt1", "alt2"], deciding_factors: ["factor1", "factor2"] }
})
```

*Bug fix* — `[SYMPTOM]. Root: [CAUSE]. Solution: [FIX].`

```js
store_memory({
  content: "[SYMPTOM]. Root: [CAUSE]. Solution: [FIX].",
  type: "Insight", importance: 0.8, confidence: 0.85,
  tags: ["bugfix", "solution", "<project>", "<component>"],
  metadata: { error_signature: "exact error message", solution_pattern: "pattern-name", files_modified: ["path/to/file.ts"] }
})
```

*User preference* — `User prefers [PREFERENCE] in [CONTEXT].`

```js
store_memory({
  content: "User prefers [PREFERENCE] in [CONTEXT].",
  type: "Preference", importance: 0.8, confidence: 0.95,
  tags: ["preference", "<domain>"]
})
```

*Code pattern* — `Using [PATTERN]. [BENEFIT]. Applied in [SCOPE].`

```js
store_memory({
  content: "Using [PATTERN]. [BENEFIT]. Applied in [SCOPE].",
  type: "Pattern", importance: 0.7, confidence: 0.8,
  tags: ["pattern", "<project>", "<domain>"],
  metadata: { pattern: "pattern-name", applied_in: ["path/to/*.ts"] }
})
```

*Feature summary* — `Added [FEATURE]. [CAPABILITIES]. Impact: [VALUE].`

```js
store_memory({
  content: "Added [FEATURE]. [CAPABILITIES]. Impact: [VALUE].",
  type: "Context", importance: 0.8, confidence: 0.8,
  tags: ["feature", "<project>", "<component>"],
  metadata: { files_modified: ["file1.ts", "file2.ts"], feature: "feature-name" }
})
```

**Tagging convention:** prefer (1) category — `decision`, `bugfix`, `solution`, `pattern`, `feature`; (2) project slug only when clearly project-scoped; (3) component/domain — `auth`, `api`, `frontend`, `deployment`; (4) language/domain only if it improves recall.

**Importance scoring**

| Range   | Use for                                              |
| ------- | ---------------------------------------------------- |
| 0.9–1.0 | Critical decisions, major features, breaking changes |
| 0.7–0.8 | Important patterns, significant bugs, preferences    |
| 0.5–0.7 | Helpful patterns, minor features, config changes     |
| 0.3–0.5 | Small fixes, temporary workarounds, notes            |

**Modes worth knowing**

- `store_memory` also has a batch mode: pass `memories: [...]` (≤500 items) for bulk ingestion. Per-item `id`/`embedding`/`t_valid`/`t_invalid` aren't supported in batch mode — use single-mode for those.

- `recall_memory` also supports an ID fetch (`memory_id`, ignores other params) and a tag-enumeration mode (`tags` + `exhaustive: true`, paginated exact-match listing, `limit` ≤200, `offset`, returns `has_more`) — reach for exhaustive mode over ranked recall for cleanup/audit passes.

- `associate_memories` also has a batch mode via `associations: [...]` (≤500), with optional relation-specific props (`reason`, `context`, `resolution`, `observations`, `transformation`, `role`).

- `delete_memory` is single (`memory_id`) by default, but `tags: [...]` bulk-deletes ALL memories matching ANY tag (exact match, case-insensitive) with no dry-run. Verify scope first with `recall_memory({ tags, exhaustive: true })` before a tag-based delete.

**Three mid-conversation triggers (and only three)**

1. **User correction or override.** Cues: "actually", "no, I prefer", "not X, Y", "that's wrong", "stop doing X", "never do X", "I told you before", "we decided X already". Store as `Preference`, importance 0.9, confidence 0.95, tag `correction`; then `INVALIDATED_BY` the prior memory.
2. **Decision stabilizes after at least one round of discussion.** Cues: "let's go with X", "yeah that's the plan", "ship it", "do it that way", "final answer", "okay let's do that". Store as `Decision`, importance 0.85–0.9; then `PREFERS_OVER` any alternatives that came up.
3. **Pattern articulated — not inferred.** Cues: "I always do X", "every time", "this is how I usually", "my thing is". Store as `Pattern`, importance 0.8; then `EXEMPLIFIES` against concrete examples.

**The atomic ritual — every store runs all four steps**

```js
const related = await recall_memory({ query: "<what's being corrected / decided / named>", limit: 5 })
const stored  = await store_memory({
  content: "Brief title. Context + reasoning. Outcome.",
  type: "Preference",
  tags: ["correction", "<PROJECT_TAG>"],
  importance: 0.9,
  confidence: 0.95
})
await recall_memory({ query: "<distinctive phrase from content>", limit: 3 })  // verify it landed
if (related?.results?.length) {
  await associate_memories({ memory1_id: related.results[0].id, memory2_id: stored.memory_id, type: "INVALIDATED_BY", strength: 0.9 })
}
```

Step 4 is where the graph gets built — skipping it is the main way AutoMem degrades into a flat bag of notes.

**Mandatory association pairings**

| Trigger                | Store as                                           | Then associate                    |
| ---------------------- | -------------------------------------------------- | --------------------------------- |
| User correction        | `Preference`, 0.9 / 0.95                           | Old memory → `INVALIDATED_BY`     |
| Architectural decision | `Decision`, 0.9 / 0.9                              | Alternatives → `PREFERS_OVER`     |
| Bug fix                | `Insight`, 0.75 / 0.85, tags `bugfix` + `solution` | Bug report → `LEADS_TO`           |
| Pattern discovered     | `Pattern`, 0.8                                     | Concrete examples → `EXEMPLIFIES` |
| Knowledge evolved      | `update_memory` old + store new                    | Old → `EVOLVED_INTO`              |
| Deprecated info        | `update_memory` old with deprecated metadata       | Old → `INVALIDATED_BY`            |

Valid relation types for `associate_memories` (11 public, authorable): `RELATES_TO`, `LEADS_TO`, `OCCURRED_BEFORE`, `PREFERS_OVER`, `EXEMPLIFIES`, `CONTRADICTS`, `REINFORCES`, `INVALIDATED_BY`, `EVOLVED_INTO`, `DERIVED_FROM`, `PART_OF`.

System/internal relations — `SIMILAR_TO`, `PRECEDED_BY`, `EXPLAINS`, `SHARES_THEME`, `PARALLEL_CONTEXT`, `DISCOVERED` — can appear in recall results (added automatically by enrichment/consolidation) but are not valid `associate_memories` inputs; don't try to author them.

Prefer `update_memory` over a duplicate store when a fact simply changes in place.

**Guidelines**

- Weave recalled context naturally; don't announce memory operations to the user. Avoid robotic phrasing like "searching my memory database" — present recalled context as normal working knowledge.

- Prefer high-signal memories: decisions, root causes, reusable patterns, explicit preferences.

- Keep memories atomic and focused — avoid wall-of-text entries. Don't store large code blocks; store the pattern or decision instead.

- Recalled context is a prior, not ground truth. If a memory disagrees with current repo state, the user's latest instruction, or a freshly read file, current evidence wins — update or invalidate the stale memory instead of acting on it.

- If recall fails or returns nothing, continue without memory and don't mention the failure to the user.

**Full reference**

For the complete playbook (recall patterns, association guidance, and copy-paste storage templates), see the automem skill, available at any of:

- ${VAD_WORKSPACE_ROOT}\@skills\automem/ (project @skills scope — also picked up by the deep-explore subagent)

Its `SKILL.md` holds the full explanation; `patterns.md` holds the ready-to-use storage templates.

<!-- END AUTOMEM RULES -->






























### Memtrace Install Notice

<!-- BEGIN MEMTRACE BLOCK — managed by `memtrace install` — remove with `memtrace uninstall` -->

<!-- block-version: 0.3.35 -->

Memtrace is installed on this machine. For code-discovery questions, call `memtrace__find_symbol` or `memtrace__find_code` BEFORE `Read` / `Grep` / `Glob` — see `MEMTRACE.md` for the full rule. (Prefix corrected 2026-07-14: the live Toolport-registered server exposes `memtrace__*`, not the stale `mcp__memtrace__*` this block was originally generated with.)

<!-- END MEMTRACE BLOCK -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->


<!-- REPOWISE:START — Do not edit below this line. Auto-generated by Repowise. -->
## IMPORTANT: Codebase Intelligence Instructions for VAD

> This repository is indexed by [Repowise](https://repowise.dev).
> Use the MCP tools below for orientation, discovery, and enriched context
> (documentation, ownership, history, decisions). **Always verify against
> actual source files before making changes** — the index may be stale.

Last indexed: 2026-06-26 (commit 3fa52b3)
### Entry Points
- `UI/__main__.py`
### Tech Stack
**Languages:** C#
**Frameworks:** .NET

### Architectural Layers
| Layer | Files | Purpose |
|-------|-------|---------|
| ui | 19 |  |
| __init__ | 18 |  |
| chunk_scheduler | 9 |  |
| ui/widgets | 6 |  |
| .gitlab-ci | 1 |  |
| .mcp | 2 |  |
| view | 1 |  |
| readme | 1 |  |
| quick_start | 1 |  |
| claude | 1 |  |
### Hotspots (High Churn)
| File | Churn | 90d Commits | Owner |
|------|-------|-------------|-------|
| `Modules/adaptive_lufs_normalizer.py` | 98.2th %ile | 1 | uni.universefire |
| `Modules/audio_file_handler.py` | 96.5th %ile | 1 | uni.universefire |
| `Modules/config_manager.py` | 94.7th %ile | 1 | uni.universefire |
| `Modules/error_handling.py` | 93.0th %ile | 1 | uni.universefire |
| `Modules/file_manifest.py` | 91.2th %ile | 1 | uni.universefire |

## Code health
Hotspot health: 6.92/10 (stable) ·
Average: 6.73/10 ·
Worst: 3.58/10 (`VAD.py`)

### Critical biomarkers
- `Modules/ffmpeg_helper.py` — untested hotspot — impact −2.0
- `Modules/volume_normalizer.py` — complex method (_apply_standard_volume_normalization) — impact −0.6
- `VAD.py` — brain method (stage_export) — impact −0.2
- `VAD.py` — brain method (_apply_marblenet_vad_stage3) — impact −0.2
- `VAD.py` — brain method (_apply_tenet_vad_stage2) — impact −0.2

### Repowise MCP Tools

This repo has the Repowise MCP server configured. The tools below answer questions `grep`/`Read` cannot. Every response carries an `_meta` envelope with `index_age_days`, `indexed_commit`, and a `stale_warning` only when the index has actually diverged from HEAD — silence means the index is current.

**When to call which tool:**

| Tool | What only this tool answers |
|------|------------------------------|
| `get_answer(question)` | Synthesised answer with verified citations and a calibrated `retrieval_quality`. First call for "how does X work" / "why is Y like this". On low confidence returns `best_guesses` with one-line justifications instead of an empty answer. |
| `get_context(targets=[...])` | Triage card for files/modules/symbols — title, summary, signatures, `hotspot` bit, `decision_records` titles, and `symbol_id`s to pipe into `get_symbol`. Use `include=["callers","ownership",...]` to widen. NOT for source bytes. |
| `get_symbol("path/to/file.py::Name")` | Raw source bytes for one indexed symbol with exact line bounds. Cheaper and safer than `Read` + offset math. Use the `symbol_id` returned by `get_context`. |
| `search_codebase(query, kind?)` | Find pages by concept when you don't know the file. Each result carries `search_method` (`embedding` vs `bm25` fallback). For exact identifiers use Grep — the tool will hint when it sees one. |
| `get_why(query, targets?)` | Architectural decision archaeology — *why* the code is shaped this way. Call before refactors or pattern divergences. Falls back to git archaeology when no ADRs exist for a file. |
| `get_risk(targets, changed_files?)` | What history says about touching these files: churn, owners, blast radius. Pass `changed_files` for PR mode → returns a `directive` (`will_break`, `missing_cochanges`, `missing_tests`). |
| `get_dead_code(...)` | Tiered unreachable / unused-export / zombie-package findings. Run before a cleanup sprint, not before a targeted fix. |
| `get_overview(repo?)` | Architecture map for an unfamiliar repo. One-time orientation; skip on subsequent calls in the same session. |

**Composition tips:**
- `get_answer` → if `confidence` is `medium`/`low`, follow the `best_guesses[0].file` or `fallback_targets[0]` into `get_context`, then `get_symbol` for bytes.
- `get_context` returns `decision_records` titles → call `get_why(targets=[...])` for the rationale.
- `get_context` returns `hotspot: true` → call `get_risk` before editing.
- PR review → `get_risk(targets=[...], changed_files=[...])`; read the `directive` block first.

**Verify when:** `_meta.stale_warning` is present, or `retrieval_quality` is `partial`/`weak`, or `search_method` is `bm25`. Otherwise trust the response and act on it.

<!-- REPOWISE:END -->

## graphify-rs

This project has a graphify-rs knowledge graph at C:\Users\yuni\.graphify-rs\VAD-499645c0501b9e90/.

Rules:
- Before answering architecture or codebase questions, read C:\Users\yuni\.graphify-rs\VAD-499645c0501b9e90/GRAPH_REPORT.md for god nodes and community structure
- If C:\Users\yuni\.graphify-rs\VAD-499645c0501b9e90/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `graphify-rs build --path . --output C:\Users\yuni\.graphify-rs\VAD-499645c0501b9e90 --no-llm --update` to keep the graph current (fast, AST-only, ~2-5s)


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->









## Code Exploration Policy

Always use jCodeMunch-MCP for code navigation. Never fall back to Read, Grep, Glob, or Bash for code exploration.
**Exception:** use `Read` when you are about to edit a file — the harness requires a `Read` before `Edit`/`Write`. Use jCodeMunch to *find and understand* code, then `Read` only the file you are changing.

This server runs the **front door** surface: three tools reach every jCodeMunch capability, so the tool list stays small and the catalogue is fetched only when you need it.

**Start any session:**
1. `order { "action": "resolve_repo", "args": { "path": "." } }` — confirm the project is indexed. If it is not: `order { "action": "index_folder", "args": { "path": "." } }`

**Then, for any task:**
- Know what you want → `order { "action": "<name>", "args": { ... } }`
- Know the goal, not the tool → `route { "query": "your task in a sentence" }` picks the action and shapes the arguments
- Want to see what exists → `menu { "query": "what you are trying to do" }` returns matching actions with example arguments
- Want the whole catalogue and the usage rules → `jcodemunch_guide`

`menu` and `jcodemunch_guide` list every action this server can run, including ones absent from your tool list. That is expected: the front door is the way to call them.

**Interpreting results:**
- A `verdict` of `no_implementation_found` is evidence of absence. Report the gap; do not re-search with different wording.
- A `verdict` of `degraded` means a channel was unavailable, so absence is NOT proven. Read the note before relying on the result.
- `source: ""` alongside `source_status` means the body could not be read, not that the symbol is empty.

**After editing files:**
- With PostToolUse hooks installed (Claude Code), edited files are reindexed automatically.
- Otherwise `order { "action": "register_edit", "args": { "paths": [...] } }` after an edit, batched for bulk changes.

**Announce your model once per session** so the server can size its answers: `announce_model { "model": "<your-model-id>" }`.








## grepai - Semantic Code Search

**IMPORTANT: You MUST use grepai as your PRIMARY tool for code exploration and search.**

### When to Use grepai (REQUIRED)

Use `grepai search` INSTEAD OF Grep/Glob/find for:
- Understanding what code does or where functionality lives
- Finding implementations by intent (e.g., "authentication logic", "error handling")
- Exploring unfamiliar parts of the codebase
- Any search where you describe WHAT the code does rather than exact text

### When to Use Standard Tools

Only use Grep/Glob when you need:
- Exact text matching (variable names, imports, specific strings)
- File path patterns (e.g., `**/*.go`)
- Intent with a canonical syntax anchor (`@main`, `func main(`) - an exact-match query in disguise

### Completeness Check (recall-safe)

grepai returns the top ~10 ranked chunks - a ranking, not an exhaustive list.
When completeness matters (audits, refactors, "find ALL X"), pair it with a
file-names-only grep - exhaustive recall at almost no token cost:

```bash
grepai search "where errors are handled" --json --compact   # ranked starting points
git grep -ilE 'error|handl|logg' | head -50                 # exhaustive checklist (names only)
```

Read ranked hits first, then any relevant-looking checklist file grepai did
not rank. Never dump full grep content output for an intent query.

### Fallback

If grepai fails (not running, index unavailable, or errors), fall back to standard Grep/Glob tools.

### Usage

```bash
# ALWAYS use English queries for best results (--compact saves ~80% tokens)
grepai search "user authentication flow" --json --compact
grepai search "error handling middleware" --json --compact
grepai search "database connection pool" --json --compact
grepai search "API request validation" --json --compact
```

### Query Tips

- **Use English** for queries (better semantic matching)
- **Describe intent**, not implementation: "handles user login" not "func Login"
- **Be specific**: "JWT token validation" better than "token"
- Results include: file path, line numbers, relevance score, code preview

### Call Graph Tracing

Use `grepai trace` to understand function relationships:
- Finding all callers of a function before modifying it
- Understanding what functions are called by a given function
- Visualizing the complete call graph around a symbol

#### Trace Commands

**IMPORTANT: Always use `--json` flag for optimal AI agent integration.**

```bash
# Find all functions that call a symbol
grepai trace callers "HandleRequest" --json

# Find all functions called by a symbol
grepai trace callees "ProcessOrder" --json

# Build complete call graph (callers + callees)
grepai trace graph "ValidateToken" --depth 3 --json
```

### Property/Data Usage Tracing

Use `grepai refs` to find non-call property/state usage (reads/writes):

```bash
# Find where a property is read
grepai refs readers "uid" --json

# Find where a property is written
grepai refs writers "uid" --json
```

### Workflow

1. Start with `grepai search` to find relevant code
2. Add `git grep -ilE '<keywords>'` for the exhaustive file checklist when completeness matters
3. Use `grepai trace` to understand function relationships
4. Use `grepai refs` for property/state readers and writers
5. Use `Read` tool to examine files from results
6. Use Grep directly for exact strings and syntax anchors

