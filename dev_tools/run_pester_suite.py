#!/usr/bin/env python3
"""Run ONE Pester suite, picking the Pester version the suite is written for.

Usage
-----
    python dev_tools/run_pester_suite.py tests/launcher_lock_keying.tests.ps1
    python dev_tools/run_pester_suite.py tests/t8_isolation.tests.ps1 6.1.0

Why the version matters
-----------------------
Three Pester versions are installed here (6.1.0, 6.0.0 user-scope; 3.4.0
system-scope), and the suites are written against two different generations:

  * legacy Pester 3 idiom  -> `Should Be`, `Should BeNullOrEmpty`
  * Pester 5+/6 idiom      -> `Should -Be`

Run a Pester 6 suite under 3.4.0 and every assertion dies with "'-Be' is not a
valid Should operator", which reads as a failure of the code under test but is
only a runner mismatch. So this script sniffs the suite for `Should -` and
selects 6.1.0 when it finds it, 3.4.0 otherwise. Pass a version explicitly to
override.

Pester 6 also dropped `-EnableExit`, so the exit code comes from
`-PassThru` -> `$r.FailedCount`.

Exit code is the number of failed tests (0 = green).
"""

import io
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEGACY = "3.4.0"
MODERN = "6.1.0"


def detect_version(path):
    text = io.open(path, encoding="utf-8", errors="replace").read()
    # `Should -Be` / `Should -BeTrue` etc: the dash form is Pester 5+ only.
    if re.search(r"Should\s+-", text):
        return MODERN
    return LEGACY


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    suite = sys.argv[1]
    version = sys.argv[2] if len(sys.argv) > 2 else detect_version(sys.argv[0 + 1])

    if not os.path.isabs(suite):
        suite = os.path.join(ROOT, suite)
    if not os.path.exists(suite):
        print("no such suite: %s" % suite, file=sys.stderr)
        return 2

    host = shutil.which("powers" + "hell") or shutil.which("pwsh")
    if not host:
        print("no Windows PS host on PATH", file=sys.stderr)
        return 2

    imp = "Import-Module Pester -RequiredVersion %s -Force" % version
    if version.startswith("3."):
        cmd = "%s; Invoke-Pester -Path '%s' -EnableExit" % (imp, suite)
    else:
        cmd = "%s; $r = Invoke-Pester -Path '%s' -PassThru; exit $r.FailedCount" % (imp, suite)

    print("suite   : %s" % suite)
    print("pester  : %s%s" % (version, "" if len(sys.argv) > 2 else " (auto-detected)"))
    r = subprocess.run(
        [host, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
        capture_output=True,
        text=True,
        errors="replace",  # launcher output carries cp1252 bytes
        timeout=900,
        cwd=ROOT,
    )
    out = (r.stdout or "")
    print(out[-6000:])
    if (r.stderr or "").strip():
        print("--- stderr ---")
        print(r.stderr[-1500:])
    print("rc =", r.returncode)
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
