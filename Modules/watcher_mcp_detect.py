"""Port of Modules/watcher_mcp_detect.ps1 - bead mcpw-xeu.3.

MCP "is it initialized?" detection contract: one probe per MCP answering
"is this repo already initialized for that tool?". No probe builds, indexes,
repairs or spawns anything persistent. Init code lives in
Modules/watcher_mcp_provision.py (the WRITE side of this pair).

Contract (identical shape for all seven probes):
    test_<mcp>_initialized(path, probe_output=None) -> (ok, reason)
    ok     True = initialized, the caller may skip the build.
           False = not initialized (or cannot tell) -> provision runs.
    reason one-line human-readable why, for the log. Probes never throw.

Rules every probe obeys:
  * Everything is rooted at the passed path. No absolute repository path, no
    assumption about WHICH repository this is, and no assumption that it is a
    git repository (a plain directory must work).
  * A MISSING BINARY is a normal answer, never an exception: (False,
    "binary not found: <name>"). This check runs FIRST.
  * A signal that is only PARTLY present is NOT initialized.

TWO REPRESENTATIONS EXIST UNTIL THE LAUNCHER IS PORTED. The PowerShell module
is still live and is still what the launcher dot-sources, so this file
duplicates the probe logic. tests/test_ported_mcp_detect.py pins the two
against each other (same vectors, same reason vocabulary). Delete this caveat
only when the .ps1 is retired.

Fidelity notes, verified against the live .ps1 rather than assumed:
  - Tool resolution tries <name>.exe, then .cmd/.bat, then the bare name
    (memtrace and graft are npm shims with no .exe on PATH).
  - The detect command runner drains BOTH pipes (communicate) and kills on
    timeout; the exit code is ignored because `repowise doctor` exits 0 while
    reporting FAILing checks - the TEXT is the signal.
  - memtrace matching is by PATH only (repo_id is a hand-authored slug, not
    derivable from a path), normalised for slash direction and case.
  - grepai decides on the CHUNK count ("Total chunks" > 0), never the file
    count (upstream hardcodes TotalFiles: 0 on qdrant backends).
  - graphenium keys on `.grapheniumignore` (the FILE `gm init` writes), NOT a
    `.graphenium/` directory (no gm subcommand creates one).
  - graft requires wiring.json AND INDEX.md together (never manifest.json,
    the --deep artifact; --deep needs an LLM key and is hard-forbidden).
  - repowise reads the DETAIL column of the "Claude Code MCP entry" row only
    (the `Agent: claude-code` row also contains "not registered").
  - atlas has NO binary check (machine-global npm package, no per-repo
    executable) and matches keys case-sensitively, mirroring dotenv exactly.
"""
import json
import os
import re
import shutil
import subprocess

# (mcp, probe-function-name) in the fixed order the launcher logs and the
# tests assert on. Atlas is appended, not inserted: it has no ordering
# dependency on any of the six above.
DETECT_ORDER = (
    "memtrace",
    "grepai",
    "graphenium",
    "graphify-rs",
    "repowise",
    "graft",
    "atlas",
)

_GREP_FILE_COUNT = re.compile(r"Files indexed\s*:\s*(\d+)")
_GREP_CHUNK_COUNT = re.compile(r"Total chunks\s*:\s*(\d+)")
_REPOWISE_ENTRY_ROW = re.compile(r"Claude Code MCP entry[^\r\n]*")

ATLAS_ENV_KEYS = ("NEO4J_URI", "NEO4J_USER", "NEO4J_PASSWORD")


def get_mcp_detect_root(path=None):
    """Normalise the caller's path; fall back to the current location."""
    if path:
        return path.rstrip("\\/")
    try:
        loc = os.getcwd()
    except OSError:
        loc = ""
    if not loc:
        return ""
    return loc.rstrip("\\/")


def compare_path(path):
    """Normalise a repository path so two spellings of the same repo compare
    equal: absolute, forward slashes, no trailing slash, lowercased."""
    if not path:
        return ""
    p = path
    try:
        p = os.path.abspath(path)
    except OSError:
        pass
    p = p.replace("\\", "/")
    while len(p) > 1 and p.endswith("/"):
        p = p[:-1]
    return p.lower()


