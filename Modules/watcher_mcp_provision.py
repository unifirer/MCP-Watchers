"""Port of Modules/watcher_mcp_provision.ps1 - bead mcpw-xeu.3.

MCP initialization ("provision") layer: bring all seven watched MCPs up in
ANY repository the launcher is started from. The WRITE side of the pair whose
READ side is Modules/watcher_mcp_detect.py: detection answers "is this repo
already initialized?", provision answers "then make it so, or explain why it
cannot be".

Contract:
    invoke_provision_for_repo(path, ...) -> summary dict (never throws):
        path/state_dir/started/finished/total/done/stamped/planned/skipped/
        report_only, results[] of {mcp,status,reason,tool,stamp,optional,phase}
        status is exactly one of 'done' | 'stamped' | 'skipped' | 'planned'
        ('planned' is report-only: the step WOULD run. There is no 'failed':
        a provision problem degrades to a logged skip and the other MCPs
        still get their chance).
    initialize_<mcp>_for_repo(path, ...) -> one row, callable on its own.
        Never throws. initialize_atlas_for_repo is the ONE step taking no
        tool path and no timeout: it spawns nothing and writes a file itself.

Hard rules encoded here:
  * IDEMPOTENT. A successful (or already-initialized) step writes a STAMP -
    one key inside <repo>/.mcpw-provision/state.json, checked BEFORE anything
    else. force=True re-runs everything.
  * THE STAMP IS EARNED, NEVER ASSUMED. Nothing stamps without the matching
    detection probe confirming the repo is initialized - BEFORE the command
    (already done) or AFTER it (post_command_gate, bead mcpw-0zo.1). An exit
    code of 0 is never enough on its own. A stamp is also re-checked while it
    is held (bead mcpw-0zo.5): a stale stamp (probe now says "not
    initialized") re-runs the initializer instead of reporting "already
    provisioned" forever. A probe that cannot answer is SILENCE, not
    evidence, so the stamp still holds (otherwise a briefly-down grepai
    would trigger a full re-index on every launch).
  * NON-INTERACTIVE, unconditionally. Every child gets stdin CLOSED, runs
    with no window and a hard timeout, and is killed on timeout; each tool
    gets the non-interactive flag it actually has.
  * DEGRADES. Missing binary, missing optional input, launch failure,
    timeout, non-zero exit, or an exit 0 the post-command probe refused to
    confirm all become 'skipped' rows with a one-line reason.
  * REPO-AGNOSTIC. Every path is derived from path. No absolute reference to
    any particular repository.
  * ORDERED CHEAP-FIRST: atlas (a file write), then config steps, then build
    steps, then index steps. The list order IS the contract; Order restates it.

mcp-agent-mail (:8765) IS DELIBERATELY NOT AN 8TH STEP (bead mcpw-ymo.4,
option b - recorded here so the omission stops looking like an oversight).
Mail is a machine-global singleton supervised by the launcher (single owner
per mcpw-ymo.2: Start-BackendSupervisor owns :8765, the start job is only a
readiness gate), not per-repo state: it has no per-repo artifact to detect,
no per-repo command to run, and no per-repo stamp to hold - every input this
layer keys on (<repo>/.mcpw-provision, per-repo config/graph/index files)
is meaningless for a port shared by all checkouts. Provisioning a port two
things were fighting over would also make the flap worse, which is why
mcpw-ymo.4 waits on mcpw-ymo.2 and still lands here: one supervised starter,
zero provision rows.

PER-REPO GRAPH ISOLATION PATH (bead mcpw-cnc.8 - decision, not code).
Neo4j 5 Community (the container's image, neo4j:5-community) allows exactly
ONE database - verified 2026-09-23: SHOW DATABASES returns only "neo4j" and
"system". So every repo that points atlas at this instance writes into the
SAME graph, and the per-repo .env this layer writes CANNOT isolate repos;
it carries connection credentials only (identical NEO4J_URI/NEO4J_USER in
every repo, one shared NEO4J_PASSWORD). What real isolation would cost:
  A. one Neo4j container per repo - a distinct host port pair, NEO4J_URI,
     credentials and Toolport registry entry per repo; breaks the one-entry
     'atlas' model and the readiness gate's single-container assumption;
     one container per repo to run, watch and back up.
  B. Neo4j Enterprise multi-database - a different, licensed image; the
     compose capture in docker/neo4j-atlas/ would have to be rewritten.
  C. keep one database, rely on atlas's own project/task scoping - zero
     infrastructure change, but UNVERIFIED: settle whether atlas namespaces
     its project/task/knowledge nodes per project well enough that a query
     from repo B can never see repo A's nodes, against atlas's own schema
     rather than assuming it.
DECISION: do nothing until Option C has been checked. The graph holds 0
nodes, so no pain is felt yet and no data is at risk from deferring.
Revisit only when a second repo is actually onboarded to atlas. The chilling
direction, either way, is a single shared graph with repo tagging versus a
future Enterprise/multi-DB split - not a per-repo .env, which can never be
the mechanism. No code beyond this comment unless trivial.

TWO REPRESENTATIONS EXIST UNTIL THE LAUNCHER IS PORTED. The PowerShell module
is still live. tests/test_ported_mcp_provision.py pins this port's plan,
argv, stamp and gate behaviour against the .ps1's. The stamp file shape is
kept byte-compatible with the .ps1's ({"mcp": {"At","Tool","Detail","Head"}})
so either side can read a stamp the other wrote. Delete this caveat only
when the .ps1 is retired.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

try:
    from Modules import watcher_mcp_detect as _detect
except ImportError:  # pragma: no cover - direct-file execution fallback
    import watcher_mcp_detect as _detect

_DEFAULT_TIMEOUT_MS = 1800000
_GREP_AI_FIRST_SCAN_TIMEOUT_MS = 300000

# Opt-in config file per OPTIONAL step, mirroring the gate each real
# initializer applies. Used by report-only so the report cannot claim it
# plans a step the real run would skip.
_OPTIONAL_CONFIG_GATE = {"graphify-rs": "graphify-rs.toml"}


def get_mcp_provision_root(path=None):
    """Normalise the caller's path. Mirrors the detect root rule so the two
    layers cannot disagree about what the root is."""
    return _detect.get_mcp_detect_root(path)


def get_mcp_provision_state_dir(path=None, state_dir=None):
    """Where the provision stamp for one repository lives: the explicit
    state_dir, else MCPW_PROVISION_STATE_DIR, else <repo>/.mcpw-provision
    (rooted at path, so two repos never share a stamp)."""
    if state_dir:
        return state_dir.rstrip("\\/")
    env_dir = os.environ.get("MCPW_PROVISION_STATE_DIR")
    if env_dir:
        return env_dir.rstrip("\\/")
    root = get_mcp_provision_root(path)
    if not root:
        return ""
    return os.path.join(root, ".mcpw-provision")


def get_mcp_provision_state_file(state_dir):
    if not state_dir:
        return ""
    return os.path.join(state_dir, "state.json")


def import_mcp_provision_legacy_stamp(state_dir):
    """One-time migration of the pre-rename .mcpw-bootstrap stamp. Copies
    <repo>/.mcpw-bootstrap/state.json to <repo>/.mcpw-provision/state.json
    when the new file is absent and the old one exists, then removes the old
    directory. Never throws. Only the default layout is migrated."""
    if not state_dir:
        return
    new_file = get_mcp_provision_state_file(state_dir)
    if not new_file or os.path.isfile(new_file):
        return
    if os.path.basename(state_dir.rstrip("\\/")) != ".mcpw-provision":
        return
    root = os.path.dirname(state_dir.rstrip("\\/"))
    if not root:
        return
    legacy_file = os.path.join(root, ".mcpw-bootstrap", "state.json")
    if not os.path.isfile(legacy_file):
        return
    try:
        os.makedirs(state_dir, exist_ok=True)
        shutil.copyfile(legacy_file, new_file)
        shutil.rmtree(os.path.join(root, ".mcpw-bootstrap"),
                      ignore_errors=True)
    except OSError:
        pass


def read_mcp_provision_state(state_dir):
    """The stamp file as a dict keyed by MCP name. A missing, empty or
    corrupt file reads as {} - never throws, so a truncated stamp can only
    cause one extra (safe) provision run, never a crash."""
    import_mcp_provision_legacy_stamp(state_dir)
    state = {}
    path = get_mcp_provision_state_file(state_dir)
    if not path or not os.path.isfile(path):
        return state
    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        return state
    if not isinstance(doc, dict):
        return state
    state.update(doc)
    return state


def test_mcp_provision_stamp(path=None, mcp=None, state_dir=None):
    """Is there a recorded successful provision for this MCP in this repo?
    The idempotence gate, deliberately the FIRST thing every initializer
    checks: one file read, spawns nothing."""
    if not mcp:
        return False
    directory = get_mcp_provision_state_dir(path, state_dir)
    state = read_mcp_provision_state(directory)
    entry = state.get(mcp)
    if not entry or not isinstance(entry, dict):
        return False
    return bool(entry.get("At"))


def _provision_head(path):
    # mcpw-0zo.5: also record the repo HEAD, so a stamp can be traced back
    # to a commit instead of only to a moment. Best-effort and deliberately
    # cheap: git is asked ONLY when the path really is a git repo.
    if not path or not os.path.isdir(os.path.join(path, ".git")):
        return ""
    git = resolve_mcp_provision_tool("git")
    if not git:
        return ""
    try:
        proc = subprocess.run(
            [git, "-C", path, "rev-parse", "HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", errors="replace").strip()


def set_mcp_provision_stamp(path=None, mcp=None, detail="", tool="",
                            state_dir=None):
    """Record a successful provision for one MCP. Written temp-then-move so
    a crash mid-write cannot leave a half-parsed stamp. Returns True when
    the stamp is on disk."""
    if not mcp:
        return False
    directory = get_mcp_provision_state_dir(path, state_dir)
    if not directory:
        return False
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        return False
    state = read_mcp_provision_state(directory)
    state[mcp] = {
        "At": datetime.now(timezone.utc).isoformat(),
        "Tool": str(tool or ""),
        "Detail": str(detail or ""),
        "Head": _provision_head(path),
    }
    try:
        text = json.dumps(state, indent=2)
    except (TypeError, ValueError):
        return False
    path_file = os.path.join(directory, "state.json")
    tmp_file = "%s.tmp-%d" % (path_file, os.getpid())
    try:
        with open(tmp_file, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(tmp_file, path_file)
        return True
    except OSError:
        try:
            if os.path.exists(tmp_file):
                os.remove(tmp_file)
        except OSError:
            pass
        return False


def get_mcp_provision_plan():
    """The seven provision steps in the order they must run, CHEAP-FIRST:
    config (atlas file write, gm init, repowise agents add), then build
    (graphify-rs optional, graft), then index (memtrace, grepai). The list
    order IS the contract; Order restates it. Nothing keys off the literal
    Order values. FileOnly marks a step spawning NO external command (atlas
    only); callers branch on the row, never on the initializer's name."""
    return [
        {"order": 1, "mcp": "atlas", "phase": "config",
         "optional": False, "tool": "", "fn": "initialize_atlas_for_repo",
         "file_only": True},
        {"order": 2, "mcp": "graphenium", "phase": "config",
         "optional": False, "tool": "gm", "fn": "initialize_graphenium_for_repo",
         "file_only": False},
        {"order": 3, "mcp": "repowise", "phase": "config",
         "optional": False, "tool": "repowise",
         "fn": "initialize_repowise_for_repo", "file_only": False},
        {"order": 4, "mcp": "graphify-rs", "phase": "build",
         "optional": True, "tool": "graphify-rs",
         "fn": "initialize_graphify_rs_for_repo", "file_only": False},
        {"order": 5, "mcp": "graft", "phase": "build",
         "optional": False, "tool": "graft", "fn": "initialize_graft_for_repo",
         "file_only": False},
        {"order": 6, "mcp": "memtrace", "phase": "index",
         "optional": False, "tool": "memtrace",
         "fn": "initialize_memtrace_for_repo", "file_only": False},
        {"order": 7, "mcp": "grepai", "phase": "index",
         "optional": False, "tool": "grepai", "fn": "initialize_grepai_for_repo",
         "file_only": False},
    ]


