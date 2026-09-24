# heimdall upstream drift, re-measured: v0.10.0 installed, README still v0.2.0, and a harness is code — not a template

**Bead:** mcpw-qxj.7 (P3 OPTIONAL, child of mcpw-qxj)
**Date:** 2026-09-24
**Verdict:** verified, no code change. The 2026-09-20 findings reproduce today. The
"WorkBuddy harness" gap is **not** a small declarative addition: a harness is a
hard-coded writer function compiled into the npm package, so adding one requires
editing the installed package (off limits) or an upstream PR — neither of which is a
repo change. The operator keeps the live Toolport stdio entry instead.

## What the bead recorded (2026-09-20, not re-derived)

- INSTALLED v0.10.0; GitHub README describes v0.2.0.
- Harness lists disagree in both directions; `windsurf` only in `--help`,
  `opencode`/`gemini-cli` only in `--detect`.
- No WorkBuddy/CodeBuddy harness; workaround = Toolport stdio entry id `heimdall`.
- `heimdall mcp` is an undocumented verb (absent from `--help`).

## Verified today (2026-09-24)

### 1. Version

`package.json` (read directly, unchanged):

    "version": "0.10.0"
    "engines": { "node": ">=22.5" }

Upstream `README.md` (fetched from
`https://raw.githubusercontent.com/ArihantDeva/heimdall/main/README.md`) still says:

> "v0.2.0 — adds the reconciler: a single-writer, level-triggered convergence loop
> with a content-hash oracle ... Published on npm as
> [`@arihantdeva/heimdall`](https://www.npmjs.com/package/@arihantdeva/heimdall)."

and in the FAQ:

> "...a 166-test suite guarding the concurrency invariants. v0.2.0."

**Drift is now wider than on 2026-09-20.** The README *page* also carries commit
messages that reference **0.10.0** ("Five defects reported against 0.10.0") and
**0.12.0** ("CHANGELOG 0.12.0"). So the README prose (v0.2.0) lags the repo's own
commit history (0.12.0) by ~10 minor versions, while the installed tarball is 0.10.0
— i.e. the installed copy is newer than the README's stated version but older than
the newest code the README page itself shows. Treat the README version line as
unreliable in both directions.

### 2. The three harness lists, re-measured

`heimdall --help` (verbatim, the `init` line):

    init [--harness pi|claude-code|codex|cursor|windsurf|all]   configure backend + harness hooks

`heimdall init --detect` (verbatim, exit 0, one name per line):

    claude-code
    codex
    cursor
    opencode
    gemini-cli
    pi

Upstream README command list (verbatim):

    heimdall init --harness claude-code   # or codex, cursor, pi, opencode, gemini-cli, deepseek
    heimdall init --detect                # list harnesses found on this machine

| source | harness names |
|---|---|
| `heimdall --help` | pi, claude-code, codex, cursor, **windsurf**, all |
| `heimdall init --detect` | claude-code, codex, cursor, opencode, gemini-cli, pi |
| README | claude-code, codex, cursor, pi, opencode, gemini-cli, **deepseek** |
| **actual code** (`WRITERS`) | pi, claude-code, codex, cursor, opencode, gemini-cli, deepseek |

`--detect` is a *probe*, not the registry: it lists only harnesses whose config dir
exists in `$HOME`. The 2026-09-20 run and today's run both printed the same six.
The missing seventh is `deepseek`, because `~/.deepseek` does not exist here
(checked: `.claude`, `.codex`, `.cursor`, `.config/opencode`, `.gemini`, `.pi/agent`
present; `.deepseek` absent). `--detect` output therefore depends on this machine,
not on heimdall's version.

`windsurf` in `--help` is a **phantom**: it is absent from `WRITERS`, absent from
`detectHarnesses`, and absent from the README's command list (the README mentions
Windsurf only in prose — an architecture diagram and a comparison table — never as
`--harness windsurf`). `heimdall init --harness windsurf` would be rejected at
`cli-main.mjs:170`. The help line is stale upstream text, not a local edit — the
installed `cli-main.mjs` differs from its own `.bak-20260919-0150` only in the
Windows-bash resolution patch; the `USAGE` block is byte-identical in both.

