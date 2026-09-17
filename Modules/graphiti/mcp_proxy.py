#!/usr/bin/env python3
r"""Graphiti MCP HTTP proxy - clean threaded version with proper response routing.

Exposes the stdio-only Graphiti MCP server as an HTTP JSON-RPC endpoint so
Toolport can reach it via `http://127.0.0.1:8002/mcp`.

This file is version-controlled in the watcher repos at
`Modules/graphiti/mcp_proxy.py` (VAD and MCP-Watchers). The graphiti install it
drives - the `getzep/graphiti` clone, its `.venv`, and `main.py` - stays under
`%LOCALAPPDATA%\Programs\graphiti-mcp`. Only this wrapper, `embed_server.py`
and `config-litellm.yaml` are ours; the rest is upstream and re-clonable.

Fixes applied 2026-09-17:
  1. bufsize=0 made proc.stdout a raw FileIO, which has no read1(), so the
     reader thread died on the first frame and the bridge never became ready.
     Dropped bufsize=0 so stdout is a buffered reader.
  2. The bridge never sent an MCP `initialize` handshake to the subprocess, so
     it never answered anything and tools/list returned an empty list.
     Added initialize -> notifications/initialized -> tools/list on start.
  3. Switched to ThreadingHTTPServer so /health probes are not blocked behind
     a long tools/list (the launcher supervisor polls /health every 15s).
  4. ensure_bridge() was not self-healing: start() swallowed handshake
     failures, so one slow cold start bricked the proxy until a manual
     restart. It now reaps the child and retries.
  5. Paths are resolved instead of hardcoded, so the same file runs from the
     install tree or from either watcher repo.
"""
import json, os, sys, time, uuid, subprocess, threading, queue
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

_HERE = os.path.dirname(os.path.abspath(__file__))

# The graphiti install (clone + .venv + main.py). Derived from %LOCALAPPDATA%
# so this file stays portable; the literal is a last-resort fallback only.
_INSTALL_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA") or r"C:\Users\yuni\AppData\Local",
    "Programs", "graphiti-mcp", "mcp_server",
)

# The repo layout keeps config-litellm.yaml NEXT TO this file; the install
# layout keeps it under config/. Probe in order, use the first that exists.
_CONFIG_CANDIDATES = [
    os.path.join(_HERE, "config-litellm.yaml"),
    os.path.join(_HERE, "config", "config-litellm.yaml"),
    os.path.join(_INSTALL_DIR, "config", "config-litellm.yaml"),
]


def _resolve_config():
    for cand in _CONFIG_CANDIDATES:
        if os.path.isfile(cand):
            return cand
    # Nothing found: hand the first candidate over so the server's own error
    # message names a concrete path instead of failing obscurely.
    return _CONFIG_CANDIDATES[0]


MCP_CMD = [
    os.path.join(_INSTALL_DIR, ".venv", "Scripts", "python.exe"),
    "main.py",
    "--transport", "stdio",
    "--config", _resolve_config(),
]

HANDSHAKE_TIMEOUT = 180


