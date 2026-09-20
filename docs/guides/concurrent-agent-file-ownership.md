# Concurrent agents sharing one git index: the file-ownership discipline

Bead: `mcpw-gsj`. Tools: `dev_tools/claim_paths.py`, `dev_tools/guard_silent_diff.py`.

## The incident

Commit `4891fe0` is labelled `mcpw-oft`. It also carries another agent's
repowise recurrence-guard hunk and a 210-line verification doc. Two agents were
editing the same path at the same time; whichever committed first took the
other's in-flight edits with it.

The instinctive fix -- "stage explicit paths, never `git add -A`" -- does not
work. It only prevents picking up files you never named. It cannot help when
two agents touch the **same** path, because a git index entry is the whole
file. Staging `launcher.ps1` stages every byte of `launcher.ps1`, including the
other agent's half-finished edit.

## What is actually true about this repo (measured 2026-09-20)

| Fact | Value |
|---|---|
| `.gitattributes` | `* -text` -- applies to **all 158 tracked files**, no exceptions |
| `git check-attr -a` on the launcher | `text: unset` only; no `diff` attribute |
| `.git/info/attributes` | absent |
| `core.autocrlf` (global) | `true` (overridden by `-text`, so no phantom EOL diffs) |
| Launcher size | 320,699 bytes |
| `core.hooksPath` | `J:/audio/MCP-Watchers/.beads/hooks` (repo-local, so every commit here pays it) |
| Commit cost | ~4 minutes; `.beads/hooks/pre-commit` shells out to `bd hooks run pre-commit` under `BEADS_HOOK_TIMEOUT=300`, and `post-commit` fires the repowise update |

### The "silent diff" trap, corrected

The original report attributed the silent diff to `* -text`. That attribute is
real, but it is **not** the mechanism. Measured: with `* -text` in force, plain
`git diff` still prints the launcher's unstaged hunks in full (117 insertions,
63 deletions, 350 lines of patch).

The state in which a diff really is silent is the **index**, and it is silent
for every file, attribute or not:

```
worktree != index   ->  git diff            sees it
index    != HEAD    ->  git diff --cached   sees it
```

Once a hunk is staged, `git diff` compares worktree to index, they agree, and it
prints nothing. An agent that runs `git diff`, sees nothing alarming, and stages
its own path ships the hunk that was already in the index. `git diff --cached`
has the mirror-image blind spot.

Reproduced in a scratch repo (`tests/test_guard_silent_diff.py`):

```
$ git diff --stat                  # after `git add launcher.ps1`
$                                   # <-- silence, rc=0
$ git diff --cached --stat
 launcher.ps1 | 1 +
```

The only state-independent view is `git diff HEAD`, which compares the worktree
to the last commit and therefore sees staged and unstaged changes alike. Both
tools gate on that view.

## Options weighed

### (a) One agent per file per wave -- **adopted as the policy**

Cheap, and it is the only rule that addresses the actual failure: two writers,
one path. But as prose it is folklore -- nothing fails when it is broken. It
needs a mechanism, which is (b).

### (b) An advisory claim before staging -- **adopted as the mechanism**

A claim is a file created with `O_CREAT|O_EXCL`, so two racing claimants cannot
both win and the loser is told exactly who holds the path. It costs one command,
needs no daemon, and fails loudly. This is what makes (a) enforceable.

Claims live in `<git-dir>/mcpw-claims/`, i.e. inside `.git`. They never appear
in `git status` and can never be committed by accident.

### (c) Per-agent git worktrees -- **rejected**

- **It does not remove the cost, it multiplies it.** `core.hooksPath` is
  repo-local configuration, shared by every linked worktree of this repo. Each
  worktree commit still pays the ~4 minute beads hook. Serialising commits
  through the orchestrator pays that cost once per wave; worktrees pay it once
  per agent.
