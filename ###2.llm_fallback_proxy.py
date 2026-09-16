"""
Local OpenAI-compatible Chat Completions proxy (multi-tier, litellm-backed).

Forwards every request to a local LiteLLM proxy (http://127.0.0.1:4000/v1),
trying a cascade of models tier by tier until one succeeds. LiteLLM owns key
rotation, load-balancing and the upstream API call; this proxy owns only the
tier ordering and the fallthrough.

Tiers (in order, printed at startup):
  1. Nous general: poolside/laguna-s-2.1:free, poolside/laguna-xs-2.1:free,
     stepfun/step-3.7-flash:free, upstage/solar-pro4:free
  2. Nous ling: inclusionai/ling-3.0-flash-fin:free,
     inclusionai/ling-3.0-flash-sante:free
  3. openrouter nex-agi/nex-n2.5-pro:free
  4. openrouter dots-studio/dots-3-note-preview:free
  5. surplusintelligence deepseek-v4.1-flash

Each candidate is forwarded to LiteLLM as `model=<name>`. On 429/5xx the
proxy retries the candidate with backoff; on exhaustion it moves to the next
candidate, then the next tier. Tier 1 candidates are tried in listed order;
active watchers are first spread across healthy candidates.

Double-click start: the console prints the model priorities and serves in the
foreground. The window pauses before closing so the output stays readable.

The model names MUST match model_list entries in C:\\Users\\yuni\\litellm\\litellm_config.yaml (the two
are kept in sync by the quorum sync). No API keys live here -- LiteLLM handles
all key rotation.

Env vars:
  LITELM_BASE_URL   default http://127.0.0.1:4000
  LLM_PROXY_PORT    default 11436
  LLM_PROXY_TIMEOUT default 120 (seconds)
  TIER_MAX_RETRIES  default 2  (retries PER CANDIDATE on 429/5xx)
  TIER_BACKOFF_SEC  default 1.0 (exponential backoff base, seconds)
  PROXY_TOTAL_BUDGET_SEC default 90.0 (total wall-clock budget across
                    retries + candidates before giving up and returning 502)
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request

def _env_int(name: str, default: int) -> int:
    """Read an integer env var; fall back to the default on bad values.

    A non-numeric env value must not crash the import (the proxy is started
    by double-click and by the hidden launcher child, where a crashed import
    is nearly invisible)."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        sys.stderr.write("llm-tier-proxy: bad %s=%r; using default %d\n" % (name, raw, default))
        return default


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        sys.stderr.write("llm-tier-proxy: bad %s=%r; using default %s\n" % (name, raw, default))
        return default