def resolve_mcp_detect_tool(name):
    """Resolve a tool's runnable command the same way the launcher does:
    <name>.exe, then <name>.cmd/.bat, then the bare <name>. Returns the full
    path, or None when the tool is not on PATH. Never throws."""
    if not name:
        return None
    for cand in ("%s.exe" % name, "%s.cmd" % name, "%s.bat" % name, name):
        try:
            found = shutil.which(cand)
        except OSError:
            found = None
        if found:
            return found
    return None


def invoke_mcp_detect_command(file_path, argv, working_directory=None,
                              timeout_ms=60000):
    """Run a tool's read-only status command and return stdout+stderr as one
    string, or None when it cannot be launched or wedges past the timeout.
    The exit code is deliberately ignored. Never throws."""
    if not file_path:
        return None
    if timeout_ms is None or timeout_ms <= 0:
        timeout_ms = 60000
    if isinstance(argv, str):
        import shlex
        argv = shlex.split(argv, posix=False)
    try:
        proc = subprocess.Popen(
            [file_path] + list(argv or ()),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=working_directory or None,
        )
    except OSError:
        return None
    try:
        try:
            out, err = proc.communicate(timeout=timeout_ms / 1000.0)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except OSError:
                pass
            return None
        try:
            text_out = out.decode("utf-8", errors="replace")
        except (AttributeError, UnicodeError):
            text_out = str(out or "")
        try:
            text_err = err.decode("utf-8", errors="replace")
        except (AttributeError, UnicodeError):
            text_err = str(err or "")
        return text_out + os.linesep + text_err
    finally:
        try:
            proc.wait(timeout=0)
        except (subprocess.TimeoutExpired, OSError):
            pass


def root_usable(root):
    """Shared guard: the repository root must exist as a directory. Returns
    the reason string when it does NOT, or '' when the root is fine."""
    if not root:
        return "no repository path supplied"
    if not os.path.isdir(root):
        return "path not found: %s" % root
    return ""


def get_grepai_index_signal(text):
    """Parse `grepai status --no-ui` text into the index counters grepai
    ACTUALLY computes. Returns (files, chunks, indexed); indexed is true when
    EITHER counter is > 0. Shared by the detection probe and the provisioner
    so the two can never disagree about what "indexed" means."""
    files = 0
    chunks = 0
    if text:
        m = _GREP_FILE_COUNT.search(text)
        if m:
            files = int(m.group(1))
        m = _GREP_CHUNK_COUNT.search(text)
        if m:
            chunks = int(m.group(1))
    return (files, chunks, (files > 0) or (chunks > 0))


def read_atlas_env_file(path):
    """Parse a .env file into a dict of KEY -> VALUE. A deliberately small,
    strict subset of dotenv: blank lines and '#' comments skipped, split on
    the FIRST '=', one layer of surrounding quotes stripped, leading
    'export ' accepted. KEYS MATCH CASE-SENSITIVELY, mirroring dotenv
    exactly. Returns None when the file does not exist; otherwise a dict,
    which may legitimately be empty."""
    if not path or not os.path.isfile(path):
        return None
    mapping = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None
    for raw in lines:
        s = raw.strip()
        if not s:
            continue
        if s.startswith("#"):
            continue
        if s.startswith("export "):
            s = s[7:].strip()
        eq = s.find("=")
        if eq < 1:
            continue
        key = s[:eq].strip()
        value = s[eq + 1:].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key:
            mapping[key] = value
    return mapping


