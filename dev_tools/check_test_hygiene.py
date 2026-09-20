#!/usr/bin/env python3
"""Guard test-directory hygiene: no untracked tests, no unmarked characterization tests.

The failure mode this pins (bead mcpw-efu, measured while landing mcpw-3si)
--------------------------------------------------------------------------
tests/launcher_grepai_idle_clock_reap.tests.ps1 held a test that encoded a
KNOWN-BAD behaviour -- 540 idle minutes measured against a 20 minute TTL for a
watcher that had started seconds earlier -- with a comment saying the assertion
had to be inverted once the fix landed. The file was UNTRACKED, so:

  * the committed suite never ran it, and
  * the correct fix (mcpw-3si) presented itself as a test failure to whoever
    made it, while everyone else still saw a green suite.

Two rules, both enforced here. They are written up in
docs/guides/test-conventions.md:

  1. Every test file under tests/ must be TRACKED by git. A test that is not in
     the index cannot fail for anyone, so the bug it describes can be "fixed"
     without the suite ever noticing.
  2. A test that encodes known-bad behaviour -- a CHARACTERIZATION test -- must
     carry the [CHARACTERIZATION] marker in its Describe/It name (Pester) or in
     its module docstring (pytest), so that landing the real fix reads as
     "invert this assertion" rather than "an unrelated test broke".

What "untracked" means here
---------------------------
Computed from git, not from a directory listing:
`git ls-files -o --exclude-standard` lists untracked files that are not
ignored. Ignored paths (__pycache__, .pytest_cache) are not test files and are
not reported.

The staging queue
-----------------
PENDING_STAGING below is a RATCHET, not an allowlist. This repo shares one git
index between concurrent agents, so this tool cannot stage the files it finds
(bead mcpw-gsj). The queue names the test files that are known-untracked and
waiting to be staged. It is a violation to leave an entry there once the file
IS tracked: prune the entry when you stage the file. A new untracked test file
is never excused.

Scope
-----
tests/ only, because that is where every test file in this repo lives: the
2026-09-20 repo-wide sweep for `*.tests.ps1` and `test_*.py` found no tracked or
untracked test file outside tests/. Scanning the whole tree would instead pick
up tool state that is generated, untracked and not a test -- .codegraph/,
.repowise/lancedb/, data/ -- so it is deliberately not done here.

Exit code is the number of violations (0 = clean), the same convention as
dev_tools/run_pester_suite.py, which returns its failed-test count.

Usage
-----
    python dev_tools/check_test_hygiene.py
    python dev_tools/check_test_hygiene.py --self-test
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS_REL = "tests"

# Ratchet: test files known-untracked and awaiting an explicit `git add`.
# Every entry here is a debt. Prune it as soon as the file is tracked.
# Empty as of 2026-09-21 (mcpw-9n1). The 2026-09-20 sweep (mcpw-efu) queued five
# files, but every one of them was already staged: four by 03fe566 (the commit
# that added this ratchet) and tests/launcher_memtrace_orphan_sweep.tests.ps1 by
# 1f6ffc7. The queue was never pruned, so check() reported all five as
# "now tracked -- prune it" and this gate returned 5 violations on every run
# since it landed. Prune an entry as soon as its file is staged; an empty queue
# is the healthy state. The tool still reports rather than stages (one shared
# index -- bead mcpw-gsj).
PENDING_STAGING = ()

# A test file is either a Pester suite or a pytest module.
TEST_FILE_RES = (
    re.compile(r"\.tests\.ps1$", re.I),
    re.compile(r"^test_.*\.py$", re.I),
)

MARKER = "[CHARACTERIZATION]"

# Phrases that mean "this file talks about pinning a bug". Kept tight on
# purpose: a bare mention of "characterization" in a docstring must NOT trip it,
# because the convention doc and this tool's own write-up do exactly that.
BUG_PHRASES = (
    ("characterization-assert",
     re.compile(r"characterization\s+(?:test\s+)?(?:that\s+|which\s+)?"
                r"(?:assert|pin|reproduc|encod|document)", re.I)),
    ("asserts-the-bug", re.compile(r"asserts?\s+(?:that\s+)?the\s+bug", re.I)),
    ("bug-is-present", re.compile(r"bug\s+is\s+present", re.I)),
    ("reproduces-the-bug",
     re.compile(r"reproduc\w*\s+the\s+(?:live\s+)?"
                r"(?:bug|outage|deadlock|crash|failure)", re.I)),
    ("known-bug", re.compile(r"known[- ]bug", re.I)),
    ("currently-broken",
     re.compile(r"currently\s+(?:broken|wrong|incorrect|fails)", re.I)),
    ("still-broken", re.compile(r"still\s+broken", re.I)),
    ("expected-to-fail", re.compile(r"expected\s+to\s+fail", re.I)),
    ("should-fail-until", re.compile(r"should\s+fail\s+until", re.I)),
)

# A file that says it has been inverted no longer encodes the bad behaviour;
# it is narrating history. Without this, the mcpw-3si file's own "inverted ...
# it reproduced the live outage" note reads as an unmarked characterization
# test. An inverted file is the GOOD end state, so it is exempt.
INVERTED_NOTE = re.compile(r"\binverted\b|\bno longer asserts\b", re.I)

# Describe/Context/It names, and pytest function names.
NAME_RE = re.compile(r"""^\s*(?:Describe|Context|It)\s+(['"])(?P<name>.*?)\1""",
                     re.M)
PYTEST_NAME_RE = re.compile(r"""^\s*def\s+(?P<name>test_\w+)""", re.M)


def is_test_file(name):
    """True when a basename is a test file this guard governs."""
    return any(r.search(name) for r in TEST_FILE_RES)


def find_bug_phrases(text):
    """Names of the bug-pinning phrases present in `text` (may be empty)."""
    return [label for label, rx in BUG_PHRASES if rx.search(text)]


def has_marker(text):
    """True when the [CHARACTERIZATION] marker sits in a test name or docstring."""
    if MARKER not in text:
        return False
    for m in NAME_RE.finditer(text):
        if MARKER in m.group("name"):
            return True
    for m in PYTEST_NAME_RE.finditer(text):
        if MARKER in m.group("name"):
            return True
    # Module docstring / marker comment (pytest has no Describe/It name).
    for line in text.splitlines():
        if MARKER in line and line.lstrip().startswith(("#", '"', "'")):
            return True
    return False


def scan_text(text):
    """Return the reasons `text` violates rule 2. Pure, so tests can call it."""
    if INVERTED_NOTE.search(text):
        return []
    phrases = find_bug_phrases(text)
    if not phrases:
        return []
    if has_marker(text):
        return []
    return ["unmarked characterization test (found %s, no %s marker)"
            % (", ".join(phrases), MARKER)]


def _git(*args):
    r = subprocess.run(("git",) + args, cwd=ROOT, capture_output=True,
                       text=True, errors="replace")
    if r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return [p for p in r.stdout.split("\0") if p]


def test_files_on_disk():
    """Relative posix paths of every test file under tests/, sorted."""
    found = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, TESTS_REL)):
        dirnames[:] = [d for d in dirnames
                       if d not in ("__pycache__", ".pytest_cache")]
        for fn in filenames:
            if is_test_file(fn):
                full = os.path.join(dirpath, fn)
                found.append(os.path.relpath(full, ROOT).replace(os.sep, "/"))
    return sorted(found)


