"""Port of Modules/watcher_job_helpers.ps1 - bead mcpw-xeu.5.

Single source of truth for the shared job-scope helpers used by the
launcher and its supervisor runspaces. The PowerShell module is still
live and is still what every job scriptblock dot-sources, so this file
duplicates the helper logic. tests/test_ported_watcher_job_helpers.py
pins the two against each other (same names, same pure-function
vectors). Delete this caveat only when the .ps1 is retired.

WHY THIS MODULE EXISTS (VAD-v14z.5): Start-ThreadJob and Start-Job run
their scriptblocks in a FRESH runspace that does NOT inherit the
launcher's functions. One canonical body per helper removes that drift
class; the Python port keeps one canonical body per helper here.

mcpw-xeu.4 shared export: no host literal is redefined here. Where a
helper needs the pane host it consumes watcher_patterns; the grepai
supervisor names below stay literal process-image matches, exactly as
in the .ps1.

STDLIB ONLY: every Windows call is lazy (ctypes / psutil probed inside
the function, never imported at top level) and every process-table or
filesystem access takes an injectable seam, so importing this module
and running the pure tests never needs anything beyond the stdlib.
The parent-death job object is built with ctypes (kernel32) directly -
the stdlib equivalent of the .ps1's Add-Type C# P/Invoke holding
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. No pywin32 is required.

SAFE TO IMPORT: no top-level side effects.

Fidelity notes, verified against the live .ps1 rather than assumed:
  - Test-GrepaiLockStale leaves unrecognised shapes alone (False).
  - Get-GrepaiSpawnLogPair keeps attempt 1 on the canonical pair.
  - Resolve-GrepaiPaneLog prefers a FRESH worktree log, else the newer
    of the two files, else the launcher log (never a stale log over a
    live one). Freshness default 10 min matches the launcher probe.
  - Test-GrepaiWatcherProcess needs name grepai(.exe) AND a whole-arg
    `watch` token (a recycled PID fails this, which is the point).
  - A .tmp pid file is always stale (a partial atomic write).
  - *.pid.lock files are never touched by the stale cleaners.
  - Get-GrepaiSpawnDecision adopts ONLY our own worktree lock; a
    foreign live lock means backoff, never adoption (adopting a
    foreign PID would make this supervisor reap someone else's
    watcher).
  - Idle -1 means UNKNOWN and callers must treat it as "do not reap".
  - New-WatcherParentDeathJob never throws: no job means the caller
    runs without the backstop (None here, IntPtr.Zero in the .ps1).
"""

import ctypes
import fnmatch
import os
import re
import sys
import time
from datetime import datetime

try:
    from Modules import watcher_patterns as _patterns
except ImportError:  # pragma: no cover - direct-file execution fallback
    import watcher_patterns as _patterns

STALE_PATTERNS = ("grepai-worktree-*.pid*", "grepai-stop-*")
SPAWN_PID_PATTERNS = ("grepai-watch.pid", "grepai-watch.pid.tmp",
                      "grepai-worktree-*.pid", "grepai-worktree-*.pid.tmp")
INVENTORY_PATTERNS = ("grepai-watch.pid", "grepai-worktree-*.pid")

_WATCH_WHOLE_ARG = re.compile(r"(?i)(^|[\s\"])watch([\s\"]|$)")
_GREPAI_NAME = re.compile(r"(?i)^grepai(\.exe)?$")
_STOP_NAME = re.compile(r"^grepai-stop-(\d+)$")
_WORKTREE_PID = re.compile(r"^grepai-worktree-([^.]+)\.pid")
_WORKTREE_PID_TMP = re.compile(r"^grepai-worktree-([^.]+)\.pid\.tmp$")
_GLOBAL_PID = re.compile(r"^grepai-watch\.pid$")
_GLOBAL_PID_TMP = re.compile(r"^grepai-watch\.pid\.tmp$")
_IDLE_STAMP = re.compile(r"(\d{4}/\d{2}/\d{2}) (\d{2}:\d{2}:\d{2})")
_LAST_INDEX = re.compile(r"(?m)^\s*last_index_time:\s*(\S+)\s*$")
_IDLE_TIMEOUT_KEY = re.compile(r"(?m)^\s*idle_timeout_minutes:\s*(\d+)\s*$")

_JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
_PROCESS_TERMINATE = 0x0001
_PROCESS_SET_QUOTA = 0x0100


# --- Injectable process seams ---------------------------------------------------

def _pid_alive(pid):
    """True while a PID names a live process. Never throws."""
    try:
        if int(pid) <= 0:
            return False
    except (TypeError, ValueError):
        return False
    try:
        import psutil

        return bool(psutil.pid_exists(int(pid)))
    except Exception:
        pass
    try:
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not handle:
            return False
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    except Exception:
        return False


def _snapshot_grepai():
    """Live pid -> {Name, CommandLine, CreationDate}. [] when unavailable."""
    try:
        import psutil

        out = []
        for proc in psutil.process_iter(["pid", "ppid", "name", "cmdline", "create_time"]):
            try:
                info = proc.info
                cmd = info.get("cmdline") or []
                out.append({
                    "ProcessId": int(info.get("pid") or 0),
                    "Name": str(info.get("name") or ""),
                    "CommandLine": " ".join(cmd),
                    "CreationDate": float(info.get("create_time") or 0),
                })
            except Exception:
                continue
        return out
    except Exception:
        return []


# --- Stale grepai locks (mcpw-eud) ---------------------------------------------------

def get_grepai_log_dir(log_dir=None):
    """Machine-global grepai log dir, mirroring daemon.GetDefaultLogDir."""
    if log_dir and not str(log_dir).isspace():
        return str(log_dir)
    base = os.environ.get("LOCALAPPDATA") or ""
    if not base or not base.strip():
        return ""
    return os.path.join(base, "grepai", "logs")


def test_grepai_lock_stale(lock_file, project_root, pid_alive=None):
    """True only when removing this lock is provably safe. Never throws."""
    if not lock_file or not str(lock_file).strip():
        return False
    name = os.path.basename(str(lock_file))
    alive = pid_alive or _pid_alive
    try:
        match = _STOP_NAME.match(name)
        if match:
            try:
                return not bool(alive(int(match.group(1))))
            except Exception:
                return False
        match = re.match(r"^grepai-worktree-([^.]+)\.pid", name)
        if match:
            if not project_root or not str(project_root).strip():
                return False
            directory = os.path.dirname(str(lock_file))
            sibling = os.path.join(directory, "grepai-worktree-" + match.group(1) + ".log")
            if not os.path.exists(sibling):
                return False
            mine = os.path.abspath(str(project_root)).rstrip("\\/").lower()
            try:
                with open(sibling, "r", encoding="utf-8", errors="replace") as handle:
                    return mine in handle.read().lower()
            except OSError:
                return False
    except Exception:
        return False
    return False


def clear_stale_locks(project_root, lock_dir=None):
    """Delete only provably-stale grepai locks. Returns removed paths."""
    removed = []
    directory = get_grepai_log_dir(lock_dir)
    if not directory or not os.path.isdir(directory):
        return removed
    try:
        names = os.listdir(directory)
    except OSError:
        return removed
    for pattern in STALE_PATTERNS:
        for name in fnmatch.filter(names, pattern):
            full = os.path.join(directory, name)
            try:
                if not test_grepai_lock_stale(full, project_root):
                    continue
                os.remove(full)
                removed.append(full)
            except OSError:
                continue
    return removed


def get_grepai_spawn_log_pair(log_path, err_path, attempt=1):
    """Attempt 1 keeps the canonical pair; later attempts get suffixed pairs."""
    try:
        number = int(attempt)
    except (TypeError, ValueError):
        number = 1
    if number <= 1:
        return {"Log": str(log_path), "Err": str(err_path)}
    return {"Log": "%s.attempt%d" % (log_path, number),
            "Err": "%s.attempt%d" % (err_path, number)}


