"""LIVE data round-trip test for the watcher launcher's teardown-state.json.

Proves the exact JSON the launcher persists -- {RootPids, MemtraceStatePath,
RepoRoot, WtWindowName, GrepaiPid} written with ConvertTo-Json -Compress to
$env:LOCALAPPDATA\\watchers\\teardown-state.json -- is produced, parseable,
and carries the repo root + tracked PIDs. We exercise the real writer shape via
tests/_write_teardown_state.ps1 (a faithful reproduction of the inline writer
in ###1, so no full launcher needs to run). No watchers are launched.

TabId was removed on 2026-08-11: wt (1.24) has no --tabIdFile / close-tab, so
no tab GUID is ever captured. GrepaiPid is required by
Modules/watcher_teardown.ps1 (lines ~110, 121, 183-189).
"""
import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent
HELPER = ROOT / "tests" / "_write_teardown_state.ps1"
REAL_STATE = Path(os.environ.get("LOCALAPPDATA", "")) / "watchers" / "teardown-state.json"


def _launcher_session_active() -> bool:
    """True when a real ###1 controller window is currently alive."""
    try:
        out = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "(Get-Process -ErrorAction SilentlyContinue | "
            "Where-Object { $_.MainWindowTitle -eq 'vadwatchers' -or $_.ProcessName -eq 'vadwatchers' }).Count"],
            capture_output=True, text=True, timeout=20,
            creationflags=0x08000000,  # CREATE_NO_WINDOW
        )
        return out.returncode == 0 and out.stdout.strip() not in ("", "0")
    except Exception:
        return False


@pytest.mark.skipif(_launcher_session_active(),
                    reason="a real ###1 launcher session is running")
def test_teardown_state_roundtrip_shape_and_keys():
    import sys
    dummy_pid = os.getpid()
    with tempfile.TemporaryDirectory() as td:
        out_path = os.path.join(td, "teardown-state.json")
        r = subprocess.run(
            ["pwsh.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(HELPER),
             "-RepoRoot", str(ROOT), "-DummyPid", str(dummy_pid), "-OutPath", out_path],
            capture_output=True, text=True,
            creationflags=0x08000000,  # CREATE_NO_WINDOW
        )
        assert r.returncode == 0, f"helper failed:\n{r.stderr}\n{r.stdout}"
        assert os.path.exists(out_path), "teardown-state.json was not written"

        raw = Path(out_path).read_text(encoding="utf-8")
        data = json.loads(raw)  # must be parseable JSON

        assert set(data.keys()) == {"RootPids", "MemtraceStatePath", "RepoRoot", "WtWindowName", "GrepaiPid"}, \
            f"unexpected keys: {set(data.keys())}"

        assert isinstance(data["RootPids"], list), "RootPids must be a list"
        assert data["RootPids"] == [dummy_pid], "RootPids must carry the tracked PID"

        expected = {
            "RootPids": [dummy_pid],
            "MemtraceStatePath": str(ROOT / ".memdb" / "daemon-state.json"),
            "RepoRoot": str(ROOT),
            "WtWindowName": "vadwatchers",
            "GrepaiPid": 0,
        }
        # Re-serialize both with sorted keys so PS hashtable key order is irrelevant;
        # this proves the launcher's persisted blob is byte-equivalent to the contract.
        python_equivalent = json.dumps(expected, indent=2, sort_keys=True, ensure_ascii=False)
        assert json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) == python_equivalent


@pytest.mark.skipif(not REAL_STATE.exists(),
                    reason="no live teardown-state.json present on this machine")
def test_real_teardown_state_file_has_contract_keys():
    # Windows PowerShell 5.1 Set-Content -Encoding UTF8 writes a BOM; the
    # launcher uses that cmdlet, so parse with utf-8-sig to tolerate it.
    data = json.loads(REAL_STATE.read_text(encoding="utf-8-sig"))
    assert set(data.keys()) == {"RootPids", "MemtraceStatePath", "RepoRoot", "WtWindowName", "GrepaiPid"}, \
        f"real state file missing contract keys: {set(data.keys())}"
    assert isinstance(data["RootPids"], list) and len(data["RootPids"]) >= 1
