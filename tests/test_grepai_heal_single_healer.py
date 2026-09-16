"""Regression for VAD-v14z.3: dedupe overlapping grepai heal loops.

The thread-job supervisor and the pane-local Invoke-GrepaiHealthCheck both
cleared *.pid* locks and relaunched `grepai watch` with no mutex, causing
restart storms. Contract (parse-level, no processes spawned):

  1. Single healer: the pane heal must skip when the supervisor is alive
     (Test-SupervisorAlive gate precedes any pid-lock clear in the pane copy).
  2. Mutex-gated: BOTH heal paths must acquire the same named mutex
     (Global\\VAD_Grepai_Heal, non-blocking) before clearing *.pid* locks,
     so concurrent heals can never double-clear / double-relaunch.
  3. Wiring: the grepai pane must be generated with SupervisorLog/LaunchLog/
     LockFile paths (previously omitted, so the pane healed blind).

vad-uzb split note: the pane heal (Invoke-GrepaiHealthCheck) now lives in
Modules/watcher_pane_scripts.ps1, not the launcher. The supervisor heal stays in
the launcher. Each assertion below reads whichever file owns the symbol.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).parent.parent
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
PANE_MODULE = ROOT / "Modules" / "watcher_pane_scripts.ps1"

HEAL_MUTEX = "VAD_Grepai_Heal"
PID_PATTERN = "grepai-worktree-*.pid*"


def _read():
    assert LAUNCHER.exists(), "watcher launcher must exist"
    return LAUNCHER.read_text(encoding="utf-8")


def _read_pane_module():
    assert PANE_MODULE.exists(), "Modules/watcher_pane_scripts.ps1 must exist"
    return PANE_MODULE.read_text(encoding="utf-8")


def _pane_heal_body():
    src = _read_pane_module()
    idx = src.find("function Invoke-GrepaiHealthCheck")
    assert idx != -1, "pane-local Invoke-GrepaiHealthCheck missing from the pane module"
    return src[idx:]


def test_single_pane_heal_copy():
    # Exactly one healer function: adding a second heal loop must fail loudly.
    # The launcher must hold no inline copy now that the pane module owns it.
    assert _read().count("function Invoke-GrepaiHealthCheck") == 0, (
        "launcher must not embed an inline Invoke-GrepaiHealthCheck copy"
    )
    assert _read_pane_module().count("function Invoke-GrepaiHealthCheck") == 1, (
        "exactly one Invoke-GrepaiHealthCheck (the pane heal) is expected"
    )


def test_pane_heal_skips_when_supervisor_alive():
    body = _pane_heal_body()
    assert "Test-SupervisorAlive" in body, (
        "pane heal must gate on supervisor liveness (Test-SupervisorAlive)"
    )
    assert body.find("Test-SupervisorAlive") < body.find(PID_PATTERN), (
        "supervisor-liveness gate must precede any *.pid* lock clear"
    )


def test_both_healers_share_heal_mutex():
    launcher_src = _read()
    pane_src = _read_pane_module()
    assert launcher_src.count(HEAL_MUTEX) >= 1, (
        "thread-job supervisor heal must acquire the heal mutex"
    )
    assert pane_src.count(HEAL_MUTEX) >= 1, (
        "pane heal must acquire the heal mutex"
    )
    assert launcher_src.count("WaitOne(0)") >= 1, "supervisor mutex acquire must be non-blocking"
    assert pane_src.count("WaitOne(0)") >= 1, "pane mutex acquire must be non-blocking"


def test_no_unconditional_pid_clear_in_pane_heal():
    # Every *.pid* clear in the pane heal happens only after the single-healer
    # gate AND the mutex acquire (no concurrent clears with the supervisor).
    body = _pane_heal_body()
    first_clear = body.find(PID_PATTERN)
    assert first_clear != -1, "pane heal pid-clear block missing"
    gate = body.find("Test-SupervisorAlive")
    mutex = body.find(HEAL_MUTEX)
    assert 0 <= gate < first_clear, "liveness gate must come before pid clears"
    assert 0 <= mutex < first_clear, "mutex acquire must come before pid clears"


def test_grepai_pane_wired_with_heal_paths():
    src = _read()
    line = next(
        ln for ln in src.splitlines() if 'New-WatcherPaneScript -Label "grepai"' in ln
    )
    for flag in ("-SupervisorLog", "-LaunchLog", "-LaunchErr", "-LockFile"):
        assert flag in line, f"grepai pane generation must pass {flag} (healed blind without it)"


# --- VAD-7qf0: the gate must read the supervisor's OWN liveness stamp --------
# The old gate trusted the live launcher PID in the lock file. But the VAD-jmw
# idle-TTL reap RETURNS the supervisor while the launcher keeps running, so a
# live launcher PID does NOT mean a live supervisor: the pane skipped its only
# heal forever and stuck at "supervised restart pending". The supervisor now
# refreshes a <lockfile>.sup timestamp stamp every tick; the gate heals once
# that stamp goes stale (or is missing).

STAMP_SUFFIX = ".sup"


def _pane_function(name):
    src = _read_pane_module()
    m = re.search(r"function\s+" + re.escape(name) + r"\b", src)
    assert m, "function %s not found in the pane module" % name
    brace = src.find("{", m.end())
    assert brace != -1, "no opening brace for %s" % name
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return "function %s %s" % (name, src[brace:i + 1])
    raise AssertionError("unbalanced braces for %s" % name)


def _run_ps(script):
    # Trailing "exit 0": `pwsh -Command` reports exit 1 when the last command
    # leaves $? = $false (every script here ends on a probe with
    # -ErrorAction SilentlyContinue). A real break still aborts earlier.
    return subprocess.run(
        ["pwsh", "-NoProfile", "-NonInteractive", "-Command", script + "\nexit 0"],
        capture_output=True, text=True, timeout=120,
        creationflags=0x08000000,  # CREATE_NO_WINDOW
    )


def test_supervisor_gate_reads_own_liveness_stamp_not_launcher_pid():
    body = _pane_function("Test-SupervisorAlive")
    assert STAMP_SUFFIX in body, (
        "the single-healer gate must read the supervisor's own .sup liveness "
        "stamp, not the launcher PID in the lock file."
    )
    assert "LastWriteTime" in body, (
        "the gate must judge the stamp by freshness (LastWriteTime)."
    )
    assert "lockJson" not in body, (
        "the gate must NOT trust the launcher PID: the idle reap returns the "
        "supervisor while the launcher keeps running (VAD-7qf0)."
    )


def test_supervisor_gate_is_fresh_stamp_only():
    fn = _pane_function("Test-SupervisorAlive")
    res = _run_ps(r"""
