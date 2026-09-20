# mcpw-ut6 — gm init: no .graphenium workspace config exists

- **Bead:** mcpw-ut6 (P1)
- **Date:** 2026-09-20
- **Repo:** `J:\audio\MCP-Watchers` @ branch `mcpw-sweep-20260920-1305`
- **Verdict:** **NOT DONE** — `gm init` ran clean (exit 0) but **no-op'd**; `.graphenium/` still does not exist.

---

## 1. Pre-state (recorded, not re-litigated)

```
$ ls -la .graphenium
ls: cannot access '.graphenium': No such file or directory

$ ls -la graphenium-out/
graph.json   529536 bytes   2026-09-20 19:14
manifest.json
quality.json
GRAPH_REPORT.md
```

gm binary OK: `C:\Users\yuni\.cargo\bin\gm.exe` (25,603,072 bytes).

```
$ gm doctor
  gm binary .................... OK (C:\Users\yuni\.cargo\bin\gm.exe)
  graph file (graphenium-out/graph.json) ... OK — 343 nodes, 844 edges, 18 communities (AST-only)
  graph schema .................. 0.2.0
  built by ...................... gm 0.19.3
  created at .................... 2026-09-20T07:14:07Z
```

(A graph exists — 343/844/18, refreshed since the 241/581/10 noted in the bead. Either way: graph present, config absent.)

## 2. Safety step — back up the graph before running init

The bead warned: "if `gm init` would clobber it, say so and check first."

```bash
cp graphenium-out/graph.json C:/Temp/graph.json.preinit.bak

# BEFORE
sha256sum graphenium-out/graph.json
0a4ae1d904df481305747b76f84b727be008e22d4f77d9c68547f4effa37c536 *graphenium-out/graph.json
stat -c '%n | size=%s | mtime=%y' graphenium-out/graph.json
graphenium-out/graph.json | size=529536 | mtime=2026-09-20 19:14:07.388957700 +1200
```

## 3. Command run

```bash
cd /j/audio/MCP-Watchers
gm init
```

Real output — **complete**:

```
Workspace at '.' already initialized (.grapheniumignore exists).
```

Exit code **0**. Nothing else was printed. No files were created.

## 4. Post-state — criterion FAILS

```
$ ls -la .graphenium
ls: cannot access '.graphenium': No such file or directory

$ sha256sum graphenium-out/graph.json
0a4ae1d904df481305747b76f84b727be008e22d4f77d9c68547f4effa37c536 *graphenium-out/graph.json

$ cmp C:/Temp/graph.json.preinit.bak graphenium-out/graph.json
IDENTICAL - graph NOT clobbered
```

- `.graphenium/` — **still absent**. Acceptance criterion not met.
- `graphenium-out/graph.json` — **byte-identical**, hash and mtime unchanged. Existing graph preserved (good), but a graph without the config is, per mcpw-rkg.1, **not initialized**.

## 5. Root cause — `gm init` never creates `.graphenium/`

`gm init --help` (gm 0.19.3):

```
Initialize a Graphenium workspace with default config files

Usage: gm.exe init [PATH]
Arguments:
  [PATH]  Directory to initialize (default: current directory) [default: .]
Options:
  -h, --help  Print help
```

No `--force`, no `--reconfigure`. Two facts explain the no-op:

1. **The marker is `.grapheniumignore`, not `.graphenium/`.** Strings in `gm.exe`:

   ```
   %Initialized Graphenium workspace at '
   '. Created .grapheniumignore.
   2' already initialized (.grapheniumignore exists).
   ```

   So `gm init`'s **only** artifact is `.grapheniumignore`. On first run it prints
   "Initialized Graphenium workspace at '<path>'. Created .grapheniumignore." — there is no
   string anywhere that creates a `.graphenium/` directory.

2. **The marker already existed.** `.grapheniumignore` is a **tracked, committed** file
   (220 bytes, dated 2026-09-18 05:25; `git status --short .grapheniumignore` is empty).
   Because it is present, init short-circuits with "already initialized" and writes nothing.

`.graphenium/` is an *optional, read-only-when-present* config dir — gm reads
`.graphenium/policy.json` if it exists ("Loads rules from `.graphenium/policy.json` when present",
"No rules in `.graphenium/policy.json`") but **no gm subcommand creates it**. Checked the full
command list and the relevant sub-help:

- `gm graph` → `migrate | schema | build-map | test-map` — none create config.
- `gm check` → takes `--graph`/`--plan`, reads policy, writes nothing.
- `gm setup` → prints MCP instructions for `claude|cursor|codewhale` only.

## 6. What was NOT done (deliberate)

- I did **not** delete or edit `.grapheniumignore` to force init to re-run: it is a **tracked,
  committed** file, and the file-ownership rule forbids editing tracked repo files.
- I did **not** hand-create an empty `.graphenium/`. The task authorises creating it "as a side
  effect of running the tools" — fabricating the marker by hand would fake the artifact rather
  than initialise the workspace, and would misreport the bead as done.

## 7. DONE / NOT DONE

**NOT DONE.** `gm init` exited 0 but reported
`Workspace at '.' already initialized (.grapheniumignore exists).` and created nothing.
`.graphenium/` does not exist; `graphenium-out/graph.json` is intact (sha256
`0a4ae1d9…37c536`, 529536 bytes). Per mcpw-rkg.1's contract (graph **and** config both required),
gm is still not initialized.

**Blocker for the bead:** `gm init` in gm 0.19.3 has no code path that creates `.graphenium/`,
and its `.grapheniumignore` marker is already committed. The bead's premise — that `gm init`
produces `.graphenium/` — does not hold for this gm version. Recommend re-scoping to whichever
command actually writes `.graphenium/policy.json` (not identified in 0.19.3).
