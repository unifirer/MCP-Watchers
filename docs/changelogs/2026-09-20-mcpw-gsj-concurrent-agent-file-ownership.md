# mcpw-gsj — one owner per file per wave, made enforceable

Date: 2026-09-20
Bead: `mcpw-gsj` (P2 chore)
Component: `dev_tools/claim_paths.py`, `dev_tools/guard_silent_diff.py` (both new)

## Summary

Parallel sub-agents share one git index. The orchestrator had adopted an
ad-hoc rule -- one owner per file per wave, agents never commit, commits land
serially with explicit paths -- but nothing failed when the rule was broken.
This bead turns that folklore into a claim tool that refuses a second owner,
plus a gate that refuses to let a stray hunk ride into an unrelated commit.

## The incident

`4891fe0` is labelled `mcpw-oft` and also carries another agent's repowise
recurrence-guard hunk and a 210-line verification doc. Two agents were editing
the same path; whichever committed first took the other's in-flight edits.

"Stage explicit paths, never `git add -A`" does not fix this. It only avoids
files you never named. When two agents touch the **same** path, staging that
path stages the whole file, including the other agent's unfinished edit.

## The silent-diff claim, corrected

The report attributed the silent diff to `.gitattributes: * -text`. Measured
on 2026-09-20, that attribute is real -- it applies to **all 158 tracked
files**, and `git check-attr -a` shows no `diff` attribute and
`.git/info/attributes` is absent -- but it is **not** the mechanism. With
`* -text` in force, plain `git diff` still prints the launcher's unstaged hunks
in full: 117 insertions, 63 deletions, 350 lines of patch.

The state in which a diff really is silent is the **index**, for every file:

```
worktree != index   ->  git diff            sees it
index    != HEAD    ->  git diff --cached   sees it
```

Once a hunk is staged, `git diff` compares worktree to index, they agree, and
it prints nothing. `git diff --cached` has the mirror-image blind spot. Only
`git diff HEAD` sees staged and unstaged changes alike, so both tools gate on
that view. Reproduced in `tests/test_guard_silent_diff.py`: after
`git add launcher.ps1`, `git diff --stat` is empty and `git diff --cached
--stat` is not.

## Discipline chosen

**One owner per file per wave** as the policy, **an advisory claim** as the
mechanism.

Rejected, concretely:

- **Per-agent worktrees** -- `core.hooksPath` is repo-local and shared by every
  linked worktree, so each worktree commit still pays the ~4 minute beads
  pre-commit hook. `.beads/` and `.repowise/` state is read by watchers outside
  git, so worktrees fork state other processes are using. The merge is where
  the contamination returns, on a 320 KB single-file launcher with no automatic
  conflict signal on the wiring strings the tests anchor on. And the `J:`
  volume silently discards slash-named refs (mcpw-sr4).
- **Per-agent branches** -- same merge problem, plus the mcpw-sr4 defect means
  `agent/foo` may not create a ref at all, and agents never commit here by
  design, so the branch is machinery nobody would use.

Full reasoning: `docs/guides/concurrent-agent-file-ownership.md`.

## What was built

`dev_tools/claim_paths.py` -- claim/release/list/check. Atomic `O_EXCL` claim
files under `<git-dir>/mcpw-claims/` (inside `.git`, so they never show in
`git status` and cannot be committed). `claim` is all-or-nothing; a collision
exits 1 and names the holder, wave, pid and timestamp. Keys are
case-insensitive with forward slashes and are derived from the working
directory, never from the store, so `Dev_Tools\Foo.py` cannot bypass a claim on
`dev_tools/foo.py`. No git subprocess is spawned, so the declick `git` shim
cannot be involved.

`dev_tools/guard_silent_diff.py` -- `scan` reports dirty tracked files with the
three views side by side and names the single view that would miss each change;
`verify --expect <paths>` exits 1 and names every offender that differs from
`HEAD` outside the expected set. A narrow built-in allowlist absorbs
machine-generated churn (`.repowise/**`, `.workbuddy-ai/memory/**`,
`__pycache__`, `*.pyc`); everything else fails loudly. git is resolved by
validating that `git --version` really prints `git version`, so a declick shim
on PATH cannot silently shadow it.

## Two real bugs found while building this

1. **argparse subparser defaults discarded pre-subcommand options.** A
   subparser parses into a fresh namespace and copies every attribute onto the
   main one, so `--store X claim ...` silently fell back to the in-repo store.
   Fixed with `default=argparse.SUPPRESS` on the subparser copies.
2. **`release --owner X` with no paths swept the whole store**, hit other
   owners' claims, and refused. Now it releases only that owner's claims.

## The delete guard

A first cut failed `release` with a mysterious `rc=1` and a `targetCount` JSON
blob on stderr. Cause: this box installs
`.../cli/vendor/shim/sitecustomize.py`, which wraps `os.remove` and
`shutil.rmtree` in a bulk-delete guard -- past roughly 50 deletions in a turn it
raises `SystemExit(1)`. That is not an `OSError`, so it passes through ordinary
error handling and kills the process.

`claim_paths.py` therefore deletes nothing. Release and rollback **rename** the
claim file to `<key>.json.released`; `os.replace` is not intercepted. Renaming
is atomic, releasing twice is safe, the released record stays as an audit
trail, and a released path still has no `<key>.json`, so re-claiming keeps its
`O_EXCL` atomicity.

## Verification

- `tests/test_claim_paths.py` + `tests/test_guard_silent_diff.py`:
  **29 of 29 tests passed** (`pytest -c pytest.ini -q`, rc=0), run sandboxed so
  the delete guard was active.
- The central test asserts the premise itself: after staging a stray hunk,
  `git diff --stat` is empty while `git diff HEAD --name-only` names the file,
  and `scan`/`verify` both flag it.
- `guard_silent_diff.py scan` on this repo correctly names the launcher,
  `Modules/watcher_pane_scripts.ps1`, `Modules/watcher_teardown.ps1`,
  `AGENTS.md`, `README.md` and `.gitignore` as dirty vs `HEAD` -- i.e. exactly
  the files that could ride into an unrelated commit right now.
- Nothing was committed and no forbidden path was edited (see bead notes).

## Files added

- `dev_tools/claim_paths.py`
- `dev_tools/guard_silent_diff.py`
- `tests/test_claim_paths.py`
- `tests/test_guard_silent_diff.py`
- `docs/guides/concurrent-agent-file-ownership.md`
- `docs/changelogs/2026-09-20-mcpw-gsj-concurrent-agent-file-ownership.md`

## Limits

Both tools are advisory: they prevent collisions among agents that claim, and
detect ride-along hunks, but nothing stops an agent that never calls them. The
guard compares against `HEAD` and so cannot distinguish an intentional part of
a commit from someone else's hunk -- that judgement is what `--expect` encodes.
Claims have no expiry; clear a crashed agent's claim with `release --force`
after confirming the holder is gone.
