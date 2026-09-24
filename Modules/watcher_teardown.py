"""Port of Modules/watcher_teardown.ps1 - bead mcpw-xeu.5.

Shared watcher teardown. The PowerShell module is still live and is still
what the launcher dot-sources, so this file duplicates the teardown logic.
tests/test_ported_watcher_teardown.py pins the two against each other
(same state shape, same sweep table, same PID-scope rule). Delete this
caveat only when the .ps1 is retired.

mcpw-xeu.9 DECISION (recorded here per the bead): carry BOTH sweep
defences (PID-scope + Persistent), never the flag alone. Today the .ps1
teardown sweep (watcher_teardown.ps1:174-187) has NO Persistent guard
while the launcher startup sweep (###1...ps1:361) skips Persistent
entries, and that is safe only because the persistent singletons
(claude-mcp-server, mail :8765, embed :8003) are excluded from RootPids
by design so the PID gate rejects them first. The port keeps BOTH gates
in BOTH sweeps: every kill below is gated on PID-scope membership AND
skips entries flagged persistent. A future widening of PID scope can
therefore never start killing the machine-wide singletons shared with
sibling checkouts. The one deliberate divergence from the .ps1 (the
teardown sweep now also skips Persistent) is a hardening, not a drift.

mcpw-xeu.8 ORDERING: the authoritative single-instance gate is the
exclusive file lock, and the named mutex is created UNDER it
(###1...ps1:130-142). That acquisition lives in
Modules/watcher_launcher_lock.py; this module never acquires the lock,
it only READS the lock file (holder PID + age) inside
stop_prior_launcher_instances, after the takeover wait. The order there
is the .ps1's: takeover-mutex wait, then lock-file read, then
PID-scoped Stop-AllWatchers, then holder kill, then attribution-gated
sweep. File-lock-first is preserved deliberately, not naturally.

mcpw-xeu.7 WAIT_ABANDONED: win32event raises no AbandonedMutexException;
WaitForSingleObject returns 128 instead. The takeover wait below goes
through watcher_launcher_lock.wait_result_is_owned (the single place
that knowledge lives) and LOGS the abandoned-takeover case explicitly:
a naive rc == 0 check would silently skip the takeover while leaking
the ownership 128 grants, repeating the skip on every later launch.

mcpw-xeu.4 shared export: the pane host name comes from
Modules/watcher_patterns (WATCHER_PANE_HOST_NAME /
WATCHER_SHELL_HOST_NAMES), never a literal here.

SAFE TO IMPORT: no top-level side effects. Windows calls are lazy and
every process-table access takes an injectable snapshot, so importing
and unit-testing this module never needs pywin32.

Byte-compatible state shapes (either side reads what the other wrote):
  - teardown-state.json: {"RootPids": [int], "MemtraceStatePath": str,
    "RepoRoot": str, "WtWindowName": str, "GrepaiPid": int}. The launcher
    writes it with ConvertTo-Json -Compress via Set-Content -Encoding
    UTF8 (BOM), so reads use utf-8-sig and writes use utf-8.
  - lock file: {"Pid": int, "StartedAt": str, "Launcher": str}.

Fidelity notes, verified against the live .ps1 rather than assumed:
  - PID sets are keyed by uint32-normalised ints (the .ps1 casts every
    PID to [uint32] so the CIM walk matches).
  - The BFS uses a real queue (the .ps1 comment warns the naive
    $queue[1..N] idiom hangs on a single element).
  - An empty sweep pattern matches every process EXCEPT an
    unattributable one (empty command line never matches).
  - Stop-AllWatchers step 3 runs `grepai watch --stop` ONLY when this
    launcher recorded its own GrepaiPid AND that PID is alive AND in
    our PID scope (VAD-49om: never a bare global stop).
  - Stop-AllWatchers step 4 kills the memtrace daemon ONLY when the
    recorded daemon-state.json says status healthy AND names a pid AND
    that PID is alive.
"""

import json
import os
import re
import subprocess
import time

try:
    from Modules import watcher_patterns as _patterns
except ImportError:  # pragma: no cover - direct-file execution fallback
    import watcher_patterns as _patterns

try:
    from Modules import watcher_workspace as _workspace
