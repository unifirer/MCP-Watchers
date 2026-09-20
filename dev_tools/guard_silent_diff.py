#!/usr/bin/env python3
"""Refuse to let an unrelated in-flight hunk ride into your commit.

Why this exists
---------------
An uncommitted hunk (the graphiti shared-copy retirement) sat in the launcher
and would have ridden silently into an unrelated bead commit. The reason a
single `git diff` view cannot be trusted is that a change is visible in exactly
one of two places, and the two places are checked by two different commands:

    worktree != index   ->  `git diff`            (unstaged)
    index    != HEAD    ->  `git diff --cached`   (staged)

Once a hunk is staged, plain `git diff` is SILENT about it -- it compares the
worktree to the index, and they agree. So an agent that runs `git diff`, sees
nothing alarming, and stages its own path can ship a hunk that was already in
the index. `git diff --cached` has the mirror-image blind spot. Neither view
alone is a safety check.

The only state-independent view is `git diff HEAD`, which compares the worktree
to the last commit and therefore sees staged and unstaged changes alike. This
tool reads all three views, reports which one each hunk lives in, and gates on
`git diff HEAD`.

Measured on this repo (2026-09-20)
----------------------------------
`.gitattributes` is `* -text`, so ALL 158 tracked files carry `text: unset`.
That attribute is real, but it is not what silences the diff: with `* -text`
alone, `git diff` still prints the launcher's unstaged hunks (117+/63- across
350 lines, verified). `git check-attr -a` shows no `diff` attribute and
`.git/info/attributes` is absent, so nothing marks these files binary. The
silent state is the staged one described above. Because the tool gates on
`git diff HEAD`, it is correct under either reading, and it still reports the
`-text` attribute per file so the trap stays visible.

Modes
-----
    # Diagnostic: what is dirty right now, and which view hides it?
    python dev_tools/guard_silent_diff.py scan

    # Gate: I am about to stage exactly these paths. Fail if anything else
    # tracked is dirty, naming the offender and the view that hides it.
    python dev_tools/guard_silent_diff.py verify --expect dev_tools/x.py docs/y.md

    # --repo/--git/--allow/--no-default-allow are accepted on either side of
    # the subcommand.

Exit codes
----------
    0  clean, or only allowlisted churn is dirty
    1  RIDE-ALONG RISK -- a non-allowlisted tracked file is dirty vs HEAD
    2  usage / git / repo error

Run it immediately before staging, and again after staging but before commit
(`verify --expect` is idempotent; staged-but-expected files are still expected).
"""

import argparse
import fnmatch
import os
import re
import shutil
import subprocess
import sys

# Machine-generated churn that is dirty almost always and is never a source
# hunk. Kept deliberately narrow: anything not listed here fails loudly.
DEFAULT_ALLOW = (
    ".repowise/**",
    ".workbuddy-ai/memory/**",
    "**/__pycache__/**",
    "*.pyc",
)

GIT_FALLBACKS = (
    r"C:\Program Files\Git\cmd\git.exe",
    r"C:\Program Files\Git\bin\git.exe",
    "/mingw64/bin/git.exe",
    "/usr/bin/git",
)


# --------------------------------------------------------------------------
# git resolution
# --------------------------------------------------------------------------