def test_memtrace_initialized(path, probe_output=None):
    """Is this repository a member of the memtrace store scope? PRIMARY
    signal: <path>/.memdb/.memtrace-store-scope.json exists, parses, and one
    of its members[].path entries equals the repository path."""
    root = get_mcp_detect_root(path)
    if not resolve_mcp_detect_tool("memtrace"):
        return (False, "binary not found: memtrace")
    bad = root_usable(root)
    if bad:
        return (False, bad)
    rel = ".memdb/.memtrace-store-scope.json"
    if not os.path.isfile(os.path.join(root, ".memdb",
                                       ".memtrace-store-scope.json")):
        return (False, "scope file missing: %s" % rel)
    try:
        with open(os.path.join(root, ".memdb", ".memtrace-store-scope.json"),
                  "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        return (False, "scope file unreadable: %s" % exc)
    if not doc:
        return (False, "scope file is empty")
    members = doc.get("members") if isinstance(doc, dict) else None
    if members is None:
        members = []
    if isinstance(members, dict):
        members = [members]
    members = list(members)
    if not members:
        return (False, "scope file has no members[]")
    want = compare_path(root)
    for member in members:
        if not member:
            continue
        have = compare_path(str(member.get("path", ""))) \
            if isinstance(member, dict) else ""
        if have and have == want:
            return (True, "repo is a member of the memtrace store scope "
                    "(%d member(s))" % len(members))
    return (False, "repo path is not a member of the memtrace store scope "
            "(%d member(s))" % len(members))


def test_grepai_initialized(path, probe_output=None):
    """Does this repository have a grepai index with content in it? Signals:
    CLI on PATH; .grepai/config.yaml exists; `grepai status` reports an index
    with content (chunk count, parsed by get_grepai_index_signal)."""
    root = get_mcp_detect_root(path)
    tool = resolve_mcp_detect_tool("grepai")
    if not tool:
        return (False, "binary not found: grepai")
    bad = root_usable(root)
    if bad:
        return (False, bad)
    rel = ".grepai/config.yaml"
    if not os.path.isfile(os.path.join(root, ".grepai", "config.yaml")):
        return (False, "config missing: %s" % rel)
    text = probe_output
    if not text:
        text = invoke_mcp_detect_command(tool, ["status", "--no-ui"],
                                         working_directory=root,
                                         timeout_ms=30000)
    if not text:
        return (False, "grepai status produced no output")
    files, chunks, indexed = get_grepai_index_signal(text)
    if not indexed:
        return (False, "grepai status reports an empty index "
                "(Files indexed: %d, Total chunks: %d)" % (files, chunks))
    return (True, "grepai status reports an index with content "
            "(Files indexed: %d, Total chunks: %d)" % (files, chunks))


def test_graphenium_initialized(path, probe_output=None):
    """Does this repository have a graphenium workspace (config AND graph)?
    `.grapheniumignore` (the FILE `gm init` writes) plus
    graphenium-out/graph.json. BOTH artifacts are required."""
    root = get_mcp_detect_root(path)
    if not resolve_mcp_detect_tool("gm"):
        return (False, "binary not found: gm")
    bad = root_usable(root)
    if bad:
        return (False, bad)
    if not os.path.isfile(os.path.join(root, ".grapheniumignore")):
        return (False, "workspace config missing: .grapheniumignore "
                "(gm init writes this file; no gm subcommand creates "
                ".graphenium/)")
    rel = "graphenium-out/graph.json"
    if not os.path.isfile(os.path.join(root, "graphenium-out", "graph.json")):
        return (False, "graph missing: %s" % rel)
    return (True, ".grapheniumignore workspace config present and "
            "graphenium-out/graph.json present")


def test_graphify_rs_initialized(path, probe_output=None):
    """Does this repository have a built graphify-rs graph?
    graphify-out/graph.json. An empty graphify-out/ is NOT initialized."""
    root = get_mcp_detect_root(path)
    if not resolve_mcp_detect_tool("graphify-rs"):
        return (False, "binary not found: graphify-rs")
    bad = root_usable(root)
    if bad:
        return (False, bad)
    rel = "graphify-out/graph.json"
    if not os.path.isfile(os.path.join(root, "graphify-out", "graph.json")):
        if os.path.isdir(os.path.join(root, "graphify-out")):
            return (False, "graphify-out/ exists but holds no built graph: "
                    "%s" % rel)
        return (False, "output dir missing: graphify-out/ (no %s)" % rel)
    return (True, "built graph present: %s" % rel)


def test_repowise_initialized(path, probe_output=None):
    """Does this repository have a repowise store AND a registered MCP entry?
    .repowise/ exists, and `repowise doctor` does not report the Claude Code
    MCP entry as "not registered"."""
    root = get_mcp_detect_root(path)
    tool = resolve_mcp_detect_tool("repowise")
    if not tool:
        return (False, "binary not found: repowise")
    bad = root_usable(root)
    if bad:
        return (False, bad)
    if not os.path.isdir(os.path.join(root, ".repowise")):
        return (False, "store missing: .repowise/")
    text = probe_output
    if not text:
        text = invoke_mcp_detect_command(tool, ["doctor"],
                                         working_directory=root,
                                         timeout_ms=120000)
    if not text:
        return (False, "repowise doctor produced no output")
    row = _REPOWISE_ENTRY_ROW.search(text)
    if not row:
        return (False, 'repowise doctor did not report a '
                '"Claude Code MCP entry" row')
    if "not registered" in row.group(0):
        return (False, ".repowise/ store present but the Claude Code MCP "
                "entry is not registered")
    return (True, ".repowise/ store present and the Claude Code MCP entry "
            "is registered")


def test_graft_initialized(path, probe_output=None):
    """Does this repository have a graft graph built by the $0 no-key tier?
    BOTH graft/.graph/wiring.json AND graft/INDEX.md must exist."""
    root = get_mcp_detect_root(path)
    if not resolve_mcp_detect_tool("graft"):
        return (False, "binary not found: graft")
    bad = root_usable(root)
    if bad:
        return (False, bad)
    wiring = "graft/.graph/wiring.json"
    index = "graft/INDEX.md"
    have_wiring = os.path.isfile(os.path.join(root, "graft", ".graph",
                                              "wiring.json"))
    have_index = os.path.isfile(os.path.join(root, "graft", "INDEX.md"))
    if have_wiring and have_index:
        return (True, "graph present: %s + %s" % (wiring, index))
    if have_wiring:
        return (False, "graph incomplete: %s present but %s missing "
                "(run graft build)" % (wiring, index))
    if have_index:
        return (False, "graph incomplete: %s present but %s missing "
                "(run graft build)" % (index, wiring))
    return (False, "graph missing: neither %s nor %s (run graft build)"
            % (wiring, index))


def test_atlas_initialized(path, probe_output=None):
    """Does this repository carry a usable atlas (Neo4j) .env? Signal:
    <path>/.env exists AND defines NEO4J_URI, NEO4J_USER and NEO4J_PASSWORD,
    each with a non-empty value. NO BINARY CHECK: atlas has no per-repo
    executable (machine-global npm package); the machine-level precondition
    is the Neo4j container, which is the launcher's job, not a repo probe's.

    WHY THE THREE VALUES ARE IDENTICAL IN EVERY REPO: Neo4j 5 Community
    supports exactly ONE database (SHOW DATABASES returns only 'neo4j' and
    'system'), so every repo writes into the same graph and this file
    carries connection credentials only. See bead mcpw-cnc.8 for what real
    isolation would cost. Only key NAMES ever appear in the reason; values
    never do, so a password cannot reach the launcher log."""
    root = get_mcp_detect_root(path)
    bad = root_usable(root)
    if bad:
        return (False, bad)
    mapping = read_atlas_env_file(os.path.join(root, ".env"))
    if mapping is None:
        return (False, ".env missing (run the atlas provision step)")
    missing = [key for key in ATLAS_ENV_KEYS if not mapping.get(key)]
    if missing:
        return (False, ".env is missing key(s): %s" % ", ".join(missing))
    return (True, ".env present with %s" % ", ".join(ATLAS_ENV_KEYS))


_PROBES = {
    "memtrace": test_memtrace_initialized,
    "grepai": test_grepai_initialized,
    "graphenium": test_graphenium_initialized,
    "graphify-rs": test_graphify_rs_initialized,
    "repowise": test_repowise_initialized,
    "graft": test_graft_initialized,
    "atlas": test_atlas_initialized,
}


def get_mcp_initialization_report(path):
    """Run all seven probes against one repository and return one row per MCP
    (dicts with mcp/ok/reason, fixed DETECT_ORDER). Never throws: a probe
    that cannot answer reports ok=False with its reason."""
    rows = []
    for name in DETECT_ORDER:
        probe = _PROBES[name]
        try:
            ok, reason = probe(path)
        except Exception as exc:  # noqa: BLE001 - the report must not throw
            ok, reason = False, "detection probe threw: %s" % exc
        rows.append({"mcp": name, "ok": bool(ok), "reason": reason})
    return rows