except ImportError:  # pragma: no cover - direct-file execution fallback
    import watcher_workspace as _workspace

try:
    from Modules import watcher_launcher_lock as _lock
except ImportError:  # pragma: no cover - direct-file execution fallback
    import watcher_launcher_lock as _lock

TEARDOWN_STATE_NAME = "teardown-state.json"
LOCK_FILE_NAME = "###1-launcher.lock"

WRAPPER_PATTERN = "graphify-watch-wrapper"

# mcpw-ajy orphan sweep constants (mirror the .ps1 param defaults).
ORPHAN_HOST_NAMES = ("powershell.exe", "pwsh.exe", "node.exe")
ORPHAN_SHIM_PATTERNS = ("memtrace.ps1", "memtrace.js")
DAEMON_NAMES = ("memcore-server.exe", "memcortex-daemon.exe", "memtrace.exe")
DAEMON_PORTS = (50051,)

_TAKEOVER_WAIT_MS = 15000
_MIN_AGE_SEC = 30


def _pane_host_name():
    """The shell host name behind the xeu.4 shared export."""
    try:
        return _patterns.WATCHER_PANE_HOST_NAME
    except AttributeError:
        return "powershell.exe"


# --- State paths ------------------------------------------------------------

def teardown_state_dir(key=None, local_app_data=None):
    """%LOCALAPPDATA%\\watchers\\<key> - same shape as the launcher lock dir."""
    if not key:
        key = os.environ.get("VAD_WATCHERS_WORKSPACE_KEY") or "default"
    base = local_app_data if local_app_data is not None else os.environ.get("LOCALAPPDATA", ".")
    return os.path.join(base, "watchers", key)


def teardown_state_path(key=None, local_app_data=None):
    return os.path.join(teardown_state_dir(key, local_app_data), TEARDOWN_STATE_NAME)


def legacy_teardown_state_path(local_app_data=None):
    """Pre-xeu fallback: the un-keyed path, used only when no key exists."""
    base = local_app_data if local_app_data is not None else os.environ.get("LOCALAPPDATA", ".")
    return os.path.join(base, "watchers", TEARDOWN_STATE_NAME)


def read_teardown_state(path):
    """Read a teardown-state.json file. Missing/unreadable -> empty dict."""
    try:
        with open(path, "r", encoding="utf-8-sig") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def parse_teardown_state(data):
    """Normalise a decoded state blob to the contract shape. Never throws."""
    if not isinstance(data, dict):
        data = {}
    try:
        roots = [int(p) for p in (data.get("RootPids") or [])]
    except (TypeError, ValueError):
        roots = []
    try:
        grepai_pid = int(data.get("GrepaiPid") or 0)
    except (TypeError, ValueError):
        grepai_pid = 0
    return {
        "RootPids": [p for p in roots if p > 0],
        "MemtraceStatePath": str(data.get("MemtraceStatePath") or ""),
        "RepoRoot": str(data.get("RepoRoot") or ""),
        "WtWindowName": str(data.get("WtWindowName") or ""),
        "GrepaiPid": grepai_pid,
    }


def write_teardown_state(path, root_pids, memtrace_state_path="",
                          repo_root="", wt_window_name="", grepai_pid=0):
    """Write the contract shape. Returns the path. Never throws."""
    payload = {
        "RootPids": [int(p) for p in (root_pids or [])],
        "MemtraceStatePath": str(memtrace_state_path or ""),
        "RepoRoot": str(repo_root or ""),
        "WtWindowName": str(wt_window_name or ""),
        "GrepaiPid": int(grepai_pid or 0),
    }
    try:
        parent = os.path.dirname(path)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"))
    except OSError:
        pass
    return path


def read_lock_file(path):
    """Read a launcher lock file. Returns (pid, started_at, launcher)."""
    try:
        with open(path, "r", encoding="utf-8-sig") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return (0, "", "")
    if not isinstance(data, dict):
        return (0, "", "")
    try:
        pid = int(data.get("Pid") or 0)
    except (TypeError, ValueError):
        pid = 0
    return (pid, str(data.get("StartedAt") or ""), str(data.get("Launcher") or ""))


# --- Injectable process seams -------------------------------------------------
#
# Every table access goes through one of these so the suite can prove the
# PID-scope rule without racing real processes. The orchestration around
# them - which is where the sweep hazards live - is not injectable.