LITELM_BASE = os.environ.get("LITELM_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
PORT = _env_int("LLM_PROXY_PORT", 11436)
TIMEOUT = _env_int("LLM_PROXY_TIMEOUT", 120)

TIER_MAX_RETRIES = _env_int("TIER_MAX_RETRIES", 2)
TIER_BACKOFF_SEC = _env_float("TIER_BACKOFF_SEC", 1.0)

CIRCUIT_FAILURE_THRESHOLD = _env_int("CIRCUIT_FAILURE_THRESHOLD", 5)
CIRCUIT_COOLDOWN_SEC = _env_int("CIRCUIT_COOLDOWN_SEC", 30)

MODEL_COOLDOWN_SEC = _env_float("MODEL_COOLDOWN_SEC", 30.0)

# Total wall-clock budget for ONE routed request across all retries and all
# candidate models. Without it the worst case is retries x candidates x up to
# 30s backoff before the 502 fallback; the budget caps that. An in-flight HTTP
# request is NOT aborted (urllib has no clean cancel); only the inter-attempt
# sleeps are capped and the remaining candidates are skipped once the budget
# runs out.
PROXY_TOTAL_BUDGET_SEC = _env_float("PROXY_TOTAL_BUDGET_SEC", 90.0)


class ModelHealthTracker:
    """Tracks per-model failure states and cooldown periods."""

    def __init__(self, cooldown_sec: float = MODEL_COOLDOWN_SEC):
        self.cooldown_sec = cooldown_sec
        self._lock = threading.Lock()
        self._failures: dict[str, int] = {}
        self._cooldown_until: dict[str, float] = {}

    def record_success(self, model_label: str) -> None:
        with self._lock:
            self._failures[model_label] = 0
            self._cooldown_until.pop(model_label, None)

    def record_failure(self, model_label: str) -> None:
        with self._lock:
            count = self._failures.get(model_label, 0) + 1
            self._failures[model_label] = count
            self._cooldown_until[model_label] = time.time() + self.cooldown_sec

    def is_healthy(self, model_label: str) -> bool:
        with self._lock:
            cooldown = self._cooldown_until.get(model_label)
            if cooldown is None:
                return True
            if time.time() >= cooldown:
                self._cooldown_until.pop(model_label, None)
                return True
            return False

    def get_healthy_models(self, candidates: list[dict]) -> list[dict]:
        return [c for c in candidates if self.is_healthy(c["label"])]

    @property
    def cooldown_count(self) -> int:
        with self._lock:
            return len(self._cooldown_until)

    def reset(self) -> None:
        with self._lock:
            self._failures.clear()
            self._cooldown_until.clear()


model_health = ModelHealthTracker()

WATCHER_LEASE_TTL_SEC = _env_float("WATCHER_LEASE_TTL_SEC", 300.0)


def extract_watcher_id(headers: dict, payload: dict | None = None) -> str:
    """Extract MCP watcher identity from HTTP headers or payload with default fallback."""
    hdr_map = {k.lower(): v for k, v in headers.items()} if headers else {}
    for h in ("x-mcp-watcher", "x-watcher-id", "x-client-id"):
        if h in hdr_map and hdr_map[h].strip():
            return hdr_map[h].strip()

    ua = hdr_map.get("user-agent", "")
    if "watcher" in ua.lower() or "mcp" in ua.lower():
        return ua.strip()

    if payload and isinstance(payload, dict):
        for field in ("watcher_id", "client_id", "watcher"):
            val = payload.get(field)
            if val and isinstance(val, str) and val.strip():
                return val.strip()

    return "default"


class WatcherModelAllocator:
    """Allocates distinct healthy models across active MCP watchers.

    Falls back to sharing healthy models when active watchers exceed healthy models.
    """

    def __init__(
        self,
        health_tracker: ModelHealthTracker,
        lease_ttl_sec: float = WATCHER_LEASE_TTL_SEC,
    ):
        self.health_tracker = health_tracker
        self.lease_ttl_sec = lease_ttl_sec
        self._lock = threading.Lock()
        self._leases: dict[str, dict] = {}

    def _purge_stale_leases(self, now: float) -> None:
        stale = [
            wid
            for wid, info in self._leases.items()
            if now - info["last_seen"] > self.lease_ttl_sec
        ]
        for wid in stale:
            del self._leases[wid]

    def get_candidate_order(
        self, watcher_id: str, all_candidates: list[dict]
    ) -> list[dict]:
        with self._lock:
            now = time.time()
            self._purge_stale_leases(now)

            healthy = self.health_tracker.get_healthy_models(all_candidates)
            unhealthy = [c for c in all_candidates if not self.health_tracker.is_healthy(c["label"])]

            if not healthy:
                return list(all_candidates)

            healthy_labels = {c["label"] for c in healthy}

            existing = self._leases.get(watcher_id)
            assigned_label = None
            if existing and existing["model_label"] in healthy_labels:
                assigned_label = existing["model_label"]
            else:
                claimed_by_others = {
                    info["model_label"]
                    for wid, info in self._leases.items()
                    if wid != watcher_id and info["model_label"] in healthy_labels
                }
                unclaimed = [c for c in healthy if c["label"] not in claimed_by_others]

                if unclaimed:
                    assigned_label = unclaimed[0]["label"]
                else:
                    # Stable across processes: PYTHONHASHSEED randomizes
                    # built-in hash(), so a restart would reshuffle
                    # watcher-to-model assignments.
                    digest = hashlib.sha256(watcher_id.encode("utf-8")).digest()
                    idx = int.from_bytes(digest[:8], "big") % len(healthy)
                    assigned_label = healthy[idx]["label"]

            self._leases[watcher_id] = {
                "model_label": assigned_label,
                "last_seen": now,
            }

            primary = [c for c in healthy if c["label"] == assigned_label]
            claimed_by_others = {
                info["model_label"]
                for wid, info in self._leases.items()
                if wid != watcher_id and info["model_label"] in healthy_labels
            }
            other_unclaimed = [
                c for c in healthy if c["label"] != assigned_label and c["label"] not in claimed_by_others
            ]
            other_claimed = [
                c for c in healthy if c["label"] != assigned_label and c["label"] in claimed_by_others
            ]

            return primary + other_unclaimed + other_claimed + unhealthy

    def get_active_watchers(self) -> dict[str, str]:
        with self._lock:
            now = time.time()
            self._purge_stale_leases(now)
            return {wid: info["model_label"] for wid, info in self._leases.items()}

    def reset(self) -> None:
        with self._lock:
            self._leases.clear()


watcher_allocator = WatcherModelAllocator(health_tracker=model_health)

_circuit_failures = 0
_circuit_opened_at: float | None = None
# vad-89r: litellm-down is NOT model-down. A connection-level failure
# (URLError/OSError/TimeoutError reaching litellm) can never be a specific
# model's fault, so it must not cool down healthy models nor trip the
# all-models circuit. Connection failures count here and open the circuit
# with reason "litellm_down"; model-level exhaustion (429/5xx/4xx after all
# candidates) counts in _circuit_failures with reason "all_models_down".
_litellm_down_failures = 0
_circuit_reason = "all_models_down"

# Sentinel returned by _try_candidate when a candidate exhausted on
# connection-level errors (litellm unreachable), distinct from None
# (candidate failed at the model level).
_LITELLM_CONN_FAILED = object()

TIERS = [
    # Tier 1: Nous general models (tried in listed order).
    [
        {"model": "poolside/laguna-s-2.1:free", "label": "nous_laguna-s"},
        {"model": "poolside/laguna-xs-2.1:free", "label": "nous_laguna-xs"},
        {"model": "stepfun/step-3.7-flash:free", "label": "nous_step"},
        {"model": "upstage/solar-pro4:free", "label": "nous_solar"},
    ],
    # Tier 2: Nous ling models (registered model_name entries in litellm config;
    # vad-hes 2026-09-13: aligned with the live config's inclusionai names -
    # the old nous-ling-*-pool names were never/are no longer registered, so
    # litellm could not route them).
    [
        {"model": "inclusionai/ling-3.0-flash-fin:free", "label": "nous_ling_fin"},
        {"model": "inclusionai/ling-3.0-flash-sante:free", "label": "nous_ling_sante"},
    ],
    # Tiers 4-6: registered fallbacks (vad-hes 2026-09-13: replaced the
    # unregistered opencode zen models with live-config model_names so every
    # tier is actually routable).
    [{"model": "nex-agi/nex-n2.5-pro:free", "label": "nex_n25_pro"}],
    [{"model": "dots-studio/dots-3-note-preview:free", "label": "dots_3_note"}],
    [{"model": "deepseek-v4.1-flash", "label": "surplus_ds41"}],]

ALL_CANDIDATES: list[dict] = [cand for tier in TIERS for cand in tier]


def print_model_priorities() -> None:
    """Print the tier ordering so a double-click start shows what gets used first."""
    print("=" * 64)
    print("LLM fallback proxy - model priorities (tried top to bottom)")
    for number, tier in enumerate(TIERS, 1):
        print("  %d. %s" % (number, ", ".join(c["model"] for c in tier)))
    print("The proxy moves down the list whenever a model fails.")
    print("=" * 64, flush=True)


def _log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def _backoff(attempt: int, retry_after: float) -> float:
    return min(max(TIER_BACKOFF_SEC * (2 ** attempt), retry_after), 30.0)


def _retry_after(err: urllib.error.HTTPError) -> float:
    try:
        ra = err.headers.get("Retry-After")
        if ra:
            return float(ra)
    except (ValueError, TypeError, AttributeError) as exc:
        _log("retry_after_parse_failed exc=%s" % exc)
    return 0.0


def _circuit_open() -> bool:
    global _circuit_opened_at
    if _circuit_opened_at is None:
        return False
    if time.time() - _circuit_opened_at >= CIRCUIT_COOLDOWN_SEC:
        _circuit_opened_at = None
        return False
    return True


def _circuit_remaining_cooldown() -> int:
    if _circuit_opened_at is None:
        return 0
    remaining = int(CIRCUIT_COOLDOWN_SEC - (time.time() - _circuit_opened_at))
    return max(remaining, 0)


def _reset_circuit() -> None:
    global _circuit_failures, _circuit_opened_at, _litellm_down_failures
    _circuit_failures = 0
    _circuit_opened_at = None
    _litellm_down_failures = 0


def _post_to_litellm(body: bytes) -> tuple[int, bytes]:
    url = LITELM_BASE + "/v1/chat/completions"
    headers = {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.status, resp.read()


def _try_candidate(payload: dict, model: str, label: str, deadline: float | None = None):
    """Forward payload to LiteLLM as `model`.

    Returns (status, data) on success, or None on candidate failure. When a
    deadline (monotonic timestamp) is given, the inter-attempt backoff sleeps
    are capped at the remaining budget; once the budget is spent the candidate
    aborts WITHOUT a health penalty (the model did not fail - the caller ran
    out of time).
    """
    body = dict(payload)
    body["model"] = model
    encoded = json.dumps(body).encode()
    conn_level = False   # True when the LAST attempt failed at the connection level
    for attempt in range(TIER_MAX_RETRIES):
        remaining = None
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _log("budget_exhausted label=%s model=%s" % (label, model))
                return None
        try:
            status, data = _post_to_litellm(encoded)
            _log("ok label=%s model=%s status=%d" % (label, model, status))
            model_health.record_success(label)
            return status, data
        except urllib.error.HTTPError as e:
            conn_level = False
            if e.code == 429:
                delay = _backoff(attempt, _retry_after(e))
                if remaining is not None:
                    delay = min(delay, remaining)
                _log("ratelimit label=%s model=%s attempt=%d wait=%.1fs" % (label, model, attempt + 1, delay))
                time.sleep(delay)
                continue
            if 500 <= e.code < 600:
                delay = _backoff(attempt, 0.0)
                if remaining is not None:
                    delay = min(delay, remaining)
                _log("server_error label=%s model=%s status=%d attempt=%d wait=%.1fs" % (label, model, e.code, attempt + 1, delay))
                time.sleep(delay)
                continue
            _log("client_error label=%s model=%s status=%d" % (label, model, e.code))
            model_health.record_failure(label)
            return None
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            conn_level = True
            delay = _backoff(attempt, 0.0)
            if remaining is not None:
                delay = min(delay, remaining)
            _log("error label=%s model=%s exc=%s attempt=%d wait=%.1fs" % (label, model, exc, attempt + 1, delay))
            time.sleep(delay)

    _log("exhausted label=%s model=%s" % (label, model))
    if conn_level:
        # vad-89r: litellm itself is unreachable - not this model's fault.
        # Report the class to the caller instead of cooling the model down.
        return _LITELLM_CONN_FAILED
    model_health.record_failure(label)
    return None


def route_chat_completions(raw_body: bytes, headers: dict | None = None):
    """Route chat completion request using watcher-specific model allocation."""
    global _circuit_failures, _circuit_opened_at, _litellm_down_failures, _circuit_reason
    try:
        payload = json.loads(raw_body)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError) as exc:
        _log("parse_error exc=%s" % exc)
        return "parse_error", 400, b'{"error":"invalid json body"}', ""

    if _circuit_open():
        retry_after = _circuit_remaining_cooldown()
        body = json.dumps(
            {
                "error": "litellm unavailable",
                "detail": "circuit open, retry after cooldown",
                "reason": _circuit_reason,
                "retry_after": retry_after,
            }
        ).encode()
        watcher_id = extract_watcher_id(headers or {}, payload=payload)
        return "circuit_open", 503, body, watcher_id

    watcher_id = extract_watcher_id(headers or {}, payload=payload)
    candidates = watcher_allocator.get_candidate_order(watcher_id, ALL_CANDIDATES)

    deadline = time.monotonic() + PROXY_TOTAL_BUDGET_SEC
    # vad-89r: classify the REQUEST's failure class. Any candidate that got an
    # HTTP response proves litellm is up, so the failure is model-level; a
    # request where EVERY candidate failed at the connection level is
    # litellm-down. One circuit increment per request (unchanged semantics).
    saw_model_failure = False
    saw_conn_failure = False
    for candidate in candidates:
        model, label = candidate["model"], candidate["label"]
        if time.monotonic() >= deadline:
            _log("latency_budget_exhausted before label=%s model=%s - returning 502" % (label, model))
            break
        result = _try_candidate(payload, model, label, deadline=deadline)
        if result is not None and result is not _LITELLM_CONN_FAILED:
            _reset_circuit()
            status, data = result
            return label, status, data, watcher_id
        if result is _LITELLM_CONN_FAILED:
            saw_conn_failure = True
        else:
            saw_model_failure = True

    if saw_model_failure:
        _circuit_failures += 1
        if _circuit_failures >= CIRCUIT_FAILURE_THRESHOLD:
            _circuit_opened_at = time.time()
            _circuit_reason = "all_models_down"
    elif saw_conn_failure:
        # litellm itself unreachable: backpressure with its own reason, and
        # no model was cooled down (connection failures never record_failure).
        _litellm_down_failures += 1
        if _litellm_down_failures >= CIRCUIT_FAILURE_THRESHOLD:
            _circuit_opened_at = time.time()
            _circuit_reason = "litellm_down"

    return "all_tiers_exhausted", 502, json.dumps(
        {"error": "all tiers exhausted", "detail": "every model in every tier failed",
         "latency_budget_sec": PROXY_TOTAL_BUDGET_SEC}
    ).encode(), watcher_id


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/health":
            cooling = model_health.cooldown_count
            body = json.dumps(
                {
                    "status": "ok",
                    "cooling_models": cooling,
                    "litellm_down_failures": _litellm_down_failures,
                    "model_exhaustion_failures": _circuit_failures,
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = b'{"error":"not found"}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_POST(self):
        if self.headers.get("Expect", "").lower() == "100-continue":
            self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
            self.wfile.flush()
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        hdrs = {k: v for k, v in self.headers.items()}
        upstream, status, data, watcher_id = route_chat_completions(raw, headers=hdrs)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Upstream", upstream)
        self.send_header("X-Watcher-ID", watcher_id)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def main():
    print_model_priorities()
    try:
        httpd = socketserver.ThreadingTCPServer(("127.0.0.1", PORT), _Handler)
    except OSError as exc:
        sys.stderr.write(
            "llm-tier-proxy: cannot bind 127.0.0.1:%d (%s). "
            "Is another instance already running?\n" % (PORT, exc)
        )
        sys.stderr.flush()
        sys.exit(1)
    with httpd:
        sys.stderr.write(
            "llm-tier-proxy on %d -> litellm %s (%d tiers)\n"
            % (PORT, LITELM_BASE, len(TIERS))
        )
        # NEW: one-line env contract for greppability (Task 5 probes this)
        sys.stderr.write(
            "llm-tier-proxy: env LLM_PROXY_PORT=%d LITELM_BASE_URL=%s\n" % (PORT, LITELM_BASE)
        )
        sys.stderr.flush()
        print(
            "Serving on http://127.0.0.1:%d/v1 (upstream litellm %s). Press Ctrl+C to stop."
            % (PORT, LITELM_BASE),
            flush=True,
        )
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            sys.stderr.write("llm-tier-proxy: stopped\n")
            sys.stderr.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    finally:
        if sys.stderr.isatty():
            # Double-click start: keep the window open so the output stays
            # readable. The hidden launcher child (stderr redirected) skips
            # this and exits clean.
            try:
                input("Press Enter to close this window...")
            except (EOFError, KeyboardInterrupt):
                pass
