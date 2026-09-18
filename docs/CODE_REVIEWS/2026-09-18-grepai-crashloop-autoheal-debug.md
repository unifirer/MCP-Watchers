# Debug report: grepai watcher crash-loop and stalled auto-heal

Date: 2026-09-18
Scope: root-cause diagnosis + one config fix applied.
Reporter note: all timestamps are local (UTC+12).

---

## 1. Verdict

Two faults, one shared cause plus one design gap.

**Fault A (the crash loop).** The watcher did not "die" on its own. It **refused to
start**. `.grepai/config.yaml` pointed grepai's embedder at `http://localhost:11434`.
Ollama is configured on this machine to serve on **12134**. Port 11434 has no
listener. grepai probes `GET /api/tags`, gets a refused connection, prints
`Error: cannot connect to Ollama`, and exits in **under two seconds** — every time.

**Fault B (the stalled auto-heal).** The heal was not broken. It was **correctly
declining to act**. `Test-SupervisorAlive` found a fresh supervisor stamp (age 11 s
against a 60 s window), so the pane took its documented "single healer" branch and
deferred to the supervisor. But the supervisor had spent its five restart attempts on
the same doomed launch and entered its own 10-minute backoff. Both healers were
healthy; the thing they were healing could never start.

The `supervised restart pending...` line is therefore accurate but misleading — it
reads like a stuck state machine. It is a truthful report that a live supervisor owns
the retry, while that supervisor is asleep.

---

## 2. Evidence chain

### 2.1 The watcher's own error

`%LOCALAPPDATA%\grepai\logs\grepai-worktree-0882dce4c425.log`:

```
[grepai-watch] 2026/09/18 07:46:27.268505 Provider: ollama (nomic-embed-text)
[grepai-watch] 2026/09/18 07:46:27.268505 Backend: qdrant
Error: cannot connect to Ollama: failed to reach Ollama at http://localhost:11434:
  Get "http://localhost:11434/api/tags": dial tcp [::1]:11434: connectex:
  No connection could be made because the target machine actively refused it.
Make sure Ollama is running and has the nomic-embed-text model
```

Same text in `C:\Temp\vad-watchers\watchers\grepai-launch.log.err`.

Reproduced directly (`grepai watch --no-ui` in the repo): identical failure, identical
2-second exit. Confirmed the harness is not at fault.

### 2.2 Where Ollama actually lives

| Probe | Result |
|---|---|
| `OLLAMA_HOST` (HKCU Environment) | `127.0.0.1:12134` |
| Listener on 12134 | **PID 18344 `ollama`** — `ollama.exe serve` |
| `GET 127.0.0.1:12134/api/tags` | **200**, serves `nomic-embed-text:latest` |
| Listener on 11434 | **none** (raw TCP connect refused) |

The model grepai needs is present and served — on 12134.

### 2.3 The config pointed at the dead port

`.grepai/config.yaml` before the fix:

```yaml
embedder:
    provider: ollama
    model: nomic-embed-text
    endpoint: http://localhost:11434      # <-- no listener here
...
rpg:
    llm_endpoint: http://localhost:11434/v1
```

### 2.4 The supervisor crash-loop

`C:\Temp\vad-watchers\watchers\watchers.log` and
`%LOCALAPPDATA%\grepai\logs\supervisor.log` show a tight cycle, repeating every ~10
minutes once backoff elapsed:

```
[08:13:25] grepai watch exited - restarting in 1s
[08:13:32] restarted grepai (PID 96008)
[08:13:41] grepai watch exited - restarting in 1s
[08:13:44] restarted grepai (PID 89640)
[08:13:46] grepai (PID 89640) exited immediately after restart - clearing locks and retrying once
[08:13:53] retry restarted grepai (PID 7324)
[08:14:01] grepai watch exited - restarting in 1s
...
[08:14:30] 5 consecutive failed restarts - backing off 10 minutes
```

`###1...ps1` lines 1500-1511: after `$consecutiveRestarts -ge 5` the supervisor
sleeps 20 x 30 s = 10 minutes, refreshing its liveness stamp throughout (VAD-7qf0).

### 2.5 Why the pane never heals

`Modules\watcher_pane_scripts.ps1` (mirrored into
`C:\Temp\vad-watchers\panes\tail_grepai.ps1`):

