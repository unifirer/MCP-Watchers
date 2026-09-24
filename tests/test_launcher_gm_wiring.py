# tests/test_launcher_gm_wiring.py
# Regression lock for the launcher's gm command wiring (###1. updater ... .ps1).
# Static analysis of the committed launcher — proves that the DESTRUCTIVE gm
# incremental writers are gone (gm 0.19.3's `gm watch` / `gm run . --update`
# replace graph.json with only the re-extracted files' nodes), that the live
# rebuild is a full AST-only `gm run`, and that the exe resolution fix holds.
import re, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
PANE_MODULE = ROOT / "Modules" / "watcher_pane_scripts.ps1"


def _read():
    return LAUNCHER.read_text(encoding="utf-8")


def _read_pane_module():
    return PANE_MODULE.read_text(encoding="utf-8")


def test_no_destructive_gm_watch_launch():
    # gm 0.19.3 cannot refresh a graph incrementally without destroying it:
    # `gm watch` and `gm run . --update` write ONLY the re-extracted changed
    # files into graph.json, so the persisted graph is REPLACED by a handful of
    # nodes. Live-reproduced 2026-09-16: touching one file collapsed a
    # 7.3 MB / 5423-node graph to 15 KB / 15 nodes, which is exactly why the
    # MCP handshake reported real staleness while a watcher was running.
    # The launcher must therefore NEVER spawn `gm watch`; freshness comes from
    # the full `gm run` rebuild daemon plus `gm serve --watch` (registry), which
    # hot-reloads graph.json into the MCP server's memory.
    src = _read()
    assert 'Start-WatcherDetached "gm"' not in src, (
        "The destructive `gm watch` launch must stay removed: it replaces "
        "graph.json with only the changed files' nodes."
    )
    assert '"watch", ".", "--debounce", "3"' not in src, (
        "`gm watch . --debounce 3` must stay removed (incremental = destructive)."
    )