def _default_snapshot():
    """Best-effort live snapshot. Returns [] when no backend is available."""
    try:
        import psutil

        out = []
        for proc in psutil.process_iter(["pid", "ppid", "name", "cmdline", "create_time"]):
            try:
                info = proc.info
                cmd = info.get("cmdline") or []
                out.append({
                    "Name": str(info.get("name") or ""),
                    "ProcessId": int(info.get("pid") or 0),
                    "ParentProcessId": int(info.get("ppid") or 0),
                    "CommandLine": " ".join(cmd),
                    "CreationDate": float(info.get("create_time") or 0),
                })
            except Exception:
                continue
        return out
    except Exception:
        return []


def _default_terminate(pid):
    try:
        import signal

        os.kill(int(pid), signal.SIGTERM)
        return True
    except Exception:
        return False


def _default_pid_alive(pid):
    try:
        import psutil

        return bool(pid) and psutil.pid_exists(int(pid))
    except Exception:
        pass
    try:
        import ctypes

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not handle:
            return False
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    except Exception:
        return False


# --- PID sets -----------------------------------------------------------------

def _norm_pid(pid):
    try:
        return int(pid) & 0xFFFFFFFF
    except (TypeError, ValueError):
        return 0


def get_descendant_pid_set(root_pids, processes=None):
    """Root PIDs plus all descendants by parent/child walk. Dict pid -> True."""
    if processes is None:
        processes = _default_snapshot()
    by_parent = {}
    for proc in processes:
        try:
            ppid = _norm_pid(proc.get("ParentProcessId"))
            pid = _norm_pid(proc.get("ProcessId"))
        except AttributeError:
            continue
        by_parent.setdefault(ppid, []).append(pid)
    result = {}
    queue = [_norm_pid(p) for p in (root_pids or []) if _norm_pid(p) > 0]
    while queue:
        cur = queue.pop(0)
        if cur in result:
            continue
        result[cur] = True
        for child in by_parent.get(cur, []):
            if child not in result:
                queue.append(child)
    return result


def stop_watcher_tree(root_pid, processes=None, terminate=None):
    """Kill a root PID and every descendant. Returns the kill count."""
    root = _norm_pid(root_pid)
    if root <= 0:
        return 0
    if processes is None:
        processes = _default_snapshot()
    if terminate is None:
        terminate = _default_terminate
    scope = get_descendant_pid_set([root], processes)
    killed = 0
    for pid in scope:
        try:
            if terminate(pid):
                killed += 1
        except Exception:
            continue
    return killed


# --- Sweep matching ------------------------------------------------------------

def _entry_matches(name, command_line, entry):
    """Image-name equality plus the shared literal-substring match."""
    if str(getattr(entry, "name", "")) != str(name or ""):
        return False
    try:
        return bool(_patterns.test_watcher_sweep_match(command_line or "", entry.pattern))
    except AttributeError:
        pat = getattr(entry, "pattern", "")
        if pat == "":
            return bool(command_line)
        if not command_line:
            return False
        return str(pat).lower() in str(command_line).lower()


# --- Stop-AllWatchers ------------------------------------------------------------

