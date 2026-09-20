"""Portability contract for the ###1 watcher launcher's absolute-path resolution.

The launcher must not embed developer-machine paths. Every external tool it
launches (litellm, mcp-agent-mail, watcher_log_tail.ps1) resolves
through an env var, $PSScriptRoot, or a PATH lookup, with a portable fallback
candidate list. Static source assertions only - no process is spawned.
"""
from pathlib import Path

ROOT = Path(__file__).parent.parent
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
PANE_MODULE = ROOT / "Modules" / "watcher_pane_scripts.ps1"

HARDCODED_WORKSPACE = [r"J:\audio\VAD", "J:/audio/VAD"]
HARDCODED_HOME = [r"C:\Users\yuni", "C:/Users/yuni"]


def _read():
    return LAUNCHER.read_text(encoding="utf-8")


def _read_pane_module():
    return PANE_MODULE.read_text(encoding="utf-8")


def test_no_hardcoded_workspace_root():
    # vad-2ty: vad-uzb moved 747 pane-tailer lines into the pane module, so the
    # root guard must span both files or a future edit escapes it silently.
    for name, src in (("launcher", _read()), ("pane module", _read_pane_module())):
        for literal in HARDCODED_WORKSPACE:
            assert literal not in src, (
                f"Hardcoded workspace literal {literal!r} must be removed ({name})."
            )


def test_no_hardcoded_user_home():
    for name, src in (("launcher", _read()), ("pane module", _read_pane_module())):
        for literal in HARDCODED_HOME:
            assert literal not in src, (
                f"Hardcoded user-home literal {literal!r} must be removed ({name})."
            )


def test_no_generic_user_profile_path():
    for name, src in (("launcher", _read()), ("pane module", _read_pane_module())):
        assert "C:\\Users\\" not in src, f"Hardcoded C:\\Users\\<name> path found ({name})."
        assert "C:/Users/" not in src, f"Hardcoded C:/Users/<name> path found ({name})."


def test_litellm_resolution_is_portable():
    src = _read()
    assert 'Join-Path $env:APPDATA "uv\\tools\\litellm\\Scripts\\litellm.exe"' in src, (
        "litellm.exe must resolve from the uv-tool install under %APPDATA%."
    )
    assert 'Join-Path $env:USERPROFILE "litellm\\litellm_config.yaml"' in src, (
        "litellm_config.yaml must resolve from $env:USERPROFILE."
    )
    assert 'Get-Command "litellm.exe"' in src, "litellm.exe must keep a PATH fallback."


def test_mail_resolution_is_portable():
    src = _read()
    assert 'Join-Path $env:USERPROFILE ".local\\mcp-agent-mail\\run_server.cmd"' in src, (
        "mcp-agent-mail run_server.cmd must resolve from $env:USERPROFILE."
    )
    assert '$env:LOCALAPPDATA' in src and "mcp-agent-mail\\run_server.cmd" in src, (
        "mcp-agent-mail must also probe %LOCALAPPDATA%."
    )


def test_watcher_log_tail_resolution_is_portable():
    # vad-uzb: the pane tailer template's resolution moved to the pane module,
    # so both watcher_log_tail.ps1 sites must stay $PSScriptRoot-relative.
    for name, src in (("launcher", _read()), ("pane module", _read_pane_module())):
        assert r"Join-Path $PSScriptRoot 'Modules\watcher_log_tail.ps1'" in src, (
            f"watcher_log_tail.ps1 must resolve relative to $PSScriptRoot ({name})."
        )


def test_watcher_log_tail_keeps_fallback_candidate():
    # vad-uzb: the two watcher_log_tail.ps1 sites now span two files -- the
    # launcher's own tailer and the pane template in Modules/watcher_pane_scripts.ps1.
    src = _read()
    pane_src = _read_pane_module()
    legacy = r"Join-Path $env:VAD_WORKSPACE_ROOT 'Modules\watcher_log_tail.ps1'"
    assert src.count(legacy) + pane_src.count(legacy) >= 2, (
        "Both watcher_log_tail.ps1 sites must keep a candidate beyond $PSScriptRoot "
        "(env-derived via $env:VAD_WORKSPACE_ROOT, not a hardcoded absolute path)."
    )
    assert "$cands = @()" in pane_src, "Candidate-list pattern for watcher_log_tail.ps1 is missing."
    assert "$fallbackTailCands = @()" in src, "Fallback candidate list is missing."


def test_resolution_keeps_warn_and_skip():
    src = _read()
    assert 'Write-Warning "litellm.exe not found' in src, "litellm must warn-and-skip."
    assert 'Write-Warning "litellm_config.yaml not found' in src, "litellm config must warn-and-skip."
    assert 'Write-Warning "mcp-agent-mail run_server.cmd not found' in src, "mail must warn-and-skip."


def _supervisor_block():
    # vad-10m.5: the Option A backend supervisor (mail/claude-mcp).
    src = _read()
    start = src.index("$backendSupervisorScript = {")
    end = src.index("$script:mailSupJob", start)
    return src[start:end]


def _orphan_backend_pass():
    # vad-10m.5: the backend-duplicate pass inside Stop-WatcherOrphans.
    src = _read()
    start = src.index("function Stop-WatcherOrphans")
    end = src.index("Stop-WatcherOrphans @(", start)
    return src[start:end]


def test_backend_supervisor_uses_env_paths_only():
    block = _supervisor_block()
    assert "%USERPROFILE%" not in block, "supervisor must use $env:USERPROFILE, not %USERPROFILE%."
    assert "C:\\Users" not in block, "supervisor must not hardcode C:\\Users."
    assert "C:/Users" not in block, "supervisor must not hardcode C:/Users."


def test_backend_supervisor_keeps_portable_resolution():
    block = _supervisor_block()
    assert "Join-Path $env:USERPROFILE" in block, "supervisor mail paths must Join-Path from $env:USERPROFILE."
    assert "Join-Path $env:LOCALAPPDATA" in block, "supervisor logs must Join-Path from $env:LOCALAPPDATA."


def test_orphan_backend_pass_uses_no_hardcoded_paths():
    block = _orphan_backend_pass()
    assert "%USERPROFILE%" not in block, "orphan backend pass must not use %USERPROFILE%."
    assert "C:\\Users" not in block, "orphan backend pass must not hardcode C:\\Users."
    assert "C:/Users" not in block, "orphan backend pass must not hardcode C:/Users."