def get_mcp_provision_argv(mcp, path=None, step=None):
    """The exact argument vector for one provision step. One place for every
    command line, so the non-interactive flags are assertable in a test.
    atlas returns an empty vector EXPLICITLY (a deliberate contract for a
    step with no command, not the "unknown MCP" answer)."""
    if mcp == "atlas":
        return []
    if mcp == "memtrace":
        # No `memtrace build` verb; `start`/`mcp` are forbidden here (they
        # break the shared union store). --allow-non-git covers plain dirs.
        return ["index", path, "--allow-non-git"]
    if mcp == "grepai":
        if step == "status":
            return ["status", "--no-ui"]
        if step == "config":
            return ["init", "--yes"]
        # Foreground: performs the initial scan, then stays up. Bounded by
        # the caller's timeout.
        return ["watch", "--no-ui"]
    if mcp == "graphenium":
        return ["init", path]
    if mcp == "graphify-rs":
        # The launcher's rebuild argv unconditionally carries --no-llm;
        # this literal is that same contract.
        return ["build", "--path", ".", "--update", "--no-llm"]
    if mcp == "repowise":
        # Register the Claude Code MCP entry - the piece detection keys on.
        # --yes means "never prompt". No model, no key, no wiki generation.
        return ["agents", "add", path, "--target", "claude-code",
                "--scope", "project", "--yes", "--format", "json"]
    if mcp == "graft":
        # $0 no-key tier. NEVER --deep (needs an LLM key).
        return ["build", path]
    return []


