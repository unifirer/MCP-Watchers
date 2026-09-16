# tests/test_launcher_gm_popup_state.py
# Regression lock for beads VAD-ygdo.8:
# Invoke-GmSemanticBuild guards the semantic-build-unavailable popup with $State.
# The only production call site lives inside the thread-job scriptblock whose
# $global: scope is isolated, so omitting -State leaves the default
# $global:gmSemState as $null and the branch is unreachable.
# This file pins the fix: the job forwards the shared $State explicitly,
# and the once-per-session PopupShown gate stays intact.
import pathlib
import re

LAUNCHER = pathlib.Path(__file__).resolve().parents[1] / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"


def _read():
    return LAUNCHER.read_text(encoding="utf-8", errors="ignore")


def test_state_param_defaults_to_global():
    src = _read()
    m = re.search(
        r"function Invoke-GmSemanticBuild\s*\{.*?param\((.*?)\)",
        src,
        re.DOTALL,
    )
    assert m, "Invoke-GmSemanticBuild param block not found"
    params = m.group(1)
    assert re.search(r"\$State\s*=\s*\$global:gmSemState", params), (
        "Invoke-GmSemanticBuild must define [object]$State = $global:gmSemState"
    )


def test_popup_gate_checks_state_once_per_session():
    src = _read()
    assert "if ($State -and -not $State.PopupShown)" in src, (
        "popup gate must check $State and $State.PopupShown"
    )
    assert "$State.PopupShown = $true" in src, (
        "popup gate must set PopupShown so it fires at most once per session"
    )


def test_global_state_defines_popupshown():
    src = _read()
    m = re.search(r"\$global:gmSemState\s*=\s*@\{(.*?)\}", src, re.DOTALL)
    assert m, "$global:gmSemState definition not found"
    body = m.group(1)
    assert re.search(r"PopupShown\s*=\s*\$false", body), (
        "$global:gmSemState must define PopupShown = $false"
    )


def test_thread_job_forwards_state_to_build():
    # VAD-ygdo.8 root cause: the job scriptblock called
    # Invoke-GmSemanticBuild without -State, so the default evaluated to
    # $null in the isolated runspace. It must forward the shared $State.
    src = _read()
    # Only real invocations: line starts (after whitespace) with the command
    # name followed by arguments. Excludes comments, function definition,
    # Set-Item rebuild, and .ToString() argument plumbing.
    calls = [
        line.strip()
        for line in src.splitlines()
        if re.match(r"^Invoke-GmSemanticBuild\s+-", line.strip())
    ]
    assert calls, "no Invoke-GmSemanticBuild invocation found"
    forwarded = [c for c in calls if re.search(r"-State\s+\$State\b", c)]
    assert forwarded, (
        "thread-job must call Invoke-GmSemanticBuild with -State $State; "
        "got: %r" % (calls,)
    )
    bare = [c for c in calls if "-State" not in c]
    assert not bare, (
        "all Invoke-GmSemanticBuild calls must pass -State explicitly; "
        "bare calls: %r" % (bare,)
    )
