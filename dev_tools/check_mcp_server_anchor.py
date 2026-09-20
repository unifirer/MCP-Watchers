#!/usr/bin/env python3
"""Detect Toolport MCP servers anchored to a repo other than the launched one.

Why this exists
---------------
The watcher launcher is path-generic: `$watchersWorkspaceRoot = (Get-Location)`
and every watcher it spawns inherits that root. But the six MCP *server*
processes are NOT spawned by the launcher -- the Toolport gateway spawns them
from `%APPDATA%\\toolport\\registry.json`. A server entry that carries an
absolute `--graph` / workspace path keeps serving whichever repo was current
when the entry was authored, so the watchers report healthy while the MCP tools
answer from a different repository (bead mcpw-rkg.7: graphenium, graphify and
repowise were all pinned to J:/audio/VAD).

What the gateway actually does (verified against gateway 1.19.0, 2026-09-20)
---------------------------------------------------------------------------
* The gateway resolves a per-session *project root* from the client's
  ProcessCwd and passes it as the **default child cwd** -- a server with no
  `cwd` field still starts in the launched repo.
* `cwd` values support the `${ROOT}` placeholder, which expands to that project
  root. (Verified with an isolated throwaway gateway.)
* `${ROOT}` is NOT expanded inside `args` -- it reaches the child as the
  literal string "${ROOT}". Use a relative path plus `cwd: "${ROOT}"` instead.

What it checks
--------------
For each watched server, every argument that looks like an absolute path must
either live under the target repo root, or be a tool-cache/toolchain path that
is legitimately repo-independent. A `${ROOT}` token inside `args` is reported as
a hard error, because it will never expand.

Usage
-----
    python dev_tools/check_mcp_server_anchor.py [--repo <path>] [--registry <path>]

Exit code: 0 when every server is anchored to the target repo (or explicitly
declared repo-independent), 1 when at least one is misanchored.
"""

import argparse
import io
import json
import os
import re
import sys

WATCHED = ("graphenium", "graphify", "repowise", "grepai", "memtrace", "graft")

# Servers that resolve their workspace per MCP session instead of per process.
# memtrace's registry entry runs a cwd proxy that does an MCP `roots` handshake
# and starts a daemon per caller workspace, so a fixed cwd is correct for it.
PER_SESSION = {"memtrace"}

ABS_PATH = re.compile(r"^[A-Za-z]:[\\/]|^\\\\")


def default_registry():
    env = os.environ.get("TOOLPORT_REGISTRY")
    if env:
        return env
    appdata = os.environ.get("APPDATA")
    if not appdata:
        # Git Bash does not always export APPDATA; fall back to the home dir.
        appdata = os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
    return os.path.join(appdata, "toolport", "registry.json")


def norm(path):
    return os.path.normcase(os.path.normpath(path)).rstrip("\\/")


def under(child, parent):
    c, p = norm(child), norm(parent)
    return c == p or c.startswith(p + os.sep)


def check_entry(entry, repo_root):
    """Return a list of (severity, message) for one registry server entry."""
    problems = []
    args = entry.get("args") or []
    cwd = entry.get("cwd")

    for a in args:
        if not isinstance(a, str):
            continue
        if "${ROOT}" in a:
            problems.append(
                "ERROR  arg %r contains ${ROOT}; the gateway does NOT expand "
                "${ROOT} in args (it reaches the child literally). Use a "
                "relative path with cwd=${ROOT}." % a
            )
        elif ABS_PATH.match(a) and not under(a, repo_root):
            problems.append(
                "ERROR  arg %r is an absolute path outside the launched repo "
                "(%s) -- this entry is pinned to another repository." % (a, repo_root)
            )

    if cwd and isinstance(cwd, str) and "${ROOT}" not in cwd:
        if ABS_PATH.match(cwd) and not under(cwd, repo_root):
            problems.append(
                "ERROR  cwd %r is an absolute path outside the launched repo." % cwd
            )
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=os.getcwd(),
                    help="launched repo root (default: current directory)")
    ap.add_argument("--registry", default=default_registry(),
                    help="path to toolport registry.json")
    opts = ap.parse_args()

    if not opts.registry or not os.path.exists(opts.registry):
        print("registry not found: %s" % opts.registry, file=sys.stderr)
        return 1

    repo_root = os.path.abspath(opts.repo)
    with io.open(opts.registry, encoding="utf-8", errors="replace") as f:
        reg = json.load(f)

    if "version" not in reg:
        print("WARNING: registry has no 'version' key; the gateway expects one.",
              file=sys.stderr)

    servers = reg.get("servers") or []
    by_id = {s.get("id"): s for s in servers}

    print("repo root : %s" % repo_root)
    print("registry  : %s (version=%s, %d servers)"
          % (opts.registry, reg.get("version"), len(servers)))
    print()

    failures = 0
    for sid in WATCHED:
        entry = by_id.get(sid)
        if entry is None:
            print("SKIP   %-11s not present in this registry" % sid)
            continue
        if sid in PER_SESSION:
            print("OK     %-11s per-session workspace (cwd proxy / roots "
                  "handshake) -- no fixed anchor required" % sid)
            continue
        problems = check_entry(entry, repo_root)
        if problems:
            failures += 1
            print("FAIL   %-11s %s" % (sid, entry.get("command", "")))
            for p in problems:
                print("         %s" % p)
        else:
            print("OK     %-11s args=%s cwd=%s"
                  % (sid, entry.get("args"), entry.get("cwd")))

    print()
    if failures:
        print("%d watched server(s) are anchored outside %s." % (failures, repo_root))
        return 1
    print("Clean: every watched server follows the launched repo.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
