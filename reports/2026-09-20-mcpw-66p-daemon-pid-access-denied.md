# mcpw-66p — `daemon.pid` "Access is denied (os error 5)" while :50051 is healthy

Date: 2026-09-20 · Branch: mcpw-sweep-20260920-1305 · Read-only investigation
Status: **CANDIDATE (b) ACL REFUTED · CANDIDATE (a) CONFIRMED but re-framed** — the contention is with the *live, legitimate owner*, not with an overlapping start

---

## 1. Live state at probe time (2026-09-20 ~13:10 NZT)

```
PID 43748  memtrace.exe        memtrace.exe start --headless --workspace C:\Users\yuni\.config\memtrace\workspace.toml
PID 62980  memcore-server.exe  ...\memcore-server.exe --bind 127.0.0.1:50051 --data-dir \\?\C:\Users\yuni\.config\memtrace\.memdb --default-db memtrace --vector-dims 768
:50051     Listen 127.0.0.1 PID=62980
```

`C:\Users\yuni\.memdb\daemon-state.json`: `"pid": 43748, "status": "healthy", "loopbackEndpoint": "http://127.0.0.1:50051"`.
`C:\Users\yuni\.memdb\daemon.pid.owner` = `43748`.
`C:\Users\yuni\.memdb` is a **junction** (`ReparsePoint`) → `C:\Users\yuni\.config\memtrace\.memdb`, so the two paths in play are one store.

## 2. Candidate (b) — ACL — **REFUTED**

`daemon.pid` ACL (read directly, 2026-09-20):

```
OWNER = ADMINISTRATOR\yuni
SDDL  = O:S-1-5-21-...-1001 G:S-1-5-21-...-513 D:AI
        (A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;FA;;;...-1001)(A;ID;FA;;;...-1002)
ACE   = NT AUTHORITY\SYSTEM      Allow FullControl inherited=True
        BUILTIN\Administrators   Allow FullControl inherited=True
        ADMINISTRATOR\yuni       Allow FullControl inherited=True
        ADMINISTRATOR\Siwon      Allow FullControl inherited=True
ATTRS = Archive            (not ReadOnly)
```

**FullControl for the caller's own SID, all inherited, no DENY ACE.** A restrictive ACL is not the cause.

## 3. The denial is file-specific, not directory- or token-specific

Probed with `System.IO.File::Open` (raw Win32 code recovered from the inner exception's HRESULT):

| open | result |
|---|---|
| `daemon.pid` **Write**, share=None | **FAIL hresult=0x80070005 win32=5** (`Access to the path ... is denied`) |
| `daemon.pid` **Write**, share=ReadWrite | **FAIL hresult=0x80070005 win32=5** |
| `daemon.pid` **Read**, share=ReadWrite | OK |
| `daemon.pid` **Read**, share=None | FAIL hresult=0x80070020 win32=32 (sharing violation — *my* share mode denies the holder's write access) |
| `daemon.pid.owner` **Write**, share=None | OK |
| `daemon-state.json` **Write**, share=None | OK |
| `sidecars.json` **Write**, share=None | OK |
| brand-new file in the same directory | OK |

So: the directory is writable, the token is fine, sibling files are writable — **only `daemon.pid` refuses a write-open, and it does so with the exact code memtrace reports (`os error 5`).** That is the signature of the daemon's own open handle on the file, not of an ACL, not of a directory permission, and not of my shell's sandbox (a sandbox interception would not surface as a genuine `CreateFile` HRESULT 0x80070005; the harness's own guard emits a distinct `[safe-delete][SAFE_DELETE_BULK_GUARD_ERROR]` marker, which did not appear here).

Independently, `cat` on the same file returns `Device or resource busy`, and the daemon is alive and healthy — consistent with a held handle.

## 4. Re-framing of candidate (a)

Candidate (a) was "genuine lock contention from **overlapping starts**". The evidence supports contention, but **not with an overlapping start**: it is with the daemon that is already running correctly. `memtrace mcp` is attempting to **acquire** the runtime owner lock at a moment when the legitimate owner holds it by design, and surfaces the kernel refusal verbatim as `Access is denied. (os error 5)`.

That is a *message/path* problem, not a lock-leak problem — and it explains the observation in the bead that a shell-driven proxy run attached successfully to the same daemon concurrently: attach can work when the caller takes the *discovery* path (`daemon-state.json` / `sidecars.json` → gRPC) rather than the *acquire* path.

## 5. Evidence still missing

1. **memtrace's own code path** for owner-lock acquisition vs discovery. I could not inspect it (binary at `J:\Programs\npm-global\node_modules\memtrace\node_modules\@memtrace\win32-x64\bin\`), and I did **not** run `memtrace mcp` — the bead records `MEMTRACE_SIDECAR_CRASH_CONTAINMENT=active (Windows kill-on-job-close)`, so a short-lived `memtrace mcp` child can take the shared daemon down. Deliberately avoided.
2. **Why the shell-driven proxy run succeeded.** Without a safe reproduction I cannot say whether the discriminator is (i) acquire-vs-discover, (ii) the resolved `--data-dir` path (`C:\Users\yuni\.memdb` junction vs `\\?\C:\Users\yuni\.config\memtrace\.memdb`), or (iii) something about the spawning job/handle. The junction is a real candidate: `daemon-state.json` records `memdbDataDir` as the `\\?\`-prefixed real path, while callers that pass `C:\Users\yuni\.memdb` reach the same file through a reparse point.
3. **Candidate (c) stale lock from a killed process** — not tested. It predicts a `daemon.pid` whose PID is dead; here `daemon.pid.owner` = 43748 = the live daemon, so it does not apply to the 06:00/06:01 attempts unless the state changed since.

## 6. Cheapest safe discriminating test (not run)

Start a `memtrace` client with `MEMTRACE_SIDECAR_CRASH_CONTAINMENT` unset/disabled (or from a run that is *not* joined to the daemon job) and diff its behaviour against a job-joined run, logging the resolved store path. If the non-joined run acquires cleanly, the discriminator is the job/spawn path, not contention.
