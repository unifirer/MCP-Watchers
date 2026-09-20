# Change Log: Fix @@launch watcher for grepai.ps1 IPv6 and Performance Issues

**Date:** June 28, 2026  
**Issue:** `@@launch watcher for grepai.ps1` falsely reports that the Ollama service is offline and fails to start it/errors out, even when Ollama is running. This occurred because `localhost` was resolving to the IPv6 loopback address `[::1]` on Windows, while Ollama only listens on the IPv4 loopback address `127.0.0.1:11434`. Additionally, subsequent runs of the script would perform a blocking HTTP query against Ollama, which could timeout or fail under high CPU/indexing load from grepai.

## Root Cause
1. **IPv6 vs IPv4 Mismatch:** The script used `$ollamaUrl = "http://localhost:$ollamaPort/"`. On Windows, `localhost` resolves to both `[::1]` (IPv6) and `127.0.0.1` (IPv4). Since IPv6 takes precedence, PowerShell's `Invoke-RestMethod` attempted to connect to `[::1]:11434`. However, `netstat -ano` confirmed that Ollama is bound strictly to `127.0.0.1:11434` (IPv4), resulting in connection timeouts/refusals.
2. **Timing/Load-induced Failures on Re-run:** When `grepai watch` starts, it heavily loads Ollama with embedding tasks. During this time, Ollama can become unresponsive to HTTP GET `/` requests. If the launch script was run again while grepai was indexing, the Ollama HTTP check would fail or timeout, causing the script to incorrectly report Ollama is offline or attempt to launch another instance.

## Fix Applied
1. **Changed endpoint to 127.0.0.1:** Updated `@@launch watcher for grepai.ps1` to use `http://127.0.0.1:$ollamaPort/`, ensuring connections succeed instantly without being blocked by IPv6 name resolution.
2. **Updated grepai configs:** Updated `.grepai/config.yaml` and `.worktrees/2026-sync/.grepai/config.yaml` to point to `http://127.0.0.1:11434` for both embeddings and the LLM endpoint.
3. **Reordered execution check (Performance Optimization):** Restructured the launch script to check if `grepai` watch is already running or active at the very top of the script. If `grepai` is already running, the script immediately exits with code 0 without hitting the Ollama endpoint. This avoids querying Ollama under high load and avoids false-positive offline errors.
4. **Increased timeouts:** Raised the initial Ollama check timeout from 2 to 5 seconds, and loop polling timeout from 1 to 2 seconds to make the script more resilient under system load.

## Tests & Verification
1. Manually verified name resolution on both `localhost` and `127.0.0.1` endpoints.
2. Verified that running the launch script when grepai watch is active exits instantly and cleanly with no output.
3. Ran the entire test suite (`pytest`) and verified that all 65 tests passed successfully.