- **The shared state is not isolated anyway.** `.beads/` and `.repowise/` are
  read and written by watchers running outside git. Forking them per worktree
  forks the beads view and the repowise index that other processes are reading.
- **The merge is where the contamination comes back.** The deliverable is one
  linear history on `main`. Two worktrees editing the launcher produce two
  320 KB versions of a single file with no automatic conflict signal on the
  wiring strings the tests anchor on. The conflict surfaces at merge time, at
  which point the ~4 minute commit that would have warned you is long past.
- **This volume is hostile to it.** Slash-named refs are silently discarded on
  `J:` (mcpw-sr4), and worktrees add path length on a Windows box that already
  has a 320 KB filename-prefixed launcher.

### (d) Per-agent branches -- **rejected**

Same merge problem as (c), plus two repo-specific disqualifiers: the mcpw-sr4
defect means `agent/foo` may not create a ref at all, and agents **never
commit** here by design -- the orchestrator commits serially -- so a branch per
agent is machinery nobody would ever use. Meanwhile `main` keeps moving under
concurrent commits from master and the mayor, so a long-lived branch drifts and
forces the rebases that reintroduce cross-contamination.

## The discipline

1. **One owner per file per wave.** No exceptions, no "I'll be quick".
2. **Claim before you edit.** `claim_paths.py claim` must exit 0 before the
   first write to a path.
3. **Agents never commit.** The orchestrator commits serially with explicit
   paths.
4. **Before staging, run the ride-along gate.** `guard_silent_diff.py verify
   --expect <exactly the paths you are staging>` must exit 0.
5. **Never trust `git diff` alone.** Use `git diff HEAD` for the authoritative
   view, or the guard.

Coordination requires a **shared store**. The default (`<git-dir>/mcpw-claims`)
is the shared one; `--store` exists to isolate tests and CI, not to give an
agent a private namespace.

## `dev_tools/claim_paths.py`

Pure stdlib file I/O. It deliberately never invokes git, so the declick `git`
shim -- `~/.declick/bin/git` is a bash launcher and `git.bat`/`git.cmd` a
command document, neither of which runs in a PowerShell pipeline -- can never
be involved.

```
python dev_tools/claim_paths.py claim --owner mcpw-gsj --wave 20260920-1305 \
    dev_tools/claim_paths.py docs/guides/concurrent-agent-file-ownership.md

python dev_tools/claim_paths.py check   --owner mcpw-gsj <paths...>
python dev_tools/claim_paths.py list    [--owner X] [--json]
python dev_tools/claim_paths.py release --owner mcpw-gsj [<paths...>]
```

`claim` is **all-or-nothing**: if any path in the batch is held by someone
else, none of them are claimed and the exit code is 1. A half-claim is worse
than no claim, because it looks like success.

Paths are keyed case-insensitively with forward slashes, so on Windows
`Dev_Tools\Foo.py` and `dev_tools/foo.py` are the same claim and a case-only
difference cannot bypass the lock. Keys are derived from the working directory,
never from the store location, so the same file hashes identically no matter
which store is in use.

A conflict looks like this and exits 1:

```
CLAIM CONFLICT -- refusing all 2 path(s); another owner holds 1
  dev_tools/foo.py
      held by: mcpw-oft (wave 20260920-1305, pid 83844, 2026-09-20T01:12:23+00:00)
  Rule: one owner per file per wave. Release it, or pick a different
  path, or --steal if you know the holder is gone.
```

`--steal` overrides an existing claim and is the only way to take a path from
another owner. It is never automatic: a stale claim is reported, not silently
reclaimed.

### It deletes nothing

`release` and conflict rollback **rename** the claim file to
`<key>.json.released` rather than unlinking it. This is not tidiness. This box
installs a `sitecustomize` shim
(`.../cli/vendor/shim/sitecustomize.py`) that wraps `os.remove` and
`shutil.rmtree` in a bulk-delete guard: past roughly 50 deletions in a turn it
raises `SystemExit(1)`. That is not an `OSError`, so it passes straight through
normal error handling and kills the process -- which is exactly how a first cut
of this tool failed `release` with a mysterious `rc=1` and a `targetCount` JSON
blob on stderr. `os.replace` is not intercepted.

