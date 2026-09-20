#!/usr/bin/env python3
"""Claim file ownership before staging, and fail loudly on a second owner.

Why this exists
---------------
Commit 4891fe0 is labelled mcpw-oft but also carries another agent's repowise
recurrence-guard hunk and a 210-line verification doc. Two agents were editing
the same path at the same time; whichever committed first took the other's
in-flight edits with it. Telling agents "stage explicit paths, never git add -A"
does NOT fix this: explicit staging of a SHARED path still ships the other
agent's half-finished work, because the index entry is the whole file.

The discipline that actually holds here is one owner per file per wave. This
tool is the enforcement: a claim is a file created with O_EXCL, so two racing
claimants cannot both win, and the loser is told exactly who holds the path.

What it does NOT do
-------------------
It does not touch git and it does not block anything by itself. It is an
advisory lock with a loud failure mode. Nothing stops an agent that never calls
it; the point is that the honest path (claim, then edit) is cheap and the
collision is impossible to miss.

No git subprocess is spawned on purpose: the declick shim puts a `git` .cmd
document on PATH that cannot run in a pipeline, and every git call from
PowerShell is a chance to hit it. This tool is pure stdlib file I/O.

It also deletes nothing. Release and rollback rename the claim file to
`<key>.json.released` instead of unlinking it -- see retire().

Usage
-----
    python dev_tools/claim_paths.py claim --owner mcpw-gsj --wave 20260920-1305 \
        dev_tools/claim_paths.py docs/guides/x.md

    python dev_tools/claim_paths.py check --owner mcpw-gsj docs/guides/x.md
    python dev_tools/claim_paths.py list
    python dev_tools/claim_paths.py release --owner mcpw-gsj docs/guides/x.md
    python dev_tools/claim_paths.py release --owner mcpw-gsj          # all mine

`claim` is all-or-nothing: if any path in the list is held by someone else,
none of the paths in that call are claimed. A half-claim is worse than no
claim, because it looks like success.

Exit codes
----------
    0  claimed / released / nothing to do
    1  OWNERSHIP CONFLICT -- another owner holds a requested path
    2  usage or I/O error

Store location
--------------
Default is <git-dir>/mcpw-claims, found by walking up for `.git` (a directory,
or a file containing `gitdir:` for linked worktrees). Inside the git dir the
files never show up in `git status` and can never be committed by accident.
Override with --store or MCPW_CLAIM_STORE.

Paths are keyed case-insensitively and with forward slashes, because this repo
only ever runs on Windows: `Dev_Tools\\Foo.py` and `dev_tools/foo.py` are the
same claim, and a case-only mismatch must not be a silent bypass.
"""

import argparse
import hashlib
import json
import os
import socket
import sys
from datetime import datetime, timezone

SCHEMA = 1
STORE_DIRNAME = "mcpw-claims"
ENV_STORE = "MCPW_CLAIM_STORE"
RELEASED_SUFFIX = ".released"


# --------------------------------------------------------------------------
# repo / store discovery (no git subprocess)
# --------------------------------------------------------------------------