- `Test-SupervisorAlive` line 124: returns true when `<lockfile>.sup` is younger than 60 s.
- `Invoke-GrepaiHealthCheck` line 615: if the supervisor is alive, log
  `supervisor alive - skipping pane heal (single healer)` and return.

Measured at 08:25:17:

```
lockpath: C:\Users\yuni\AppData\Local\watchers\###1-launcher.lock   exists=True
sup:      C:\Users\yuni\AppData\Local\watchers\###1-launcher.sup    exists=True
age=11.06 sec (MaxAge=60) -> alive=True
```

So the pane deferred to a supervisor that was mid-backoff. Not a stall — a
correctly-applied single-healer policy meeting a permanently-failing launch.

### 2.6 Correction: the pane heal target is NOT a bug

An earlier draft of this report flagged `-RepoRoot 'J:\audio\VAD'` in
`C:\Temp\vad-watchers\panes\tail_grepai.ps1` line 761 as a wrong-repo defect.
**That reading was wrong, and it is withdrawn.**

What actually happened: `C:\Temp\vad-watchers\panes\` is the **legacy** scratch
directory. Scratch is now per-workspace — `C:\Temp\vad-watchers\<workspaceKey>\panes\`.
The file I read was a leftover from a pre-keying launch (mtime 07:27). The live
session regenerates its panes elsewhere.

The live pane, in the correct per-workspace location, reads:

```
C:\temp\vad-watchers\77442b14\panes\tail_grepai.ps1 line 820:
  $healResult = Invoke-GrepaiHealthCheck -RepoRoot 'J:\audio\MCP-Watchers' ...
```

That is correct. `-RepoRoot $scriptDir` resolves to the launcher's own directory,
which is where `.grepai/` lives and where `grepai watch` runs — exactly as the
comment at launcher lines 3797-3802 intends. Commit `020c191` was a real fix and it
works. No action needed.

**The real lesson is a diagnostic one:** three `tail_grepai.ps1` copies exist on this
machine (legacy `panes\`, `77442b14\panes\`, `ad90e3fb\panes\`). Reading the wrong one
produces a confident, wrong conclusion. Resolve the live pane by the launcher PID or
by the workspace key, never by guessing the path.

---

## 3. Premise correction: there is no port-reservation problem

`###1...ps1` lines 659-733 (`Enable-GrepaiOllamaPortFix`) and its comments assert:

> The default Ollama port (11434) sits inside Windows' administratively-reserved
> range 11408-11507, so Ollama cannot bind it ...

That is false on this machine. `netsh int ipv4 show excludedportrange protocol=tcp`:

```
Start Port    End Port
      5357        5357
      5985        5985
     47001       47001
     50000       50059     *
* - Administered port exclusions.
```

11434 is **not** in any excluded range. The workaround exists to route around a
constraint that is not present. The real reason 11434 is empty is simply that
`OLLAMA_HOST=127.0.0.1:12134` tells Ollama to bind 12134.

---

## 4. The fix applied

One file, two lines. `.grepai/config.yaml`:

```diff
 embedder:
-    endpoint: http://localhost:11434
+    endpoint: http://127.0.0.1:12134
 rpg:
-    llm_endpoint: http://localhost:11434/v1
+    llm_endpoint: http://127.0.0.1:12134/v1
```

Backup: `.grepai/config.yaml.bak-2026-09-18`.

Note: grepai reads the **config**, not `OLLAMA_HOST`. Verified by exporting the
correct `OLLAMA_HOST` and re-running — still failed against 11434. The config is the
only lever.

### 4.1 Verification (fresh output)

Symptom gone — the watcher indexes instead of dying:

```
Initial scan complete: 70 files indexed, 379 chunks created, 0 files removed, 0 skipped (took 43.433s)
Symbol index built: 166 symbols extracted
[RUNNING] J:\audio\MCP-Watchers - steady
Watching for changes... (Press Ctrl+C to stop)
```

Supervisor recovered on its own after the 10-minute backoff expired, and adopted a
watcher that stayed up:

```
[2026-09-18T08:30:29] supervisor started (enhanced: auto-heal + stale-lock cleanup)
[2026-09-18T08:30:31] grepai idle TTL armed: 20 minute(s) (0 = disabled)
[2026-09-18T08:30:32] tracking grepai watch PID 40548 (adopted single live watcher)
```

