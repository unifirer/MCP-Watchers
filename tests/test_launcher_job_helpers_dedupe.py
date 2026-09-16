"""Static guards for bead VAD-v14z.5 (vad-0si): dedupe the launcher's job-scope helpers.

The ###1 watcher launcher used to copy-paste Clear-StaleLocks / Limit-LogSize /
Test-LauncherAlive into the parent scope AND into every Start-ThreadJob /
Start-Job scriptblock, because a job gets a FRESH runspace that inherits neither
the launcher's functions nor its script-scope variables. The helpers now live
once in Modules/watcher_job_helpers.ps1 and each job dot-sources that file from
a literal path passed via -ArgumentList.

These tests read source only; they spawn no processes. Companion gates:
tests/test_launcher_watchers_contract.py (pwsh AST parse) and tests/launcher_tests.ps1
(T22 pins the shared-module Clear-StaleLocks dot-source, T10e pins the gob-repair block) plus
tests/test_launcher_worktree_quoting.py (pins the liveness helper in the shared module).

vad-sef adds the four litellm supervisor helpers to the same module (Test-LitellmConfig
vad-yrx, Get-LitellmBackoffDelay vad-0m6, Stop-PriorLitellmProxy vad-olv,
Backup-LitellmStderr vad-gfn). The static guards below pin their singular definition
and the litellm supervisor dot-source/call sites; the behavior tests at the bottom
EXECUTE each helper in a fresh pwsh that dot-sources the module from its literal path,
the same way the supervisor runspace does.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).parent.parent
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
JOB_HELPERS = ROOT / "Modules" / "watcher_job_helpers.ps1"

# Vad-sef: added to the shared module by the 2026-09-13 litellm commits. Each must
# stay defined exactly once here and be reached from the litellm supervisor runspace.
LITELLM_SUPERVISOR_HELPERS = (
    "Test-LitellmConfig",
    "Get-LitellmBackoffDelay",
    "Stop-PriorLitellmProxy",
    "Backup-LitellmStderr",
)
# Vad-jmw (2026-09-15): grepai idle TTL. grepai exposes no idle timeout of its own,
# so the launcher's grepai supervisor reaps the watcher once its index has been idle
# for the TTL and then returns. The three helpers must stay singular in the shared
# module and be reached from that supervisor runspace.
GREPAI_IDLE_HELPERS = (
    "Test-GrepaiActivityLine",
    "Get-GrepaiIdleMinutes",
    "Get-GrepaiIdleMinutesFromConfig",
    "Get-GrepaiIdleMinutesFromLog",
    "Get-GrepaiWatchStartTime",
    "Get-GrepaiIdleTimeoutMinutes",
)
# Now defined ONLY in the shared module; every launcher copy became a dot-source.
MODULE_ONLY_HELPERS = (
    "Limit-LogSize",
    "Clear-StaleLocks",
    "Test-LauncherAlive",
) + LITELLM_SUPERVISOR_HELPERS + GREPAI_IDLE_HELPERS
# No pinned inline helper copies remain (vad-0si): T22 and the worktree-quoting
# heal test pin the canonical bodies in the shared module, and each supervisor
# block dot-sources $JobHelpersModule for the fresh-runspace scope rule.
PINNED_HELPERS = ()
# The supervisor's corrupt-gob repair stays inline (T10e pins its begin/end markers).
PINNED_GOB_FN = "Repair-CorruptGobIndex"

JOB_SCRIPTBLOCKS = (
    "$supervisorScript = {",
    "$litellmSupervisorScript = {",
    "$memtraceHealScript = {",
)


def _read(path):
    return path.read_text(encoding="utf-8")


def _defs(src, name):
    return len(re.findall(r"function\s+" + re.escape(name) + r"\b", src))


def _extract_function_body(src, name):
    m = re.search(r"function\s+" + re.escape(name) + r"\b", src)
    assert m, "function %s not found" % name
    brace = src.find("{", m.end())
    assert brace != -1, "no opening brace for %s" % name
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[brace:i + 1]
    raise AssertionError("unbalanced braces for %s" % name)


def _normalize_ws(body):
    return re.sub(r"\s+", " ", body).strip()


def _scriptblock_regions(src):
    out = {}
    for marker in JOB_SCRIPTBLOCKS:
        start = src.find(marker)
        assert start != -1, "job scriptblock %r not found" % marker
        m = re.search(r"Start-(?:ThreadJob|Job)\s+-ScriptBlock", src[start:])
        assert m, "no Start-ThreadJob/Start-Job invocation after %r" % marker
        out[marker] = src[start:start + m.start()]
    return out


def test_module_exists():
    assert JOB_HELPERS.exists(), "Modules/watcher_job_helpers.ps1 must exist."


def test_module_parses():
    assert JOB_HELPERS.exists(), "Modules/watcher_job_helpers.ps1 must exist."
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-Command",
         "$e=@(); [void][System.Management.Automation.Language.Parser]::ParseFile('%s', [ref]$null, [ref]$e); "
         "if($e){$e | ForEach-Object { $_.Message }; exit 1}; exit 0" % JOB_HELPERS],
        capture_output=True, text=True,
        creationflags=0x08000000,  # CREATE_NO_WINDOW
    )
    assert result.returncode == 0, (
        "watcher_job_helpers.ps1 parse failed:\n%s\n%s" % (result.stdout, result.stderr)
    )


def test_module_defines_each_helper_exactly_once():
    src = _read(JOB_HELPERS)
    for name in MODULE_ONLY_HELPERS + PINNED_HELPERS:
        assert _defs(src, name) == 1, (
            "%s must be defined exactly once in the shared module; found %d."
            % (name, _defs(src, name))
        )


def test_module_does_not_duplicate_the_pinned_gob_repair():
    src = _read(JOB_HELPERS)
    assert _defs(src, PINNED_GOB_FN) == 0, (
        "the corrupt-gob repair stays inline in the launcher (T10e pin); the "
        "shared module must not define a second copy."
    )


def test_launcher_has_no_duplicate_helper_definitions():
    src = _read(LAUNCHER)
    for name in MODULE_ONLY_HELPERS:
        assert _defs(src, name) == 0, (
            "%s must be fully replaced by the shared module dot-source; the "
            "launcher still defines it %d time(s)." % (name, _defs(src, name))
        )
    for name in PINNED_HELPERS:
        assert _defs(src, name) == 1, (
            "%s must have exactly one inline definition left (the pinned grepai "
            "supervisor copy); found %d." % (name, _defs(src, name))
        )
    assert _defs(src, PINNED_GOB_FN) == 1, (
        "exactly one inline %s expected; found %d." % (PINNED_GOB_FN, _defs(src, PINNED_GOB_FN))
    )
    # The old parent-scope copies must be gone (not merely shadowed).
    assert "\nfunction Clear-StaleLocks {" not in src, (
        "the parent-scope Clear-StaleLocks copy is still present."
    )
    assert "\nfunction Limit-LogSize {" not in src, (
        "a top-level Limit-LogSize copy is still present."
    )
    assert "\nfunction Test-LauncherAlive {" not in src, (
        "a top-level Test-LauncherAlive copy is still present."
    )


def test_shared_module_bodies_cover_the_supervisor_needs():
    # No inline copies remain (vad-0si), so pin the canonical bodies directly:
    # the stale-lock patterns, the PID-reuse guards, and the heal-path error
    # surfacing that the 2026-08-26 crash loop and the heal-logging gate need.
    module_src = _read(JOB_HELPERS)
    assert "grepai-worktree-*.pid*" in module_src, (
        "shared Clear-StaleLocks must target the stale worktree pid locks."
    )
    assert "grepai-stop-*" in module_src, (
        "shared Clear-StaleLocks must target the grepai-stop markers."
    )
    liveness_body = _normalize_ws(_extract_function_body(module_src, "Test-LauncherAlive"))
    assert "StartedAt" in liveness_body, (
        "shared Test-LauncherAlive must keep the StartedAt PID-reuse guard."
    )
    assert "Launcher" in liveness_body, (
        "shared Test-LauncherAlive must keep the Launcher token guard."
    )
    assert "$_.Exception.Message" in module_src, (
        "shared Test-LauncherAlive must surface heal-path errors, not swallow them."
    )


def test_every_job_scriptblock_dot_sources_the_shared_module():
    regions = _scriptblock_regions(_read(LAUNCHER))
    for marker, region in regions.items():
        assert ". $JobHelpersModule" in region, (
            "%s must dot-source $JobHelpersModule (a fresh job runspace inherits "
            "neither the launcher's functions nor its variables)." % marker
        )
        for name in MODULE_ONLY_HELPERS:
            assert not re.search(r"function\s+" + re.escape(name) + r"\b", region), (
                "%s still embeds the %s body instead of dot-sourcing it." % (marker, name)
            )


def test_launcher_resolves_module_with_portable_candidate_list():
    src = _read(LAUNCHER)
    assert "$jobHelpersModule = $null" in src, "module-path variable not initialised."
    assert r"Join-Path $PSScriptRoot 'Modules\watcher_job_helpers.ps1'" in src, (
        "module must be probed relative to $PSScriptRoot."
    )
    assert r"Join-Path $env:VAD_WORKSPACE_ROOT 'Modules\watcher_job_helpers.ps1'" in src, (
        "module must keep an env-derived fallback candidate."
    )
    assert ". $jobHelpersModule" in src, "the parent scope must dot-source the module."


def test_job_spawns_pass_the_literal_module_path():
    src = _read(LAUNCHER)
    expected = (
        "supervisorScript",
        "litellmSupervisorScript",
        "memtraceHealScript",
    )
    spawns = re.findall(r"Start-(?:ThreadJob|Job)\s+-ScriptBlock\s+\$(\w+)", src)
    ours = [v for v in spawns if v in expected]
    assert len(ours) == 6, (
        "expected 6 supervisor spawns (2 per job: Start-ThreadJob + Start-Job); "
        "found %d." % len(ours)
    )
    for var in expected:
        pattern = (
            r"Start-(?:ThreadJob|Job)\s+-ScriptBlock\s+\$" + var
            + r"[\s\S]{0,160}?-ArgumentList([^\r\n]*)"
        )
        for m in re.finditer(pattern, src):
            assert m.group(1).rstrip().endswith("$jobHelpersModule"), (
                "job spawn must pass $jobHelpersModule through -ArgumentList: %s"
                % m.group(1).strip()
            )


def test_litellm_supervisor_dot_sources_and_calls_the_four_helpers():
    # vad-sef: the supervisor runspace reaches the four litellm helpers ONLY
    # through the shared-module dot-source. A dropped dot-source or a dropped
    # call silently reverts the runspace to "term not recognized" behaviour, so
    # pin both halves: the dot-source and one call site per helper.
    region = _scriptblock_regions(_read(LAUNCHER))["$litellmSupervisorScript = {"]
    assert ". $JobHelpersModule" in region, (
        "the litellm supervisor runspace must dot-source the shared module."
    )
    for name in LITELLM_SUPERVISOR_HELPERS:
        assert re.search(r"\b" + re.escape(name) + r"\s+-", region), (
            "%s is no longer called from the litellm supervisor runspace." % name
        )


# --- vad-sef: behavior pins for the four litellm supervisor helpers -----------
# Each helper is EXECUTED (not grepped) in a fresh pwsh that dot-sources the
# shared module from its literal path - exactly how the litellm supervisor
# runspace gets it. Hermetic: no network, no port bind, no litellm spawn. The
# only process work is a throwaway pwsh Start-Sleep stub that the reap test
# genuinely kills, plus an immediately-exiting stub that stands in for an
# already-dead PID.


def _run_ps(script):
    # The trailing "exit 0" is required: `pwsh -Command` reports exit 1 whenever
    # the LAST command leaves $? = $false, and every script here ends on a
    # Get-Process / Remove-Item probe with -ErrorAction SilentlyContinue. A real
    # break (parse failure, terminating error, CommandNotFound) still aborts
    # before this line, so _no_throw keeps its teeth.
    return subprocess.run(
        ["pwsh", "-NoProfile", "-NonInteractive", "-Command",
         script.replace("__MODULE__", str(JOB_HELPERS)) + "\nexit 0"],
        capture_output=True, text=True, timeout=120,
        creationflags=0x08000000,  # CREATE_NO_WINDOW
    )


def _no_throw(res, label):
    assert res.returncode == 0, (
        "%s: pwsh exited %d\n%s\n%s" % (label, res.returncode, res.stdout, res.stderr)
    )


def test_litellm_config_rejects_non_ascii_api_key():
    # vad-yrx: a non-ASCII placeholder in an api_key aborts litellm before bind.
    # Pin $false plus the file:line the operator has to fix.
    res = _run_ps(r"""
