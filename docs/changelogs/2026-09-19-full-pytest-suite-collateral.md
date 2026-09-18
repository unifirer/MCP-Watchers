# 2026-09-19 — full pytest sweep after the mcpw-tao fix

Context: mcpw-tao (commit "fix(tests): make the pytest + Pester launcher suites
runnable") unblocked collection. Running the whole suite afterwards
(`cd tests && python -m pytest -c pytest.ini -q`) still showed three failures.
This is what they were and what changed.

## 1. `test_launcher.py::test_launcher_powershell_suite_passes` — TimeoutExpired

Two causes, both fixed in `tests/test_launcher.py`:

- The 300 s ceiling was too low for the loaded case. Measured: the suite takes
  160 s when this module runs alone, but exceeded 300 s inside the full run,
  where sibling modules drive the same watchers. Ceiling raised to 900 s.
- `capture_output=True` discarded everything on timeout, so "slow" and "hung"
  were indistinguishable. The shim now redirects stdout+stderr to a temp file
  and, on `TimeoutExpired`, fails with the last 40 lines of output.

## 2. `test_bridge_upstream_points_to_proxy` — FileNotFoundError

`dev_tools/gm-ollama-bridge.ps1` does not exist in this checkout and never did
(`git log --all -- dev_tools/gm-ollama-bridge.ps1` is empty). MCP-Watchers is a
stripped extraction of VAD; `J:\audio\VAD\dev_tools` has the file. Now SKIPs
when absent, the same rule already applied to `###2.launch_watcher_for_grepai.ps1`.

## 3. `test_repowise_watch_wired_to_proxy` — real drift, NOT auto-fixed

The launcher half passes: `Ensure-LlmProxyRunning` (offset 150092) precedes
`Start-WatcherDetached "repowise"` (offset 168492). The config half fails:

```
.repowise/config.yaml has no litellm.base_url
(provider='openai' model='poolside/laguna-xs-2.1:free')
```

The file has never had a `litellm` section in any revision (it entered the tree
in e2ee117). `.repowise/config.yaml` is the repowise MCP's own LLM-routing
config, and changing an MCP's LLM endpoint is an operator decision, so the test
now reports the gap with an explicit message and checks the launcher half first,
instead of a code regression being masked by the config assertion.

Tracked as bead **mcpw-1lr**. Expected to stay red until the operator approves
adding `litellm.base_url: http://127.0.0.1:11436/v1`.

## 4. T23 flake introduced by the mcpw-tao timeout change

Moving the marker append to run while the tailer was still alive made
`Add-Content` hit a share violation on `watch.log` ("being used by another
process") and abort the whole T23 block. `launcher_tests.ps1` now retries the
append up to 20 times at 250 ms, and asserts success explicitly — the tail
module itself treats a share violation as "retry next tick".

## Verification

- `launcher_tests.ps1` full run: `PASS=152 FAIL=0`, rc 0 (2026-09-19 01:56 NZST).
- `pytest -c pytest.ini -q test_launcher.py test_launcher_proxy_wiring.py`:
  1 passed, 1 skipped, 1 failed — the failure is #3, which is reported, not fixed.
