# Git repository repair in `J:\audio\MCP-Watchers`

**Date:** 2026-09-23
**Bead:** `mcpw-lom`
**Predecessor:** `reports/2026-09-23-git-repo-corruption.md` (diagnosis only, no repair attempted)
**Status:** repaired. `git status`, `git diff`, `git log`, `git rev-list`, `git fetch` all usable again.

---

## Summary

The damage was **not** one lost object. Four things were wrong at once, and the first
two each independently blocked `git fetch`, which is why the runbook in the diagnosis
report ("`git fetch github` restores them") did not work as written.

| # | Defect | Fix applied | Reversible? |
|---|---|---|---|
| 1 | `.git/objects/info/commit-graphs/` referenced `4f84c000…`, absent from the object database | cache parked to `commit-graphs.bak` (derived file, git regenerates it) | yes — move it back |
| 2 | `refs/heads/fixtests2-20260919-2045` and `refs/heads/mcpw-01k-remove-tier5` pointed at absent objects, so ref negotiation aborted | ref files moved to `C:\Temp\mcpw-git-repair-20260923\broken-refs\` (SHAs preserved in text) | yes — move them back |
| 3 | Every local ref's history truncated at an absent ancestor, so negotiation could not compute "haves" | `git fetch --refetch github` / `gitlab` (full pack, no negotiation) | additive only |
| 4 | `9c706b62`'s parent `42aa9514…` is unrecoverable and truncated `git log` | `git replace --graft 9c706b62 7c8daeff` | yes — `git replace -d 9c706b62` |

## What was recovered

`git fetch --refetch` restored four objects that were genuinely missing locally and
present on both remotes:

    git cat-file -t 5ed011fa…   -> commit    (mcpw-sweep-20260920-1305 ancestor)
    git cat-file -t 514ab65a…   -> commit    (main ancestor)
    git cat-file -t 2baebbbc…   -> commit    (mcpw-01k-remove-tier5 tip)
    git cat-file -t 4f84c000…   -> commit    (fixtests2-20260919-2045 tip)

Both "lost" branch tips were therefore **not** lost: `mcpw-01k-remove-tier5` and
`fixtests2-20260919-2045` are both intact again. That resolves open decision #2 in the
diagnosis report — nothing had to be deleted.

## What is permanently lost

**Seven commits** on `mcpw-beads-sweep-20260921` between the remote tip `7c8daeff` and
`9c706b6`. They are recorded only as invalid reflog entries, all absent from the object
database and from both remotes (`upload-pack: not our ref`):

    22d8b276  0d3b56d2  1de0e76f  6e90735c  7a0948b0  06b9bfa0  42aa9514

They were never pushed. `git fetch <remote> <sha>` was attempted for `42aa9514` against
both remotes and refused: `remote error: upload-pack: not our ref`.

The **trees** of the surviving commits `9c706b6` and `de2e29e` are intact, so no
working-tree content was lost — only seven intermediate revisions.

Also permanently lost: **one blob**, `1b992ce8…` = `.workbuddy-ai/memory/2026-09-22.md`
in tree `b5ad9b19`. This is a historical committed revision of a memory file whose
current content is on disk. It makes `git show --stat` fail for commits whose trees
include `b5ad9b19`, but no live content depends on it.

## The graft (and why)

`9c706b6`'s recorded parent `42aa9514` does not exist, which truncated `git log` at that
point. `git replace --graft 9c706b623925f8987c1679195321200b54c02fbb 7c8daeff66e766c2d575dcf41ed9d6fd2e85d5a3`
re-parents the readable commit onto the known-good remote tip, so traversal works:

    $ git log --oneline -3
    de2e29e fix(launcher): :8765 duplicate reaper no longer kills the live server
    9c706b6 docs(memory): graftd is not on heimdall's live path - qxj.3 can close
    7c8daef mcpw-zc3: ask for a 120-minute idle TTL at the call site, not in grepai's file

    $ git rev-list --count HEAD
    150

`git replace` is non-destructive: it writes `refs/replace/<sha>` and leaves the original
object untouched. Undo with `git replace -d 9c706b623925f8987c1679195321200b54c02fbb`.

Consequence to be aware of: `git status` now reports
`ahead 2` of `gitlab/mcpw-beads-sweep-20260921`, not ahead 9. The seven lost commits are
omitted from that count because they no longer exist.

## Residual, not repaired

`git fsck` still reports 28 `invalid reflog entry` warnings and the two broken links
(`9c706b62 -> 42aa9514`, tree `b5ad9b19 -> blob 1b992ce8`). These are **deliberately
left in place** — the diagnosis report's "Do NOT run" list is respected:

- the reflog is the only local record of the seven lost SHAs; expiring it destroys the
  evidence that would let them be hunted down in a backup later;
- nothing is prunable (`prune-packable: 0`, `garbage: 0`), so no cleanup is warranted;
- `git gc` / `repack` were not run.

## Rollback

Everything done is reversible from `C:\Temp\mcpw-git-repair-20260923\`:

    dotgit-backup/     full pre-repair .git (5.4 MB)
    broken-refs/       the two ref files, SHAs intact
    pending.txt        74-line status --porcelain at repair time
    pending.diff       889 KB working-tree diff at repair time

To revert: restore `dotgit-backup` over `.git`, then re-apply nothing.

## Root cause

Unchanged from the diagnosis report: the **J: volume** loses object writes while keeping
refs and reflogs. This is the third instance (`mcpw-sr4`, `recovered-20260918-2316`,
today). The repair makes the repo usable; it does not fix the volume.

## Acceptance check (all pass)

    git status                 # ok, no error lines
    git diff HEAD              # ok
    git log --oneline          # ok, 150 commits
    git rev-list --count HEAD  # 150
    git fetch github           # ok
    git fetch gitlab           # ok
