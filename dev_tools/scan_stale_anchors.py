#!/usr/bin/env python3
"""Find test assertions anchored on launcher source that no longer exists.

Why this exists
---------------
Many launcher tests are source-wiring locks: they assert that a literal string
appears in ###1.watchers_for_...ps1 (or in Modules/watcher_pane_scripts.ps1,
where the tailer template lives). When the launcher is refactored, such an
anchor can quietly stop matching. The test then fails on a string that no
longer exists rather than on the behaviour it was written to lock -- or, worse,
a suite that nobody runs stays green forever.

Real example (2026-09-19): tests/launcher_proxy_wiring.tests.ps1 asserted
`Invoke-GmSemanticBuild -Mode "full"`. The -Mode parameter was removed when the
"full" warm-up was replaced by the incremental daemon, so $warmIdx was -1 and
the ordering test failed on a string, not on the ordering.

What it checks
--------------
Positive anchors only: `IndexOf('X')`, `Contains('X')`, `-match 'X'`,
`Should Match 'X'`. Negative assertions (`Should Not Match`, `-notmatch`) are
skipped deliberately -- for those, absence is the PASSING state.

Only literals with no regex metacharacter are tested, so a plain substring
check against the source is a valid existence test. ALL-CAPS literals are
skipped: those are markers printed by a spawned harness (THREW:, ACQUIRED).

Usage
-----
    python dev_tools/scan_stale_anchors.py

Exit code is always 0; read the report. A non-empty report is a lead, not a
verdict -- confirm the suite actually fails before changing anything.
"""

import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCHER = os.path.join(
    ROOT, "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
)
PANE_MOD = os.path.join(ROOT, "Modules", "watcher_pane_scripts.ps1")

ANCHOR = re.compile(
    r"(?:\.IndexOf|\.Contains|-match|Should\s+Match|Should\s+Not\s+Match)"
    r"\s*\(?\s*'([^']{4,})'"
)
META = re.compile(r"[\\\[\](){}^$?*+|.]")


def main():
    sources = []
    for path in (LAUNCHER, PANE_MOD):
        if not os.path.exists(path):
            print("MISSING SOURCE: %s" % path, file=sys.stderr)
            continue
        sources.append(io.open(path, encoding="utf-8", errors="replace").read())
    if not sources:
        return 1
    combined = "\n".join(sources)

    hits = []
    for path in sorted(glob.glob(os.path.join(ROOT, "tests", "*.tests.ps1"))):
        text = io.open(path, encoding="utf-8", errors="replace").read()
        # Only suites that actually read the launcher or the pane module.
        if "###1.watchers_for_memtrace" not in text and "watcher_pane_scripts" not in text:
            continue
        for m in ANCHOR.finditer(text):
            # Negation must be read from the MATCHED OPERATOR, not from a
            # captured prefix: an optional prefix group consumes "Should Not
            # Match", the required alternation then fails, and the engine
            # backtracks to an empty prefix -- so every negative shows as a hit.
            if re.search(r"Not\s+Match|notmatch", m.group(0), re.IGNORECASE):
                continue
            lit = m.group(1)
            if META.search(lit):
                continue
            if lit == lit.upper():
                continue
            if lit in combined:
                continue
            line = text[: m.start()].count("\n") + 1
            hits.append((os.path.basename(path), line, lit))

    print("Positive literal anchors absent from launcher + pane module: %d" % len(hits))
    for name, line, lit in hits:
        print("\n%-52s :%d" % (name, line))
        print("      %s" % lit[:150])
    if not hits:
        print("\nClean: every positive anchor resolves to real source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
