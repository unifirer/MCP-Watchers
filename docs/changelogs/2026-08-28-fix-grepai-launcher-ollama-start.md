# 2026-08-28 — Fix grepai launcher Ollama auto-start (`--host` flag crash)

## Symptom
`###4.launch_watcher_for_grepai.ps1` printed:
```
Ollama service is offline. Attempting to start Ollama from C:\Users\yuni\AppData\Local\Programs\Ollama\ollama.exe...
WARNING: Ollama service is not running on port 12134 and could not be started. Skipping Ollama-dependent startup.
...
Write-Error: grepai watch did not report running within 30 s. It may have crashed on launch. Check the grepai log.
Press Enter to exit...
```

## Root cause
`###4` (line 131) started Ollama as `ollama serve --host 127.0.0.1:12134`.
Ollama v0.30.11's `serve` subcommand **rejects `--host`**:
```
Error: unknown flag: --host
```
and exits 1 immediately. So `Start-Process` launched a process that died instantly;
Ollama never bound 12134; the 20s readiness loop failed → "could not be started" →
Ollama stayed down → grepai (needs Ollama embeddings) never reached `Status: running`
→ the 30s wait failed → the reported error.

`###1` already used the correct form (`serve` with no flag, relying on the persisted
User-level `OLLAMA_HOST=127.0.0.1:12134`), so this was a feature-parity regression:
`###4` still carried the dead `--host` flag.

Verified by reproducing the exact call: `ollama serve --host 127.0.0.1:12134` →
`Error: unknown flag: --host`, exit 1.

## Fix
- `###4.launch_watcher_for_grepai.ps1` line 131: changed
  `Start-Process ... -ArgumentList "serve","--host","127.0.0.1:12134"`
  to `Start-Process ... -ArgumentList "serve"` (matches `###1`). Ollama binds via
  the persisted `OLLAMA_HOST` env var, which is set at User level.
- Corrected the same broken snippet + description in
  `plans/2026-08-15-grepai-index-corruption-check.md` (Task 4, Step 4) so the doc no
  longer instructs the dead `--host` form.

## Verification (live)
1. Reproduced `ollama serve --host ...` → `Error: unknown flag: --host`, exit 1.
2. From a cold state (Ollama killed), ran the real `###4` with the fix:
   `grepai watch is RUNNING (confirmed after 1 s).` — Ollama auto-started, grepai
   reached steady `[RUNNING]`.
3. Final live state: Ollama HTTP 200 on 12134; `grepai watch --status` → `Status: running`.
4. Repo-wide scan: no remaining live-code `ollama serve --host` start pattern.

## Manual test checklist
- Close Ollama (Task Manager / `taskkill /F /IM ollama.exe`).
- Double-click `###4.launch_watcher_for_grepai.ps1`.
- Confirm: console shows "Ollama service started successfully!" then
  "grepai watch is RUNNING (confirmed after N s)."; no "could not be started" / 30s error.
- `grepai watch --status` returns `Status: running`.
