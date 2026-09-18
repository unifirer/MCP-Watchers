#!/usr/bin/env python3
"""Provision the grepai RPG block so it uses the cloud LLM proxy, not local Ollama.

Why this exists
---------------
`.grepai/config.yaml` is **tool state**: gitignored, owned by grepai, and rewritten
by the watcher (it stamps `watch.last_index_time` on every index pass). Anything
hand-edited there is lost on a fresh clone, a new worktree, or a checkout reset.

The repo's tests assert the intended end state:

    rpg.enabled:        true
    rpg.llm_endpoint:   http://127.0.0.1:11436/v1   (###2.llm_fallback_proxy.py,
                                                     the litellm-backed proxy)

The as-shipped grepai default -- and what a crash-loop mitigation pass left behind --
is `enabled: false` with `llm_endpoint: http://127.0.0.1:12134/v1` (local Ollama).
12134 is the *embedder* endpoint and stays there; RPG is the LLM-graph feature and
belongs on the proxy.

Run this after `grepai init`, after creating a worktree, or whenever the two
`.grepai/config.yaml` files in J:\\audio drift back. It is idempotent.

Usage
-----
    python dev_tools/ensure_grepai_rpg.py                 # patch this checkout
    python dev_tools/ensure_grepai_rpg.py --check         # report drift, change nothing
    python dev_tools/ensure_grepai_rpg.py --root J:\\audio\\MCP-Watchers --root J:\\audio\\VAD
    python dev_tools/ensure_grepai_rpg.py --no-backup     # skip the .bak-<ts> copy

Exit codes: 0 = every requested root is in the intended state (or has no config
to patch), 1 = `--check` found drift, 2 = a root could not be processed.

Stdlib only. No third-party imports -- this runs before any venv exists.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import time

WANT_ENABLED = "true"
WANT_ENDPOINT = "http://127.0.0.1:11436/v1"

# Block header and the two keys we own. Anything else under `rpg:` is left alone.
BLOCK_RE = re.compile(r"^(?P<indent>[ \t]*)rpg:[ \t]*(#.*)?$", re.M)
KEY_RE_TEMPLATE = r"^(?P<indent>[ \t]+){key}:[ \t]*(?P<value>.*?)[ \t]*$"


def _find_block(text: str):
    """Return (start, end, body_indent) of the `rpg:` block, or None.

    The block ends at the next top-level key (a non-blank line starting in
    column 0) or at EOF. Comments inside the block are preserved.
    """
    m = BLOCK_RE.search(text)
    if m is None:
        return None
    start = m.start()
    rest = text[m.end():]
    lines = rest.splitlines()
    consumed = 0
    child_indent = None
    for line in lines:
        if line.strip() and not line[0].isspace():
            break
        if line.strip() and child_indent is None:
            child_indent = line[: len(line) - len(line.lstrip())]
        consumed += len(line) + 1  # +1 for the newline split() dropped
    end = m.end() + consumed
    return start, end, (child_indent or "    ")


def patch_text(text: str):
    """Apply the intended RPG settings. Returns (new_text, changes, notes).

    `changes` lists human-readable "key: old -> new" strings; empty means the
    text was already correct. `notes` lists non-fatal findings.
    """
    notes = []
    block = _find_block(text)
    if block is None:
        # No rpg: block at all -- append one rather than fail. grepai writes a
        # full default config on init, so this is the unusual case.
        if not text.endswith("\n"):
            text += "\n"
        block_body = (
            "rpg:\n"
            "    enabled: %s\n"
            "    llm_endpoint: %s\n" % (WANT_ENABLED, WANT_ENDPOINT)
        )
        notes.append("no rpg: block found - appended one")
        return text + block_body, ["rpg: <absent> -> enabled/llm_endpoint set"], notes

    start, end, child_indent = block
    body = text[start:end]
    changes = []

    for key, want in (("enabled", WANT_ENABLED), ("llm_endpoint", WANT_ENDPOINT)):
        kre = re.compile(KEY_RE_TEMPLATE.format(key=re.escape(key)), re.M)
        m = kre.search(body)
        if m is None:
            # Key absent: append it at the end of the block.
            addition = "%s%s: %s\n" % (child_indent, key, want)
            if not body.endswith("\n"):
                body += "\n"
            body += addition
            changes.append("%s: <absent> -> %s" % (key, want))
            continue
        have = m.group("value")
        if have == want:
            continue
        body = body[: m.start()] + "%s%s: %s" % (m.group("indent"), key, want) + body[m.end():]
        changes.append("%s: %s -> %s" % (key, have, want))

    return text[:start] + body + text[end:], changes, notes


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def process_root(root: str, apply: bool, backup: bool) -> int:
    """Patch one checkout. Returns 0 ok / 1 drift / 2 error."""
    cfg = os.path.join(root, ".grepai", "config.yaml")
    if not os.path.exists(cfg):
        print("[skip ] %s - no .grepai/config.yaml (grepai not initialized)" % root)
        return 0

    try:
        text = _read(cfg)
    except OSError as exc:
        print("[error] %s - cannot read %s: %s" % (root, cfg, exc))
        return 2

    new_text, changes, notes = patch_text(text)

    if not changes:
        print("[ok   ] %s - rpg already provisioned" % root)
        for n in notes:
            print("         note: %s" % n)
        return 0

    for c in changes:
        print("[drift] %s - %s" % (root, c))
    for n in notes:
        print("         note: %s" % n)

    if not apply:
        print("[check] %s - drift found, --check left it untouched" % root)
        return 1

    if backup:
        bak = cfg + ".bak-" + time.strftime("%Y-%m-%d-%H%M%S")
        try:
            shutil.copy2(cfg, bak)
            print("         backup: %s" % bak)
        except OSError as exc:
            print("[error] %s - backup failed, not writing: %s" % (root, exc))
            return 2

    try:
        with open(cfg, "w", encoding="utf-8", newline="") as fh:
            fh.write(new_text)
    except OSError as exc:
        print("[error] %s - write failed: %s" % (root, exc))
        return 2

    # Read back: grepai owns this file and may rewrite it concurrently.
    verify = _read(cfg)
    _, remaining, _ = patch_text(verify)
    if remaining:
        print("[warn ] %s - still drifting after write (something rewrote it): %s"
              % (root, "; ".join(remaining)))
        return 2

    print("[fixed] %s" % root)
    return 0


def main(argv=None) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.dirname(here)  # dev_tools/ -> repo root

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", action="append", default=None,
                    help="checkout to patch (repeatable). Default: the repo "
                         "containing this script.")
    ap.add_argument("--check", action="store_true",
                    help="report drift and exit 1 if any; write nothing.")
    ap.add_argument("--no-backup", action="store_true",
                    help="do not write a .bak-<timestamp> copy before patching.")
    args = ap.parse_args(argv)

    roots = args.root or [default_root]
    worst = 0
    for r in roots:
        rc = process_root(os.path.abspath(r), apply=not args.check,
                          backup=not args.no_backup)
        worst = max(worst, rc)
    return worst


if __name__ == "__main__":
    sys.exit(main())