def resolve_mcp_provision_tool(name, tool_path=None):
    """Resolve a runnable command for a tool. An explicit tool_path wins and
    is used verbatim (how repowise is pinned, and how tests inject fakes). A
    supplied tool_path that does not exist resolves to '' (skip) - NEVER
    silently downgraded to PATH lookup."""
    if tool_path:
        try:
            if os.path.isfile(tool_path):
                return tool_path
        except OSError:
            pass
        return ""
    return _detect.resolve_mcp_detect_tool(name) or ""


def provision_arg_line(arguments):
    """Join an argument vector into one command line, quoting only what
    needs it (whitespace or quotes)."""
    parts = []
    for arg in (arguments or []):
        if arg is None:
            continue
        s = str(arg)
        if s == "":
            parts.append('""')
        elif re_match_needs_quote(s):
            parts.append('"' + s.replace('"', '\\"') + '"')
        else:
            parts.append(s)
    return " ".join(parts)


def re_match_needs_quote(s):
    import re as _re
    return bool(_re.search(r'[\s"]', s))


class ProvisionResult:
    """One bounded command run: launched/timed_out/exit_code/output/error."""

    def __init__(self):
        self.launched = False
        self.timed_out = False
        self.exit_code = None
        self.output = ""
        self.error = ""


def invoke_mcp_provision_command(file_path, arguments=None,
                                 working_directory=None,
                                 timeout_ms=_DEFAULT_TIMEOUT_MS):
    """Run one provision command, bounded and non-interactive. Never throws.
    stdin is REDIRECTED AND CLOSED (a prompt reads EOF instead of hanging
    the launcher); a .cmd/.bat shim runs through cmd.exe /d /s /c and a .ps1
    shim through powershell -NonInteractive (CreateProcess cannot execute a
    batch file directly); stdout/stderr drain concurrently (communicate) so a
    child past the ~4 KB pipe buffer cannot deadlock the wait."""
    result = ProvisionResult()
    if not file_path:
        result.error = "no command path supplied"
        return result
    if not timeout_ms or timeout_ms <= 0:
        timeout_ms = _DEFAULT_TIMEOUT_MS
    argv = [str(a) for a in (arguments or []) if a is not None]
    try:
        ext = os.path.splitext(file_path)[1].lower()
    except (TypeError, AttributeError):
        ext = ""
    # NOTE: the shim branches pass a single verbatim command-line STRING
    # (shell=False sends it to CreateProcess unchanged), NOT a list. A list
    # would make list2cmdline re-quote the already-quoted inner command and
    # cmd.exe rejects the doubled quotes (measured 2026-09-23: '""C:\..\fake
    # .cmd" build C:\x"' is not recognized). The string shape below is
    # exactly what the .ps1 builds in ProcessStartInfo.Arguments.
    try:
        if ext in (".cmd", ".bat"):
            comspec = os.environ.get("ComSpec", r"C:\Windows\System32\cmd.exe")
            inner = '"%s"' % file_path
            if argv:
                inner += " " + provision_arg_line(argv)
            cmd = '%s /d /s /c "%s"' % (comspec, inner)
        elif ext == ".ps1":
            cmd = ('powershell.exe -NoProfile -NonInteractive '
                   '-ExecutionPolicy Bypass -File "%s"' % file_path)
            if argv:
                cmd += " " + provision_arg_line(argv)
        else:
            cmd = [file_path] + argv
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL, cwd=working_directory or None)
    except OSError as exc:
        result.error = str(exc)
        return result
    result.launched = True
    try:
        proc.stdin.close()
    except (OSError, AttributeError, ValueError):
        pass
    try:
        out, err = proc.communicate(timeout=timeout_ms / 1000.0)
    except subprocess.TimeoutExpired:
        result.timed_out = True
        try:
            proc.kill()
        except OSError:
            pass
        try:
            out, err = proc.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError, ValueError):
            return result
    try:
        result.output = (out or b"").decode("utf-8", errors="replace") \
            if isinstance(out, bytes) else str(out or "")
    except (UnicodeError, ValueError):
        pass
    try:
        result.error = (err or b"").decode("utf-8", errors="replace") \
            if isinstance(err, bytes) else str(err or "")
    except (UnicodeError, ValueError):
        pass
    if not result.timed_out:
        try:
            result.exit_code = int(proc.returncode)
        except (TypeError, ValueError):
            pass
    return result


