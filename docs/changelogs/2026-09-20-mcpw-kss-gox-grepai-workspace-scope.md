# 2026-09-20 — grepai qdrant store scope: MCP-Watchers clean, VAD misconfigured (mcpw-kss, mcpw-gox, mcpw-25p)

Date: 2026-09-20, ~05:50–06:40 NZT (UTC+12)
Commits: `f9ae82f` (mcpw-25p evidence), `3bc8309` (mcpw-eud + mcpw-0on)
Author: sub-agent `general-purpose-11`

---

## 1. mcpw-25p — the store was never down; `netstat` cannot see Docker ports

Closed. Two separate corrections, both measured on this box:

1. **16334 is qdrant's gRPC port.** `curl http://127.0.0.1:16334/` returning `000`
   is the correct answer for an HTTP/1.1 request against a gRPC listener, not an
   outage. A TCP connect succeeds (`time_connect` 1.2 ms).
2. **`netstat -ano` / `Get-NetTCPConnection -State Listen` report NO
   Docker-published port as LISTENING on this host at all.** Checked against
   16333, 16334, 6333, 6334, 7474, 8002, 8400, 3000 and 6379 — every one of them
   answers, and none of them appears as a host listener. Only native host
   processes (Ollama on `127.0.0.1:12134`) show up. The original report's "no
   LISTENING socket" row was therefore a false negative, not a finding.

Store state: `GET 127.0.0.1:16333/` → `version 1.19.1` (container `qdrant-grepai`,
`qdrant/qdrant:latest`, `16333->6333` / `16334->6334`). **`6333` is
`server-qdrant-1`, image `qdrant/qdrant:v1.11.3`** — repointing grepai there would
have produced the documented silent-write-failure mode against its v1.19.0
client. `store.qdrant.port` stays **16334**.

The ≈2 h 10 m gap the bead was retitled to is real (the whole Docker stack
restarted together — `qdrant-grepai` `StartedAt 2026-09-19T11:19:47Z`, i.e.
23:19:47 NZT, `RestartCount 0`), but its cause is host-side and unknown. Details
and the full probe table are in `CODE_REVIEWS/2026-09-20-grepai-watcher-reap-loop.md`.

---

## 2. mcpw-kss — VAD was falling back to the shared v1.11.3 server

Closed as MCP-Watchers-clean; the fix was applied to the **VAD** workspace.

### Root cause

`J:\audio\VAD\.grepai\config.yaml` did not exist (only
`config.yaml.bak-2026-09-18` and `config.yaml.bak-2026-09-18-181603`). Without a
project config, grepai does not treat `J:\audio\VAD` as an initialized project —
`grepai status --no-ui` in that directory answered `Error: no grepai project
found (run 'grepai init' first)` — and its `grepai watch` fell back to the
machine-level `~/.grepai/workspace.yaml`, whose `vad` workspace sets
`store.qdrant.endpoint http://localhost` / `port: 6334`. Port 6334 is
`server-qdrant-1` (**v1.11.3**), which is where
`WARN Client version is not compatible with server version …
clientVersion=v1.19.0 serverVersion=1.11.3` came from.

MCP-Watchers was never affected: the `ad90e3fb` watcher's
`grepai-launch.log.err` contains **0** occurrences of that warning, while the VAD
watcher's `77442b14` copy contains 1.

### What was changed

`J:\audio\VAD\.grepai\config.yaml` was written as the **newest** backup
(`config.yaml.bak-2026-09-18-181603`) with exactly one edit:

```diff
 store:
     backend: qdrant
     qdrant:
         endpoint: localhost
-        port: 6334
+        port: 16334
```

`diff` against that backup now reports that single line, nothing else.

**Route taken, and why not the literal "minimal file".** The newest backup *does*
point at 6334, so it was not restored blindly. The alternative offered was to
write a minimal config with only the store block. That was rejected because a
minimal file silently changes VAD's behaviour: the backup carries
`rpg.enabled: false`, `embedder.parallelism: 0` and
`llm_endpoint: http://127.0.0.1:12134/v1`, so a minimal file would re-enable RPG
against a 45 k-node graph with grepai's *default* LLM endpoint. Restoring the
backup with only the port corrected is the minimum-delta change and is strictly
closer to VAD's last-known-good state.

The older backup (`config.yaml.bak-2026-09-18`, 08:59) was **not** used: it differs
only in pointing at `http://localhost:11434` / `.../v1`, the wrong Ollama port
(Ollama listens on 12134). The newer backup is the correct one.

### Evidence