def resolve_grepai_pane_log(worktree_log, launcher_log, fresh_minutes=10, now=None):
    """Pick the log the grepai pane should tail (freshness-gated)."""
    try:
        window = abs(int(fresh_minutes))
    except (TypeError, ValueError):
        window = 10
    moment = now if now is not None else datetime.now()
    try:
        cutoff = moment.timestamp() - window * 60
    except Exception:
        cutoff = time.time() - window * 60

    def mtime(path):
        try:
            if path and os.path.exists(path):
                return os.path.getmtime(path)
        except OSError:
            pass
        return None

    wt_time = mtime(worktree_log)
    if wt_time is not None and wt_time > cutoff:
        return worktree_log
    ll_time = mtime(launcher_log)
    if wt_time is not None and (ll_time is None or wt_time > ll_time):
        return worktree_log
    if launcher_log:
        return launcher_log
    return worktree_log


# --- Spawn-time lock gate (mcpw-ozm) ---------------------------------------------------

def get_grepai_process_info(process_id, snapshot=None):
    """Name + command line for a live PID, else None. Never throws."""
    try:
        pid = int(process_id)
    except (TypeError, ValueError):
        return None
    if pid <= 0:
        return None
    table = snapshot if snapshot is not None else _snapshot_grepai()
    for proc in table or ():
        try:
            if int(proc.get("ProcessId")) == pid:
                return {"Name": str(proc.get("Name") or ""),
                        "CommandLine": str(proc.get("CommandLine") or "")}
        except (AttributeError, TypeError, ValueError):
            continue
    return None


def test_grepai_watcher_process(process_id, process_probe=None):
    """True only for a LIVE `grepai ... watch` (recycled PIDs fail)."""
    try:
        pid = int(process_id)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        if process_probe is not None:
            info = process_probe(pid)
        else:
            info = get_grepai_process_info(pid)
    except Exception:
        return False
    if not info:
        return False
    try:
        name = str(info.get("Name") or "")
        cmd = str(info.get("CommandLine") or "")
    except AttributeError:
        return False
    if not _GREPAI_NAME.match(name):
        return False
    if not cmd or not cmd.strip():
        return False
    return bool(_WATCH_WHOLE_ARG.search(cmd))