def get_mcp_provision_failure_reason(result, timeout_ms, label):
    """One-line "why did this step not complete" for the log. Truncated to
    200 chars: a tool dumping a stack trace must not blow up the log line."""
    if result is None:
        return "%s produced no result" % label
    if not result.launched:
        why = str(result.error or "")
        if not why:
            why = "could not be launched"
        return "%s could not be launched: %s" % (label, why)
    if result.timed_out:
        return "%s timed out after %sms" % (label, timeout_ms)
    tail = str(result.error or "") or str(result.output or "")
    lines = [line for line in tail.replace("\r\n", "\n").split("\n")
             if line.strip()]
    first = lines[0] if lines else ""
    if len(first) > 200:
        first = first[:200]
    if first:
        return "%s exited %s: %s" % (label, result.exit_code, first)
    return "%s exited %s" % (label, result.exit_code)


def new_mcp_provision_row(mcp, status, reason, tool, stamp):
    return {"mcp": mcp, "status": status, "reason": reason, "tool": tool,
            "stamp": stamp}


def get_mcp_provision_already_reason(mcp, root, probe_output=None):
    """Run the detection probe for one MCP. Returns
    {ok, answered, reason}. Never throws. answered=False (no such probe, or
    it threw) is SILENCE, not evidence - callers invalidating a stamp must
    honour the difference."""
    probe = _detect._PROBES.get(mcp)
    if probe is None:
        return {"ok": False, "answered": False,
                "reason": "no probe for %s" % mcp}
    reason = ""
    try:
        if probe_output:
            ok, reason = probe(root, probe_output)
        else:
            ok, reason = probe(root)
    except Exception as exc:  # noqa: BLE001 - a probe must never break us
        return {"ok": False, "answered": False,
                "reason": "detection probe threw: %s" % exc}
    return {"ok": bool(ok), "answered": True, "reason": reason}


def get_mcp_provision_post_command_gate(mcp, root, label, probe_output=None):
    """Did the command that just exited 0 actually provision the repo? The
    SAME probe the pre-command gate uses is asked again; the stamp is earned
    only on a confirmed ok. Otherwise the Reason names the probe's verdict
    prefixed with the command that exited 0."""
    already = get_mcp_provision_already_reason(mcp, root, probe_output)
    if already["ok"]:
        return {"ok": True, "reason": str(already["reason"])}
    why = str(already["reason"] or "")
    if not why:
        why = "the probe reports the repository is still not initialized"
    return {"ok": False,
            "reason": "%s exited 0 but the probe still reports: %s"
            % (label, why)}


def start_mcp_provision_step(mcp, tool_name=None, path=None, state_dir=None,
                             tool_path=None, file_only=False, force=False):
    """The prologue every initializer shares. Returns
    {root, state_dir, tool, skip}: skip is a ready-made row when the step
    must NOT run, or None when the caller should proceed. Order is cheap-
    first: stamp (a file read), then the root, then the binary (skipped for
    FileOnly steps, which spawn nothing and would otherwise report
    'skipped: binary not found' forever)."""
    root = get_mcp_provision_root(path)
    directory = get_mcp_provision_state_dir(root, state_dir)
    out = {"root": root, "state_dir": directory, "tool": "", "skip": None}
    if not force and test_mcp_provision_stamp(root, mcp, directory):
        # mcpw-0zo.5: a stamp no longer AUTHORIZES a skip by itself. The
        # SAME probe the initializer would run is asked first, and the stamp
        # holds only while the probe agrees.
        if root and os.path.isdir(root):
            verdict = get_mcp_provision_already_reason(mcp, root)
            if verdict["ok"]:
                out["skip"] = new_mcp_provision_row(
                    mcp, "stamped",
                    "already provisioned (stamp present and the probe agrees: "
                    "%s; use force to re-run)" % verdict["reason"],
                    "", directory)
                return out
            if not verdict["answered"]:
                out["skip"] = new_mcp_provision_row(
                    mcp, "stamped",
                    "already provisioned (stamp present; the probe could not "
                    "answer: %s; use force to re-run)" % verdict["reason"],
                    "", directory)
                return out
            sys.stderr.write(
                "MCP provision: the '%s' stamp is stale - %s. "
                "Re-running the initializer.\n" % (mcp, verdict["reason"]))
    if not root:
        out["skip"] = new_mcp_provision_row(
            mcp, "skipped", "no repository path supplied", "", directory)
        return out
    if not os.path.isdir(root):
        out["skip"] = new_mcp_provision_row(
            mcp, "skipped", "path not found: %s" % root, "", directory)
        return out
    if file_only:
        out["tool"] = ""
        return out
    tool = resolve_mcp_provision_tool(tool_name, tool_path)
    out["tool"] = tool
    if not tool:
        reason = ("binary not found: %s" % tool_path) if tool_path else \
            ("binary not found: %s" % tool_name)
        out["skip"] = new_mcp_provision_row(mcp, "skipped", reason, "",
                                            directory)
        return out
    return out


def _run_step(mcp, pre, label, run, detail, done_reason):
    """Shared initializer tail: run the command, post-gate it, stamp it."""
    result = run()
    if result.launched and not result.timed_out and result.exit_code == 0:
        gate = get_mcp_provision_post_command_gate(mcp, pre["root"], label)
        if not gate["ok"]:
            return new_mcp_provision_row(mcp, "skipped", gate["reason"],
                                         pre["tool"], pre["state_dir"])
        set_mcp_provision_stamp(pre["root"], mcp, detail, pre["tool"],
                                pre["state_dir"])
        return new_mcp_provision_row(mcp, "done", done_reason, pre["tool"],
                                     pre["state_dir"])
    timeout = getattr(run, "timeout_ms", _DEFAULT_TIMEOUT_MS)
    return new_mcp_provision_row(
        mcp, "skipped",
        get_mcp_provision_failure_reason(result, timeout, label),
        pre["tool"], pre["state_dir"])


def _already_row(mcp, pre, verdict):
    set_mcp_provision_stamp(pre["root"], mcp, verdict["reason"], pre["tool"],
                            pre["state_dir"])
    return new_mcp_provision_row(
        mcp, "stamped", "already initialized: %s" % verdict["reason"],
        pre["tool"], pre["state_dir"])