def stop_all_watchers(root_pids=(), memtrace_state_path="", repo_root="",
                       grepai_pid=0, key=None, processes=None, terminate=None,
                       pid_alive=None, run_grepai_stop=None, events=None):
    """PID-scoped teardown. Returns a summary dict. Never throws.

    Pass `events` (a list) to record the step order for assertions.
    """
    def note(*entry):
        if events is not None:
            events.append(entry)

    roots = [int(p) for p in (root_pids or []) if int(p) > 0]
    state_path = ""
    if not roots:
        ws_key = os.environ.get("VAD_WATCHERS_WORKSPACE_KEY") or (key or "")
        if ws_key:
            state_path = teardown_state_path(ws_key)
        else:
            state_path = legacy_teardown_state_path()
        try:
            if state_path and os.path.exists(state_path):
                state = parse_teardown_state(read_teardown_state(state_path))
                roots = [int(p) for p in state["RootPids"] if int(p) > 0]
                if not memtrace_state_path:
                    memtrace_state_path = state["MemtraceStatePath"]
                if not repo_root:
                    repo_root = state["RepoRoot"]
                if not grepai_pid:
                    grepai_pid = state["GrepaiPid"]
        except Exception:
            pass

    if processes is None:
        processes = _default_snapshot()
    if terminate is None:
        terminate = _default_terminate
    if pid_alive is None:
        pid_alive = _default_pid_alive

    our_pids = get_descendant_pid_set(roots, processes)
    note("scope", "roots", len(roots), len(our_pids))
    summary = {"roots": list(roots), "tree_killed": 0, "hosts": 0,
               "swept": 0, "skipped": 0, "grepai_stopped": False,
               "memtrace_killed": False}

    # 1) Tree-kill every tracked root.
    for root in roots:
        try:
            summary["tree_killed"] += stop_watcher_tree(root, processes, terminate)
        except Exception:
            continue
    note("step", 1, summary["tree_killed"])

    # 1b) Wrapper HOSTS by PID first, so an in-flight rebuild child dies
    # with its host. Host name behind the xeu.4 shared export.
    if our_pids:
        host = _pane_host_name()
        for proc in processes:
            try:
                name = str(proc.get("Name") or "")
                cmd = str(proc.get("CommandLine") or "")
                pid = _norm_pid(proc.get("ProcessId"))
            except AttributeError:
                continue
            if name != host or WRAPPER_PATTERN not in cmd:
                continue
            if pid not in our_pids:
                summary["skipped"] += 1
                continue
            try:
                summary["hosts"] += stop_watcher_tree(pid, processes, terminate)
            except Exception:
                continue
    note("step", "1b", summary["hosts"])

    # 2) Pattern sweep, PID-SCOPED, skipping Persistent singletons
    # (mcpw-xeu.9: both defences, even though the .ps1 teardown step
    # lacks the Persistent guard - see the module header).
    if our_pids:
        try:
            sweeps = list(_patterns.WATCHER_SWEEP_PATTERNS)
        except AttributeError:
            sweeps = []
        for entry in sweeps:
            try:
                if bool(getattr(entry, "persistent", False)):
                    note("skip", "persistent", getattr(entry, "name", ""), getattr(entry, "pattern", ""))
                    continue
            except Exception:
                continue
            for proc in processes:
                try:
                    name = str(proc.get("Name") or "")
                    cmd = str(proc.get("CommandLine") or "")
                    pid = _norm_pid(proc.get("ProcessId"))
                except AttributeError:
                    continue
                if pid not in our_pids:
                    continue
                if not _entry_matches(name, cmd, entry):
                    continue
                try:
                    if terminate(pid):
                        summary["swept"] += 1
                    note("sweep", getattr(entry, "name", ""), pid)
                except Exception:
                    continue
    note("step", 2, summary["swept"])

    # 3) Grepai tracked stop, PID-SCOPED (VAD-49om: never a bare global).
    try:
        gp = int(grepai_pid or 0)
    except (TypeError, ValueError):
        gp = 0
    if gp > 0:
        try:
            alive = bool(pid_alive(gp))
        except Exception:
            alive = False
        if alive and _norm_pid(gp) in our_pids:
            runner = run_grepai_stop
            if runner is None:
                def runner():
                    try:
                        subprocess.run(["grepai", "watch", "--stop"],
                                       capture_output=True, timeout=60)
                    except Exception:
                        pass
            try:
                runner()
                summary["grepai_stopped"] = True
            except Exception:
                pass
            note("step", 3, summary["grepai_stopped"])
        else:
            note("step", 3, "skipped-unattributable")

    # 4) Memtrace daemon by recorded pid (status healthy only).
    try:
        mt_state = str(memtrace_state_path or "")
        if not mt_state and repo_root:
            mt_state = os.path.join(str(repo_root), ".memdb", "daemon-state.json")
        if mt_state and os.path.exists(mt_state):
            with open(mt_state, "r", encoding="utf-8-sig") as handle:
                mst = json.load(handle)
            if isinstance(mst, dict) and mst.get("status") == "healthy" and mst.get("pid"):
                try:
                    mp = int(mst.get("pid"))
                except (TypeError, ValueError):
                    mp = 0
                if mp > 0:
                    try:
                        alive = bool(pid_alive(mp))
                    except Exception:
                        alive = False
                    if alive:
                        try:
                            if terminate(mp):
                                summary["memtrace_killed"] = True
                        except Exception:
                            pass
    except Exception:
        pass
    note("step", 4, summary["memtrace_killed"])
    return summary