class MCPBridge:
    def __init__(self):
        self.proc = None
        self.tools = []
        self._lock = threading.Lock()
        self._startLock = threading.Lock()
        self._pending = {}
        self._ready = threading.Event()
        self._started = False

    def _log(self, msg):
        sys.stderr.write(f"[proxy] {msg}\n")
        sys.stderr.flush()

    def start(self):
        """Spawn the stdio server and complete the MCP handshake.

        Returns True when tools are available. A False return means the attempt
        failed; the caller may retry, so the half-dead child is reaped here.
        """
        env = os.environ.copy()
        env["PYTHONPATH"] = ""
        env["VIRTUAL_ENV"] = ""
        env["GRAPHITI_TELEMETRY_ENABLED"] = "false"

        # NOTE: no bufsize=0 - a raw FileIO stdout has no read1().
        self.proc = subprocess.Popen(
            MCP_CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env,
            cwd=_INSTALL_DIR,
        )
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._stderr, daemon=True).start()
        return self._handshake()

    def teardown(self):
        """Reap the child so failed attempts do not pile up as orphans.

        An orphaned main.py keeps a FalkorDB connection open, which slows the
        next cold start down enough to trip the handshake timeout again.
        """
        p, self.proc = self.proc, None
        with self._lock:
            self.tools = []
            self._pending.clear()
        if p is None:
            return
        try:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        except Exception:
            pass
        for s in (p.stdin, p.stdout, p.stderr):
            try:
                if s:
                    s.close()
            except Exception:
                pass

    def _handshake(self):
        """MCP lifecycle: initialize -> notifications/initialized -> tools/list.

        Returns True only when tools were obtained. Cold start is slow and
        variable (graphiti builds FalkorDB indices first), so a timeout here is
        expected occasionally and must NOT be treated as a permanent failure.
        """
        try:
            init = self.call("initialize", {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "graphiti-http-proxy", "version": "1.0.0"},
            }, timeout=HANDSHAKE_TIMEOUT)
            if init.get("error"):
                self._log(f"initialize failed: {init['error']}")
                return False
            self._notify("notifications/initialized", {})
            tl = self.call("tools/list", {}, timeout=HANDSHAKE_TIMEOUT)
            if tl.get("error"):
                self._log(f"tools/list failed: {tl['error']}")
                return False
            tools = (tl.get("result") or {}).get("tools") or []
            with self._lock:
                self.tools = tools
            if tools:
                self._ready.set()
                self._log(f"ready - {len(tools)} tools exposed")
                return True
            self._log("tools/list returned 0 tools - leaving bridge unready")
            return False
        except Exception as e:
            self._log(f"handshake error: {e}")
            return False

    def _notify(self, method, params):
        try:
            msg = {"jsonrpc": "2.0", "method": method}
            if params:
                msg["params"] = params
            self.proc.stdin.write((json.dumps(msg) + "\n").encode())
            self.proc.stdin.flush()
        except Exception as e:
            self._log(f"notify {method} failed: {e}")

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _reader(self):
        buf = b""
        while True:
            try:
                data = self.proc.stdout.read1(8192)
                if not data:
                    break
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    result = msg.get("result", {})
                    if isinstance(result, dict) and "tools" in result and msg.get("id"):
                        with self._lock:
                            self.tools = result["tools"]

                    eid = msg.get("id")
                    if eid is None:
                        continue
                    with self._lock:
                        slot = self._pending.get(eid)
                    if slot is not None:
                        slot["result"] = msg
                        slot["event"].set()
            except Exception as e:
                sys.stderr.write(f"[bridge] reader error: {e}\n")
                sys.stderr.flush()
                break

    def _stderr(self):
        while True:
            try:
                line = self.proc.stderr.readline()
                if not line:
                    break
                sys.stderr.write(f"[graphiti] {line.decode('utf-8', errors='replace')}")
                sys.stderr.flush()
            except Exception:
                break

    def call(self, method, params=None, timeout=120):
        if not self.alive():
            return {"error": {"code": -32000, "message": "graphiti subprocess not running"}}
        eid = str(uuid.uuid4())[:8]
        event = threading.Event()
        with self._lock:
            self._pending[eid] = {"event": event, "result": None}

        msg = {"jsonrpc": "2.0", "id": eid, "method": method}
        if params:
            msg["params"] = params

        try:
            self.proc.stdin.write((json.dumps(msg) + "\n").encode())
            self.proc.stdin.flush()
        except Exception as e:
            with self._lock:
                self._pending.pop(eid, None)
            return {"error": {"code": -32000, "message": f"write failed: {e}"}}

        if event.wait(timeout=timeout):
            with self._lock:
                r = self._pending.pop(eid)["result"]
            return r
        with self._lock:
            self._pending.pop(eid, None)
        return {"error": {"code": -32600, "message": f"Timeout after {timeout}s"}}


_bridge = MCPBridge()


MAX_BRIDGE_ATTEMPTS = 4