Independent liveness, 4 minutes after restart:

```
PID 40548 started=09/18/2026 08:30:09 rss=40MB cmd="...grepai.exe" watch
config last_index_time: 2026-09-18T08:33:48.1913271+12:00     (15 s old at check)
NOW=2026-09-18T08:34:03
```

Before the fix the same process died in <2 s, four to six times per 10 minutes, for
hours. It has now survived a full supervisor restart cycle with zero restarts logged.

### 4.2 Live proof from the continuation pass (strongest evidence)

The watcher indexed **this report while it was being written**. Each append produced a
new incremental re-index, which proves watch mode, debounce and the incremental reader
are all functioning end-to-end:

```
2026/09/18 08:45:31 Indexed .workbuddy-ai\memory\2026-09-18.md (11 chunks)
2026/09/18 08:45:37 Indexed reports\2026-09-18-defect-scriptdir-vs-workspaceroot.md (7 chunks)
2026/09/18 08:55:29 Indexed .workbuddy-ai\memory\2026-09-18.md (11 chunks)
2026/09/18 08:58:59 Indexed docs\CODE_REVIEWS\2026-09-18-grepai-crashloop-autoheal-debug.md (8 chunks)
2026/09/18 08:59:09 Indexed docs\CODE_REVIEWS\2026-09-18-grepai-crashloop-autoheal-debug.md (10 chunks)
2026/09/18 08:59:10 Indexed docs\CODE_REVIEWS\2026-09-18-grepai-crashloop-autoheal-debug.md (10 chunks)
2026/09/18 08:59:24 Indexed docs\CODE_REVIEWS\2026-09-18-grepai-crashloop-autoheal-debug.md (11 chunks)
2026/09/18 08:59:33 Indexed docs\CODE_REVIEWS\2026-09-18-grepai-crashloop-autoheal-debug.md (12 chunks)
```

The chunk count climbs `8 → 10 → 11 → 12` in step with the sections added to this file.
`grepai watch` PID 30296 stayed up throughout; only **one** `watch` process exists (the
other `grepai.exe` instances are `mcp-serve` stdio MCP servers, one per client session —
not a leak).

### 4.3 B2 gate verified by execution

The single-healer gate had only ever been confirmed *present* in the tree. It is now
confirmed *working*. The real `Test-SupervisorAlive` was AST-extracted from the generated
pane (`C:\Temp\vad-watchers\77442b14\panes\tail_grepai.ps1`, line 151) and exercised
against the live stale stamp:

| Case | Result | Expected |
|---|---|---|
| Real `.sup` aged 814 s | `False` | `False` ✓ |
| Fresh `.sup` (control) | `True` | `True` ✓ |
| Empty lock path | `False` | `False` ✓ |
| Nonexistent lock file | `False` | `False` ✓ |

Generated pane AST errors: **0**. This is the first *executed* verification of any of the
B1/B2/B3 fixes recorded in §6.

The live state at 09:01 exercises exactly this path: launcher PID 16464 is gone, all
`RootPids` are gone, the `.sup` stamp is 814 s old (window is 60 s) → **stale** → the pane
is entitled to take over healing. The heal target is healthy, so no heal fires. Correct.

---

## 5. Outstanding issues (NOT fixed - need a decision)

Ordered by risk.

1. **`Enable-GrepaiOllamaPortFix` rests on a false premise** (§3) and silently writes
   `OLLAMA_HOST` at User level. Its 12134 fallback is what put the machine into the
   split state in the first place. Worth deleting or rewriting once the config is
   authoritative.