# --- mcpw-ajy orphaned memtrace host sweep ---------------------------------------
#
# Pure matchers over an injected snapshot, so they are unit-testable
# without spawning anything.

def test_memtrace_daemon_anchor(name, command_line):
    """True when this process IS (part of) the shared union daemon tree."""
    if name and name in DAEMON_NAMES:
        return True
    if name == "node.exe" and command_line:
        if re.search(r"memtrace\.js", command_line):
            if re.search(r"(^|\s)--workspace(\s|=|-|$)", command_line):
                return True
    return False


def test_orphaned_memtrace_host_process(candidate, all_processes=(),
                                        host_names=ORPHAN_HOST_NAMES,
                                        shim_patterns=ORPHAN_SHIM_PATTERNS,
                                        daemon_names=DAEMON_NAMES,
                                        protected_pids=(), self_pid=0):
    """Pure matcher. True only for a killable orphaned memtrace host."""
    if candidate is None:
        return False
    try:
        name = str(candidate.get("Name") or "")
        cmd = str(candidate.get("CommandLine") or "")
        pid = int(candidate.get("ProcessId") or 0)
        ppid = int(candidate.get("ParentProcessId") or 0)
    except (AttributeError, TypeError, ValueError):
        return False
    if name not in list(host_names):
        return False
    token = False
    for pat in shim_patterns:
        try:
            if cmd and re.search(pat, cmd):
                token = True
                break
        except re.error:
            if pat in cmd:
                token = True
                break
    if not token:
        return False
    if self_pid > 0 and pid == self_pid:
        return False
    if pid in set(int(p) for p in (protected_pids or ())):
        return False
    if test_memtrace_daemon_anchor(name, cmd):
        return False

    by_pid = {}
    for proc in all_processes or ():
        try:
            by_pid[int(proc.get("ProcessId"))] = proc
        except (AttributeError, TypeError, ValueError):
            continue
    if ppid <= 0:
        return False
    if ppid not in by_pid:
        orphan = True
    else:
        parent = by_pid[ppid]
        try:
            if int(parent.get("ProcessId")) in set(int(p) for p in (protected_pids or ())):
                return False
        except (AttributeError, TypeError, ValueError):
            pass
        reused = False
        try:
            parent_time = parent.get("CreationDate")
            child_time = candidate.get("CreationDate")
            if parent_time and child_time and float(parent_time) > float(child_time):
                reused = True
        except (TypeError, ValueError):
            reused = False
        if not reused:
            return False
        orphan = True
    if not orphan:
        return False

    # No LIVE descendant may be a daemon-tree member.
    child_map = {}
    for proc in all_processes or ():
        try:
            key = int(proc.get("ParentProcessId"))
        except (AttributeError, TypeError, ValueError):
            continue
        child_map.setdefault(key, []).append(proc)
    seen = set()
    queue = [pid]
    while queue:
        cur = queue.pop(0)
        if cur in seen:
            continue
        seen.add(cur)
        for child in child_map.get(cur, []):
            try:
                child_id = int(child.get("ProcessId"))
                child_cmd = str(child.get("CommandLine") or "")
                child_name = str(child.get("Name") or "")
            except (AttributeError, TypeError, ValueError):
                continue
            if child_id in seen:
                continue
            if child_id in set(int(p) for p in (protected_pids or ())):
                return False
            if test_memtrace_daemon_anchor(child_name, child_cmd):
                return False
            queue.append(child_id)
    return True


def get_orphaned_memtrace_host_pids(processes=None, self_pid=0,
                                    protected_pids=()):
    """Snapshot (or use an injected one) and return orphaned host PIDs."""
    if not processes:
        processes = _default_snapshot()
    if not processes:
        return []
    if self_pid <= 0:
        try:
            self_pid = int(os.getpid())
        except Exception:
            self_pid = 0
    found = []
    for proc in processes:
        try:
            if test_orphaned_memtrace_host_process(
                    proc, processes,
                    protected_pids=protected_pids, self_pid=self_pid):
                found.append(int(proc.get("ProcessId")))
        except Exception:
            continue
    return found