%s
$dir = Join-Path $env:TEMP ('vad_7qf0_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $lock = Join-Path $dir 'launcher.lock'
    Set-Content -LiteralPath $lock -Value '{"Pid": 1}' -Encoding UTF8
    Write-Output ('MISSING_STAMP=' + (Test-SupervisorAlive -LockPath $lock))
    $stamp = Join-Path $dir 'launcher.sup'
    Set-Content -LiteralPath $stamp -Value 'x' -Encoding UTF8
    Write-Output ('FRESH_STAMP=' + (Test-SupervisorAlive -LockPath $lock))
    (Get-Item -LiteralPath $stamp).LastWriteTime = (Get-Date).AddSeconds(-300)
    Write-Output ('STALE_STAMP=' + (Test-SupervisorAlive -LockPath $lock))
    Write-Output ('EMPTY_PATH=' + (Test-SupervisorAlive -LockPath ''))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""" % fn)
    assert res.returncode == 0, (
        "pwsh exited %d\n%s\n%s" % (res.returncode, res.stdout, res.stderr)
    )
    out = res.stdout
    assert "MISSING_STAMP=False" in out, (
        "a supervisor with no stamp must read as gone so the pane can heal:\n%s" % out
    )
    assert "FRESH_STAMP=True" in out, (
        "a fresh stamp means the supervisor is the live healer (pane skips):\n%s" % out
    )
    assert "STALE_STAMP=False" in out, (
        "a stale stamp (supervisor exited/reaped) must read as gone so the pane "
        "heals instead of sticking at 'supervised restart pending':\n%s" % out
    )
    assert "EMPTY_PATH=False" in out, out


def test_supervisor_refreshes_the_liveness_stamp():
    src = _read()
    assert "ChangeExtension($LockFile, '.sup')" in src, (
        "the supervisor must derive the same <lockfile>.sup path the pane reads."
    )
    assert "Set-Content -LiteralPath $supStamp" in src, (
        "the supervisor must refresh its liveness stamp."
    )
    cooldown = src[src.index("backing off 10 minutes"):].split("$consecutiveRestarts = 0")[0]
    assert "Set-Content -LiteralPath $supStamp" in cooldown, (
        "the stamp must stay fresh through the 10-minute backoff cooldown, so a "
        "backed-off (still alive) supervisor is not mistaken for a dead one."
    )