def test_launcher_runs_semantic_build_inline_live():
    # Decision 2026-08-27 (amended VAD-3apv 2026-09-06): the semantic build
    # (previously the external ###5 script) is consolidated INLINE into the
    # launcher as a live-incremental daemon. The launcher must:
    #   - define Invoke-GmSemanticBuild (owns the cloud gm run; no ###5 file),
    #   - arm a FileSystemWatcher + thread-job that runs incremental
    #     `gm run . --update` on live file change via the passed-in $BuildSrc
    #     source text (rebuilt inside the job via Set-Item
    #     function:Invoke-GmSemanticBuild; param() first; no startup FULL
    #     warm-up — see below), and
    #   - stop cleanly via Stop-GmSemanticLive on teardown.
    src = _read()
    assert '###5.graphenium_build_semantic_graph_with_qwen_7b.ps1' not in src, \
        "Launcher must no longer reference the deleted ###5 script"
    assert 'function Invoke-GmSemanticBuild' in src, \
        "Launcher must own the semantic build inline (Invoke-GmSemanticBuild)."
    assert 'function Stop-GmSemanticLive' in src, \
        "Launcher must stop the live semantic loop on teardown (Stop-GmSemanticLive)."
    # FULL (non-incremental) mode: the live loop must run a whole-graph rebuild.
    # gm 0.19.3's `gm run . --update` replaces graph.json with only the changed
    # files' nodes (live-reproduced 2026-09-16), so --update must not appear in
    # executable code. Comments may still name it (they explain WHY it is gone),
    # so the check runs on comment-stripped source, like the key test below.
    code = '\n'.join(line.split('#', 1)[0] for line in src.splitlines())
    assert '--update' not in code, \
        "Live rebuild must NOT pass --update: it replaces graph.json with a partial graph."
    assert '--no-semantic' in code, \
        "Live rebuild must be AST-only (--no-semantic) so a per-change rebuild is free."
    # Live trigger must be armed (not the old one-time spawn).
    assert 'gm-sem-changed' in src, \
        "Launcher must arm a FileSystemWatcher for live semantic builds."
    # VAD-3apv (amended VAD-draz.1): the thread job receives the build/probe
    # functions as SOURCE TEXT ($BuildSrc/$ProbeSrc) and rebuilds them inside
    # the job runspace via Set-Item function:..., calling with
    # -BuildDir/-RunLog/-BuildKey. A $BuildFn delegate is parent-session-bound
    # and its cmdlets do not resolve across the runspace hop, so the old
    # `& $BuildFn -Mode "incremental"` contract is stale. A literal
    # `Invoke-GmSemanticBuild -Mode "full"` inside the job scriptblock was the
    # dead-on-arrival bug (statements before param()), and
    # launcher_gm_semantic_build.tests.ps1 now forbids that exact string.
    # The first live file change drives the first (full-cache-warming)
    # incremental build, so no startup warm-up is required.
    # mcpw-b81.2: $ModeSrc joins the contract. The semantic-mode reader must be
    # rebuilt inside the job runspace too - a thread job inherits NO launcher
    # functions, so without it Invoke-GmSemanticBuild cannot resolve
    # Test-GmSemanticEnabled and every build throws.
    assert 'param($State, $BuildSrc, $ProbeSrc, $BuildDir, $RunLog, $ModeSrc)' in src, \
        "Thread job must take build/probe/mode source text + paths via param($State, $BuildSrc, ..., $ModeSrc)."
    assert 'Set-Item -Path function:Invoke-GmSemanticBuild -Value ([scriptblock]::Create($BuildSrc))' in src, \
        "Thread job must rebuild Invoke-GmSemanticBuild from $BuildSrc inside the job runspace."
    assert 'Set-Item -Path function:Test-GmSemanticEnabled -Value ([scriptblock]::Create($ModeSrc))' in src, \
        "Thread job must rebuild Test-GmSemanticEnabled from $ModeSrc inside the job runspace."
    # The live switch is only live if the loop re-reads it: the control file sits
    # in a dot-directory BOTH watchers skip, so no FSW event ever fires for it.
    assert 'Test-GmSemanticEnabled -RepoRoot $BuildDir' in src, \
        "Thread job must poll the semantic mode file each iteration (no FSW event fires for it)."
    assert '-or $State.ModeChanged' in src, \
        "A mode flip must bypass the debounce and the stale timer instead of waiting up to 10 min."
    assert 'Invoke-GmSemanticBuild -BuildDir $BuildDir -RunLog $RunLog -BuildKey' in src, \
        "Live incremental build must call Invoke-GmSemanticBuild with -BuildDir/-RunLog/-BuildKey."
    assert '& $BuildFn -Mode "incremental"' not in src, \
        'Stale $BuildFn -Mode contract must stay removed (BuildSrc + -BuildDir/-RunLog/-BuildKey is current).'


def test_semantic_build_no_dummy_api_key_on_cmdline():
    # VAD-draz.3 (kept): no hardcoded dummy key may ever land on the gm cmdline.
    # VAD-v14z.1 (supersedes the old conditional --api-key append): the proxy
    # key must NEVER reach the child via ArgumentList (Win32_Process.CommandLine
    # is world-readable). gm's key gate is satisfied through the child
    # environment (GRAPHENIUM_API_KEY) instead, so --api-key is gone entirely.
    src = _read()
    assert 'proxy-dummy-key' not in src, (
        "The hardcoded proxy-dummy-key must be gone; no dummy key on the gm cmdline."
    )
    assert '$proxyKey = $env:LLM_PROXY_API_KEY' in src, (
        "proxyKey must read LLM_PROXY_API_KEY from the environment (no hardcoded fallback)."
    )
    # --api-key must not appear anywhere in the launcher: neither baked into
    # the static $runArgs array nor appended conditionally. (The wiring anchor
    # mentions --api-base, which is unaffected by this check.)
    assert '--api-key' not in src, (
        "--api-key must never be passed on the gm command line; "
        "the key travels via the GRAPHENIUM_API_KEY child environment."
    )
    # The key gate is satisfied via the child environment instead.
    assert 'GRAPHENIUM_API_KEY' in src, (
        "The proxy key must be staged via GRAPHENIUM_API_KEY in the child environment."
    )
    # Proxy defaults are preserved (port 11436, model nous-proxy).
    assert '"11436"' in src, "Default proxy port 11436 must be preserved."
    assert '"nous-proxy"' in src, "Default proxy model nous-proxy must be preserved."
    # Wiring test anchor is preserved.
    assert 'wiring test anchor' in src, (
        "The Invoke-GmSemanticBuild wiring test anchor comment must be preserved."
    )


