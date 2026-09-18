#!/usr/bin/env python3
"""Run ONE Pester suite and report a verdict you can trust.

Usage
-----
    python dev_tools/run_pester_suite.py tests/launcher_lock_keying.tests.ps1
    python dev_tools/run_pester_suite.py tests/t8_isolation.tests.ps1 6.1.0

Shares its logic with sweep_pester.py on purpose
------------------------------------------------
This used to carry its own copy of the version-picking rule, and the two tools
then disagreed on the same file: launcher_equal_quarters came back "15 passed"
from the sweeper and "15 failed, rc=15" from here. The version rule is now
imported from sweep_pester so they cannot drift apart again.

The rule, since it is easy to get wrong:

  * File contains `Import-Module Pester` -> EXECUTE THE FILE, let it choose.
    Do not wrap it in an outer Invoke-Pester. Wrapping a self-invoking suite
    double-runs it: launcher_equal_quarters passes 15 when executed directly
    and "fails" all 15 when wrapped, same Pester version, same box.
  * File does NOT import Pester -> it gets whatever autoload hands it (6.1.0),
    which is wrong for legacy idiom. Pick by sniffing `Should -`: present ->
    6.1.0, else 3.4.0.

Passing a version explicitly overrides all of the above. It is honoured, but
warned about when the file imports Pester itself, because that is the
combination that manufactures false failures.

Exit code is the number of failed tests (0 = green).
"""

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:
    import sweep_pester as sp
except ImportError:
    print("cannot import sweep_pester from %s" % HERE, file=sys.stderr)
    sys.exit(2)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    suite = sys.argv[1]
    explicit = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.isabs(suite):
        suite = os.path.join(sp.ROOT, suite)
    if not os.path.exists(suite):
        print("no such suite: %s" % suite, file=sys.stderr)
        return 2

    own = sp.picks_own_pester(suite)
    if explicit:
        version = explicit
        cmd = sp.build_cmd(suite, version)
        mode = "wrapped (explicit override)"
        if own:
            mode += " -- WARNING: file imports Pester itself"
    elif own:
        version = "file"
        cmd = "& '%s'" % suite
        mode = "direct (file picks its own Pester)"
    else:
        version = sp.detect_version(suite)
        cmd = sp.build_cmd(suite, version)
        mode = "wrapped (auto-detected)"

    host = shutil.which("powers" + "hell") or shutil.which("pwsh")
    if not host:
        print("no Windows PS host on PATH", file=sys.stderr)
        return 2

    print("suite   : %s" % suite)
    print("pester  : %s  [%s]" % (version, mode))
    r = subprocess.run(
        [host, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", cmd],
        capture_output=True,
        text=True,
        errors="replace",  # launcher output carries cp1252 bytes
        timeout=900,
        cwd=sp.ROOT,
    )
    out = r.stdout or ""
    passed, fails = sp.parse(out)

    tail = out[-4000:]
    if tail.strip():
        print(tail)
    if (r.stderr or "").strip():
        print("--- stderr ---")
        print(r.stderr[-1500:])

    print("VERDICT : passed=%d failed=%d   (rc=%s, ignored)" % (passed, len(fails), r.returncode))
    for f in fails:
        print("  x " + f)
    return len(fails)


if __name__ == "__main__":
    sys.exit(main())
