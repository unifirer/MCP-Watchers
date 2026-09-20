# mcpw-127 — host cause of the 2026-09-19T11:19:47Z Docker stack restart

Date: 2026-09-20 · Branch: mcpw-sweep-20260920-1305 · Read-only investigation
Status: **HOST CAUSE ESTABLISHED** — a clean, user-initiated **Windows host reboot**; the "stack restart" is Docker Desktop starting the compose stack ~9 min after boot

---

## 1. Restatement of the symptom (re-verified 2026-09-20 06:40 NZT)

```
qdrant-grepai          2026-09-19T11:19:47.019178392Z  restarts=0  status=running
server-qdrant-1        2026-09-19T11:19:47.03646424Z   restarts=0  status=running
graphiti-mcp           2026-09-19T11:19:47.040063722Z  restarts=0  status=running
```

25 ms spread, all `RestartCount=0`, `docker logs qdrant-grepai` has exactly **2** startup banners (`Version: 1.19.1, build: 6ab21cac`) at `2026-09-18T14:22:25Z` and `2026-09-19T11:19:48.846Z`.

## 2. Windows Event Log — the host rebooted

Query window 2026-09-19 23:00–23:45 **local NZT** (= 11:00–11:45Z). Quoted verbatim, local timestamps:

```
2026-09-19T23:08:16.666 | User32 | 1074 | The process C:\Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe (ADMINISTRATOR) has initiated the restart of computer ADMINISTRATOR on behalf of user ADMINISTRATOR\yu...

2026-09-19T23:08:25.781 | winsrvext | 100 | Process C:\Program Files\Everything\Everything.exe is delaying system shutdown after 5781 milliseconds.

2026-09-19T23:08:45.662 | Microsoft-Windows-Kernel-Power | 109 | The kernel power manager has initiated a shutdown transition.  Action: Power Action Reboot  Event Code: 0x0  Reason: Kernel API

2026-09-19T23:08:49.944 | Microsoft-Windows-Kernel-Power | 577 | The system has prepared for a system initiated reboot from Active.

2026-09-19T23:08:50.191 | Microsoft-Windows-Kernel-General | 13 | The operating system is shutting down at system time 2026-09-19T11:08:50.191732500Z.

2026-09-19T23:10:48.806 | Microsoft-Windows-Kernel-General | 12 | The operating system started at system time 2026-09-19T11:10:48.500000000Z.

2026-09-19T23:10:48.807 | Microsoft-Windows-Kernel-Boot | 20 | The last shutdown's success status was true. The last boot's success status was true.
```

And a second, servicing-initiated request recorded just after the boot:

```
2026-09-19T23:12:22.143 | User32 | 1074 | The process C:\WINDOWS\servicing\TrustedInstaller.exe (ADMINISTRATOR) has initiated the restart of computer ADMINISTRATOR on behalf of user NT AUTHORITY\SYSTEM for the following reason: Operating System: Upgrade (Planned)...
```

Timeline (UTC):

| time (UTC) | event |
|---|---|
| 11:08:16.666 | restart initiated — Start-menu, user `ADMINISTRATOR\yuni` |
| 11:08:45.662 | Kernel-Power 109, `Power Action Reboot` |
| 11:08:50.191 | OS shutdown (Kernel-General 13) |
| 11:10:48.500 | OS started (Kernel-General 12) — 1 m 58 s later |
| **11:19:47.019–.040** | **all containers StartedAt, RestartCount=0** |
| 11:19:48.846 | qdrant-grepai 2nd banner |

## 3. What this rules in and out

- **Clean shutdown, not a crash.** `Kernel-Boot 20` reports `The last shutdown's success status was true`; there is **no** `Kernel-Power 41`, no `BugCheck`, no `EventLog 6008` (unexpected shutdown) anywhere in the window.
- **Not an app-level restart.** A 25 ms spread with `rc=0` and `RestartCount=0` means the containers were *started* by a fresh engine, not restarted by the Docker daemon after a failure. The engine came back because the **host** came back.
- **Not Windows Update alone.** The primary trigger is the Start-menu restart (User32 1074 at 11:08:16Z); the TrustedInstaller `Operating System: Upgrade (Planned)` 1074 at 11:12:22Z is recorded *after* the boot, i.e. servicing activity, not the trigger for the 11:08 shutdown.
- **Not disk/memory.** The window contains only benign storage noise: `Microsoft-Windows-Ntfs 98 "Volume C: ... is healthy"`, and three `disk 158` duplicate-identifier notices at 23:10:50 — none of which stop anything.
- The 8 m 59 s gap between boot (11:10:48Z) and containers (11:19:47Z) is Docker Desktop's own autostart/engine-init time.

## 4. Evidence still missing

1. **Docker Desktop's own logs do not cover 11:19Z.** `C:\Users\yuni\AppData\Local\Docker\log\host\com.docker.backend.exe.log` has been rotated; its earliest entries are `2026-09-19T20:34Z`, and `log/vm/init.log` starts at `18:40Z`. So the engine-start moment itself is **inferred** from `StartedAt` + `RestartCount=0`, not directly logged. `log/vm/dockerd.log` likewise starts `2026/09/20 00:30`.
2. **No explicit `com.docker.service` start event** appears in System/Application in the window (the log query returned zero Docker/WSL/vmcompute mentions) — expected if the service starts before the event-log service is fully capturing, but it means the chain `boot → Docker Desktop → compose up` is not evidenced step-by-step from the host side.
3. **Whether the update was actually installed.** The `TrustedInstaller` 1074 names `Operating System: Upgrade (Planned)`; I did not enumerate the CBS/WindowsUpdate logs to confirm which KB landed. Not needed for this bead's question (what restarted the stack) but it is the one open thread.
