"""
Regression test for double-click launch of the main controller launcher
(`###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`).

Like the grepai watcher launcher (###2), the controller must be
double-clickable from Windows Explorer. Double-clicking a .ps1 directly hits
Windows' Restricted execution policy and silently closes (the 2026-07-11
"window closes immediately on double-click" crash, fixed for the watchers by
adding .bat wrappers). This test pins the contract that a `###1.bat` wrapper
exists and bypasses the policy, so the controller is launchable by double-click
exactly like the watchers.

This is the structural half of the contract (mirrors the 'double-click wrapper'
block of tests/launch_watcher_for_grepai.tests.ps1, which covers
###2.required_for_launch_watcher_for_grepai.bat; that block replaced the deleted
tests/test_launch_watcher_standalone.py, see vad-1ku).
A behavioural "stays open" test is intentionally omitted here because ###1 is a
long-running controller that spawns the watcher stack + memtrace index on launch
(heavy, would stall the suite like the pre-existing launcher_tests.ps1 T8/T10-T13
stall). The structural wrapper guarantees double-click reaches the .ps1.
"""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
BAT = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.bat"


def test_controller_bat_wrapper_exists_and_bypasses_policy():
    """Double-click path: the .bat wrapper runs the .ps1 via pwsh (or
    powershell) with -ExecutionPolicy Bypass, so it executes even though .ps1
    has no reliable Explorer association and even under Restricted policy."""
    assert BAT.exists(), "A .bat wrapper must exist for double-click launch of the controller."
    body = BAT.read_text(encoding="utf-8")
    assert "-ExecutionPolicy Bypass" in body, "Wrapper must bypass execution policy."
    assert "-File" in body, "Wrapper must pass the .ps1 via -File."
    # Prefers pwsh.exe, falls back to powershell.exe (matches the ###2 wrapper).
    assert "pwsh.exe" in body
    assert "powershell.exe" in body
    # Must target the controller launcher by name.
    assert (
        "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1" in body
    ), "Wrapper must invoke the controller launcher script."


def test_controller_launcher_powershell_syntax_ok():
    """Parse the controller script with PowerShell's parser; no syntax errors."""
    result = subprocess.run(
        [
            "pwsh.exe", "-NoProfile", "-Command",
            f"$e=@();$t=$null;"
            f"[System.Management.Automation.Language.Parser]::ParseFile('{LAUNCHER}',[ref]$t,[ref]$e)"
            f" | Out-Null; if($e){{exit 1}}; exit 0",
        ],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"PowerShell syntax check failed: {result.stderr}"