def get_grepai_pid_file_value(pid_file):
    """Bare decimal PID from a pid file, else 0. Never throws."""
    if not pid_file or not str(pid_file).strip():
        return 0
    if not os.path.exists(str(pid_file)):
        return 0
    try:
        with open(str(pid_file), "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read().strip()
    except OSError:
        return 0
    if not re.match(r"^\d+$", text):
        return 0
    try:
        return int(text)
    except ValueError:
        return 0


def test_grepai_pid_file_stale(pid_file, process_probe=None):
    """True when this pid file provably names no live watcher. Never throws."""
    if not pid_file or not str(pid_file).strip():
        return False
    name = os.path.basename(str(pid_file))
    is_global = bool(_GLOBAL_PID.match(name) or _GLOBAL_PID_TMP.match(name))
    is_worktree = bool(_WORKTREE_PID.match(name) or _WORKTREE_PID_TMP.match(name))
    if not (is_global or is_worktree):
        return False
    if name.endswith(".tmp"):
        return True
    if not os.path.exists(str(pid_file)):
        return True
    owner = get_grepai_pid_file_value(pid_file)
    if owner <= 0:
        return True
    try:
        return not bool(test_grepai_watcher_process(owner, process_probe))
    except Exception:
        return False


def test_grepai_pid_file_owned_by_project(pid_file, project_root):
    """True when a worktree pid file is attributable to project_root."""
    if not pid_file or not str(pid_file).strip():
        return False
    if not project_root or not str(project_root).strip():
        return False
    name = os.path.basename(str(pid_file))
    match = _WORKTREE_PID.match(name)
    if not match:
        return False
    sibling = os.path.join(os.path.dirname(str(pid_file)),
                           "grepai-worktree-" + match.group(1) + ".log")
    if not os.path.exists(sibling):
        return False
    mine = os.path.abspath(str(project_root)).rstrip("\\/").lower()
    try:
        with open(sibling, "r", encoding="utf-8", errors="replace") as handle:
            return mine in handle.read().lower()
    except OSError:
        return False


def get_grepai_lock_inventory(log_dir=None, project_root="", process_probe=None):
    """Classify every grepai pid file this workspace would consult."""
    out = []
    directory = get_grepai_log_dir(log_dir)
    if not directory or not os.path.isdir(directory):
        return out
    try:
        names = os.listdir(directory)
    except OSError:
        return out
    seen = []
    for pattern in INVENTORY_PATTERNS:
        for name in sorted(fnmatch.filter(names, pattern)):
            full = os.path.join(directory, name)
            if full in seen or not os.path.isfile(full):
                continue
            seen.append(full)
            owner = get_grepai_pid_file_value(full)
            live = bool(owner > 0 and test_grepai_watcher_process(owner, process_probe))
            kind = "global" if name == "grepai-watch.pid" else "worktree"
            try:
                stale = bool(test_grepai_pid_file_stale(full, process_probe))
            except Exception:
                stale = False
            try:
                ours = bool(test_grepai_pid_file_owned_by_project(full, project_root))
            except Exception:
                ours = False
            out.append({"Path": full, "Name": name, "Kind": kind,
                        "OwnerPid": owner, "LiveWatcher": live,
                        "Stale": stale, "BelongsToUs": ours})
    return out


def clear_stale_grepai_spawn_locks(log_dir=None, process_probe=None):
    """Delete only provably-stale spawn locks. Returns removed paths."""
    removed = []
    directory = get_grepai_log_dir(log_dir)
    if not directory or not os.path.isdir(directory):
        return removed
    try:
        names = os.listdir(directory)
    except OSError:
        return removed
    for pattern in SPAWN_PID_PATTERNS:
        for name in sorted(fnmatch.filter(names, pattern)):
            full = os.path.join(directory, name)
            try:
                if not test_grepai_pid_file_stale(full, process_probe):
                    continue
                os.remove(full)
                removed.append(full)
            except OSError:
                continue
    return removed


def get_grepai_spawn_backoff_seconds(consecutive_blocked, base_seconds=15, max_seconds=600):
    """Doubling backoff for a lock a live process holds. Pure."""
    try:
        base = int(base_seconds)
    except (TypeError, ValueError):
        base = 15
    try:
        cap = int(max_seconds)
    except (TypeError, ValueError):
        cap = 600
    try:
        blocked = int(consecutive_blocked)
    except (TypeError, ValueError):
        blocked = 0
    if base < 1:
        base = 15
    if cap < base:
        cap = base
    if blocked <= 1:
        return base
    try:
        delay = int(pow(2, blocked - 1) * base)
    except (OverflowError, ValueError):
        return cap
    if delay > cap:
        return cap
    if delay < base:
        return base
    return delay


def get_grepai_spawn_decision(log_dir=None, project_root="", consecutive_blocked=0,
                              base_delay_seconds=15, max_delay_seconds=600,
                              process_probe=None):
    """What the spawn path should do RIGHT NOW. Pure (reads, never writes)."""
    inventory = get_grepai_lock_inventory(log_dir, project_root, process_probe)
    blockers = [row for row in inventory if row.get("LiveWatcher")]
    if not blockers:
        return {"Action": "spawn", "DelaySeconds": 0, "BlockerPid": 0,
                "BlockerPath": "", "Blockers": [],
                "Reason": "no live grepai watcher holds a lock this workspace would consult"}
    ours = [row for row in blockers if row.get("BelongsToUs")]
    if ours:
        first = ours[0]
        return {"Action": "adopt", "DelaySeconds": 0,
                "BlockerPid": int(first.get("OwnerPid") or 0),
                "BlockerPath": str(first.get("Path") or ""), "Blockers": blockers,
                "Reason": "live grepai watcher PID %s holds %s, which this project owns"
                          % (first.get("OwnerPid"), first.get("Name"))}
    first = blockers[0]
    delay = get_grepai_spawn_backoff_seconds(consecutive_blocked, base_delay_seconds,
                                             max_delay_seconds)
    return {"Action": "backoff", "DelaySeconds": delay,
            "BlockerPid": int(first.get("OwnerPid") or 0),
            "BlockerPath": str(first.get("Path") or ""), "Blockers": blockers,
            "Reason": "live grepai watcher PID %s holds %s and cannot be attributed "
                      "to this project - a respawn would be refused"
                      % (first.get("OwnerPid"), first.get("Name"))}


# --- Log helpers (VAD-hne6, mcpw-p83) ---------------------------------------------------

def limit_log_size(path, max_mb=16):
    """Rename to <path>.old when path exceeds max_mb. Never throws."""
    try:
        if not path or not os.path.exists(path):
            return
        try:
            limit = int(max_mb)
        except (TypeError, ValueError):
            limit = 16
        if os.path.getsize(path) > limit * 1024 * 1024:
            try:
                if os.path.exists(path + ".old"):
                    os.remove(path + ".old")
            except OSError:
                pass
            os.rename(path, path + ".old")
    except OSError:
        pass


def new_log_parent_dir(path):
    """Create the parent dir for an append-style log writer. Never throws."""
    try:
        if not path or not str(path).strip():
            return
        parent = os.path.dirname(os.path.abspath(str(path)))
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
    except OSError:
        pass


# --- Launcher liveness ---------------------------------------------------

def test_launcher_alive(path, process_probe=None, pid_alive=None):
    """True while the launcher that wrote this lock file is still alive."""
    if not path or not os.path.exists(str(path)):
        return False
    try:
        with open(str(path), "r", encoding="utf-8-sig") as handle:
            data = __import__("json").load(handle)
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict) or not data.get("Pid"):
        return False
    try:
        pid = int(data.get("Pid"))
    except (TypeError, ValueError):
        return False
    alive = pid_alive or _pid_alive
    try:
        if not bool(alive(pid)):
            return False
    except Exception:
        return False
    if data.get("StartedAt"):
        try:
            lock_started = datetime.fromisoformat(str(data.get("StartedAt")))
            info = None
            if process_probe is not None:
                try:
                    info = process_probe(pid)
                except Exception:
                    info = None
            else:
                try:
                    import psutil

                    info = {"StartTime": datetime.fromtimestamp(
                        psutil.Process(pid).create_time())}
                except Exception:
                    info = None
            if info and info.get("StartTime"):
                delta = abs((info["StartTime"] - lock_started).total_seconds())
                if delta > 5:
                    return False
        except (ValueError, TypeError):
            pass
    if data.get("Launcher"):
        expected = str(data.get("Launcher"))
        cmdline = ""
        try:
            if process_probe is not None:
                info = process_probe(pid)
                if info:
                    cmdline = str(info.get("CommandLine") or "")
            else:
                info = get_grepai_process_info(pid)
                if info:
                    cmdline = str(info.get("CommandLine") or "")
                else:
                    try:
                        import psutil

                        proc = psutil.Process(pid)
                        cmdline = " ".join(proc.cmdline() or [])
                    except Exception:
                        cmdline = ""
        except Exception:
            cmdline = ""
        if not (cmdline and expected in cmdline):
            return False
    return True


