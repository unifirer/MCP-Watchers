# mcpw-jgh — hermes memtrace watchdog retired as redundant and harmful

Date: 2026-09-20
Bead: `mcpw-jgh` (P1, follow-on to `mcpw-l40`)
Component: outside this repo — see paths below

## Summary

The hermes memtrace watchdog was **deleted**, not repaired. `mcpw-l40` fixed
*how* it started memtrace; this bead asks whether it should start memtrace at
all. It should not.

## Which script was actually running

Two hermes directories exist and they are **different**:

| Path | File | Status |
|---|---|---|
| `C:\Users\yuni\AppData\Local\hermes\scripts\` | `memtrace_backend_watchdog.py` | **LIVE** — deleted |
| `C:\Users\yuni\.hermes\scripts\` | `memtrace_watchdog.sh` | dead legacy twin — deleted |

Attribution by log signature in `~/.hermes/logs/memtrace-watchdog.log`:

- `DOWN -> recovering` — **1293** occurrences (emitted only by the `.py`)
- `RECOVERED pid=unknown` — 277 (only the `.py` can produce `unknown`)
- `RECOVERED pid=?` — **1** (the `.sh` uses `${PID:-?}`)

So only the `.py` was scheduled; the `.sh` had run at most once. The `.sh` was
deleted anyway because it is an **unfixed** duplicate — it still launched
`start --headless --bless-workspace` from `J:/audio/VAD` with no `--workspace`,
i.e. exactly the single-member-scope failure `mcpw-l40` removed from the `.py`.

## Why redundant

Three supervisors were managing one union store:

1. this watchdog, every 5 minutes;
2. the launcher's memtrace auto-heal supervisor;
3. `memtrace_mcp_cwd_proxy.py` `start_daemon()`, which starts the daemon **on
   demand** whenever an MCP client actually attaches.

Overlapping starts were already shown to contend for the store-scope lock and
produce `could not acquire runtime owner lock ... daemon.pid: Access is denied
(os error 5)` — see `mcpw-66p`.

## Why harmful, not merely redundant

1. **It probes the wrong port.** `PORT = 3030` (the sidecar HTTP API), not
   `50051` (the MemDB data port). A briefly unresponsive sidecar therefore reads
   as a down backend.
2. **It is destructive on a timer.** On every DOWN it runs `memtrace stop`
   *before* relaunching — against a store shared by **8 repos**.
3. **It was not delivering availability.** 1293 DOWN events logged;
   `RESTART FAILED` as recently as 07:07; both `:50051` and `:3030` were down
   for hours on 2026-09-20.
4. **It leaked processes.** It was the source of the ~46 orphaned `node.exe`
   `memtrace.js start --headless --bless-workspace` processes (reaped during
   `mcpw-l40`).

## What covers availability now

- Consumer-driven start: the Toolport proxy's `start_daemon()` brings the daemon
  up whenever an MCP client needs memtrace. This is how memtrace is actually
  consumed on this box.
- The launcher's auto-heal supervisor, now with a 240 s cold-start grace and
  `-DeferToListening` so it adopts a listening union daemon instead of killing
  it (`mcpw-oft`).

## Not touched

`C:\Users\yuni\AppData\Local\hermes\scripts\memtrace_opencode_watchdog.py` is
**unrelated** — it only removes a `memtrace` key from
`~/.config/opencode/opencode.json` so memtrace is served via Toolport rather
than as a standalone MCP entry. It does not supervise the daemon. Left in place.

## Rollback

Backups (restore by copy):

- `C:\Temp\mcpw-backups\memtrace_backend_watchdog.py.bak-20260920-0715`
- `C:\Temp\mcpw-backups\memtrace_watchdog.sh.bak-20260920-0715`
- `C:\Users\yuni\AppData\Local\hermes\scripts\memtrace_backend_watchdog.py.bak-20260920-0600`
  (pre-existing backup from `mcpw-l40`)

Restoring the `.py` alone reinstates the previous behaviour; the scheduler that
invoked it was not modified, so no schedule change needs reverting.

## Verification

- Both files confirmed absent after deletion.
- Acceptance: `~/.hermes/logs/memtrace-watchdog.log` stops gaining new entries.