`docs/adapters.md` (shipped) is stale a third way: its table lists Pi, Claude Code,
Codex, Cursor, **Windsurf**, All — omitting opencode/gemini-cli/deepseek and
including the phantom windsurf.

## What a "harness" actually is in this codebase

**It is compiled code, not a declarative template.** A harness is a writer function
registered in a plain object literal:

- `bin/lib/adapters.mjs:242-250` — the registry:

      const WRITERS = {
          pi: writePi,
          "claude-code": writeClaudeCode,
          codex: writeCodex,
          cursor: writeCursor,
          opencode: writeOpencode,
          "gemini-cli": writeGeminiCli,
          deepseek: writeDeepseek,
      };

- `bin/lib/adapters.mjs:252` — `export const KNOWN_HARNESSES = Object.keys(WRITERS);`
- `bin/lib/adapters.mjs:255-266` — `detectHarnesses()` is a hard-coded `probes` array
  of `[name, path]` pairs (the seven `$HOME` dirs above).
- Each writer (e.g. `writeClaudeCode`, `adapters.mjs:115-133`; `writeCodex`,
  `adapters.mjs:138-149`) hard-codes one harness's config path **and** its dialect:
  JSON-merge into `~/.claude/settings.json`, line-based TOML into
  `~/.codex/config.toml`, `.mdc` frontmatter into `~/.cursor/rules/`, etc.

So "add a harness" means: (1) write a new function that knows the target's config
path and format, (2) add it to `WRITERS`, (3) add a `probes` entry. All three live
in `bin/lib/adapters.mjs` — inside the installed package.

## Conclusion: no WorkBuddy/CodeBuddy harness was added, and why

Not feasible as a repo-local change, for three independent reasons:

1. **Not declarative.** Per above, a harness is a JS function in the shipped
   package. There is no template file + list entry to add from this repo.
2. **The registry is off limits.** `WRITERS`/`detectHarnesses` live under
   `J:/Programs/npm-global/node_modules/@arihantdeva/heimdall/bin/lib/adapters.mjs`,
   which this task forbids modifying. A patch could only be proposed upstream.
3. **The target is unknown.** A writer must hard-code the harness's real config path
   and format. No WorkBuddy/CodeBuddy MCP-config layout is documented anywhere in
   this stack, so a writer could not be written correctly even if we could ship it —
   `writeDeepseek` is already flagged "experimental — verify config path" for exactly
   this reason (`adapters.mjs:217-222`).

Even a correct upstream PR would not help *this* box until published and installed.
**What the operator must keep doing instead:** maintain the manual Toolport stdio
entry that exposes heimdall's MCP to the host. Confirmed live in
`C:/Users/yuni/AppData/Roaming/Toolport/registry.json:392-429`:

    "id": "heimdall",
    "name": "heimdall",
    "transport": "stdio",
    "command": "C:/nvm4w/nodejs/node.exe",
    "args": [
      "J:/Programs/npm-global/node_modules/@arihantdeva/heimdall/bin/heimdall.js",
      "mcp"
    ],
    "source": "manual"

`heimdall init --harness <x>` cannot replace this for WorkBuddy: the harness writers
target *other* agents' config files, and none of them is WorkBuddy.

## Caveats / notes

- The `mcp` verb used by that entry is real but undocumented in `--help`. It is a
  `case "mcp"` arm in `cli-main.mjs` dispatching to `mcp-server.mjs`. Absence from
  `--help` is not evidence the server is missing.
- The README's version line and its harness list should both be treated as stale;
  this is an upstream documentation problem, not a local misconfiguration.
- Nothing under `J:/Programs/npm-global/node_modules/` was modified.

## Files

No repository source changed. Working evidence (raw captures) under
`.bead-work/mcpw-qxj.7/`:

- `help.txt` — `heimdall --help` (exit 0)
- `detect.txt` — `heimdall init --detect` (exit 0)
