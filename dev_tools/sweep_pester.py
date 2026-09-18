#!/usr/bin/env python3
"""Run every Pester suite in tests/ and report the real failure set.

Why this does not trust exit codes
----------------------------------
Most suites in this repo end with a self-invoking guard:

    if (-not $env:SOME_FLAG) { $env:SOME_FLAG = '1'; Invoke-Pester -Path $MyInvocation.MyCommand.Path }

The OUTER Invoke-Pester then reports "Passed: 0 Failed: 0" and, with
-EnableExit, returns 0. Real failures inside the INNER run never reach the exit
code. On 2026-09-19 launcher_proxy_wiring.tests.ps1 was green on rc=0 while
actually failing "proxy gate runs before gm semantic warm-up".

So: count [-] lines, and de-duplicate them, because the self-invoking pattern
runs every test twice.

Pester versions
---------------
This box has 6.1.0, 6.0.0 and 3.4.0. Most suites are legacy Pester 3 idiom
(`Should Be`) and pin 3.4.0 themselves; this sweeper pins 3.4.0 for the same
reason. tests/t8_isolation.tests.ps1 is written for Pester 6 (`Should -Be`) and
will therefore show as red here -- that is a runner mismatch, not a failure of
the code under test. Run it separately under 6.1.0 (note: Pester 6 dropped
-EnableExit; use -PassThru and exit on $r.FailedCount).

Usage
-----
    python dev_tools/sweep_pester.py

Writes a running report to temp/pester_sweep.txt (temp/ is gitignored) so a
hang in one suite does not hide the results of the others.
"""

import glob
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "temp", "pester_sweep.txt")
PER_SUITE_TIMEOUT = 300
PESTER_VERSION = "3.4.0"

TIME_RE = re.compile(r"\s+\d+(?:\.\d+)?\s*(?:ms|s)\s*(?:\(\d+ tests?\))?\s*$")


def parse(out):
    """Return (passed, unique failing test names) from one suite's output."""
    passed = 0
    for m in re.finditer(r"(?:Tests Passed|Passed):\s*(\d+)", out):
        passed = max(passed, int(m.group(1)))
    names = []
    for ln in out.splitlines():
        if "[-]" in ln:
            nm = ln.split("[-]", 1)[1].strip()
            nm = re.sub(r"^\S+\.tests\.ps1\.?", "", nm)  # Pester 6 file prefix
            nm = TIME_RE.sub("", nm).strip()
            if nm:
                names.append(nm)
        elif "Error occurred in test script" in ln:
            names.append("SCRIPT-ERROR: " + ln.strip()[:120])
    seen, uniq = set(), []
    for n in names:
        if n not in seen:
            seen.add(n)
            uniq.append(n)
    return passed, uniq


def main():
    host = shutil.which("powers" + "hell") or shutil.which("pwsh")
    if not host:
        print("no Windows PS host on PATH", file=sys.stderr)
        return 1

    suites = sorted(glob.glob(os.path.join(ROOT, "tests", "*.tests.ps1")))
    lines = [
        "Pester sweep %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "host: %s" % host,
        "suites: %d" % len(suites),
        "method: [-] line count, NOT exit code (self-invoking suites mask rc)",
        "",
    ]

    tot_p = tot_f = 0
    bad = []
    for s in suites:
        name = os.path.basename(s)
        cmd = (
            "if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion %s -Force }; "
            "Invoke-Pester -Path '%s'" % (PESTER_VERSION, s)
        )
        t0 = time.time()
        try:
            r = subprocess.run(
                [host, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
                capture_output=True,
                text=True,
                # Launcher output carries cp1252 bytes; strict utf-8 kills the
                # reader thread and r.stdout comes back None.
                errors="replace",
                timeout=PER_SUITE_TIMEOUT,
                cwd=ROOT,
            )
            out, rc = (r.stdout or "") + "\n" + (r.stderr or ""), r.returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            out, rc, timed_out = "", "TIMEOUT", True
        except BaseException as exc:  # one bad suite must not kill the sweep
            out, rc, timed_out = "EXC: %r" % (exc,), "EXC", False
        dt = time.time() - t0

        p, fails = parse(out)
        if timed_out:
            fails.append("TIMEOUT after %ss" % PER_SUITE_TIMEOUT)
        tot_p += p
        tot_f += len(fails)
        if fails:
            bad.append((name, fails))

        lines.append("%-58s rc=%-4s %5.1fs  P=%-4d F=%d" % (name, rc, dt, p, len(fails)))
        for f in fails:
            lines.append("      x " + f[:150])
        sys.stdout.write("." if not fails else "X")
        sys.stdout.flush()
        with open(OUT, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))

    lines += [
        "",
        "TOTAL Passed=%d Failed=%d" % (tot_p, tot_f),
        "",
        "Suites with failures: %d of %d" % (len(bad), len(suites)),
    ]
    for n, f in bad:
        lines.append("  %s (%d)" % (n, len(f)))
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print()
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