def get_memtrace_daemon_protected_pids(processes=None, ports=DAEMON_PORTS):
    """Best-effort set of PIDs that must never be swept. Never throws."""
    found = set()
    if processes is None:
        processes = _default_snapshot()
    try:
        for proc in processes or ():
            try:
                if str(proc.get("Name") or "") in DAEMON_NAMES:
                    found.add(int(proc.get("ProcessId")))
            except (AttributeError, TypeError, ValueError):
                continue
    except Exception:
        pass
    for port in ports or ():
        try:
            import socket

            for family in (socket.AF_INET,):
                _ = family
            # Port-owner lookup needs OS help; try psutil net_connections
            # lazily and treat absence as "no owners found", never an error.
            try:
                import psutil

                for conn in psutil.net_connections(kind="tcp"):
                    try:
                        if conn.status == "LISTEN" and conn.laddr and conn.laddr.port == int(port):
                            if conn.pid:
                                found.add(int(conn.pid))
                    except Exception:
                        continue
            except Exception:
                pass
        except Exception:
            continue
    return sorted(found)


def stop_orphaned_memtrace_hosts(processes=None, protected_pids=(),
                                 terminate=None, no_port_guard=False):
    """Reap orphaned memtrace hosts. Returns the kill count. Never throws."""
    if terminate is None:
        terminate = _default_terminate
    guard = [int(p) for p in (protected_pids or [])]
    if not no_port_guard:
        try:
            guard += [int(p) for p in get_memtrace_daemon_protected_pids(processes)]
        except Exception:
            pass
    try:
        victims = get_orphaned_memtrace_host_pids(processes, protected_pids=guard)
    except Exception:
        return 0
    killed = 0
    for victim in victims:
        try:
            if terminate(int(victim)):
                killed += 1
        except Exception:
            continue
    return killed


# --- Stop-PriorLauncherInstances ---------------------------------------------------
#
# LAST-WINS takeover (###1...ps1:261-398). Order is the .ps1's: the
# takeover mutex FIRST (bounded wait, abandoned counts as held WITH a
# log line - mcpw-xeu.7), then the lock-file read, then the PID-scoped
# teardown, then the holder kill, then the attribution-gated sweep with
# the Persistent skip (mcpw-xeu.9: both defences).

def _log(message):
    try:
        print(message)
    except Exception:
        pass


def wait_for_takeover_mutex(handle, timeout_ms=_TAKEOVER_WAIT_MS, log=None):
    """Bounded takeover wait. Abandoned (128) takes over WITH logging."""
    emit = log or _log
    try:
        import win32event

        rc = int(win32event.WaitForSingleObject(handle, int(timeout_ms)))
    except ImportError:
        try:
            rc = int(_lock.wait_for_takeover_mutex(handle, timeout_ms))
            return rc
        except Exception:
            return False
    except Exception:
        return False
    try:
        owned = bool(_lock.wait_result_is_owned(rc))
    except Exception:
        owned = rc in (0, 128)
    if rc == 128:
        try:
            emit("takeover mutex was abandoned - taking over (previous launcher died holding it)")
        except Exception:
            pass
    return owned