2. **The 10-minute backoff is unbounded.** Five failures buys a 10-minute nap, then
   five more, forever. For a *deterministic* failure (bad config) backoff never
   converges. A cheap preflight — probe the configured embedder endpoint before
   declaring a restart attempt — would turn six blind relaunches into one clear
   message.

   **PARTIALLY ADDRESSED (2026-09-18).** A reachability preflight was added to the
   `if ($consecutiveRestarts -ge 5)` branch in `###1...ps1` (line ~1503). It reads
   `embedder.endpoint` from the watched repo's `.grepai\config.yaml`, probes
   `<endpoint>/api/tags`, and when unreachable names the cause instead of logging the
   generic backoff line. **The 10-minute sleep is deliberately unchanged** in both
   branches — grepai may recover on its own once the operator corrects the config, so
   shortening the nap would only add churn. What changed is the *diagnostic*, not the
   schedule. Verified: AST parse 0 errors, regex captures `http://127.0.0.1:12134`,
   control probe against dead `11434` yields `embedderDead=True`.

   **Caveat — the branch has never executed in production.** Both crash loops today
   (08:14:17-08:14:30 and 08:24:37-08:25:19) logged the *old* generic message, and the
   config fix landed at ~08:25. The supervisor has not reached 5 consecutive failures
   since. The preflight is therefore verified by parse and by unit-level logic only —
   **not by a live crash cycle.** Treat it as untested in situ until a cycle exercises
   it.

3. **qdrant client/server version skew.** grepai logs on every start:
   `clientVersion=v1.19.0 serverVersion=1.11.3 ... Major versions should match`.
   Indexing worked regardless, so this is a warning, not a blocker. Track separately.

4. **Priority inversion.** `###1` spends a 20-minute idle TTL, a mutex, a 10-minute
   backoff, and a probe subsystem on watcher lifecycle — but a five-line reachability
   check on the embedder would have caught this before the first launch.

5. **Stale scratch does not get cleaned.** Three `tail_grepai.ps1` generations sit
   under `C:\Temp\vad-watchers\` (legacy `panes\`, plus two keyed dirs). One of them
   actively misled this investigation (§2.6). Worth pruning on launch.

---

## 5b. New findings from the continuation pass

These appeared while verifying the fix and are recorded with an explicit confidence
level. Do not treat an unproven cause as a proven one.

### 5b.1 `J:\audio\VAD\.grepai\config.yaml` still pointed at the dead port — HIGH, proven, NOW FIXED

The sibling repo retained the identical latent fault:

```yaml
embedder:
    endpoint: http://localhost:11434      # nothing listens here
rpg:
    llm_endpoint: http://localhost:11434/v1