# --- Litellm supervisor helpers (vad-sef, vad-0m6, vad-olv, vad-gfn) ---------------------------------------------------

def test_litellm_config(config_path):
    """Fail-fast preflight: ASCII-only plus best-effort YAML. Never throws."""
    if not config_path or not os.path.exists(str(config_path)):
        print("litellm config not found: %s - skipping litellm launch." % (config_path,),
              file=sys.stderr)
        return False
    try:
        with open(str(config_path), "r", encoding="utf-8", errors="strict") as handle:
            lines = handle.read().splitlines()
    except (OSError, UnicodeError) as exc:
        print("litellm config unreadable at %s: %s - skipping litellm launch."
              % (config_path, exc), file=sys.stderr)
        return False
    number = 0
    for line in lines:
        number += 1
        col = 0
        for char in line:
            col += 1
            code = ord(char)
            if code > 127:
                tag = "U+%04X" % code
                if "api_key" in line:
                    print("litellm config has non-ASCII api_key char %s at %s:%d "
                          "(col %d) - refusing to launch litellm." % (tag, config_path, number, col),
                          file=sys.stderr)
                else:
                    print("litellm config has non-ASCII char %s at %s:%d (col %d) - "
                          "refusing to launch litellm." % (tag, config_path, number, col),
                          file=sys.stderr)
                return False
    try:
        import yaml

        with open(str(config_path), "r", encoding="utf-8") as handle:
            yaml.safe_load(handle)
        return True
    except ImportError:
        return True
    except Exception as exc:
        print("litellm config YAML parse failed at %s: %s - refusing to launch litellm."
              % (config_path, exc), file=sys.stderr)
        return False