def test_semantic_build_key_never_in_argumentlist():
    # VAD-v14z.1 regression: the secret must never be interpolated into the
    # Start-Process ArgumentList. The check runs on executable code with
    # PowerShell comments stripped, so explanatory comments cannot trip it.
    src = _read()
    code_lines = [line.split('#', 1)[0] for line in src.splitlines()]
    code = '\n'.join(code_lines)
    assert '--api-key' not in code, (
        "Executable code must not reference --api-key; "
        "the key travels via the child environment, never ArgumentList."
    )
    for line in code_lines:
        if '$proxyKey' in line:
            assert 'runArgs' not in line and 'ArgumentList' not in line, (
                "The proxy key must never flow into $runArgs / -ArgumentList: %r"
                % line.strip()
            )
    # Staged env key must be restored/removed after the spawn so it does not
    # leak into the parent session.
    assert 'Remove-Item env:GRAPHENIUM_API_KEY' in src, (
        "The staged GRAPHENIUM_API_KEY must be cleaned up after spawning gm."
    )
    # The key must never be logged. These are the lines that announce a
    # semantic build about to run, and each must name only the base / model /
    # mode - never the credential:
    #   [gm-semantic] running FULL non-destructive gm rebuild - semantic mode <label>
    #   [gm-semantic] semantic mode changed <was> -> <now>; rebuilding.
    # The needle is matched with `in` against the raw source, so it MUST track
    # the literal the launcher actually prints. It previously read
    # "running incremental", which no line has ever contained, so the loop body
    # never executed and this guard was inert while the suite still reported
    # green (mcpw-b81.9). The match counter below is what stops that recurring.
    launch_needles = (
        'gm-semantic] running FULL non-destructive gm rebuild',
        'gm-semantic] semantic mode changed',
    )
    matched = 0
    for line in src.splitlines():
        if any(needle in line for needle in launch_needles):
            matched += 1
            assert '$proxyKey' not in line and 'GRAPHENIUM_API_KEY' not in line, (
                "The gm-semantic launch log line must not include the key: %r"
                % line.strip()
            )
    assert matched >= 1, (
        "The gm-semantic launch log-line guard matched no line at all. Its "
        "needle has drifted from the launcher's actual log line, which turns "
        "this check into a silent no-op - exactly the mcpw-b81.9 failure."
    )


def test_cleanlogline_strips_graphenium_log_level_tag():
    # Regression lock for the display-only fix that removes gm's "[graphenium ERR]"
    # severity prefix from every pane line. The tag is NOT a real error and only
    # clutters the pane; gm prints it on every watch event (e.g. "changed (code):").
    # CleanLogLine lives inside the tailer template the launcher writes via
    # New-WatcherPaneScript; vad-uzb moved that template to
    # Modules/watcher_pane_scripts.ps1. Guard the exact strip regex so it can't
    # regress.
    src = _read_pane_module()
    assert "CleanLogLine" in src, "CleanLogLine filter must exist in the pane tailer template"
    # Strip regex broadened to remove BOTH the severity variant "[graphenium ERR]"
    # and the plain "[graphenium]" prefix gm puts on every line, so the pane's own
    # [graphenium] tag is the only one shown (no doubled prefix).
    assert "$s = $s -replace '\\[graphenium(?: [A-Z]+)?\\]\\s*', ''" in src, (
        "CleanLogLine must strip gm's '[graphenium]'/'[graphenium ERR]'-style "
        "log-level tag from displayed lines (display-only; gm still does its job)."
    )