def ensure_bridge():
    """Bring the stdio bridge up (idempotent, self-healing).

    A cold start that misses the handshake timeout is a normal transient, not a
    permanent failure - so a failed attempt reaps its child and is retried
    instead of bricking the proxy until someone restarts it.
    """
    if _bridge._ready.is_set() or _bridge._started:
        return
    with _bridge._startLock:
        if _bridge._ready.is_set() or _bridge._started:
            return
        _bridge._started = True
        for attempt in range(1, MAX_BRIDGE_ATTEMPTS + 1):
            try:
                if _bridge.start():
                    return
            except Exception as e:
                _bridge._log(f"bridge start failed (attempt {attempt}): {e}")
            _bridge.teardown()
            if attempt < MAX_BRIDGE_ATTEMPTS:
                _bridge._log(f"retrying bridge start ({attempt}/{MAX_BRIDGE_ATTEMPTS}) in 5s")
                time.sleep(5)
        _bridge._log(f"bridge gave up after {MAX_BRIDGE_ATTEMPTS} attempts")
        _bridge._started = False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _j(self, o):
        d = json.dumps(o).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length else b""
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return self._j({"jsonrpc": "2.0", "id": 0, "error": {"code": -32700, "message": "Parse error"}})

        method = data.get("method", "")
        eid = data.get("id")
        params = data.get("params", {})

        if method == "initialize":
            threading.Thread(target=ensure_bridge, daemon=True).start()
            self._j({"jsonrpc": "2.0", "id": eid, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "graphiti-mcp", "version": "1.1.0"}
            }})
        elif method == "tools/list":
            # Cold start is slow: graphiti builds FalkorDB indices before it
            # answers the first tools/list (observed >3 min). Wait long enough
            # to ride that out instead of returning an empty tool list.
            _bridge._ready.wait(timeout=300)
            with _bridge._lock:
                tools = _bridge.tools
            self._j({"jsonrpc": "2.0", "id": eid, "result": {"tools": tools}})
        elif method == "tools/call":
            if not _bridge._ready.wait(timeout=300):
                return self._j({"jsonrpc": "2.0", "id": eid, "error": {"code": -32600, "message": "Server not ready"}})
            r = _bridge.call("tools/call", {"name": params.get("name"), "arguments": params.get("arguments", {})})
            if r.get("error"):
                return self._j({"jsonrpc": "2.0", "id": eid, "error": r["error"]})
            self._j({"jsonrpc": "2.0", "id": eid, "result": r.get("result", {})})
        elif method == "ping":
            self._j({"jsonrpc": "2.0", "id": eid, "result": {}})
        else:
            self._j({"jsonrpc": "2.0", "id": eid, "error": {"code": -32601, "message": f"Method {method}"}})

    def do_GET(self):
        if self.path == "/health":
            self._j({"status": "healthy", "service": "graphiti-mcp"})
        else:
            self.send_error(404)

    def log_message(self, *a):
        pass


class ProxyServer(ThreadingHTTPServer):
    """Threaded so /health answers even while tools/list waits on a cold start.

    Clients that time out and drop the socket are normal here (a cold
    tools/list can take minutes), so their connection errors are swallowed
    instead of dumping tracebacks into the launcher's log file.
    """

    daemon_threads = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, TimeoutError)):
            return
        super().handle_error(request, client_address)


if __name__ == "__main__":
    import atexit

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8002
    print(f"Graphiti MCP HTTP proxy on :{port}", flush=True)
    # Name the resolved inputs up front: this file runs from either the install
    # tree or a watcher repo, and which copy won must never be a silent guess.
    print(f"  script : {os.path.abspath(__file__)}", flush=True)
    print(f"  config : {MCP_CMD[MCP_CMD.index('--config') + 1]}", flush=True)
    print(f"  server : {MCP_CMD[0]}", flush=True)
    # Never leave an orphaned stdio server behind: it holds a FalkorDB
    # connection and slows the next cold start into a timeout.
    atexit.register(_bridge.teardown)
    # Warm the stdio bridge in the background so the first tools/list is fast.
    threading.Thread(target=ensure_bridge, daemon=True).start()
    ProxyServer(("127.0.0.1", port), Handler).serve_forever()
