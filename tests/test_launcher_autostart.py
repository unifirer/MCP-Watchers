# tests/test_launcher_autostart.py — bead mcpw-anb
"""
:8787 (headroom proxy) must be LISTENING after a Windows restart with no
manual step, and the mechanism that starts it must be recorded in this repo.

SINGLE-OWNER DECISION (option A) — do not re-litigate without new evidence:

    The ###1 launcher is the ONE supervised starter for :8787. It is
    registered at launcher line ~5573 as
        Start-BackendSupervisor -Name 'headroom-proxy' -Port 8787 \
            -Health 'http://127.0.0.1:8787/livez'
    and it is the launcher -- not a second starter -- that is given the logon
    trigger.

Why A and not B (a standalone :8787 autostart entry), measured on 2026-09-24:

  * Every other port the launcher supervises has its standalone logon starter
    DISABLED on this box: `\\MCPAgentMail8765` (:8765), `\\ClaudeMCPServer8080`
    (:8080) and `\\GraphitiProxy8004` (:8004, retired) are all State=Disabled.
    The machine already encodes "launcher owns the port; the standalone
    starter is off".  Adding a standalone :8787 starter would be the only
    exception, and it is exactly the two-heal-loops-one-singleton shape that
    produced the memtrace flap and mcpw-ymo (9,657 mail relaunches).
  * B would additionally require deleting the working, acceptance-tested
    headroom-proxy supervisor added by mcpw-a5q, which also removes the
    mid-session heal (a proxy that dies at 15:00 stays dead).
  * Nothing else on this box autostarts the launcher: no HKCU/HKLM Run value,
    no Startup-folder shortcut, no scheduled task (the only \\MCPWatchers task
    is ClaudeSpawnWatch, a process tracer).  So "the launcher is running" was
    never a guarantee -- it was a manual double-click.

The acceptance therefore splits in two, and this file asserts both halves:

  1. the launcher owns :8787 (source-level, so nobody deletes the supervisor);
  2. the launcher itself is started at logon (machine-level, so :8787 comes
     back after a reboot).

The logon mechanism is a repo file -- an autostart .cmd beside the launcher --
so it is versioned and reviewable, not a registry-only change. The .cmd must
cd into the repo root: the launcher watches the CURRENT WORKING DIRECTORY
(README "Workspace root"), and a Run entry inherits an unpredictable cwd.
"""

import os
import pathlib
import re
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
BAT = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.bat"
# The logon entry point registered under HKCU\...\Run. Named after the launcher
# so it sits next to the thing it starts and is found by anyone reading ###1.*.
AUTOSTART_CMD = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.autostart.cmd"

# Registered by the mcpw-anb fix. Changing the name means re-registering it.
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE_NAME = "MCP-Watchers-Launcher"


def _read(p):
    return p.read_text(encoding="utf-8", errors="ignore")


# --------------------------------------------------------------------------
# 1. the launcher is the supervised owner of :8787
# --------------------------------------------------------------------------

def test_launcher_supervises_headroom_proxy_on_8787():
    """:8787 has exactly one supervised starter and it lives in the launcher."""
    src = _read(LAUNCHER)
    assert re.search(
        r"Start-BackendSupervisor\s+-Name\s+'headroom-proxy'\s+-Port\s+8787", src
    ), ("the launcher no longer registers the headroom-proxy supervisor for "
        ":8787 -- nothing would start or heal the proxy")


def test_headroom_proxy_supervisor_has_a_start_backend():
    """Registration alone is not enough; the dispatch must reach a starter."""
    src = _read(LAUNCHER)
    assert "Start-HeadroomProxyBackend" in src, \
        "no Start-HeadroomProxyBackend: a dead :8787 could never be relaunched"


def test_single_owner_invariant_names_headroom_proxy():
    """The invariant comment is what stops the next agent adding a 2nd starter."""
    lines = _read(LAUNCHER).splitlines()
    start = next((i for i, line in enumerate(lines)
                  if "SINGLE-OWNER INVARIANT" in line), None)
    assert start is not None, "the SINGLE-OWNER INVARIANT comment block is gone"
    # The block is the marker plus every contiguous comment line after it.
    block = []
    for line in lines[start:start + 30]:
        if not line.lstrip().startswith("#"):
            break
        block.append(line)
    text = "\n".join(block)
    assert "headroom-proxy" in text and "8787" in text, \
        "the single-owner invariant no longer names headroom-proxy :8787"


# --------------------------------------------------------------------------
# 2. the launcher itself is started at logon -- recorded AND registered
# --------------------------------------------------------------------------

def test_autostart_decision_is_recorded_in_the_launcher():
    """The launcher must name its own logon starter, so the mechanism survives
    in the repo and not only in the registry."""
    src = _read(LAUNCHER)
    assert AUTOSTART_CMD.name in src, (
        "the launcher does not mention %s -- a reader cannot tell what starts "
        "the launcher after a reboot" % AUTOSTART_CMD.name
    )
    assert "mcpw-anb" in src, "the launcher comment must cite the bead"


def test_autostart_cmd_exists_and_sets_the_workspace_root():
    """The logon entry point must pin the cwd: the launcher watches the current
    working directory, and a Run entry inherits an unpredictable one."""
    assert AUTOSTART_CMD.exists(), \
        "missing logon entry point: %s" % AUTOSTART_CMD.name
    body = _read(AUTOSTART_CMD)
    assert re.search(r'(?i)\bcd\s+/d\s+"?%~dp0', body), \
        "the autostart .cmd must cd /d into the repo root (launcher watches cwd)"
    assert BAT.name in body, \
        "the autostart .cmd must go through the existing .bat wrapper"


@pytest.mark.skipif(sys.platform != "win32", reason="HKCU Run is Windows-only")
def test_hkcu_run_entry_registered_for_the_launcher():
    """Machine-level half of the acceptance: the logon trigger is actually
    registered, and it points at the repo's autostart script."""
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            value, _ = winreg.QueryValueEx(key, RUN_VALUE_NAME)
    except FileNotFoundError:
        pytest.fail(
            "HKCU\\%s has no %r value -- nothing starts the launcher at logon, "
            "so :8787 stays down after a reboot" % (RUN_KEY, RUN_VALUE_NAME)
        )
    assert AUTOSTART_CMD.name.lower() in value.lower(), (
        "HKCU Run %r points at %r, not at the repo autostart script"
        % (RUN_VALUE_NAME, value)
    )
    assert os.path.exists(value), \
        "registered autostart script does not exist: %s" % value


@pytest.mark.skipif(sys.platform != "win32", reason="HKCU Run is Windows-only")
def test_no_second_starter_registered_for_the_proxy_itself():
    """Option B guard: the proxy must not have its own Run entry, or :8787 has
    two starters (the mcpw-ymo / memtrace-flap shape)."""
    import winreg

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
        names = []
        i = 0
        while True:
            try:
                names.append(winreg.EnumValue(key, i)[0])
            except OSError:
                break
            i += 1
    offenders = [n for n in names
                 if ("headroom" in n.lower() or "8787" in n)
                 and n != RUN_VALUE_NAME]
    assert not offenders, (
        "a second autostart entry owns the headroom proxy (%s) while the "
        "launcher supervises :8787 -- two starters for one singleton"
        % ", ".join(offenders)
    )