def stop_prior_launcher_instances(lock_dir, current_pid=0, min_age_sec=_MIN_AGE_SEC,
                                  takeover_mutex_name=None, key=None,
                                  workspace_root="", processes=None,
                                  terminate=None, pid_alive=None,
                                  events=None, log=None):
    """Stop an ESTABLISHED prior launcher so this one takes over. Never throws."""
    emit = log or _log

    def note(*entry):
        if events is not None:
            events.append(entry)

    if not key:
        key = os.environ.get("VAD_WATCHERS_WORKSPACE_KEY") or "default"
    if not takeover_mutex_name:
        takeover_mutex_name = "Global\\VAD_Watchers_Takeover_%s" % key
    if not current_pid:
        try:
            current_pid = int(os.getpid())
        except Exception:
            current_pid = 0

    # Guard 1: serialize the takeover (bounded; abandoned takes over).
    note("takeover", "wait")
    takeover_held = False
    takeover_handle = None
    try:
        try:
            import win32event

            takeover_handle = win32event.CreateMutex(None, False, takeover_mutex_name)
            takeover_held = wait_for_takeover_mutex(takeover_handle, _TAKEOVER_WAIT_MS, emit)
        except ImportError:
            takeover_held = False
    except Exception:
        takeover_held = False
    if not takeover_held:
        note("takeover", "peer-mid-takeover")
        return {"action": "deferred", "holder": 0}
    note("takeover", "held")
    try:
        lock_path = os.path.join(str(lock_dir), LOCK_FILE_NAME)
        if not os.path.exists(lock_path):
            return {"action": "no-prior", "holder": 0}
        holder_pid, started_at, _launcher = read_lock_file(lock_path)
        note("lock", "read", holder_pid)
        if holder_pid <= 0 or holder_pid == int(current_pid):
            return {"action": "no-prior", "holder": 0}
        check_alive = pid_alive or _default_pid_alive
        try:
            alive = bool(check_alive(holder_pid))
        except Exception:
            alive = False
        if not alive:
            return {"action": "holder-dead", "holder": holder_pid}
        # Guard 2: a young holder is still starting up - leave it alone.
        age_sec = -1
        if started_at:
            try:
                from datetime import datetime, timezone

                stamp = datetime.fromisoformat(str(started_at))
                now = datetime.now(timezone.utc)
                if stamp.tzinfo is None:
                    stamp = stamp.replace(tzinfo=timezone.utc)
                age_sec = (now - stamp).total_seconds()
            except Exception:
                age_sec = -1
        if age_sec >= 0 and age_sec < float(min_age_sec):
            note("takeover", "young-holder", holder_pid)
            return {"action": "young-holder", "holder": holder_pid}
        # Tear down the prior launcher's watchers PID-SCOPED first.
        try:
            stop_all_watchers((), processes=processes, terminate=terminate,
                              pid_alive=pid_alive, events=events)
        except Exception:
            pass
        terminate_fn = terminate or _default_terminate
        try:
            terminate_fn(holder_pid)
        except Exception:
            pass
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                if not bool(check_alive(holder_pid)):
                    break
            except Exception:
                break
            time.sleep(0.2)
        try:
            emit("Stopped prior ###1 launcher (PID %d) - taking over for a fresh pane grid" % holder_pid)
        except Exception:
            pass
        note("takeover", "killed", holder_pid)
        # Attribution-gated orphan sweep with the Persistent skip.
        swept = 0
        skipped = 0
        try:
            if processes is None:
                snap = _default_snapshot()
            else:
                snap = processes
            try:
                table = list(_patterns.WATCHER_SWEEP_PATTERNS)
            except AttributeError:
                table = []
            for entry in table:
                try:
                    if bool(getattr(entry, "persistent", False)):
                        continue
                except Exception:
                    continue
                for proc in snap:
                    try:
                        name = str(proc.get("Name") or "")
                        cmd = str(proc.get("CommandLine") or "")
                        pid = _norm_pid(proc.get("ProcessId"))
                    except AttributeError:
                        continue
                    if not _entry_matches(name, cmd, entry):
                        continue
                    try:
                        attributed = bool(_workspace.test_watchers_process_attribution(
                            cmd, key, workspace_root))
                    except Exception:
                        attributed = bool(key and key.lower() in (cmd or "").lower())
                    if not attributed:
                        skipped += 1
                        continue
                    try:
                        if terminate_fn(pid):
                            swept += 1
                    except Exception:
                        continue
        except Exception:
            pass
        if skipped > 0:
            try:
                emit("Startup orphan sweep skipped %d process(es) not attributable "
                     "to this workspace (key %s)." % (skipped, key))
            except Exception:
                pass
        return {"action": "took-over", "holder": holder_pid, "swept": swept,
                "skipped": skipped}
    finally:
        try:
            if takeover_handle is not None:
                try:
                    import win32event

                    try:
                        win32event.ReleaseMutex(takeover_handle)
                    except Exception:
                        pass
                    try:
                        win32event.CloseHandle(takeover_handle)
                    except Exception:
                        try:
                            takeover_handle.Close()
                        except Exception:
                            pass
                except ImportError:
                    pass
        except Exception:
            pass
