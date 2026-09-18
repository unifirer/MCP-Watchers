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

A suite with detailed output prints "[+] name 123ms" per test but its OUTER
Pester then summarises "Passed: 0" -- the inner summary is swallowed, so the
summary alone undercounts (launcher_proxy_wiring really passes 8). Count
de-duplicated [+] lines as well and take the max of the two sources. A suite
with default output prints no [+] at all but does print "Tests Passed: N", so
the summary is needed there too. Neither source alone is correct; both are
de-duplicated because the self-invocation runs every test twice.

Pester versions -- and why the sweeper mostly keeps its hands off
------------------------------------------------------------------
This box has 6.1.0, 6.0.0 and 3.4.0, and the suites target two generations:
legacy `Should Be` (Pester 3) and `Should -Be` (Pester 5+/6).

Pre-importing a version for EVERY suite is wrong, in both directions:
  * Pinning 3.4.0 reported tests/t8_isolation.tests.ps1 red all session on
    "'-Be' is not a valid Should operator" -- a runner mismatch, not a real
    failure.
  * Pinning 6.1.0 broke tests/launcher_equal_quarters.tests.ps1, which is
    green. That file opens with a bare `Import-Module Pester` (no version), so
    it loads the NEWEST Pester itself; preloading 6.1.0 -Force changes which
    copy's state the outer Invoke-Pester registers into, and 15 passing tests
    turn red. Measured: preload 3.4.0 -> 15 passed; preload 6.1.0 -> 15 failed.

So: 26 of the 35 suites self-invoke (`Invoke-Pester -Path $MyInvocation...`)
and import their own Pester. For those the sweeper just EXECUTES the file and
lets the suite decide. Only the 9 that do not self-invoke get an explicit
version, chosen the same way dev_tools/run_pester_suite.py does it -- sniff for
`Should -`, which is Pester 5+ only. Pester 6 dropped -EnableExit, so there the
exit code comes from -PassThru -> $r.FailedCount.

Usage
-----
    python dev_tools/sweep_pester.py

Writes a running report to temp/pester_sweep.txt (temp/ is gitignored) so a
hang in one suite does not hide the results of the others.
"""

import glob
import io
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "temp", "pester_sweep.txt")
PER_SUITE_TIMEOUT = 300
LEGACY = "3.4.0"
MODERN = "6.1.0"

TIME_RE = re.compile(r"\s+\d+(?:\.\d+)?\s*(?:ms|s)\s*(?:\(\d+ tests?\))?\s*$")


def detect_version(path):
    """Pick the Pester generation a suite is written for. `Should -` is 5+ only."""
    text = io.open(path, encoding="utf-8", errors="replace").read()
    return MODERN if re.search(r"Should\s+-", text) else LEGACY


def picks_own_pester(path):
    """True when the suite imports Pester itself, so it chooses the version.

    This -- not self-invocation -- is the discriminator. If the file imports
    Pester, leave it alone: tests/launcher_equal_quarters.tests.ps1 does a bare
    Import-Module Pester with no version, gets the newest, and is green, while
    forcing 6.1.0 from outside turns its 15 passes red. If it does NOT import
    Pester, the engine is whatever autoload picks (6.1.0), which is wrong for
    the legacy-idiom suites: tests/launcher_repowise_wiring.tests.ps1 uses
    'Should Match' / 'Should Not BeNullOrEmpty' and fails all 4 under 6.
    """
    text = io.open(path, encoding="utf-8", errors="replace").read()
    return "Import-Module Pester" in text


def build_cmd(suite, version):
    imp = "Import-Module Pester -RequiredVersion %s -Force" % version
    if version.startswith("3."):
        return "%s; Invoke-Pester -Path '%s' -EnableExit" % (imp, suite)
    # Pester 6 dropped -EnableExit.
    return "%s; $r = Invoke-Pester -Path '%s' -PassThru; exit $r.FailedCount" % (imp, suite)


def parse(out):
    """Return (passed, unique failing test names) from one suite's output.

    Passed comes from two sources, because a self-invoking suite hides one of
    them. Detailed output prints `[+] name 123ms` per test but the OUTER
    Pester then summarises "Passed: 0" -- the inner summary is swallowed.
    Default output prints no [+] at all but does print "Tests Passed: N".
    Take the max of both, and de-duplicate [+] names, because the
    self-invocation runs every test twice.
    """
    passed = 0
    for m in re.finditer(r"(?:Tests Passed|Passed):\s*(\d+)", out):
        passed = max(passed, int(m.group(1)))
    plus = []
    for ln in out.splitlines():
        if "[+]" in ln:
            nm = TIME_RE.sub("", ln.split("[+]", 1)[1].strip()).strip()
            if nm:
                plus.append(nm)
    plus = set(plus)
    if plus:
        passed = max(passed, len(plus))
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
        "note:   Passed = max(summary, unique [+] lines); both de-duplicated",
        "        because the self-invocation runs every test twice.",
        "",
    ]

    tot_p = tot_f = 0
    bad = []
    for s in suites:
        name = os.path.basename(s)
        if picks_own_pester(s):
            # Let the suite load its own Pester and run itself.
            version = 'file'
            cmd = "& '%s'" % s
        else:
            version = detect_version(s)
            cmd = build_cmd(s, version)
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

        lines.append("%-52s rc=%-4s %5.1fs v=%-6s P=%-4d F=%d" % (name, rc, dt, version, p, len(fails)))
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