def initialize_graphenium_for_repo(path=None, state_dir=None, tool_path=None,
                                   force=False,
                                   timeout_ms=_DEFAULT_TIMEOUT_MS):
    """Ensure this repo has a graphenium workspace config (`gm init`). The
    graph itself is `gm run`, owned by the launcher's watcher: exit 0 here
    writes only .grapheniumignore while the probe also wants the graph, so
    the post-gate reports 'skipped' until the watcher has produced it."""
    pre = start_mcp_provision_step("graphenium", "gm", path, state_dir,
                                   tool_path, force=force)
    if pre["skip"] is not None:
        return pre["skip"]
    verdict = get_mcp_provision_already_reason("graphenium", pre["root"])
    if verdict["ok"]:
        return _already_row("graphenium", pre, verdict)

    def run():
        return invoke_mcp_provision_command(
            pre["tool"],
            get_mcp_provision_argv("graphenium", pre["root"]),
            working_directory=pre["root"], timeout_ms=timeout_ms)
    run.timeout_ms = timeout_ms
    return _run_step(
        "graphenium", pre, "gm init", run,
        "gm init completed (wrote .grapheniumignore)",
        "gm init wrote .grapheniumignore - it does NOT create .graphenium/ "
        "(graph is gm run, owned by the launcher watcher)")


def initialize_repowise_for_repo(path=None, state_dir=None, tool_path=None,
                                 force=False, timeout_ms=300000):
    """Register the repowise Claude Code MCP entry (`repowise agents add
    --yes`). `repowise init` is deliberately NOT used (regenerates the wiki
    with a model, can prompt for a key). Defaults to the absolute uv-tool
    binary; the PATH `repowise` is a declick shim with no `agents` verb."""
    if not tool_path and os.environ.get("APPDATA"):
        tool_path = os.path.join(os.environ["APPDATA"], "uv", "tools",
                                 "repowise", "Scripts", "repowise.exe")
    pre = start_mcp_provision_step("repowise", "repowise", path, state_dir,
                                   tool_path, force=force)
    if pre["skip"] is not None:
        return pre["skip"]
    verdict = get_mcp_provision_already_reason("repowise", pre["root"])
    if verdict["ok"]:
        return _already_row("repowise", pre, verdict)

    def run():
        return invoke_mcp_provision_command(
            pre["tool"],
            get_mcp_provision_argv("repowise", pre["root"]),
            working_directory=pre["root"], timeout_ms=timeout_ms)
    run.timeout_ms = timeout_ms
    return _run_step(
        "repowise", pre, "repowise agents add", run,
        "agents add completed",
        "repowise agents add --target claude-code --scope project --yes")


def initialize_graphify_rs_for_repo(path=None, state_dir=None, tool_path=None,
                                    force=False,
                                    timeout_ms=_DEFAULT_TIMEOUT_MS):
    """Build the graphify-rs graph, when this repo is configured for it.
    OPTIONAL: graphify-rs.toml is the opt-in; a repo without one skips as
    optional rather than having a config invented for it."""
    pre = start_mcp_provision_step("graphify-rs", "graphify-rs", path,
                                   state_dir, tool_path, force=force)
    if pre["skip"] is not None:
        return pre["skip"]
    if not os.path.isfile(os.path.join(pre["root"], "graphify-rs.toml")):
        return new_mcp_provision_row(
            "graphify-rs", "skipped",
            "optional: graphify-rs.toml missing (bead mcpw-01g, P3) - "
            "nothing to configure", pre["tool"], pre["state_dir"])
    verdict = get_mcp_provision_already_reason("graphify-rs", pre["root"])
    if verdict["ok"]:
        return _already_row("graphify-rs", pre, verdict)

    def run():
        return invoke_mcp_provision_command(
            pre["tool"],
            get_mcp_provision_argv("graphify-rs", pre["root"]),
            working_directory=pre["root"], timeout_ms=timeout_ms)
    run.timeout_ms = timeout_ms
    return _run_step("graphify-rs", pre, "graphify-rs build", run,
                     "build completed",
                     "graphify-rs build --path . --update --no-llm")


def initialize_graft_for_repo(path=None, state_dir=None, tool_path=None,
                              force=False, timeout_ms=_DEFAULT_TIMEOUT_MS):
    """Build graft's wiring graph (`graft build <dir>`, $0 no-key tier;
    NEVER --deep)."""
    pre = start_mcp_provision_step("graft", "graft", path, state_dir,
                                   tool_path, force=force)
    if pre["skip"] is not None:
        return pre["skip"]
    verdict = get_mcp_provision_already_reason("graft", pre["root"])
    if verdict["ok"]:
        return _already_row("graft", pre, verdict)

    def run():
        return invoke_mcp_provision_command(
            pre["tool"],
            get_mcp_provision_argv("graft", pre["root"]),
            working_directory=pre["root"], timeout_ms=timeout_ms)
    run.timeout_ms = timeout_ms
    return _run_step(
        "graft", pre, "graft build", run, "build completed",
        "graft build (wiring graph + per-file cards; $0 no-key tier, "
        "no --deep)")


def initialize_memtrace_for_repo(path=None, state_dir=None, tool_path=None,
                                 force=False, timeout_ms=_DEFAULT_TIMEOUT_MS):
    """Index this repo into the memtrace store (`memtrace index [PATH]`).
    `memtrace start`/`mcp` are deliberately NOT run (they break the shared
    union store / daemon)."""
    pre = start_mcp_provision_step("memtrace", "memtrace", path, state_dir,
                                   tool_path, force=force)
    if pre["skip"] is not None:
        return pre["skip"]
    verdict = get_mcp_provision_already_reason("memtrace", pre["root"])
    if verdict["ok"]:
        return _already_row("memtrace", pre, verdict)

    def run():
        return invoke_mcp_provision_command(
            pre["tool"],
            get_mcp_provision_argv("memtrace", pre["root"]),
            working_directory=pre["root"], timeout_ms=timeout_ms)
    run.timeout_ms = timeout_ms
    return _run_step(
        "memtrace", pre, "memtrace index", run, "index completed",
        "memtrace index <path> --allow-non-git (no build verb; start/mcp "
        "deliberately not run)")