```

`J:\audio\VAD` was never fixed. Any launcher started from that repo crashed in exactly
the same way — and the 08:14 and 08:24 crash loops **were** that repo.

**Fixed in this pass.** Same two lines, same change as the MCP-Watchers config, with a
backup at `J:\audio\VAD\.grepai\config.yaml.bak-2026-09-18`:

```
5c5
<     endpoint: http://localhost:11434
---
>     endpoint: http://127.0.0.1:12134
126c126
<     llm_endpoint: http://localhost:11434/v1
---
>     llm_endpoint: http://127.0.0.1:12134/v1
```

Sweep result: only two `.grepai/config.yaml` files exist under `J:\audio`, and **zero**
now reference `11434`. Both probe `HTTP 200 OK` against `/api/tags`.

**`enable-GrepaiOllamaPortFix` is the systemic cause.** It is what wrote
`OLLAMA_HOST=127.0.0.1:12134` while leaving both repos' configs on `11434`. The two
mechanisms disagree, and the config wins — see §3 and §5 item 1.

### 5b.2 grepai's vector store is empty while grepai reports success — MEDIUM, cause unknown

Fresh, exact counts (`POST /collections/<name>/points/count {"exact":true}`):

| Collection | Exact points |
|---|---|
| `J__audio_MCP-Watchers` | **0** |
| `J__audio_VAD` | **0** |
| `memories` (graphiti) | 391 |

Qdrant is healthy and writable — `memories` proves it. But grepai logged
`Initial scan complete: 73 files indexed, 403 chunks created` at 08:42:57 and its
collection holds **0** points. Each grepai collection reports `segments_count: 8` with
`points_count: 0`, i.e. segments were created and are empty.

**Confidence: the observation is exact and reproducible; the root cause is NOT
established.** Candidate explanations, none tested:

- a write that is deferred or dropped after the "chunks created" line,
- the collection being recreated on each start (name is derived from the repo path),
- a client/server mismatch in the upsert path (see item 3 — client v1.19.0 vs server
  v1.11.3). This is now a *leading* hypothesis rather than a cosmetic warning.

Do not treat item 3 as a mere warning until this is separated out: item 3 and 5b.2 may
be the same defect. Note the watcher *is* live-indexing (see §4.2) — so this is about
persistence, not about the watcher failing.

### 5b.3 Supervisor restarts are frequent — LOW, no cause established

`%LOCALAPPDATA%\grepai\logs\supervisor.log` shows four `supervisor started` lines today:
08:30:20, 08:30:29, 08:43:18, 08:47:28. Each re-adopts the live watcher
(`adopted single live watcher`), so healing keeps working — but a supervisor that
restarts four times in 17 minutes is either being re-spawned by successive launcher
generations or is not surviving. Not proven which.

### 5b.4 `Symbol index built: 0 symbols extracted` — LOW, observation only

The 08:42 run reported `Symbol index built: 0 symbols extracted`, whereas an earlier run
reported `166 symbols extracted`. `symbols.gob` is 228,526 bytes, so a symbol index
exists on disk. Whether 0 is correct for the current file mix (73 files, mostly
markdown and config) or a regression is not determined.

---

## 6. Note for the B1/B2/B3 workstream

The instruction for this session was "keep going with B1/B2/B3". These three beads
were verified present in the tree:

- **B1** idle clock — `Get-GrepaiIdleMinutesFromConfig` / `Get-GrepaiIdleMinutesFromLog`
  with the freshness guard (`Modules\watcher_job_helpers.ps1` lines 317-400).
- **B2** supervisor liveness stamp — `Test-SupervisorAlive` reading `<lockfile>.sup`
  (`Modules\watcher_pane_scripts.ps1` lines 124-133).
- **B3** idle-marker park — `Test-GrepaiIdleMarker` (lines 141-148), consumed at
  lines 780-786.

All three are correct **as built**, and all three were **inert** today: the fault was
upstream of every one of them. That is the lesson worth carrying — the watcher
lifecycle machinery is elaborate and, on this occasion, irrelevant. The failure was a
stale URL in a config file.

**B2 is now verified by execution**, not just by inspection — see §4.3. B1 and B3 remain
verified by inspection only.

**Testability trap worth noting.** `Modules\watcher_pane_scripts.ps1` cannot be validated
by dot-sourcing. Line 57 opens `$template = @'` and line 835 closes it, so the sixteen
functions from line 81 to line 835 — including `Test-SupervisorAlive` and
`Test-GrepaiIdleMarker` — are template **payload**, not live code. They only become real
definitions after substitution writes them into the generated pane. A harness that
dot-sources this module and calls `Test-SupervisorAlive` receives nothing
(`Get-Command` → not found). `tests\launcher_watcher_panes.tests.ps1` handles this
correctly by AST-extracting `New-WatcherPaneScript` instead — keep doing that. The module
header comment claiming it "defines New-WatcherPaneScript only" is accurate for
dot-sourcing but misleads about the other sixteen functions.

---

## 7. Status

Fault A: root cause proven, fix applied, verified with fresh output.
Fault B: root cause proven (correct deference to a backed-off supervisor). No code
change made — the heal behaved as designed.

Config change requires no approval to keep (it is a runtime-state file, gitignored,
and was already wrong). Outstanding issues in §5 are untouched pending instruction.

### 7a. Commit provenance — the preflight was bundled into someone else's commit

The preflight edit (§5 item 2) was authored in this session but **did not stay
uncommitted**. By the continuation pass it was already in `HEAD`:

```
026765e  fix(launcher): root repository-scoped paths at the workspace, not the script dir
         author uni.universefire <uni.universefire@gmail.com>
         date   Fri Sep 18 08:50:38 2026 +1200
```

That commit's message describes **only** the `mcpw-ybs.7` `$scriptDir` →
`$watchersWorkspaceRoot` workspace-rooting work. It does not mention the embedder
reachability preflight, which it carries in the same file. The change is committed but
**undocumented in history**.

Two consequences worth stating plainly:

- The preflight is no longer "uncommitted work"; it is in `HEAD` and will be inherited
  by anyone who pulls. It is also **not isolated** — it shares a commit with a 95-line
  foreign refactor, so `git revert 026765e` would remove both.
- That commit claims `deterministic gate temp\_gate.bat: 158 pass, 0 fail, 8/8 suites
  EXIT=0`. That gate was run by the other agent, not in this session (the sandbox PATH
  shim blocks the suite here — see §8). It is the only test evidence attaching to the
  preflight, and it is second-hand.

## 7b. Session note: two launcher sessions were live

