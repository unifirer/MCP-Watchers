## Review: ###1, ###4, ###7, ###5 (code-review-and-quality, 2026-09-12)

### Context
- [x] Launcher/watcher + updater + wiki + proxy scripts. Prior 2026-09-12 review fixes verified: ###5 RepoRoot now portable (PSScriptRoot fallback), ###4 allocator now stable sha256, ###4 single log parser.
- Targets: ###1.watchers...ps1 (3999 lines), ###7.update_mcps.ps1 (1835), ###4.launch_watcher_for_grepai.ps1 (325), ###5.update_wikis.ps1 (356), ###4.llm_fallback_proxy.py (479). Bat wrappers: 13 lines each, correct.

### Correctness
- [x] ###5 phases isolated, failures do not abort others. Graphify/CodeAlmanac/Stories check LASTEXITCODE.
- [ ] ###5 Invoke-Repowise never fails: runs `repowise update` + `generate-claude-md` then unconditional Write-Ok. A failed update still reports ok.
- [ ] ###4 legacy launcher uses `grepai watch --background` + `--status` as truth. ###1 documents --background 30s self-kill crash-loop on this ~38k-file repo and treats --status as unreliable. The two launchers contradict; ###4 will loop where ###1 succeeds.
- [ ] ###4 hardcoded Ollama 12134 + `ollama serve --host 127.0.0.1:12134`. ###1 moved to config-driven target and notes `serve` takes no --host flag. ###4 launch likely fails on current Ollama build.
- [x] Proxy tier fallthrough, 429/5xx retry with capped backoff, per-model health + global circuit. Thread-safe locks. Binds 127.0.0.1 only.
- [x] ###7 version-gated refresh, allowlisted registry, Test-SafePackageToken gates all exec. ###1 FIRST-WINS FileStream gate correctly documents Mutex creation race.

### Readability
- [x] Names clear, SECTION MAP in ###7, phase functions in ###5, long rationale comments in ###1.
- [ ] ###1 at 3999 lines / ~38 functions exceeds the ~1000-line inspection signal by 4x. Count of concepts per change stays high even with Modules/ splits.
- [x] ###7 at 1835 lines stays single-file by documented policy (vad-o6k, double-click + isolated-copy + Start-Job single source). Accept as designed; enforce SECTION MAP + probe-only tests.

### Architecture
- [x] Module boundaries respected: watcher helpers in Modules/, lib.* beside ###7 are guides only, wiki commit scoped to almanac/ + graphify-out/wiki/.
- [ ] ###1 keeps byte-identical Clear-StaleLocks + Test-LauncherAlive inline for test pins while also dot-sourcing the shared module. Documented but drift-prone; tests should pin the module instead.
- [x] Write-Fail divergence intentional and documented (###5 sets ExitCode, ###7 pairs with exit/counter per vad-ect).

### Security
- [x] No secrets in code. Proxy keys via env, gm key passed via child env not command line. Registry path allowlisted. Package tokens allowlisted.
- [x] Bat wrappers use `-ExecutionPolicy Bypass -File "%SCRIPT%"` with setlocal/endlocal and pwsh fallback. Scope limited to the named script. No action.
- Nit: ###5 `npx --yes @thenewguard/tng-wiki` unpinned. A tag move changes code silently. Pin a version or hash.
- Nit: ###1 `$psi.Arguments = ($ArgsList -join ' ')` (Start-WatcherDetached) splits on spaces; benign today (literal flags) but prefer ArgumentList array form.

### Performance
- [x] No N+1, no unbounded fetch, no list endpoint without pagination. CIM polls at 5-10s are launcher-scale, not hot paths.
- Consider: proxy worst-case latency is retries x candidates (2 x ~10 with up to 30s backoff) before 502. Health filtering already shortens it; consider a total-budget cap.
- [x] ###7 RAM gate + cached probe (2s) + job-count backstop. ###1 Ollama/LiteLLM gates overlapped as background jobs.

### Verification
- [x] Tests-first: test_llm_fallback_proxy.py (tiers, fallthrough, circuit, headers), test_wiki_update_launcher.py (syntax), test_launch_watcher_for_grepai_ps1.py (ps1 suite), test_update_mcps_updater_ps1.py (probe-only + SECTION MAP + ps1 suite).
- [x] Fresh run 2026-09-12: `python run_tests_isolated.py` on those 4 files = 4 passed, 0 failed.
- [ ] No live run of watchers or wiki garden in this review. No double-click test. Git log/status not re-audited here.

### Findings (ordered by leverage)
- Required: ###5 Invoke-Repowise must check LASTEXITCODE after each repowise call and Write-Fail on nonzero, else a broken index reports [ok].
- Required: ###4 grepai launch contradicts ###1: replace `--background` + `--status` truth with ###1 foreground-detached + CIM/log readiness, or mark ###4 deprecated in favor of ###1.
- Required: ###4 Ollama hardcoded 12134 + `serve --host` flag. Read endpoint via ###1 Get-GrepaiOllamaTarget pattern and drop the --host args (Ollama serve takes none on this build).
- Consider: proxy global circuit trips all models on total exhaustion. Consider per-model circuit or distinguishing litellm-down from model-down.
- Consider: ###1 inline helper duplicates kept for test pins. Repoint tests at Modules/watcher_job_helpers.ps1 and delete the inline copies.
- Nit: proxy `int(os.environ...)` at import crashes on non-numeric env. Wrap with try/except fallback to defaults.
- Nit: pin tng-wiki version in ###5 instead of `npx --yes` floating tag.
- Nit: ###1 argument join; use Start-Process -ArgumentList array.
- FYI: ###7 single-file + 16-hex mutex truncation + bat Bypass wrappers are accepted by design. No action.
- FYI: ###1 Stop-PriorLauncherInstances retained uncalled for regression-shape pinning. Dead-code exception documented; remove once the test pins the new guard.

### Dead code
- ###1 Stop-PriorLauncherInstances (uncalled, marked DEPRECATED) + inline helper copies above. Documented for tests; ask before deleting: remove after repointing tests?

### Change sizing
- ###1 (3999) and ###7 (1835) exceed the ~1000-line signal. ###7 split is rejected by policy; ###1 split plan (extract pane-script generation first) from prior review still stands as the one structural follow-up.

### Verdict
- Request changes: fix ###5 repowise failure blindness, align ###4 launch + Ollama path with ###1, then merge. Proxy + ###7 + bats are approve-ready.