def initialize_grepai_for_repo(path=None, state_dir=None, tool_path=None,
                               force=False, config_timeout_ms=120000,
                               first_scan_timeout_ms=300000):
    """Finish grepai's first scan: `grepai init --yes` ONLY when the config
    is absent (never clobber a correct config), then a bounded foreground
    `grepai watch`. The probe decides on the CHUNK count; a watch stopped at
    the timeout still stamps when the index now has content."""
    pre = start_mcp_provision_step("grepai", "grepai", path, state_dir,
                                   tool_path, force=force)
    if pre["skip"] is not None:
        return pre["skip"]
    verdict = get_mcp_provision_already_reason("grepai", pre["root"])
    if verdict["ok"]:
        return _already_row("grepai", pre, verdict)
    config_note = "config already present (left untouched)"
    config_file = os.path.join(pre["root"], ".grepai", "config.yaml")
    if not os.path.isfile(config_file):
        first = invoke_mcp_provision_command(
            pre["tool"], get_mcp_provision_argv("grepai", pre["root"],
                                                "config"),
            working_directory=pre["root"], timeout_ms=config_timeout_ms)
        if not (first.launched and not first.timed_out
                and first.exit_code == 0):
            return new_mcp_provision_row(
                "grepai", "skipped",
                get_mcp_provision_failure_reason(first, config_timeout_ms,
                                                 "grepai init --yes"),
                pre["tool"], pre["state_dir"])
        config_note = "config created by grepai init --yes"
    scan = invoke_mcp_provision_command(
        pre["tool"], get_mcp_provision_argv("grepai", pre["root"], "scan"),
        working_directory=pre["root"], timeout_ms=first_scan_timeout_ms)
    if scan.launched and not scan.timed_out and scan.exit_code == 0:
        gate = get_mcp_provision_post_command_gate("grepai", pre["root"],
                                                   "grepai watch")
        if not gate["ok"]:
            return new_mcp_provision_row(
                "grepai", "skipped", "%s; %s" % (config_note, gate["reason"]),
                pre["tool"], pre["state_dir"])
        note = "first scan complete (%s)" % gate["reason"]
    else:
        status = invoke_mcp_provision_command(
            pre["tool"], get_mcp_provision_argv("grepai", pre["root"],
                                                "status"),
            working_directory=pre["root"], timeout_ms=30000)
        text = ""
        if status.launched:
            text = str(status.output or "") + str(status.error or "")
        second = get_mcp_provision_already_reason("grepai", pre["root"],
                                                  text)
        if second["ok"]:
            note = "first scan complete (%s)" % second["reason"]
        else:
            why = get_mcp_provision_failure_reason(scan,
                                                   first_scan_timeout_ms,
                                                   "grepai watch")
            return new_mcp_provision_row(
                "grepai", "skipped",
                "%s; %s; %s" % (config_note, why, second["reason"]),
                pre["tool"], pre["state_dir"])
    set_mcp_provision_stamp(pre["root"], "grepai",
                            "%s; %s" % (config_note, note), pre["tool"],
                            pre["state_dir"])
    return new_mcp_provision_row("grepai", "done",
                                 "%s; %s" % (config_note, note), pre["tool"],
                                 pre["state_dir"])


def _repo_root_for_module():
    here = os.path.abspath(os.path.dirname(__file__))
    return os.path.dirname(here)


def get_atlas_env_defaults():
    """The canonical atlas .env values, READ from
    docker/neo4j-atlas/.env.example (one source of truth, resolved relative
    to this module), never repeated as literals here. Returns
    {ok, reason, values}. A missing/short file is a SKIP, never an invented
    password (a wrong password fails with an opaque credential error)."""
    rel = os.path.join("docker", "neo4j-atlas", ".env.example")
    path = os.path.join(_repo_root_for_module(), "docker", "neo4j-atlas",
                        ".env.example")
    mapping = _detect.read_atlas_env_file(path)
    if mapping is None:
        return {"ok": False, "values": {},
                "reason": "the canonical atlas values file is missing: "
                          "<MCP-Watchers>\\%s" % rel.replace(os.sep, "\\")}
    values = {}
    missing = []
    for key in _detect.ATLAS_ENV_KEYS:
        value = str(mapping.get(key, "") or "")
        if value:
            values[key] = value
        else:
            missing.append(key)
    if missing:
        return {"ok": False, "values": {},
                "reason": "the canonical atlas values file is short key(s): "
                          "%s (%s)" % (", ".join(missing),
                                       rel.replace(os.sep, "\\"))}
    return {"ok": True, "values": values, "reason": "read %s" % rel}