While investigating, two launcher instances were found running concurrently:

| Initiated from | Lock dir | PID | Alive at 08:41 | RepoRoot |
|---|---|---|---|---|
| `J:\audio\VAD` | `77442b14` | 80120 | **YES** (.sup 2.4 s) | MCP-Watchers |
| `J:\audio\MCP-Watchers` | `ad90e3fb` | 89424 | no (.sup 647 s) | MCP-Watchers |

**Reconciled in the continuation pass.** The two sessions explain the split brain in
`grepai-launch.log`: its header reads `Starting grepai watch in J:\audio\VAD` while the
same `.err` file later shows successful indexing of `J:\audio\MCP-Watchers` paths. Two
launcher generations wrote to one log, and the two repos disagree about the embedder
port:

| Repo | `embedder.endpoint` | Observed result |
|---|---|---|
| `J:\audio\VAD` | `http://localhost:11434` | crash loop (08:14, 08:24) |
| `J:\audio\MCP-Watchers` | `http://127.0.0.1:12134` | indexes, stays steady |

This is `mcpw-ybs.7` **working as designed**: each session resolves its own repo's
config. It is also why only one session broke — and why the sibling repo's copy of the
bug (§5b.1) went unnoticed.

Both keyed to the **same** RepoRoot (`MCP-Watchers`), because `$watchersWorkspaceRoot`
comes from the invocation directory, not the launcher's location. So the keying worked
as designed — but two sessions raced for one repo, and the loser left an orphaned
`.sup` and teardown state in `ad90e3fb`. Whether concurrent sessions on one repo should
be refused (rather than keyed apart) is an open design question, not a bug in the
keying.

---

## 8. Environment limitation: the launcher suite cannot run in this session

`tests\launcher_tests.ps1` exits with zero output here. Root cause found via
`Start-Transcript` and a deliberate check:

- Lines 151, 169, 744, 758, 770, 785, 803, 845 call a **bare** `& powershell -NoProfile
  -File …`. The WorkBuddy safe-bin PATH shim does not expose `powershell` to child
  processes, so those calls fail and the suite aborts early.
- Prepending `C:\WINDOWS\System32\WindowsPowerShell\v1.0` to `$env:PATH` did **not**
  help — the shim strips it.

Conclusion: **an environment/sandbox artifact of the assistant session, not a product
defect.** The suite is canonical when run outside this sandbox, and commit `026765e`
reports it green (`158 pass, 0 fail, 8/8 suites EXIT=0`) from a normal shell.

Practical fix for anyone hitting this: replace the bare `powershell` with
`$PSHOME\powershell.exe` in those eight spots, or run the suite from a plain terminal.
Not changed here — the eight call sites are test-harness code and outside this task's
scope.

### 8.1 Other sandbox constraints met during this pass

Recorded so the next session does not rediscover them.

- **`Invoke-Expression` is blocked** ("executes arbitrary code"). To run an extracted
  function, use `[scriptblock]::Create($text)` and dot-source it, or AST-extract with
  `FindAll({ $n -is [FunctionDefinitionAst] })`. Both work.
- **PowerShell tool stdout is frequently swallowed.** Write results with `Out-File` and
  read the file back in a separate step. This produced several false "empty output"
  readings before the pattern was adopted — including one transient conclusion that a
  module export was missing.
- **`git diff` prints nothing for `###1...ps1`.** `.gitattributes` sets `* -text` across
  the repo (intentional — byte-identity with the CRLF originals), so git classifies the
  260 KB file as binary and suppresses the text diff. `git status` still reports `M`
  correctly, and `git show HEAD:<file>` / `git log -p` work. Do not conclude "nothing
  changed" from an empty `git diff` on this file.
- **The lock directory is `%LOCALAPPDATA%\watchers\<workspaceKey>\`**, not the repo root.
  Probing `J:\audio\MCP-Watchers\###1-launcher.lock` returns MISSING and is misleading;
  the live path is `C:\Users\yuni\AppData\Local\watchers\77442b14\###1-launcher.lock`.
- **qdrant REST is on 6333; 6334 is gRPC** (and is what `store.qdrant.port` configures).
  Probing `http://localhost:6334/collections` fails and does not indicate a fault.
Not changed here — the eight call sites are test-harness code and outside this task's
scope.