$ErrorActionPreference = 'Continue'
. '__MODULE__'
$dir = Join-Path $env:TEMP ('vad_sef_cfg_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $cfg = Join-Path $dir 'litellm_config.yaml'
    $placeholder = [char]0x00AB
    Set-Content -LiteralPath $cfg -Encoding UTF8 -Value @(
        'model_list:',
        '  - model_name: muse',
        '    litellm_params:',
        ('      api_key: sk-' + $placeholder + '-REPLACE-ME')
    )
    Write-Output ('NONASCII_RESULT=' + (Test-LitellmConfig -ConfigPath $cfg))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""")
    _no_throw(res, "non-ASCII config")
    combined = res.stdout + res.stderr
    assert "NONASCII_RESULT=False" in res.stdout, combined
    assert "litellm_config.yaml:4" in combined, (
        "the preflight must name file:line of the offending char:\n%s" % combined
    )
    assert "U+00AB" in combined, (
        "the preflight must name the offending code point:\n%s" % combined
    )


def test_litellm_config_accepts_ascii_config():
    res = _run_ps(r"""
$ErrorActionPreference = 'Continue'
. '__MODULE__'
$dir = Join-Path $env:TEMP ('vad_sef_cfg_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $cfg = Join-Path $dir 'litellm_config.yaml'
    Set-Content -LiteralPath $cfg -Encoding UTF8 -Value @(
        'model_list:',
        '  - model_name: muse',
        '    litellm_params:',
        '      model: openai/muse',
        '      api_key: sk-REPLACE-ME'
    )
    Write-Output ('ASCII_RESULT=' + (Test-LitellmConfig -ConfigPath $cfg))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""")
    _no_throw(res, "ASCII config")
    assert "ASCII_RESULT=True" in res.stdout, res.stdout + res.stderr


def test_litellm_backoff_curve_is_exponential_and_capped():
    # vad-0m6: base 10s doubling per consecutive failure, ceiling 300s.
    res = _run_ps(r"""
. '__MODULE__'
$curve = 1..7 | ForEach-Object { Get-LitellmBackoffDelay -ConsecutiveFailures $_ }
Write-Output ('CURVE=' + ($curve -join ','))
Write-Output ('FORTY=' + (Get-LitellmBackoffDelay -ConsecutiveFailures 40))
Write-Output ('ZERO=' + (Get-LitellmBackoffDelay -ConsecutiveFailures 0))
""")
    _no_throw(res, "backoff curve")
    assert "CURVE=10,20,40,80,160,300,300" in res.stdout, res.stdout + res.stderr
    assert "FORTY=300" in res.stdout, "the 300s cap must hold for any failure count"
    assert "ZERO=10" in res.stdout, "0/1 failures must return the base delay"


def test_stop_prior_litellm_proxy_reaps_only_live_pids():
    # vad-olv: <=0 and already-dead PIDs return $false without throwing (the
    # supervisor calls this on every dead-path relaunch); a live PID is killed
    # for real and returns $true, otherwise :4000 keeps two litellm contenders.
    # The reaper stays PID-only by design - deciding WHICH PID to hand it is
    # Get-LitellmProxyRelaunchPlan's job, not this helper's.
    res = _run_ps(r"""
$ErrorActionPreference = 'Continue'
. '__MODULE__'
Write-Output ('ZERO=' + (Stop-PriorLitellmProxy -PriorPid 0))
Write-Output ('NEG=' + (Stop-PriorLitellmProxy -PriorPid -7))

$exe = (Get-Process -Id $PID).Path
$dead = Start-Process -FilePath $exe -ArgumentList '-NoProfile','-Command','exit' -PassThru -WindowStyle Hidden
$dead.WaitForExit()
$deadPid = $dead.Id
Write-Output ('DEAD_GONE=' + ($null -eq (Get-Process -Id $deadPid -ErrorAction SilentlyContinue)))
Write-Output ('DEAD=' + (Stop-PriorLitellmProxy -PriorPid $deadPid))

$live = Start-Process -FilePath $exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 400
$livePid = $live.Id
Write-Output ('LIVE=' + (Stop-PriorLitellmProxy -PriorPid $livePid))
Write-Output ('LIVE_GONE=' + ($null -eq (Get-Process -Id $livePid -ErrorAction SilentlyContinue)))
$left = Get-Process -Id $livePid -ErrorAction SilentlyContinue
if ($left) { Stop-Process -Id $livePid -Force -ErrorAction SilentlyContinue }
""")
    _no_throw(res, "prior-PID reap")
    out = res.stdout
    assert "ZERO=False" in out, out
    assert "NEG=False" in out, out
    assert "DEAD_GONE=True" in out, "the dead-PID fixture did not exit cleanly:\n%s" % out
    assert "DEAD=False" in out, out
    assert "LIVE=True" in out, out
    assert "LIVE_GONE=True" in out, "the helper returned $true without killing:\n%s" % out


def test_backup_litellm_stderr_appends_timestamped_generation():
    # vad-gfn: Start-Process -RedirectStandardError overwrites $Log.err on every
    # respawn, so the crash text must be copied to $Log.err.history FIRST.
    res = _run_ps(r"""
$ErrorActionPreference = 'Continue'
. '__MODULE__'
$dir = Join-Path $env:TEMP ('vad_sef_err_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $log = Join-Path $dir 'litellm-proxy.log'
    $err = "$log.err"
    Set-Content -LiteralPath $err -Encoding UTF8 -Value 'boom: UnicodeEncodeError charmap'
    Backup-LitellmStderr -LogPath $log
    $hist = "$log.err.history"
    Write-Output ('HIST_EXISTS=' + (Test-Path -LiteralPath $hist))
    $txt = Get-Content -LiteralPath $hist -Raw
    Write-Output ('HAS_HEADER=' + ($txt -match '===== \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} preserving '))
    Write-Output ('HAS_PAYLOAD=' + ($txt -match 'UnicodeEncodeError charmap'))
    Write-Output ('ERR_KEPT=' + (Test-Path -LiteralPath $err))
    Write-Output ('HEADERS=' + ([regex]::Matches($txt, '===== ').Count))
    Backup-LitellmStderr -LogPath $log
    $txt2 = Get-Content -LiteralPath $hist -Raw
    Write-Output ('HEADERS2=' + ([regex]::Matches($txt2, '===== ').Count))
    $never = Join-Path $dir 'never-started.log'
    Backup-LitellmStderr -LogPath $never
    Write-Output ('NOOP_HIST=' + (Test-Path -LiteralPath "$never.err.history"))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""")
    _no_throw(res, "stderr backup")
    out = res.stdout
    assert "HIST_EXISTS=True" in out, out
    assert "HAS_HEADER=True" in out, "history needs a timestamp header:\n%s" % out
    assert "HAS_PAYLOAD=True" in out, "history must carry the crash text:\n%s" % out
    assert "ERR_KEPT=True" in out, "the live .err must be preserved for the spawn:\n%s" % out
    assert "HEADERS=1" in out, out
    assert "HEADERS2=2" in out, "a second backup must append, not replace:\n%s" % out
    assert "NOOP_HIST=False" in out, "an absent .err must not create history:\n%s" % out


# --- vad-jmw: grepai idle TTL -------------------------------------------------
# grepai exposes no idle timeout of its own (`grepai watch --help` lists none), so
# the long-running watch daemon held the embedding model (~1.9 GB measured on this
# repo, two copies alive 2h+ after the last index write) until the launcher's
# supervisor reaped it. The reap must RETURN, not fall into the crash-restart path.


def test_grepai_supervisor_arms_the_idle_ttl():
    region = _scriptblock_regions(_read(LAUNCHER))["$supervisorScript = {"]
    assert "Get-GrepaiIdleTimeoutMinutes" in region, (
        "the grepai supervisor must read the idle TTL (0 disables it)."
    )
    assert "Get-GrepaiIdleMinutes" in region, (
        "the grepai supervisor must measure the idle age before it reaps."
    )
    assert "idle_timeout_minutes" in region, (
        "the operator knob must be documented at the arming site."
    )


def test_grepai_supervisor_reaps_on_idle_and_never_relaunches():
    region = _scriptblock_regions(_read(LAUNCHER))["$supervisorScript = {"]
    assert re.search(r"if \(\$idleMin -ge \$idleTtlMin\)", region), (
        "the reap must be gated on the measured idle age reaching the TTL."
    )
    assert "Invoke-CimMethod" in region and "Terminate" in region, (
        "the idle reap must terminate the watch daemon (CimInstance has no "
        ".Terminate() method on this host)."
    )
    assert region.index("grepai idle TTL reached") > region.index(
        "grepai watch exited - restarting in 1s"
    ), (
        "the idle reap belongs to the LIVE branch, after the crash-restart path "
        "- an idle watcher must not be counted as an unexpected death."
    )
    reap = region.index("grepai idle TTL reached")
    assert "return" in region[reap:], (
        "the idle reap must RETURN (ending the supervisor) so no relaunch "
        "follows - that relaunch loop is vad-jmw."
    )


def test_grepai_idle_timeout_minutes_reads_config_and_defaults():
    res = _run_ps(r"""
. '__MODULE__'
$dir = Join-Path $env:TEMP ('vad_jmw_cfg_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $cfg = Join-Path $dir 'config.yaml'
    Set-Content -LiteralPath $cfg -Encoding UTF8 -Value @(
        'version: 1',
        'watch:',
        '    debounce_ms: 500',
        '    idle_timeout_minutes: 7'
    )
    Write-Output ('CONFIGURED=' + (Get-GrepaiIdleTimeoutMinutes -ConfigPath $cfg))
    Set-Content -LiteralPath $cfg -Encoding UTF8 -Value @(
        'version: 1',
        'watch:',
        '    debounce_ms: 500'
    )
    Write-Output ('UNSET=' + (Get-GrepaiIdleTimeoutMinutes -ConfigPath $cfg))
    Write-Output ('MISSING=' + (Get-GrepaiIdleTimeoutMinutes -ConfigPath (Join-Path $dir 'nope.yaml')))
    Write-Output ('DISABLED=' + (Get-GrepaiIdleTimeoutMinutes -ConfigPath $cfg -DefaultMinutes 0))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""")
    _no_throw(res, "idle TTL knob")
    out = res.stdout
    assert "CONFIGURED=7" in out, "the watch.idle_timeout_minutes knob must win:\n%s" % out
    assert "UNSET=20" in out, "an absent key must fall back to 20 minutes:\n%s" % out
    assert "MISSING=20" in out, "an absent file must fall back to the default:\n%s" % out
    assert "DISABLED=0" in out, out


def test_grepai_idle_clock_ignores_the_daemons_housekeeping():
    # The regression that makes a naive log-mtime clock useless: grepai appends
    # housekeeping every 60s/300s (persist + periodic full reconcile) even with
    # zero changes, so the idle clock must skip those lines. Evidence on this repo
    # 2026-09-15: the worktree log kept growing every 5 min with changed_files=0.
    res = _run_ps(r"""
. '__MODULE__'
$dir = Join-Path $env:TEMP ('vad_jmw_log_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $now = Get-Date
    $old = $now.AddMinutes(-90).ToString('yyyy/MM/dd HH:mm:ss')
    $hk  = $now.ToString('yyyy/MM/dd HH:mm:ss')
    Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-deadbeef.log') -Encoding UTF8 -Value @(
        "[grepai-watch] $old Indexed Modules\VAD.py (70 chunks)",
        "[grepai-watch] $hk rpg_full_reconcile_triggered=true project=X reason=periodic",
        "[grepai-watch] $hk rpg_derived_refresh_ms=215 project=X mode=full changed_files=0 rpg_dirty_files_count=0",
        "[grepai-watch] $hk rpg_persist_ms=203 project=X persist_lag_ms=59687"
    )
    $idle = Get-GrepaiIdleMinutes -LogDir $dir
    Write-Output ('IDLE_OLD_GT_60=' + ($idle -gt 60))
    Write-Output ('ACTIVITY=' + (Test-GrepaiActivityLine -Line "[grepai-watch] $hk rpg_derived_refresh_ms=349 project=X mode=incremental changed_files=1 rpg_dirty_files_count=0"))
    Write-Output ('INDEXED_IS_ACTIVITY=' + (Test-GrepaiActivityLine -Line "[grepai-watch] $hk Indexed Modules\VAD.py (70 chunks)"))
    Write-Output ('PERSIST_IGNORED=' + (-not (Test-GrepaiActivityLine -Line "[grepai-watch] $hk rpg_persist_ms=203 project=X")))
    Write-Output ('RECONCILE_IGNORED=' + (-not (Test-GrepaiActivityLine -Line "[grepai-watch] $hk rpg_full_reconcile_triggered=true project=X reason=periodic")))
    Write-Output ('EMPTY_IGNORED=' + (-not (Test-GrepaiActivityLine -Line '')))
    Write-Output ('NO_LOG=' + (Get-GrepaiIdleMinutes -LogDir (Join-Path $dir 'nope')))
    Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-cafebabe.log') -Encoding UTF8 -Value @(
        "[grepai-watch] $hk Indexed Modules\vad_stages.py (83 chunks)"
    )
    Write-Output ('IDLE_FRESH=' + (Get-GrepaiIdleMinutes -LogDir $dir))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""")
    _no_throw(res, "idle clock")
    out = res.stdout
    assert "IDLE_OLD_GT_60=True" in out, (
        "90-min-old activity under fresh housekeeping must read as idle:\n%s" % out
    )
    assert "ACTIVITY=True" in out, out
    assert "INDEXED_IS_ACTIVITY=True" in out, out
    assert "PERSIST_IGNORED=True" in out, out
    assert "RECONCILE_IGNORED=True" in out, out
    assert "EMPTY_IGNORED=True" in out, out
    assert "NO_LOG=-1" in out, (
        "an unmeasurable idle age must be -1 (fail-safe: never reap):\n%s" % out
    )
    fresh = re.search(r"IDLE_FRESH=([0-9.]+)", out)
    assert fresh and float(fresh.group(1)) < 5, (
        "a fresh indexing line must read as ~0 idle minutes:\n%s" % out
    )


def test_grepai_idle_clock_returns_unknown_for_housekeeping_only_window():
    # VAD-z0mg: when the last-300-line window holds ONLY housekeeping, the real
    # work is older than the window, so the idle age is UNKNOWN and the clock
    # must return -1 (do not reap). The old fallthrough sampled $lines[0] (the
    # OLDEST line in the window), which overstates idle and reaped a HEALTHY
    # watcher - observed 346.4 min idle tripping the 20-min TTL seconds after
    # the watcher had indexed.
    res = _run_ps(r"""
. '__MODULE__'
$dir = Join-Path $env:TEMP ('vad_z0mg_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $now = Get-Date
    $hk  = $now.ToString('yyyy/MM/dd HH:mm:ss')
    $old = $now.AddMinutes(-346).ToString('yyyy/MM/dd HH:mm:ss')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("[grepai-watch] $old Indexed Modules\VAD.py (70 chunks)")
    for ($i = 0; $i -lt 320; $i++) {
        $lines.Add("[grepai-watch] $hk rpg_persist_ms=203 project=X persist_lag_ms=59687")
    }
    Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-feedface.log') -Encoding UTF8 -Value $lines
    Write-Output ('HOUSEKEEPING_ONLY=' + (Get-GrepaiIdleMinutes -LogDir $dir))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""")
    _no_throw(res, "idle clock housekeeping-only window")
    assert "HOUSEKEEPING_ONLY=-1" in res.stdout, (
        "a window holding only housekeeping must read as UNKNOWN (-1, do not "
        "reap), never the oldest line's age:\n%s" % res.stdout
    )


def test_grepai_idle_clock_prefers_the_freshest_clock_over_a_stale_log():
    # VAD-1ak (2026-09-17): the reap loop. Every launcher-spawned watcher is
    # started with -RedirectStandardOutput/-RedirectStandardError, so it never
    # refreshes %LOCALAPPDATA%\grepai\logs\grepai-worktree-*.log. The idle clock
    # read that hours-stale file, computed 156-584 min against a 20-min TTL, and
    # terminated a watcher that was actively indexing - proven by
    # watch.last_index_time in .grepai/config.yaml being 4 minutes old at the
    # moment of the reap. The fix reads grepai's own clock and takes the most
    # recent activity either clock can prove.
    res = _run_ps(r"""
. '__MODULE__'
$dir = Join-Path $env:TEMP ('vad_1ak_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $now = Get-Date
    $stale = $now.AddMinutes(-427).ToString('yyyy/MM/dd HH:mm:ss')
    Set-Content -LiteralPath (Join-Path $dir 'grepai-worktree-deadbeef.log') -Encoding UTF8 -Value @(
        "[grepai-watch] $stale Indexed Modules\VAD.py (70 chunks)"
    )
    $cfg = Join-Path $dir 'config.yaml'
    Set-Content -LiteralPath $cfg -Encoding UTF8 -Value @(
        'watch:',
        ('    last_index_time: ' + $now.ToString('o'))
    )
    Write-Output ('FROM_LOG=' + (Get-GrepaiIdleMinutesFromLog -LogDir $dir))
    Write-Output ('FROM_CONFIG=' + (Get-GrepaiIdleMinutesFromConfig -ConfigPath $cfg))
    Write-Output ('COMBINED=' + (Get-GrepaiIdleMinutes -LogDir $dir -ConfigPath $cfg))
    Write-Output ('NO_CONFIG=' + (Get-GrepaiIdleMinutesFromConfig -ConfigPath (Join-Path $dir 'nope.yaml')))
    Write-Output ('BOTH_MISSING=' + (Get-GrepaiIdleMinutes -LogDir (Join-Path $dir 'void') -ConfigPath (Join-Path $dir 'nope.yaml')))
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
""")
    _no_throw(res, "idle clock stale-log fallback")
    out = res.stdout
    stale = re.search(r"FROM_LOG=(-?[0-9.]+)", out)
    assert stale and float(stale.group(1)) > 400, (
        "the stale worktree log must still read as very idle on its own:\n%s" % out
    )
    combined = re.search(r"COMBINED=(-?[0-9.]+)", out)
    assert combined and float(combined.group(1)) < 5, (
        "grepai's own last_index_time must win over a stale log - a watcher that "
        "indexed seconds ago must never be reported idle:\n%s" % out
    )
    assert re.search(r"NO_CONFIG=\s*$", out, re.M), (
        "an unreadable config must yield $null, not a fabricated age:\n%s" % out
    )
    assert "BOTH_MISSING=-1" in out, (
        "with neither clock readable the idle age is UNKNOWN (-1, do not reap):\n%s"
        % out
    )