def test_gm_exe_resolved_in_function():
    # Root cause #7: gm.exe resolution must happen inside Start-WatcherDetached
    # (function scope) using Get-Command "$ExeName.exe", NOT at script scope
    # where 'gm' is PowerShell's built-in Get-Member alias.
    src = _read()
    assert 'Get-Command "$ExeName.exe"' in src, \
        "Start-WatcherDetached must resolve the exe via Get-Command \"$ExeName.exe\""


def test_no_script_scope_cmd_dot_source():
    # Any $cmd.Source at column 0 (script scope) is the null-crash bug (#7): at
    # script scope 'gm' is PowerShell's built-in Get-Member alias, so
    # Get-Command "gm" returns the alias (no .Source) and $cmd.Source is $null.
    # The exe MUST be resolved in function scope via Get-Command "$ExeName.exe"
    # (Start-WatcherDetached), never at script scope.
    src = _read()
    for line in src.splitlines():
        if line.startswith("$cmd.Source") or line.startswith("Start-Process -FilePath $cmd.Source"):
            raise AssertionError("script-scope $cmd.Source still present (null crash)")
    # The launcher resolves the real .exe inside Start-WatcherDetached (function
    # scope) and uses it for the spawned process. The exact spawn style has been
    # refactored from `Start-Process -FilePath $cmd.Source` to a raw-byte
    # System.Diagnostics.Process (`$psi.FileName = $cmd.Source`) to avoid cp1252
    # mojibake on UTF-8 watcher output — both are valid as long as $cmd.Source is
    # function-local. Assert the current valid form.
    assert '$psi.FileName = $cmd.Source' in src, \
        "Start-WatcherDetached must resolve and use the .exe path ($cmd.Source) in function scope."
    # Guard the actual root cause: resolution MUST go through Get-Command "<name>.exe",
    # not a bare Get-Command "gm" (which returns the Get-Member alias, no .Source).
    assert 'Get-Command \"$ExeName.exe\"' in src, \
        "Exe resolution must use Get-Command \"$ExeName.exe\" (not bare 'gm') inside the function."


def test_cargo_bin_prepended_to_path():
    # Root cause (2026-08-12): cargo\\bin is only on the interactive
    # terminal-session PATH, NOT the Machine/User PATH. When ###1 is launched
    # from a base context (double-click .bat / Explorer / non-login spawn),
    # Get-Command "gm.exe" returns null and the gm watcher is silently skipped
    # (no gm.log, no gm process). The launcher must prepend cargo\\bin
    # (and .rustup\\bin) to $env:PATH at startup so cargo-installed CLIs resolve
    # regardless of launch context.
    src = _read()
    assert 'Join-Path $env:USERPROFILE ".cargo\\bin"' in src, \
        "Launcher must prepend cargo\\bin to PATH (gm/graphify-rs resolve there)."
    # The prepend must run BEFORE the launches that resolve gm/graphify-rs.
    # The gm `watch` spawn is gone (destructive incremental writer), so anchor
    # the ordering on the repowise watcher launch, which still runs after it.
    prepend_idx = src.find('Join-Path $env:USERPROFILE ".cargo\\bin"')
    watcher_launch_idx = src.find('Start-WatcherDetached "repowise"')
    assert prepend_idx != -1 and watcher_launch_idx != -1, \
        "Both the cargo prepend and the repowise watcher launch must be present."
    assert prepend_idx < watcher_launch_idx, \
        "cargo\\bin must be prepended to PATH before the watcher launches."
