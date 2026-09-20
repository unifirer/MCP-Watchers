# Test conventions: tracked, marked, and honest about defects

Audience: anyone adding a test to `tests/`, and anyone fixing a defect that a
test currently pins. Two rules here are enforced by a guard, not by convention
alone — see "The guard" below.

## Rule 1 — a test file must be tracked

Every test file under `tests/` must be in the git index. A test that exists only
on disk cannot fail for anyone, so the defect it describes can be "fixed"
without the suite ever noticing, and the fix lands looking correct.

**The failure this rule comes from (bead mcpw-efu).** While landing mcpw-3si, a
test in `tests/launcher_grepai_idle_clock_reap.tests.ps1` was found untracked.
It pinned a *known-bad* behaviour and carried a comment saying so, plus
instructions to invert its assertion once the fix landed. Consequences:

* the committed suite never ran it, so nobody else saw the landmine;
* the correct fix presented itself as a test failure to whoever made it;
* the file had to be inverted by hand, outside any commit, during mcpw-3si.

If you are unsure whether a test file is tracked:

```bash
git ls-files tests/                      # what is in the index
git status --short tests/                # ?? = untracked, on disk only
git ls-files -o --exclude-standard -- tests
```

`git status --ignored` can be misleading here — `.gitignore` may hide a file
from the plain listing.

## Rule 2 — a characterization test must be marked

A **characterization test** encodes a *known-bad* behaviour as the expectation:
it asserts that the defect is still there, rather than asserting correct
behaviour. That is a legitimate, useful thing to write while a fix is in flight
— it documents the outage and gives you a target.

It is only safe if it announces itself. Put the marker in the test name:

```powershell
Describe 'grepai idle clock (mcpw-0k7)' {

    It 'does NOT reap a freshly spawned watcher [CHARACTERIZATION]' {
        # Reproduces the 2026-09-20 outage: 540 idle minutes measured against a
        # 20 minute TTL for a watcher that started seconds ago.
        # INVERT this assertion when mcpw-3si lands.
        $idle | Should -BeGreaterThan $ttl
    }
}
```

For pytest, put the same marker in the module docstring or in the test function
name.

**When the fix lands, invert the assertion — do not delete the test.** The
marker is what makes that instruction legible: the reader sees "this expectation
was deliberately wrong", not "an unrelated test broke". Once inverted, remove
the marker and say so in a comment, as
`tests/launcher_grepai_idle_clock_reap.tests.ps1` now does.

Rules for a marked test:

* it must be **tracked** (Rule 1) — a marked test nobody runs is the mcpw-3si
  failure mode;
* it must name the defect it pins, in the bead id or the comment;
* it must state what to do when the fix lands.

## The guard

`dev_tools/check_test_hygiene.py` enforces both rules and exits with the number
of violations (0 = clean), the same convention as
`dev_tools/run_pester_suite.py`.

```bash
python dev_tools/check_test_hygiene.py             # check the tree
python dev_tools/check_test_hygiene.py --self-test # check the detector itself
```

It is wired into the committed suite as `tests/test_test_hygiene.py`, so it runs
with pytest from `tests/`:

```bash
cd J:\audio\MCP-Watchers\tests
python -m pytest -c pytest.ini -q test_test_hygiene.py
```

It reports a file that is untracked, and a file that talks about pinning a
defect without the marker. The detector's sample strings live inside the tool,
not in `tests/` — a copy under `tests/` would make the tool flag its own test.

### The staging queue is a ratchet, not an allowlist

`PENDING_STAGING` in the tool lists test files that are known-untracked and
awaiting an explicit `git add`. This repo shares one git index between
concurrent agents (bead mcpw-gsj), so the tool cannot stage what it finds; it
reports instead.

* a new untracked test file is **never** excused — add it to the queue
  deliberately, or stage it;
* an entry that is now tracked is a **violation**, not a pass. Stage the file
  and prune the entry in the same change. The queue must drain to empty.

## Running the suites

Never trust a Pester exit code. Pester 6.0.0 dies during discovery yet exits 0,
and self-invoking suites report `Passed: 0` from the outer run. Count `[-]`
lines; pass = `max(summary, unique [+])`.

```bash
python dev_tools/run_pester_suite.py tests/<suite>.tests.ps1   # one suite
python dev_tools/sweep_pester.py                              # all of tests/
```

`run_pester_suite.py` imports `sweep_pester` — do not duplicate that parsing
logic. Both tools are the source of truth for a verdict.

`tests/launcher_tests.ps1` takes roughly 3m15s; do not run it casually.

Python tests run from the `tests` directory with the bare ini name:

```bash
cd J:\audio\MCP-Watchers\tests
python -m pytest -c pytest.ini -q
```

`-c tests/pytest.ini` double-resolves to `tests/tests/pytest.ini`. Which
interpreter has pytest is covered in `docs/guides/pytest-environment.md`.