def resolve_git(explicit=None):
    """Return a git that really is git.

    The declick shim puts `git` (a bash launcher) and `git.cmd` on PATH. The
    bash one cannot be exec'd by subprocess on Windows, and a `git` that
    answers anything other than "git version ..." is rejected. Falling back to
    the known install paths means a shadowed PATH cannot silently break the
    guard -- it either works or it says so.
    """
    candidates = []
    if explicit:
        candidates.append(explicit)
    found = shutil.which("git")
    if found:
        candidates.append(found)
    candidates.extend(GIT_FALLBACKS)

    tried = []
    for cand in candidates:
        if not cand or cand in tried:
            continue
        tried.append(cand)
        try:
            proc = subprocess.run([cand, "--version"], capture_output=True,
                                  text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            continue
        if proc.returncode == 0 and proc.stdout.strip().startswith("git version"):
            return cand
    raise RuntimeError(
        "no working git found; tried: %s\n"
        "(if a declick shim is shadowing git, pass --git <path>)" % ", ".join(tried)
    )


def git(git_exe, repo, args, check=True):
    proc = subprocess.run([git_exe, "-C", repo] + args,
                          capture_output=True, text=True, errors="replace")
    if check and proc.returncode != 0:
        raise RuntimeError("git %s failed (rc=%d): %s"
                           % (" ".join(args), proc.returncode, proc.stderr.strip()))
    return proc


def git_names(git_exe, repo, args):
    """NUL-separated path list -> set of repo-relative, forward-slash paths."""
    proc = git(git_exe, repo, args)
    return {p.replace("\\", "/") for p in proc.stdout.split("\0") if p}


# --------------------------------------------------------------------------
# globs
# --------------------------------------------------------------------------

def glob_to_re(pattern):
    """fnmatch with `**` crossing separators; case-insensitive (Windows)."""
    out = []
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "*":
            if i + 1 < len(pattern) and pattern[i + 1] == "*":
                out.append(".*")
                i += 2
                if i < len(pattern) and pattern[i] == "/":
                    out.append("/?")
                    i += 1
                continue
            out.append("[^/]*")
        elif ch == "?":
            out.append("[^/]")
        elif ch in ".+()|^$\\[]{}":
            out.append("\\" + ch)
        else:
            out.append(ch)
        i += 1
    return re.compile("^" + "".join(out) + "$", re.IGNORECASE)


def is_allowed(path, patterns):
    return any(glob_to_re(p).match(path) for p in patterns)


# --------------------------------------------------------------------------
# inspection
# --------------------------------------------------------------------------

def check_head(git_exe, repo):
    proc = git(git_exe, repo, ["rev-parse", "--verify", "HEAD"], check=False)
    if proc.returncode != 0:
        raise RuntimeError("repo has no HEAD commit yet: %s" % repo)


def views(git_exe, repo):
    """path -> {'unstaged', 'staged', 'vs_head'} booleans."""
    check_head(git_exe, repo)
    unstaged = git_names(git_exe, repo, ["diff", "--name-only", "-z"])
    staged = git_names(git_exe, repo, ["diff", "--cached", "--name-only", "-z"])
    vs_head = git_names(git_exe, repo, ["diff", "HEAD", "--name-only", "-z"])
    table = {}
    for path in vs_head | unstaged | staged:
        table[path] = {
            "unstaged": path in unstaged,
            "staged": path in staged,
            "vs_head": path in vs_head,
        }
    return table


def text_attrs(git_exe, repo, paths):
    """path -> git `text` attribute value ('unset' when `* -text` applies)."""
    if not paths:
        return {}
    payload = "\0".join(sorted(paths)) + "\0"
    proc = subprocess.run([git_exe, "-C", repo, "check-attr", "--stdin", "-z", "text"],
                          input=payload, capture_output=True, text=True,
                          errors="replace")
    if proc.returncode != 0:
        return {}
    fields = proc.stdout.split("\0")
    out = {}
    for i in range(0, len(fields) - 2, 3):
        out[fields[i].replace("\\", "/")] = fields[i + 2]
    return out


def normalize_expect(repo, path):
    p = os.path.normpath(os.path.abspath(path) if os.path.isabs(path)
                         else os.path.join(repo, path))
    try:
        rel = os.path.relpath(p, repo)
    except ValueError:
        rel = p
    return rel.replace("\\", "/")


def hidden_by(entry):
    """Which single view would MISS this change."""
    if entry["staged"] and not entry["unstaged"]:
        return "git diff (staged only)"
    if entry["unstaged"] and not entry["staged"]:
        return "git diff --cached (unstaged only)"
    return "no single view hides it (both views show it)"


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def collect_dirty(git_exe, repo, allow, no_default_allow):
    patterns = list(allow) if no_default_allow else list(DEFAULT_ALLOW) + list(allow)
    table = views(git_exe, repo)
    attrs = text_attrs(git_exe, repo, list(table))
    dirty = {p: e for p, e in table.items() if e["vs_head"] and not is_allowed(p, patterns)}
    return dirty, attrs, patterns


def cmd_scan(args, git_exe, repo):
    dirty, attrs, patterns = collect_dirty(git_exe, repo, args.allow, args.no_default_allow)
    all_dirty, _, _ = collect_dirty(git_exe, repo, [], args.no_default_allow)

    print("repo  : %s" % repo)
    print("git   : %s" % git_exe)
    print("allow : %s" % ", ".join(patterns))
    print("")
    print("%-76s %-9s %-7s %-9s %s" % ("path", "unstaged", "staged", "vs HEAD", "text"))
    print("-" * 112)
    for path in sorted(all_dirty):
        e = all_dirty[path]
        print("%-76s %-9s %-7s %-9s %s" % (
            path[:76],
            "yes" if e["unstaged"] else "-",
            "yes" if e["staged"] else "-",
            "yes" if e["vs_head"] else "-",
            attrs.get(path, "?"),
        ))
    if not all_dirty:
        print("(no tracked file differs from HEAD)")
        print("\nVERDICT: clean")
        return 0

    print("")
    for path in sorted(dirty):
        e = dirty[path]
        print("DIRTY  %s" % path)
        print("       hidden by : %s" % hidden_by(e))
        print("       text attr : %s%s" % (
            attrs.get(path, "?"),
            "   <- diff-silent candidate (`* -text`)" if attrs.get(path) == "unset" else "",
        ))
        print("       inspect   : git show HEAD:\"%s\"" % path)
    skipped = len(all_dirty) - len(dirty)
    if skipped:
        print("\n(%d allowlisted path(s) not shown above)" % skipped)
    print("\nVERDICT: %d non-allowlisted tracked file(s) differ from HEAD" % len(dirty))
    return 1 if dirty else 0


def cmd_verify(args, git_exe, repo):
    expected = {normalize_expect(repo, p).lower() for p in args.expect}
    dirty, attrs, patterns = collect_dirty(git_exe, repo, args.allow, args.no_default_allow)

    offenders = {p: e for p, e in dirty.items() if p.lower() not in expected}
    print("repo     : %s" % repo)
    print("expected : %d path(s) about to be staged" % len(args.expect))
    for p in args.expect:
        print("           %s" % normalize_expect(repo, p))
    sys.stdout.flush()  # keep the verdict below the header it belongs to

    if not offenders:
        print("\nVERDICT: SAFE -- nothing outside the expected set differs from HEAD")
        return 0

    sys.stderr.write(
        "\nRIDE-ALONG RISK -- %d tracked file(s) differ from HEAD and are NOT in --expect\n"
        % len(offenders)
    )
    for path in sorted(offenders):
        e = offenders[path]
        sys.stderr.write("  %s\n" % path)
        sys.stderr.write("      hidden by : %s\n" % hidden_by(e))
        if attrs.get(path) == "unset":
            sys.stderr.write("      text attr : unset (`* -text`); `git diff` alone is not a check\n")
        sys.stderr.write("      inspect   : git show HEAD:\"%s\"\n" % path)
    sys.stderr.write(
        "\n  Staging an explicit path set does NOT protect a path that is already\n"
        "  dirty: the index entry is the whole file. Commit or stash the offender,\n"
        "  or add it to --expect if it genuinely belongs to this commit.\n"
    )
    return 1


def add_shared(p, is_main):
    """Options accepted on either side of the subcommand.

    On a subparser every default MUST be SUPPRESS. A subparser parses into a
    fresh namespace and copies every attribute onto the main one, so a real
    default would overwrite an option given BEFORE the subcommand -- e.g.
    `--allow '*.ps1' verify ...` would silently fall back to no extra allowlist.
    """
    main = is_main
    p.add_argument("--repo", default=os.getcwd() if main else argparse.SUPPRESS,
                   help="repo root (default: cwd)")
    p.add_argument("--git", default=None if main else argparse.SUPPRESS,
                   help="explicit git executable (bypasses PATH shims)")
    p.add_argument("--allow", action="append",
                   default=[] if main else argparse.SUPPRESS,
                   help="extra allowlist glob (repeatable)")
    p.add_argument("--no-default-allow", action="store_true",
                   default=False if main else argparse.SUPPRESS,
                   help="do not apply the built-in machine-churn allowlist")


def build_parser():
    ap = argparse.ArgumentParser(
        prog="guard_silent_diff.py",
        description="Fail loudly when a stray hunk could ride into your commit.",
    )
    add_shared(ap, True)
    sub = ap.add_subparsers(dest="command")

    p_scan = sub.add_parser("scan", help="report dirty tracked files and which view hides them")
    add_shared(p_scan, False)

    p_verify = sub.add_parser("verify", help="gate: fail if anything outside --expect is dirty")
    add_shared(p_verify, False)
    # extend+nargs: both `--expect a b` and `--expect a --expect b` work. Plain
    # append would silently reject the space-separated form, which is the one
    # an orchestrator listing a staging set will actually type.
    p_verify.add_argument("--expect", action="extend", nargs="+", default=[], required=True,
                          help="path about to be staged (space-separated or repeated)")
    return ap


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    args = build_parser().parse_args(argv)
    if not args.command:
        build_parser().print_help()
        return 2

    repo = os.path.abspath(getattr(args, "repo", None) or os.getcwd())
    if not os.path.isdir(repo):
        sys.stderr.write("no such repo dir: %s\n" % repo)
        return 2
    try:
        git_exe = resolve_git(getattr(args, "git", None))
        return cmd_scan(args, git_exe, repo) if args.command == "scan" \
            else cmd_verify(args, git_exe, repo)
    except RuntimeError as exc:
        sys.stderr.write("guard_silent_diff: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