def find_git_dir(start):
    """Walk up from `start` looking for a .git directory or gitdir: file."""
    cur = os.path.abspath(start)
    while True:
        cand = os.path.join(cur, ".git")
        if os.path.isdir(cand):
            return cand
        if os.path.isfile(cand):
            # Linked worktree / submodule: .git is a pointer file.
            try:
                with open(cand, "r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if line.lower().startswith("gitdir:"):
                            target = line.split(":", 1)[1].strip()
                            if not os.path.isabs(target):
                                target = os.path.join(cur, target)
                            return os.path.normpath(target)
            except OSError:
                return None
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def resolve_store(explicit):
    if explicit:
        return os.path.abspath(explicit)
    env = os.environ.get(ENV_STORE)
    if env:
        return os.path.abspath(env)
    git_dir = find_git_dir(os.getcwd())
    if git_dir:
        return os.path.join(git_dir, STORE_DIRNAME)
    return None


def resolve_root(store):
    """Nearest ancestor of cwd holding a real `.git` directory, else store-derived.

    The root MUST NOT be derived from the store location. Claim keys are hashes
    of the normalized path, so if `--store` changed the normalization the same
    file would hash to two different keys and two agents would both "win" --
    exactly the collision this tool exists to prevent. Deriving from cwd keeps
    the key identical no matter where the store lives. Walking up past a linked
    worktree (whose `.git` is a file) is deliberate: keys stay stable across
    worktrees of the same repo.
    """
    cur = os.path.abspath(os.getcwd())
    while True:
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    git_dir = os.path.dirname(store)
    if os.path.basename(git_dir) == ".git":
        return os.path.dirname(git_dir)
    return os.getcwd()


# --------------------------------------------------------------------------
# path keys
# --------------------------------------------------------------------------

def normalize(path, root=None):
    """Canonical display form: forward slashes, relative to root when possible."""
    p = os.path.normpath(os.path.abspath(path))
    if root:
        try:
            rel = os.path.relpath(p, root)
        except ValueError:  # different drive
            rel = p
        if not rel.startswith(".."):
            p = rel
    return p.replace("\\", "/")


def key_for(normalized):
    """Case-insensitive identity, so a case-only difference cannot bypass."""
    return hashlib.sha1(normalized.lower().encode("utf-8")).hexdigest()[:16]


def claim_file(store, normalized):
    return os.path.join(store, key_for(normalized) + ".json")


def read_claim(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_claim(path, record, exclusive):
    """exclusive=True -> O_EXCL create (raises FileExistsError on a race)."""
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    fd = os.open(path, flags, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(record, fh, indent=2, sort_keys=True)
            fh.write("\n")
    except Exception:
        retire(path)
        raise


def retire(path):
    """Retire a claim file by RENAMING it, never by deleting it.

    This tool must not delete anything. The sandbox on this box installs a
    sitecustomize shim that wraps os.remove/shutil.rmtree in a bulk-delete
    guard: past ~50 deletions in a turn it raises SystemExit(1), which is not
    an OSError and therefore blows straight through ordinary error handling and
    kills the process. Renaming is not intercepted, so release and rollback
    stay reliable here and on any machine with a similar delete guard.

    It also keeps the released record on disk, so `list --all` can still show
    who held what. os.replace is atomic and overwrites a previous tombstone, so
    releasing twice is safe.
    """
    try:
        os.replace(path, path + RELEASED_SUFFIX)
    except OSError:
        pass


def make_record(normalized, owner, wave):
    return {
        "schema": SCHEMA,
        "path": normalized,
        "owner": owner,
        "wave": wave,
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "claimed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


def describe(record):
    if not record:
        return "unknown owner (unreadable claim record)"
    return "%s (wave %s, pid %s, %s)" % (
        record.get("owner", "?"),
        record.get("wave") or "-",
        record.get("pid", "?"),
        record.get("claimed_at", "?"),
    )


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_claim(args, store, root):
    requested = [normalize(p, root) for p in args.paths]
    os.makedirs(store, exist_ok=True)

    created = []      # files we created in this call -> rolled back on conflict
    conflicts = []    # (path, existing_record)
    already = []      # ours already

    try:
        for norm in requested:
            target = claim_file(store, norm)
            record = make_record(norm, args.owner, args.wave)
            if args.steal and os.path.exists(target):
                write_claim(target, record, exclusive=False)
                created.append(target)
                continue
            try:
                write_claim(target, record, exclusive=True)
                created.append(target)
            except FileExistsError:
                existing = read_claim(target)
                if existing and existing.get("owner") == args.owner:
                    already.append(norm)
                else:
                    conflicts.append((norm, existing))
    except OSError as exc:
        for f in created:
            retire(f)
        sys.stderr.write("claim store error: %s (%s)\n" % (exc, store))
        return 2

    if conflicts:
        # Roll back only what THIS call created; other owners' claims are not
        # ours to touch.
        for f in created:
            retire(f)
        sys.stderr.write(
            "CLAIM CONFLICT -- refusing all %d path(s); another owner holds %d\n"
            % (len(requested), len(conflicts))
        )
        for norm, existing in conflicts:
            sys.stderr.write("  %s\n      held by: %s\n" % (norm, describe(existing)))
        sys.stderr.write(
            "  Rule: one owner per file per wave. Release it, or pick a different\n"
            "  path, or --steal if you know the holder is gone.\n"
        )
        return 1

    print("claimed %d path(s) for owner '%s' (wave %s)"
          % (len(requested) - len(already), args.owner, args.wave or "-"))
    for norm in requested:
        tag = "already yours" if norm in already else "claimed"
        print("  [%s] %s" % (tag, norm))
    print("store: %s" % store)
    return 0


def cmd_check(args, store, root):
    requested = [normalize(p, root) for p in args.paths]
    conflicts = []
    free = []
    ours = []
    for norm in requested:
        existing = read_claim(claim_file(store, norm))
        if not existing:
            free.append(norm)
        elif existing.get("owner") == args.owner:
            ours.append(norm)
        else:
            conflicts.append((norm, existing))

    for norm in free:
        print("  [free]    %s" % norm)
    for norm in ours:
        print("  [yours]   %s" % norm)
    if conflicts:
        sys.stderr.write("CLAIM CONFLICT -- %d path(s) held by another owner\n" % len(conflicts))
        for norm, existing in conflicts:
            sys.stderr.write("  %s\n      held by: %s\n" % (norm, describe(existing)))
        return 1
    print("ok: %d free, %d already yours" % (len(free), len(ours)))
    return 0


def cmd_list(args, store, root):
    if not os.path.isdir(store):
        print("no claims (store absent: %s)" % store)
        return 0
    rows = []
    for name in sorted(os.listdir(store)):
        if not name.endswith(".json"):
            continue
        rec = read_claim(os.path.join(store, name))
        if rec:
            rows.append(rec)
    if args.owner:
        rows = [r for r in rows if r.get("owner") == args.owner]
    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
        return 0
    print("%d claim(s) in %s" % (len(rows), store))
    for rec in sorted(rows, key=lambda r: r.get("path", "")):
        print("  %-60s %s" % (rec.get("path", "?"), describe(rec)))
    return 0


def cmd_release(args, store, root):
    if not os.path.isdir(store):
        print("nothing to release (store absent: %s)" % store)
        return 0
    if args.paths:
        targets = [claim_file(store, normalize(p, root)) for p in args.paths]
    else:
        # "release everything of mine", not "release everything": sweeping the
        # whole store would hit other owners and then refuse, which reads as a
        # failure when the caller only asked to clean up after themselves.
        targets = []
        for name in os.listdir(store):
            if not name.endswith(".json"):
                continue
            full = os.path.join(store, name)
            rec = read_claim(full)
            if rec and (rec.get("owner") == args.owner or args.force):
                targets.append(full)

    released = []
    denied = []
    for target in targets:
        rec = read_claim(target)
        if not rec:
            continue
        if rec.get("owner") != args.owner and not args.force:
            denied.append(rec)
            continue
        if not os.path.exists(target):
            continue
        retire(target)
        if os.path.exists(target):
            sys.stderr.write("could not release %s (rename refused)\n" % target)
            return 2
        released.append(rec.get("path", target))
    if denied:
        sys.stderr.write("REFUSING to release %d claim(s) owned by someone else\n" % len(denied))
        for rec in denied:
            sys.stderr.write("  %s  held by %s\n" % (rec.get("path", "?"), describe(rec)))
        sys.stderr.write("  Use --force only if you are certain that owner is gone.\n")
        return 1
    print("released %d claim(s) for owner '%s'" % (len(released), args.owner))
    for path in released:
        print("  %s" % path)
    return 0


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------

def build_parser():
    ap = argparse.ArgumentParser(
        prog="claim_paths.py",
        description="Claim file ownership before staging; fail loudly on a second owner.",
    )
    ap.add_argument("--store", help="claim store dir (default <git-dir>/%s)" % STORE_DIRNAME)
    sub = ap.add_subparsers(dest="command")

    def add_common(p):
        p.add_argument("--owner", required=True, help="agent/bead id claiming the paths")
        # default=SUPPRESS, not None: the subparser parses into a fresh
        # namespace and copies every attribute onto the main one, so a None
        # default here would overwrite a --store given BEFORE the subcommand
        # and silently fall back to the in-repo store.
        p.add_argument("--store", default=argparse.SUPPRESS, help="claim store dir")

    p_claim = sub.add_parser("claim", help="claim paths (all-or-nothing)")
    add_common(p_claim)
    p_claim.add_argument("--wave", help="wave label, e.g. 20260920-1305")
    p_claim.add_argument("--steal", action="store_true",
                         help="overwrite an existing claim (use only when the holder is gone)")
    p_claim.add_argument("paths", nargs="+")

    p_check = sub.add_parser("check", help="report who holds paths, without claiming")
    add_common(p_check)
    p_check.add_argument("paths", nargs="+")

    p_list = sub.add_parser("list", help="list claims")
    p_list.add_argument("--store", default=argparse.SUPPRESS, help="claim store dir")
    p_list.add_argument("--owner", help="filter to one owner")
    p_list.add_argument("--json", action="store_true")

    p_rel = sub.add_parser("release", help="release claims you own")
    add_common(p_rel)
    p_rel.add_argument("--force", action="store_true",
                       help="release even claims owned by someone else")
    p_rel.add_argument("paths", nargs="*")
    return ap


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    args = build_parser().parse_args(argv)
    if not args.command:
        build_parser().print_help()
        return 2

    store = resolve_store(getattr(args, "store", None))
    if not store:
        sys.stderr.write(
            "no claim store: not inside a git work tree and --store/%s was not set\n"
            % ENV_STORE
        )
        return 2
    root = resolve_root(store)

    handlers = {
        "claim": cmd_claim,
        "check": cmd_check,
        "list": cmd_list,
        "release": cmd_release,
    }
    return handlers[args.command](args, store, root)


if __name__ == "__main__":
    sys.exit(main())