| Probe (in `J:\audio\VAD`) | Before | After |
|---|---|---|
| `grepai status --no-ui` | `Error: no grepai project found (run 'grepai init' first)` | `grepai index status` / `Provider: ollama (nomic-embed-text)` |
| `grepai status --no-ui 2>&1 \| grep -c "not compatible with server"` | n/a (no project) | **0** |

`Files indexed: 0` in the after-state is the pre-existing VAD state (its index
was already empty — the old `J__audio_VAD` collection held 0 points), not a
regression. VAD will build its index on its next `grepai watch` start; no VAD
watcher was running at the time of the change (its supervisor reaped itself at
01:01:09 NZT), so nothing had to be restarted and nothing was disturbed.

### Durability — this change cannot be carried by any commit

`git check-ignore -v .grepai/config.yaml` in `J:\audio\VAD` resolves to
`.gitignore:280:.grepai/`, which **overrides** the earlier
`!.grepai/config.yaml` negation at line 82. The file is untracked and ignored, so
**the fix lives on disk only and must be re-applied** after any reset of that
working tree (or after `grepai init` rewrites it). Making it durable needs either
the VAD `.gitignore` line-280 rule relaxed, or the `vad` workspace entry in
`~/.grepai/workspace.yaml` repointed at 16334. Both are outside
`J:\audio\MCP-Watchers`, so neither was done.

**Do not set `SkipCompatibilityCheck`.** Against a v1.11.3 server the version
mismatch is a real silent-write-failure signal, not log noise.

---

## 3. mcpw-gox — the 4-project watch is VAD's, and MCP-Watchers is already scoped

Closed. Mechanism, verified by construction:

**`grepai watch` auto-discovers projects from `git worktree list` of the
directory it is launched in.** `J:\audio\VAD` has exactly four entries
(`VAD`, `gentle-quokka`, `vad-ws-1787995193622-el2lns`,
`vad-ws-1787996511446-yu6kc9`) and the `77442b14` watcher's log lists exactly
those four. `J:\audio\MCP-Watchers` has one entry (`main`) and its `ad90e3fb`
watcher logs exactly one project.

Therefore:

* The three stale scratch worktrees belong to **`J:\audio\VAD`** and are
  registered in *that* repo's git state. They were deliberately **not** pruned:
  removing git worktrees is destructive and out of scope for a bead filed against
  MCP-Watchers.
* MCP-Watchers already prunes before every launch
  (`Invoke-GrepaiWorktreePrune`, mcpw-759) and its last launch reported nothing to
  prune. Its watch is already scoped to the real project, plus any worktree that
  `Test-GitWorktreeUsable` confirms is live — which is exactly this bead's
  acceptance criterion.

### Follow-up for the VAD repo (not actioned here)

VAD's watcher still watches four projects through one process, so a failure on any
scratch worktree takes down indexing for the real repo too. Fixing that means
pruning or re-registering the three VAD worktrees (`git -C J:\audio\VAD worktree
remove <path>` / `worktree prune`), or adding the equivalent of mcpw-759's
`Invoke-GrepaiWorktreePrune` to VAD's `###2.launch_watcher_for_grepai.ps1`. Both
are VAD-side decisions.

---

## 4. Also landed in this pass (details in the commit messages)

* **mcpw-eud** (`3bc8309`) — `Test-GrepaiLockStale` now gates all three sweep
  sites. Measured lock shapes: this grepai build writes `grepai-stop-<pid>` (owner
  PID in the name) to the machine-global `%LOCALAPPDATA%\grepai\logs`;
  `grepai-worktree-*.pid*` carries no project key, so it is removable only when
  its sibling `grepai-worktree-<id>.log` names this project. Unattributable locks
  are left alone.
* **mcpw-0on** (`3bc8309`) — `Get-GrepaiSpawnLogPair` gives attempt 1 the canonical
  `grepai-launch.log`/`.err` (what the pane tailer watches) and every later attempt
  its own `.attempt<N>` pair, at all four respawn sites. Nothing is overwritten.

## 5. Environment note for anyone running the suites

Several Pester suites abort with
`ArgumentException: Item has already been added. Key in dictionary: 'https_proxy'`
when both `https_proxy` and `HTTPS_PROXY` are set. Unset
`HTTP_PROXY`/`HTTPS_PROXY`/`http_proxy`/`https_proxy` before running Pester. With
them unset: `launcher_grepai_ready_timeout` 5/5, `launcher_remediation` 12/12,
`launcher_watcher_panes` 6/6, and pytest 34/34 for
`test_grepai_heal_single_healer`, `test_launcher_job_helpers_dedupe`,
`test_launcher_worktree_quoting`.