The side benefits are real: renaming is atomic, releasing twice is safe
(`os.replace` overwrites the previous tombstone), and the released record stays
on disk as an audit trail. A released path has no `<key>.json`, so `claim`
recreates it with `O_EXCL` and keeps its atomicity guarantee.

## `dev_tools/guard_silent_diff.py`

Resolves git by running `git --version` and checking the output actually starts
with `git version`, falling back to the known install paths. A declick shim on
PATH therefore cannot silently shadow the real binary -- the guard either works
or says why it cannot.

```
# Diagnostic: what is dirty, and which view is hiding it?
python dev_tools/guard_silent_diff.py scan

# Gate: fail if anything outside --expect differs from HEAD
python dev_tools/guard_silent_diff.py verify --expect <paths you will stage>
```

`scan` prints the three views side by side and names the single view that would
miss each change:

```
path                        unstaged  staged  vs HEAD   text
launcher.ps1                -         yes     yes       unset

DIRTY  launcher.ps1
       hidden by : git diff (staged only)
       text attr : unset   <- diff-silent candidate (`* -text`)
       inspect   : git show HEAD:"launcher.ps1"
```

`verify` is the gate that prevents the ride-along. It exits 1 and names every
offender:

```
RIDE-ALONG RISK -- 1 tracked file(s) differ from HEAD and are NOT in --expect
  launcher.ps1
      hidden by : git diff (staged only)
      text attr : unset (`* -text`); `git diff` alone is not a check
      inspect   : git show HEAD:"launcher.ps1"

  Staging an explicit path set does NOT protect a path that is already
  dirty: the index entry is the whole file. Commit or stash the offender,
  or add it to --expect if it genuinely belongs to this commit.
```

A narrow built-in allowlist absorbs machine-generated churn that is dirty
almost always and is never a source hunk: `.repowise/**`,
`.workbuddy-ai/memory/**`, `**/__pycache__/**`, `*.pyc`. Everything else fails
loudly. `--no-default-allow` disables it; `--allow <glob>` adds to it.

## Worked example: one wave

```bash
# 1. claim everything this bead will write, before writing anything
python dev_tools/claim_paths.py claim --owner mcpw-gsj --wave 20260920-1305 \
    dev_tools/claim_paths.py dev_tools/guard_silent_diff.py \
    docs/guides/concurrent-agent-file-ownership.md \
    tests/test_claim_paths.py tests/test_guard_silent_diff.py

# ... do the work ...

# 2. gate: only my files may differ from HEAD
python dev_tools/guard_silent_diff.py verify --expect \
    dev_tools/claim_paths.py dev_tools/guard_silent_diff.py \
    docs/guides/concurrent-agent-file-ownership.md \
    tests/test_claim_paths.py tests/test_guard_silent_diff.py
# exit 0 -> safe. exit 1 -> an offender is named above; deal with it first.

# 3. orchestrator stages exactly that set and commits serially
git add -- <the same explicit paths>

# 4. re-run the gate after staging, before commit (staged-but-expected is fine)
python dev_tools/guard_silent_diff.py verify --expect <the same paths>
```

## Limits

- Both tools are **advisory**. Nothing stops an agent that never calls them.
  The point is that the honest path is one command and the collision is
  impossible to miss.
- `claim_paths.py` cannot see an agent that edits without claiming. It prevents
  collisions among agents that do claim; it does not detect an unclaimed writer.
- The guard compares against `HEAD`, so it cannot tell an intentional part of
  your commit from someone else's hunk. That is what `--expect` is for: the
  human decides, the tool refuses to guess.
- A claim has no expiry. A crashed agent leaves its claim behind; clear it with
  `release --force` after confirming the holder is gone.