def check():
    """Return (test files on disk, violation strings). Empty violations = clean."""
    # -z: NUL-separated, so a path with a space or a quote survives verbatim.
    tracked = set(_git("ls-files", "-z", "--", TESTS_REL))
    queued = set(PENDING_STAGING)

    violations = []
    files = test_files_on_disk()

    for rel in files:
        if rel in queued:
            if rel in tracked:
                violations.append(
                    "%s: PENDING_STAGING entry is now tracked -- prune it from "
                    "dev_tools/check_test_hygiene.py" % rel)
            continue
        if rel not in tracked:
            violations.append(
                "%s: untracked test file -- it cannot fail for anyone until it "
                "is staged (`git add %s`)" % (rel, rel))
        try:
            with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as exc:
            violations.append("%s: unreadable (%s)" % (rel, exc))
            continue
        for reason in scan_text(text):
            violations.append("%s: %s" % (rel, reason))

    for rel in sorted(queued - set(files)):
        violations.append("%s: PENDING_STAGING names a file that does not exist "
                          "-- remove the entry" % rel)

    return files, violations


def self_test():
    """Prove the detector fires on the bad shapes and stays quiet on the good ones.

    The samples live here rather than in tests/ on purpose: they contain the
    very phrases the scanner looks for, so a copy under tests/ would make this
    tool report its own test as an unmarked characterization test.
    """
    pinned = ("# a characterization test that pins the bug is present\n"
              "It 'does not reap a fresh watcher' { $idle | Should Be 540 }")
    marked = ("# [CHARACTERIZATION] -- invert this assertion when the fix lands\n"
              "It 'does not reap a fresh watcher [CHARACTERIZATION]' { $idle | Should Be 540 }")
    inverted = ("It 'does not reap a fresh watcher' { $idle | Should BeLessThan $ttl }\n"
                "# inverted: this used to reproduce the live outage")
    plain = "It 'adds two numbers' { (1 + 1) | Should Be 2 }"

    failures = []
    for label, text, want in (
        ("pinned-and-unmarked", pinned, 1),
        ("marked", marked, 0),
        ("inverted", inverted, 0),
        ("plain", plain, 0),
    ):
        got = scan_text(text)
        if want == 0 and got:
            failures.append("%s: expected no violation, got %r" % (label, got))
        if want == 1 and len(got) != 1:
            failures.append("%s: expected 1 violation, got %r" % (label, got))

    if has_marker(pinned) or not has_marker(marked):
        failures.append("has_marker disagreed with the samples")

    for f in failures:
        print("FAIL  self-test: " + f)
    if failures:
        return len(failures)
    print("OK    self-test: detector fires on the bad shapes, quiet on the good ones")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()

    try:
        files, violations = check()
    except RuntimeError as exc:
        print("cannot inspect git state: %s" % exc, file=sys.stderr)
        return 2

    for v in violations:
        print("FAIL  " + v)
    if violations:
        print("\ntest hygiene: %d violation(s) across %d test file(s)"
              % (len(violations), len(files)))
        return len(violations)

    print("OK    %d test file(s) tracked or queued; none pins a bug unmarked"
          % len(files))
    if PENDING_STAGING:
        print("      %d file(s) still in PENDING_STAGING -- stage them, then "
              "prune the queue" % len(PENDING_STAGING))
    return 0


if __name__ == "__main__":
    sys.exit(main())