def get_litellm_backoff_delay(consecutive_failures, base_seconds=10, max_seconds=300):
    """Exponential backoff for the litellm supervisor. Pure."""
    try:
        failures = int(consecutive_failures)
    except (TypeError, ValueError):
        failures = 0
    if failures <= 1:
        try:
            return int(base_seconds)
        except (TypeError, ValueError):
            return 10
    try:
        base = int(base_seconds)
    except (TypeError, ValueError):
        base = 10
    try:
        cap = int(max_seconds)
    except (TypeError, ValueError):
        cap = 300
    if base < 1:
        base = 10
    if cap < base:
        cap = base
    try:
        delay = int(pow(2, failures - 1) * base)
    except (OverflowError, ValueError):
        return cap
    if delay > cap:
        return cap
    if delay < base:
        return base
    return delay


def stop_prior_litellm_proxy(prior_pid, pid_alive=None, terminate=None):
    """Reap a prior litellm proxy child. Returns True when one was reaped."""
    try:
        pid = int(prior_pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    alive = pid_alive or _pid_alive
    kill = terminate
    if kill is None:
        def kill(target):
            try:
                import signal

                os.kill(int(target), signal.SIGTERM)
                return True
            except Exception:
                return False
    try:
        if not bool(alive(pid)):
            return False
        try:
            kill(pid)
        except Exception:
            pass
        for _ in range(20):
            time.sleep(0.1)
            try:
                if not bool(alive(pid)):
                    break
            except Exception:
                break
        return True
    except Exception:
        return False


def get_litellm_proxy_relaunch_plan(prior_pid=0, port=4000, grace_sec=30,
                                    listening_pids=None, proc_start=None):
    """Reap-OR-REUSE plan for the litellm proxy. Read-only. Never throws."""
    try:
        live = []
        try:
            if int(prior_pid) > 0:
                live.append(int(prior_pid))
        except (TypeError, ValueError):
            pass
        owners = listening_pids
        if owners is None:
            owners = []
            try:
                import psutil

                for conn in psutil.net_connections(kind="tcp"):
                    try:
                        if (conn.status == "LISTEN" and conn.laddr
                                and int(conn.laddr.port) == int(port) and conn.pid):
                            owners.append(int(conn.pid))
                    except Exception:
                        continue
            except Exception:
                pass
        for owner in owners or ():
            try:
                if int(owner) > 0 and int(owner) not in live:
                    live.append(int(owner))
            except (TypeError, ValueError):
                continue
        reap = []
        for tid in live:
            try:
                start = proc_start(tid) if proc_start is not None else None
            except Exception:
                start = None
            if start is None and proc_start is None:
                try:
                    import psutil

                    start = datetime.fromtimestamp(psutil.Process(int(tid)).create_time())
                except Exception:
                    start = None
            age = -1
            if start is not None:
                try:
                    age = (datetime.now() - start).total_seconds()
                except Exception:
                    age = -1
            if age >= 0 and age < float(grace_sec):
                return {"Action": "reuse", "ReapPids": [], "Port": int(port)}
            reap.append(int(tid))
        return {"Action": "spawn", "ReapPids": reap, "Port": int(port)}
    except Exception:
        return {"Action": "spawn", "ReapPids": [], "Port": int(port)}


def backup_litellm_stderr(log_path, max_mb=16):
    """Preserve litellm crash stderr across restarts. Never throws."""
    try:
        if not log_path:
            return
        err = str(log_path) + ".err"
        if not os.path.exists(err):
            return
        if os.path.getsize(err) == 0:
            return
        history = str(log_path) + ".err.history"
        limit_log_size(history, max_mb)
        stamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
        try:
            size = os.path.getsize(err)
        except OSError:
            size = 0
        try:
            with open(history, "a", encoding="utf-8", errors="replace") as out:
                out.write("===== %s preserving %s (%d bytes) =====\n" % (stamp, err, size))
                try:
                    with open(err, "r", encoding="utf-8", errors="replace") as src:
                        out.write(src.read())
                        if not src.read(0):
                            out.write("\n")
                except OSError:
                    pass
        except OSError:
            pass
        limit_log_size(history, max_mb)
    except OSError:
        pass


# --- Grepai idle TTL (VAD-jmw) ---------------------------------------------------

def test_grepai_activity_line(line):
    """True when a grepai log line is real indexing work (not housekeeping)."""
    if not line or not str(line).strip():
        return False
    text = str(line)
    if "rpg_full_reconcile_triggered=" in text:
        return False
    if re.search(r"rpg_derived_refresh_ms=\d+.*changed_files=0(\s|$)", text):
        return False
    if "rpg_persist_ms=" in text:
        return False
    return True


def get_grepai_watch_start_time(snapshot=None):
    """Newest start time among live grepai watchers, else None."""
    table = snapshot if snapshot is not None else _snapshot_grepai()
    starts = []
    for proc in table or ():
        try:
            if str(proc.get("Name") or "").lower() not in ("grepai", "grepai.exe"):
                continue
            if "watch" not in str(proc.get("CommandLine") or ""):
                continue
            created = proc.get("CreationDate")
            if created is None:
                continue
            starts.append(float(created))
        except (AttributeError, TypeError, ValueError):
            continue
    if not starts:
        return None
    return datetime.fromtimestamp(max(starts))


def get_grepai_idle_minutes_from_config(config_path, watch_start=None):
    """Idle minutes from watch.last_index_time, else None when unknown."""
    if not config_path or not os.path.exists(str(config_path)):
        return None
    try:
        with open(str(config_path), "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return None
    match = _LAST_INDEX.search(text)
    if not match:
        return None
    try:
        stamp = datetime.fromisoformat(match.group(1))
    except ValueError:
        try:
            stamp = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
        except ValueError:
            return None
    start = watch_start if watch_start is not None else get_grepai_watch_start_time()
    try:
        if start is not None and stamp < start:
            return None
    except TypeError:
        return None
    try:
        return round((datetime.now() - stamp).total_seconds() / 60.0, 1)
    except Exception:
        return None


def get_grepai_idle_minutes_from_log(log_dir=None, max_lines=300, watch_start=None):
    """Idle minutes from the newest worktree log, else -1 (do not reap)."""
    directory = get_grepai_log_dir(log_dir)
    if not directory or not os.path.isdir(directory):
        return -1
    try:
        candidates = [os.path.join(directory, name) for name in os.listdir(directory)
                      if fnmatch.fnmatch(name, "grepai-worktree-*.log")]
    except OSError:
        return -1
    if not candidates:
        return -1
    try:
        newest = max(candidates, key=lambda p: os.path.getmtime(p))
    except OSError:
        return -1
    try:
        start = watch_start if watch_start is not None else get_grepai_watch_start_time()
        if start is not None:
            if datetime.fromtimestamp(os.path.getmtime(newest)) < start:
                return -1
    except OSError:
        return -1
    try:
        limit = int(max_lines)
    except (TypeError, ValueError):
        limit = 300
    try:
        with open(newest, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()[-limit:]
    except OSError:
        return -1
    if not lines:
        return -1
    stamp_line = None
    for line in reversed(lines):
        try:
            if test_grepai_activity_line(line):
                stamp_line = line
                break
        except Exception:
            continue
    if not stamp_line:
        return -1
    match = _IDLE_STAMP.search(stamp_line)
    if not match:
        return -1
    try:
        stamp = datetime.strptime(match.group(1) + " " + match.group(2), "%Y/%m/%d %H:%M:%S")
    except ValueError:
        return -1
    try:
        return round((datetime.now() - stamp).total_seconds() / 60.0, 1)
    except Exception:
        return -1


def get_grepai_idle_minutes(log_dir=None, max_lines=300, config_path=""):
    """Idle minutes both clocks agree on, else -1 (do not reap)."""
    known = []
    try:
        from_config = get_grepai_idle_minutes_from_config(config_path)
    except Exception:
        from_config = None
    if from_config is not None:
        known.append(float(from_config))
    try:
        from_log = get_grepai_idle_minutes_from_log(log_dir, max_lines)
    except Exception:
        from_log = -1
    if from_log is not None and from_log >= 0:
        known.append(float(from_log))
    if not known:
        return -1
    return round(min(known), 1)


def get_grepai_idle_timeout_minutes(config_path="", default_minutes=20):
    """Idle TTL in minutes (0 disables). Never throws."""
    try:
        default = int(default_minutes)
    except (TypeError, ValueError):
        default = 20
    minutes = default
    if config_path and os.path.exists(str(config_path)):
        try:
            with open(str(config_path), "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            match = _IDLE_TIMEOUT_KEY.search(text)
            if match:
                minutes = int(match.group(1))
        except (OSError, ValueError):
            pass
    if minutes < 0:
        minutes = 0
    return minutes


# --- Parent-death job object (vad-r0i, ctypes = stdlib Add-Type) ---------------------------------------------------
#
# The kernel enforces this, not a handler: the launcher owns the job
# handle, and when the launcher dies for ANY reason the handle closes
# and every process still in the job is terminated.

class _JobBasicLimit(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64),
        ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", ctypes.c_uint32),
        ("MinimumWorkingSetSize", ctypes.c_void_p),
        ("MaximumWorkingSetSize", ctypes.c_void_p),
        ("ActiveProcessLimit", ctypes.c_uint32),
        ("Affinity", ctypes.c_void_p),
        ("PriorityClass", ctypes.c_uint32),
        ("SchedulingClass", ctypes.c_uint32),
    ]


class _JobIoCounters(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_uint64),
        ("WriteOperationCount", ctypes.c_uint64),
        ("OtherOperationCount", ctypes.c_uint64),
        ("ReadTransferCount", ctypes.c_uint64),
        ("WriteTransferCount", ctypes.c_uint64),
        ("OtherTransferCount", ctypes.c_uint64),
    ]


class _JobExtendedLimit(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", _JobBasicLimit),
        ("IoInfo", _JobIoCounters),
        ("ProcessMemoryLimit", ctypes.c_void_p),
        ("JobMemoryLimit", ctypes.c_void_p),
        ("PeakProcessMemoryUsed", ctypes.c_void_p),
        ("PeakJobMemoryUsed", ctypes.c_void_p),
    ]


def new_watcher_parent_death_job():
    """Create a KILL_ON_JOB_CLOSE job object. None means no job. Never throws."""
    try:
        kernel32 = ctypes.windll.kernel32
    except (AttributeError, OSError):
        return None
    try:
        kernel32.CreateJobObjectW.restype = ctypes.c_void_p
        kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p]
        job = kernel32.CreateJobObjectW(None, None)
        if not job:
            return None
        ext = _JobExtendedLimit()
        ctypes.memset(ctypes.byref(ext), 0, ctypes.sizeof(ext))
        ext.BasicLimitInformation.LimitFlags = _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        kernel32.SetInformationJobObject.restype = ctypes.c_bool
        kernel32.SetInformationJobObject.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                     ctypes.c_void_p, ctypes.c_uint32]
        ok = kernel32.SetInformationJobObject(job, _JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                                              ctypes.byref(ext), ctypes.sizeof(ext))
        if not ok:
            kernel32.CloseHandle(job)
            return None
        return int(job)
    except Exception:
        return None


def add_process_to_watcher_death_job(job, process_id):
    """Assign a live process (and its future children) to the job. Never throws."""
    try:
        pid = int(process_id)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        handle = int(job)
    except (TypeError, ValueError):
        return False
    if not handle:
        return False
    try:
        kernel32 = ctypes.windll.kernel32
    except (AttributeError, OSError):
        return False
    try:
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_uint32]
        proc = kernel32.OpenProcess(_PROCESS_TERMINATE | _PROCESS_SET_QUOTA, False, pid)
        if not proc:
            return False
        try:
            kernel32.AssignProcessToJobObject.restype = ctypes.c_bool
            kernel32.AssignProcessToJobObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            return bool(kernel32.AssignProcessToJobObject(handle, proc))
        finally:
            kernel32.CloseHandle(proc)
    except Exception:
        return False


def close_watcher_parent_death_job(job):
    """Close the job handle (assigned children die). Never throws."""
    try:
        handle = int(job)
    except (TypeError, ValueError):
        return False
    if not handle:
        return False
    try:
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    except Exception:
        return False