def provision_path_ignored(root, rel_path):
    """Ask git whether one repo-relative path is ignored. Never throws.
    Returns {answered, ignored, reason}: answered=False (no repo here, or no
    git) is SILENCE, not evidence - only a real "not ignored" verdict is
    grounds to refuse a write."""
    if not root or not os.path.isdir(root):
        return {"answered": False, "ignored": False,
                "reason": "no repository root"}
    git = resolve_mcp_provision_tool("git")
    if not git:
        return {"answered": False, "ignored": False,
                "reason": "git not found on PATH"}
    try:
        code = subprocess.run(
            [git, "-C", root, "check-ignore", "-q", "--", rel_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, timeout=30).returncode
    except (OSError, subprocess.SubprocessError):
        return {"answered": False, "ignored": False,
                "reason": "git check-ignore could not run for %s" % root}
    if code == 0:
        return {"answered": True, "ignored": True,
                "reason": "%s is ignored" % rel_path}
    if code == 1:
        return {"answered": True, "ignored": False,
                "reason": "%s is NOT ignored" % rel_path}
    return {"answered": False, "ignored": False,
            "reason": "git check-ignore exited %s for %s" % (code, root)}


def provision_ignore_rule_present(text, pattern):
    """Does this ignore-file text already carry a rule covering pattern?
    Exact match on a trimmed, non-comment line ('.env', '/.env',
    '**/.env' all cover). Deliberately NOT a general gitignore matcher -
    the caller asks git itself for the real verdict afterwards."""
    for line in (str(text or "").replace("\r\n", "\n").split("\n")):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s in (pattern, "/" + pattern, "**/" + pattern):
            return True
    return False


def enable_mcp_provision_env_ignore(root, rel_path=".env"):
    """Make <root>/.env un-committable: record the rule in <gitdir>/info/
    exclude (never committed, works without a .gitignore) AND in the
    committed <root>/.gitignore (protects every other clone). Returns
    {ok, changed, reason}. Never throws. ok means recorded, NOT git-
    confirmed (a later negation can override) - the caller verifies with
    provision_path_ignored."""
    if not root or not os.path.isdir(root):
        return {"ok": False, "changed": False,
                "reason": "no repository root"}
    git = resolve_mcp_provision_tool("git")
    git_dir = ""
    if git:
        try:
            proc = subprocess.run(
                [git, "-C", root, "rev-parse", "--absolute-git-dir"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL, timeout=30)
            if proc.returncode == 0 and proc.stdout.strip():
                git_dir = proc.stdout.decode("utf-8",
                                             errors="replace").strip()
                if git_dir and not os.path.isabs(git_dir):
                    git_dir = os.path.normpath(os.path.join(root, git_dir))
        except (OSError, subprocess.SubprocessError):
            git_dir = ""
    if not git_dir:
        cand = os.path.join(root, ".git")
        if os.path.isdir(cand):
            git_dir = cand
    if not git_dir:
        return {"ok": True, "changed": False,
                "reason": "not a git repository - a .env here cannot be "
                          "committed"}
    changed = False
    notes = []
    exclude = os.path.join(git_dir, "info", "exclude")
    try:
        os.makedirs(os.path.dirname(exclude), exist_ok=True)
        text = ""
        if os.path.isfile(exclude):
            with open(exclude, "r", encoding="utf-8",
                      errors="replace") as handle:
                text = handle.read()
        if not provision_ignore_rule_present(text, rel_path):
            with open(exclude, "a", encoding="utf-8") as handle:
                handle.write("# MCP-Watchers provision (bead mcpw-cnc.7): "
                             "never commit the atlas Neo4j credentials.\n"
                             "%s\n" % rel_path)
            changed = True
            notes.append("added to .git/info/exclude")
        else:
            notes.append("already in .git/info/exclude")
    except OSError as exc:
        notes.append("could not write .git/info/exclude: %s" % exc)
    ignore_file = os.path.join(root, ".gitignore")
    try:
        text = ""
        exists = os.path.isfile(ignore_file)
        if exists:
            with open(ignore_file, "r", encoding="utf-8",
                      errors="replace") as handle:
                text = handle.read()
        if not provision_ignore_rule_present(text, rel_path):
            block = ("# MCP-Watchers provision (bead mcpw-cnc.7): the atlas "
                     "Neo4j credentials are\n# written into .env per "
                     "repository and must never be committed.\n%s\n"
                     % rel_path)
            mode = "a" if exists else "w"
            with open(ignore_file, mode, encoding="utf-8") as handle:
                if exists and text and not text.endswith("\n"):
                    handle.write("\n")
                handle.write(block)
            changed = True
            notes.append("added to .gitignore")
        else:
            notes.append("already in .gitignore")
    except OSError as exc:
        notes.append("could not write .gitignore: %s" % exc)
    return {"ok": True, "changed": changed, "reason": "; ".join(notes)}


def initialize_atlas_for_repo(path=None, state_dir=None, force=False):
    """Write this repo's atlas (Neo4j) .env and make sure it cannot be
    committed. The one step spawning NOTHING: ignore rule FIRST, then the
    file (temp-then-move), then the post-command gate before the stamp.
    THE SAME THREE VALUES go into EVERY repo (single shared graph - see the
    module header). Takes no tool path and no timeout."""
    pre = start_mcp_provision_step("atlas", None, path, state_dir,
                                   file_only=True, force=force)
    if pre["skip"] is not None:
        return pre["skip"]
    verdict = get_mcp_provision_already_reason("atlas", pre["root"])
    if verdict["ok"]:
        set_mcp_provision_stamp(pre["root"], "atlas", verdict["reason"], "",
                                pre["state_dir"])
        return new_mcp_provision_row(
            "atlas", "stamped", "already initialized: %s" % verdict["reason"],
            "", pre["state_dir"])
    defaults = get_atlas_env_defaults()
    if not defaults["ok"]:
        return new_mcp_provision_row(
            "atlas", "skipped", "cannot write .env - %s" % defaults["reason"],
            "", pre["state_dir"])
    ignore = enable_mcp_provision_env_ignore(pre["root"], ".env")
    if not ignore["ok"]:
        return new_mcp_provision_row(
            "atlas", "skipped",
            "refusing to write a credential that could be committed - %s"
            % ignore["reason"], "", pre["state_dir"])
    verdict_ignore = provision_path_ignored(pre["root"], ".env")
    if verdict_ignore["answered"] and not verdict_ignore["ignored"]:
        return new_mcp_provision_row(
            "atlas", "skipped",
            "refusing to write a credential that could be committed - %s"
            % verdict_ignore["reason"], "", pre["state_dir"])
    ignore_note = ignore["reason"]
    if not verdict_ignore["answered"]:
        ignore_note += " (unverified: %s)" % verdict_ignore["reason"]
    target = os.path.join(pre["root"], ".env")
    lines = [
        "# atlas-mcp-server (Neo4j knowledge graph) - repository connection "
        "settings.",
        "#",
        "# Written by the MCP-Watchers provision step "
        "(initialize_atlas_for_repo,",
        "# bead mcpw-cnc.7). Re-running provisioning rewrites this file; hand",
        "# edits are lost. Change the canonical values in",
        "# docker/neo4j-atlas/.env.example instead.",
        "#",
        "# THESE ARE LOCAL DATABASE CREDENTIALS, not a vendor API key: they "
        "are the",
        "# credentials for the neo4j-atlas-mcp-server container on this "
        "machine.",
        "#",
        "# THE SAME THREE VALUES ARE WRITTEN INTO EVERY REPOSITORY. Neo4j 5",
        "# Community supports exactly ONE database, so every repo writes into "
        "the",
        "# same graph. This file carries connection credentials only and "
        "cannot",
        "# isolate one repository from another.",
        "#",
        "# NEO4J_PASSWORD must equal NEO4J_AUTH in",
        "# docker/neo4j-atlas/docker-compose.yml and the Toolport registry env",
        "# block for server id 'atlas'. One password, three places.",
        "",
        "NEO4J_URI=%s" % defaults["values"]["NEO4J_URI"],
        "NEO4J_USER=%s" % defaults["values"]["NEO4J_USER"],
        "NEO4J_PASSWORD=%s" % defaults["values"]["NEO4J_PASSWORD"],
        "",
    ]
    body = "\r\n".join(lines)
    tmp_target = target + ".tmp-mcpw"
    try:
        with open(tmp_target, "w", encoding="utf-8", newline="") as handle:
            handle.write(body)
        os.replace(tmp_target, target)
    except OSError as exc:
        try:
            if os.path.exists(tmp_target):
                os.remove(tmp_target)
        except OSError:
            pass
        return new_mcp_provision_row(
            "atlas", "skipped", "could not write %s: %s" % (target, exc),
            "", pre["state_dir"])
    gate = get_mcp_provision_post_command_gate("atlas", pre["root"],
                                               "the .env write")
    if not gate["ok"]:
        return new_mcp_provision_row("atlas", "skipped", gate["reason"], "",
                                     pre["state_dir"])
    set_mcp_provision_stamp(pre["root"], "atlas", "wrote .env", "",
                            pre["state_dir"])
    return new_mcp_provision_row(
        "atlas", "done",
        "wrote .env with NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD from "
        "docker/neo4j-atlas/.env.example; %s" % ignore_note,
        "", pre["state_dir"])


_INITIALIZERS = {
    "atlas": initialize_atlas_for_repo,
    "graphenium": initialize_graphenium_for_repo,
    "repowise": initialize_repowise_for_repo,
    "graphify-rs": initialize_graphify_rs_for_repo,
    "graft": initialize_graft_for_repo,
    "memtrace": initialize_memtrace_for_repo,
    "grepai": initialize_grepai_for_repo,
}


def invoke_provision_for_repo(path=None, state_dir=None, tool_paths=None,
                              only=None, force=False, report_only=False,
                              timeout_ms=_DEFAULT_TIMEOUT_MS,
                              first_scan_timeout_ms=300000):
    """Provision all seven watched MCPs for one repository, in plan order.
    NEVER throws: every step is isolated, and a step that throws is recorded
    as 'skipped'. report_only answers "what would this do?" from probe
    ground truth (NOT the stamp): 'stamped' when the probe already reports
    provisioned, 'skipped' when no runnable tool exists or an optional
    opt-in file is missing, 'planned' otherwise. No provisioning command
    runs and no stamp is written."""
    root = get_mcp_provision_root(path)
    directory = get_mcp_provision_state_dir(root, state_dir)
    started = datetime.now(timezone.utc).isoformat()
    rows = []
    for step in get_mcp_provision_plan():
        if only and step["mcp"] not in only:
            continue
        override = ""
        if tool_paths and step["mcp"] in tool_paths:
            override = str(tool_paths[step["mcp"]] or "")
        row = None
        if report_only:
            tool = resolve_mcp_provision_tool(step["tool"], override) \
                if step["tool"] else ""
            gate = _OPTIONAL_CONFIG_GATE.get(step["mcp"])
            if step["optional"] and gate and not os.path.isfile(
                    os.path.join(root, gate)):
                row = new_mcp_provision_row(
                    step["mcp"], "skipped",
                    "report-only: optional - %s missing (bead mcpw-01g, P3) "
                    "- nothing to configure" % gate, tool, directory)
            elif not tool and not step["file_only"]:
                row = new_mcp_provision_row(
                    step["mcp"], "skipped",
                    "report-only: no runnable tool for %s - this step would "
                    "be skipped" % step["mcp"], "", directory)
            else:
                already = get_mcp_provision_already_reason(step["mcp"], root)
                if already["ok"] and not force:
                    row = new_mcp_provision_row(
                        step["mcp"], "stamped",
                        "report-only: already provisioned - %s - nothing to "
                        "run" % already["reason"], tool, directory)
                else:
                    row = new_mcp_provision_row(
                        step["mcp"], "planned",
                        "report-only: would run the %s step for %s"
                        % (step["phase"], step["mcp"]), tool, directory)
        else:
            try:
                if step["mcp"] == "atlas":
                    row = initialize_atlas_for_repo(root, directory,
                                                    force=force)
                elif step["mcp"] == "grepai":
                    row = initialize_grepai_for_repo(
                        root, directory, tool_path=override, force=force,
                        first_scan_timeout_ms=first_scan_timeout_ms)
                else:
                    row = _INITIALIZERS[step["mcp"]](
                        root, directory, tool_path=override, force=force,
                        timeout_ms=timeout_ms)
            except Exception as exc:  # noqa: BLE001 - degrade, never abort
                row = new_mcp_provision_row(
                    step["mcp"], "skipped", "initializer threw: %s" % exc,
                    "", directory)
        if row is None:
            row = new_mcp_provision_row(step["mcp"], "skipped",
                                        "initializer returned no result", "",
                                        directory)
        row = dict(row)
        row["optional"] = bool(step["optional"])
        row["phase"] = str(step["phase"])
        rows.append(row)
    return {
        "path": root,
        "state_dir": directory,
        "started": started,
        "finished": datetime.now(timezone.utc).isoformat(),
        "total": len(rows),
        "done": sum(1 for r in rows if r["status"] == "done"),
        "stamped": sum(1 for r in rows if r["status"] == "stamped"),
        "planned": sum(1 for r in rows if r["status"] == "planned"),
        "skipped": sum(1 for r in rows if r["status"] == "skipped"),
        "report_only": bool(report_only),
        "results": rows,
    }


def _temp_state_dir():
    return tempfile.mkdtemp(prefix="mcpw-provision-")


if __name__ == "__main__":  # ponytail: report-only smoke, no CLI framework
    import sys as _sys

    _target = _sys.argv[1] if len(_sys.argv) > 1 else os.getcwd()
    _summary = invoke_provision_for_repo(_target, report_only=True)
    for _row in _summary["results"]:
        print("%-12s %-8s %s" % (_row["mcp"], _row["status"], _row["reason"]))
