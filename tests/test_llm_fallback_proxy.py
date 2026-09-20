# tests/test_llm_fallback_proxy.py — regression suite for ###2.llm_fallback_proxy.py
import http.client
import importlib.util
import json
import os
import random
import socket
import socketserver
import subprocess
import sys
import threading
import urllib.error

import pytest

_spec = importlib.util.spec_from_file_location(
    "llm_fallback_proxy",
    os.path.join(os.path.dirname(__file__), "..", "###2.llm_fallback_proxy.py"),
)
proxy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(proxy)  # noqa: E402


class _TestServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def _make_server():
    return _TestServer(("127.0.0.1", 0), proxy._Handler)


def _serve_in_thread(httpd):
    threading.Thread(target=httpd.serve_forever, daemon=True).start()


def _ok(body=b'{"choices":[{"message":{"content":"{}"}}]}'):
    return 200, body


def _fast_retry(monkeypatch):
    monkeypatch.setattr(proxy, "TIER_MAX_RETRIES", 2)
    monkeypatch.setattr(proxy, "TIER_BACKOFF_SEC", 0.01)


def _reset_circuit(monkeypatch):
    monkeypatch.setattr(proxy, "_circuit_failures", 0)
    monkeypatch.setattr(proxy, "_circuit_opened_at", None)
    monkeypatch.setattr(proxy, "_litellm_down_failures", 0)


def test_tier1_nous_model_used_when_healthy(monkeypatch):
    # Preserve TIERS order against watcher_allocator singleton contamination.
    monkeypatch.setattr(proxy.watcher_allocator, "get_candidate_order", lambda wid, candidates: list(candidates))
    calls = []

    def fake(body):
        calls.append(json.loads(body.decode())["model"])
        return _ok()

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert upstream.startswith("nous_")
    assert upstream not in {"nous_hy3", "nous_longcat", "nous_ling_fin", "nous_ling_sante"}
    assert calls[0] in {c["model"] for c in proxy.TIERS[0]}


def test_falls_through_to_next_candidate_on_client_error(monkeypatch):
    _fast_retry(monkeypatch)
    monkeypatch.setattr(random, "shuffle", lambda lst: None)
    # The watcher_allocator singleton retains lease state from prior tests in
    # full-suite mode; patch it to return candidates in TIERS order so this
    # test's assumption that TIERS[0][0] is tried first holds.
    monkeypatch.setattr(proxy.watcher_allocator, "get_candidate_order", lambda wid, candidates: list(candidates))
    failed = "poolside/laguna-s-2.1:free"
    calls = []

    def fake(body):
        model = json.loads(body.decode())["model"]
        calls.append(model)
        if model == failed:
            raise urllib.error.HTTPError("u", 404, "nope", None, None)
        return _ok()

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert status == 200
    assert calls[0] == failed
    assert upstream in {c["label"] for c in proxy.TIERS[0]}
    assert upstream != "nous_laguna-s"


def test_falls_through_tier2_ling_when_tier1_exhausts(monkeypatch):
    _fast_retry(monkeypatch)
    monkeypatch.setattr(proxy.watcher_allocator, "get_candidate_order", lambda wid, candidates: list(candidates))
    calls = []

    def fake(body):
        model = json.loads(body.decode())["model"]
        calls.append(model)
        if model in {c["model"] for c in proxy.TIERS[0]}:
            raise urllib.error.URLError("down")
        return _ok()

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert upstream in {"nous_ling_fin", "nous_ling_sante"}
    assert status == 200


def test_all_tiers_exhausted_returns_502(monkeypatch):
    _fast_retry(monkeypatch)
    monkeypatch.setattr(proxy.watcher_allocator, "get_candidate_order", lambda wid, candidates: list(candidates))

    def fake(body):
        raise urllib.error.URLError("litellm down")

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert upstream == "all_tiers_exhausted"
    assert status == 502


def test_invalid_json_returns_parse_error():
    upstream, status, data, watcher_id = proxy.route_chat_completions(b"not json")
    assert upstream == "parse_error"
    assert status == 400

def test_model_field_overwritten_before_forward(monkeypatch):
    monkeypatch.setattr(proxy.watcher_allocator, "get_candidate_order", lambda wid, candidates: list(candidates))
    seen = {}

    def fake(body):
        seen["model"] = json.loads(body.decode())["model"]
        return _ok()

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"original","messages":[]}')
    assert seen["model"] != "original"
    assert seen["model"] in {c["model"] for tier in proxy.TIERS for c in tier}


def test_x_upstream_header_returned_end_to_end(monkeypatch):
    monkeypatch.setattr(proxy, "_post_to_litellm", lambda body: _ok())
    httpd = _make_server()
    _serve_in_thread(httpd)
    try:
        port = httpd.server_address[1]
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request(
            "POST",
            "/v1/chat/completions",
            body=b'{"model":"x","messages":[]}',
            headers={"Content-Type": "application/json"},
        )
        resp = conn.getresponse()
        assert resp.status == 200
        assert resp.getheader("X-Upstream").startswith("nous_")
        assert resp.getheader("Content-Length") is not None
        resp.read()
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_circuit_opens_after_threshold_failures(monkeypatch):
    _fast_retry(monkeypatch)
    _reset_circuit(monkeypatch)
    monkeypatch.setattr(proxy, "CIRCUIT_FAILURE_THRESHOLD", 3)
    monkeypatch.setattr(proxy, "CIRCUIT_COOLDOWN_SEC", 30)

    def fake(body):
        raise urllib.error.URLError("litellm down")

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    for _ in range(3):
        upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert upstream == "circuit_open"
    assert status == 503
    body = json.loads(data.decode())
    assert body["error"] == "litellm unavailable"
    assert body["retry_after"] > 0


def test_circuit_resets_on_success(monkeypatch):
    _fast_retry(monkeypatch)
    _reset_circuit(monkeypatch)
    monkeypatch.setattr(proxy, "CIRCUIT_FAILURE_THRESHOLD", 3)

    def fake(body):
        raise urllib.error.URLError("litellm down")

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    for _ in range(3):
        upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert proxy._circuit_opened_at is not None
    # URLError is connection-level: vad-89r classifies it as litellm-down,
    # so the litellm counter (not the model-exhaustion counter) carries it.
    assert proxy._litellm_down_failures == 3
    monkeypatch.setattr(proxy, "_circuit_opened_at", None)

    def fake_success(body):
        return 200, b'{"choices":[{"message":{"content":"{}"}}]}'

    monkeypatch.setattr(proxy, "_post_to_litellm", fake_success)
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert status == 200
    assert upstream.startswith("nous_")
    assert proxy._circuit_failures == 0
    assert proxy._litellm_down_failures == 0

def test_circuit_closes_after_cooldown(monkeypatch):
    _fast_retry(monkeypatch)
    _reset_circuit(monkeypatch)
    monkeypatch.setattr(proxy, "CIRCUIT_FAILURE_THRESHOLD", 1)
    monkeypatch.setattr(proxy, "CIRCUIT_COOLDOWN_SEC", 30)

    def fake(body):
        raise urllib.error.URLError("litellm down")

    monkeypatch.setattr(proxy, "_post_to_litellm", fake)
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert upstream == "circuit_open"
    assert status == 503
    monkeypatch.setattr(proxy, "_circuit_opened_at", None)
    monkeypatch.setattr(proxy, "_circuit_failures", 0)
    monkeypatch.setattr(proxy, "_post_to_litellm", lambda body: _ok())
    upstream, status, data, watcher_id = proxy.route_chat_completions(b'{"model":"x","messages":[]}')
    assert status == 200
    assert upstream.startswith("nous_")


def test_health_endpoint_returns_200():
    httpd = _make_server()
    _serve_in_thread(httpd)
    try:
        port = httpd.server_address[1]
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", "/health")
        resp = conn.getresponse()
        assert resp.status == 200
        body = resp.read()
        data = json.loads(body.decode())
        assert data["status"] == "ok"
        assert isinstance(data.get("cooling_models"), int)
        assert resp.getheader("Content-Type") == "application/json"
        resp.read()
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_unknown_get_returns_404():
    httpd = _make_server()
    _serve_in_thread(httpd)
    try:
        port = httpd.server_address[1]
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", "/unknown")
        resp = conn.getresponse()
        assert resp.status == 404
        body = resp.read()
        assert json.loads(body.decode()) == {"error": "not found"}
        resp.read()
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_expect_100_continue_is_acked(monkeypatch):
    monkeypatch.setattr(proxy, "_post_to_litellm", lambda body: _ok())
    httpd = _make_server()
    _serve_in_thread(httpd)
    try:
        port = httpd.server_address[1]
        content = b"large prompt " * 50
        body = (
            b'{"model":"x","messages":[{"role":"user","content":"'
            + content
            + b'"}]}'
        )
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            s.sendall(
                b"POST /v1/chat/completions HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: %d\r\n" % len(body)
                + b"Expect: 100-continue\r\n\r\n"
            )
            s.settimeout(5)
            preamble = s.recv(4096)
            assert b"100" in preamble.split(b"\r\n")[0], preamble
            s.sendall(body)
            response = b""
            while b"HTTP/1.1 200" not in response:
                chunk = s.recv(4096)
                if not chunk:
                    break
                response += chunk
            assert b"HTTP/1.1 200" in response, response
            assert b"X-Upstream: nous_" in response, response
    finally:
        httpd.shutdown()
        httpd.server_close()


# --- vad-mlb: watcher-to-model allocation must be stable across restarts ---

_ALLOC_CANDIDATES = [{"label": f"model-{i}", "tier": 1} for i in range(4)]


def _primary_model(watcher_id: str) -> str:
    # A fresh allocator instance stands in for a proxy restart: leases are
    # gone, so the watcher falls into the hash-based sharing branch.
    allocator = proxy.WatcherModelAllocator(health_tracker=proxy.ModelHealthTracker())
    order = allocator.get_candidate_order(watcher_id, [dict(c) for c in _ALLOC_CANDIDATES])
    return order[0]["label"]


def test_allocation_stable_across_fresh_allocators():
    assert _primary_model("watcher-alpha") == _primary_model("watcher-alpha")
    assert _primary_model("watcher-beta") == _primary_model("watcher-beta")


def test_allocation_stable_across_hash_seeds(tmp_path):
    # The original bug: built-in hash() is randomized per process by
    # PYTHONHASHSEED, so a proxy restart reshuffled watcher-to-model
    # assignments. Probe the allocator in subprocesses with two different
    # hash seeds and require identical mappings.
    probe = tmp_path / "_alloc_probe.py"
    probe.write_text(
        "import importlib.util, json, sys\n"
        "spec = importlib.util.spec_from_file_location(\n"
        "    'llm_fallback_proxy', sys.argv[1]\n"
        ")\n"
        "proxy = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(proxy)\n"
        "candidates = [{'label': f'model-{i}', 'tier': 1} for i in range(4)]\n"
        "out = {}\n"
        "for wid in ('watcher-alpha', 'watcher-beta', 'watcher-gamma'):\n"
        "    alloc = proxy.WatcherModelAllocator(\n"
        "        health_tracker=proxy.ModelHealthTracker()\n"
        "    )\n"
        "    out[wid] = alloc.get_candidate_order(wid, candidates)[0]['label']\n"
        "print(json.dumps(out))\n"
    )

    proxy_path = os.path.join(os.path.dirname(__file__), "..", "###2.llm_fallback_proxy.py")
    results = {}
    for seed in ("1", "2"):
        proc = subprocess.run(
            [sys.executable, str(probe), proxy_path],
            capture_output=True,
            text=True,
            check=True,
            env={**os.environ, "PYTHONHASHSEED": seed},
        )
        results[seed] = json.loads(proc.stdout.strip().splitlines()[-1])

    assert results["1"] == results["2"]


def test_single_model_failure_does_not_trip_global_circuit(monkeypatch):
    # vad-0kz evidence: per-model cooldowns (ModelHealthTracker) isolate one
    # flapping model. The global counter must only move on full all-tier
    # exhaustion, not on a request that succeeds via a fallback candidate.
    _reset_circuit(monkeypatch)

    candidates = [
        {"model": "m-a", "label": "label-a"},
        {"model": "m-b", "label": "label-b"},
        {"model": "m-c", "label": "label-c"},
    ]
    monkeypatch.setattr(
        proxy.watcher_allocator, "get_candidate_order", lambda wid, c: list(candidates)
    )

    def fake_try(payload, model, label, deadline=None):
        if label == "label-c":
            return 200, b'{"choices":[{"message":{"content":"{}"}}]}'
        proxy.model_health.record_failure(label)
        return None

    monkeypatch.setattr(proxy, "_try_candidate", fake_try)

    _fast_retry(monkeypatch)
    outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert outcome[0] == "label-c"
    assert proxy._circuit_failures == 0


def test_full_tier_exhaustion_increments_global_circuit(monkeypatch):
    # The global counter is the litellm-down / all-models-down backpressure
    # path; every candidate failing is what trips it.
    _reset_circuit(monkeypatch)
    _fast_retry(monkeypatch)
    monkeypatch.setattr(
        proxy, "_try_candidate", lambda payload, model, label, deadline=None: None
    )

    outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert outcome[1] == 502
    assert proxy._circuit_failures == 1


def test_bad_numeric_env_does_not_crash_import():
    """vad-del regression: a non-numeric env value must fall back to the
    default instead of crashing the module import. The proxy is started
    hidden (double-click / launcher child), where an import crash is nearly
    invisible."""
    import subprocess as _sp

    module_path = os.path.join(os.path.dirname(__file__), "..", "###2.llm_fallback_proxy.py")
    env = dict(os.environ)
    env["LLM_PROXY_PORT"] = "not-a-number"
    env["LLM_PROXY_TIMEOUT"] = "12x"
    env["TIER_BACKOFF_SEC"] = "fast"
    env["CIRCUIT_FAILURE_THRESHOLD"] = "many"
    env["WATCHER_LEASE_TTL_SEC"] = "soon"
    code = (
        "import importlib.util, sys;"
        "spec = importlib.util.spec_from_file_location('llm_fallback_proxy', sys.argv[1]);"
        "mod = importlib.util.module_from_spec(spec);"
        "spec.loader.exec_module(mod);"
        "assert mod.PORT == 11436 and mod.TIMEOUT == 120 and mod.TIER_BACKOFF_SEC == 1.0"
        " and mod.CIRCUIT_FAILURE_THRESHOLD == 5 and mod.WATCHER_LEASE_TTL_SEC == 300.0"
    )
    result = _sp.run([sys.executable, "-c", code, module_path], env=env, capture_output=True, text=True)
    assert result.returncode == 0, f"bad env values crashed the import:\n{result.stderr}"
    for name in ("LLM_PROXY_PORT", "TIER_BACKOFF_SEC", "CIRCUIT_FAILURE_THRESHOLD"):
        assert f"bad {name}" in result.stderr, f"expected fallback warning for {name} in stderr"


def test_latency_budget_skips_remaining_candidates(monkeypatch):
    """vad-z28 regression: once the total-latency budget is spent, the routing
    loop must stop trying candidates and return the 502 fallback."""
    _reset_circuit(monkeypatch)
    monkeypatch.setattr(proxy, "PROXY_TOTAL_BUDGET_SEC", 0.0)
    calls = []
    monkeypatch.setattr(
        proxy.watcher_allocator, "get_candidate_order", lambda wid, c: list(c)
    )

    def fake_try(payload, model, label, deadline=None):
        calls.append(label)
        return None

    monkeypatch.setattr(proxy, "_try_candidate", fake_try)

    outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert calls == [], "no candidate should be tried once the budget is spent"
    assert outcome[1] == 502
    # No attempt was made, so neither failure counter may move (vad-89r).
    assert proxy._circuit_failures == 0
    assert proxy._litellm_down_failures == 0


def test_latency_budget_caps_backoff_and_skips_health_penalty(monkeypatch):
    """vad-z28 regression: backoff sleeps are capped at the remaining budget."""
    _reset_circuit(monkeypatch)
    monkeypatch.setattr(proxy, "model_health", proxy.ModelHealthTracker())
    monkeypatch.setattr(proxy, "PROXY_TOTAL_BUDGET_SEC", 0.05)
    monkeypatch.setattr(proxy, "TIER_MAX_RETRIES", 3)
    monkeypatch.setattr(proxy, "TIER_BACKOFF_SEC", 10.0)
    sleeps = []
    monkeypatch.setattr(proxy.time, "sleep", lambda s: sleeps.append(s))

    def boom(body):
        raise urllib.error.URLError("boom")

    monkeypatch.setattr(proxy, "_post_to_litellm", boom)
    candidates = [{"model": "m-a", "label": "label-a"}]
    monkeypatch.setattr(
        proxy.watcher_allocator, "get_candidate_order", lambda wid, c: list(candidates)
    )

    outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert outcome[1] == 502
    assert sleeps, "expected at least one capped backoff sleep"
    assert all(s <= 0.06 for s in sleeps), f"backoff not capped by budget: {sleeps}"


def test_budget_abort_in_candidate_has_no_health_penalty(monkeypatch):
    """vad-z28 regression: a candidate aborted because the latency budget ran
    out must NOT record a model failure (the model did not fail - the caller
    ran out of time) and must not touch the upstream."""
    import time as _time

    fresh = proxy.ModelHealthTracker()
    monkeypatch.setattr(proxy, "model_health", fresh)

    def unexpected(body):
        raise AssertionError("upstream must not be called once the budget is spent")

    monkeypatch.setattr(proxy, "_post_to_litellm", unexpected)

    result = proxy._try_candidate(
        {"model": "m-a"}, "m-a", "label-a", deadline=_time.monotonic() - 1
    )
    assert result is None
    assert fresh._failures.get("label-a", 0) == 0, (
        "budget abort must not record a model failure"
    )


def test_connection_failure_does_not_cool_down_model(monkeypatch):
    """vad-89r regression: a candidate exhausted on connection-level errors
    (litellm unreachable) must NOT record a model failure - one backend's
    outage must not cool down a healthy model."""
    monkeypatch.setattr(proxy, "model_health", proxy.ModelHealthTracker())
    _reset_circuit(monkeypatch)
    _fast_retry(monkeypatch)

    def conn_boom(body):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(proxy, "_post_to_litellm", conn_boom)

    result = proxy._try_candidate({"model": "m-a"}, "m-a", "label-a")
    assert result is proxy._LITELLM_CONN_FAILED
    assert proxy.model_health._failures.get("label-a", 0) == 0, (
        "litellm-down must not cool down the model"
    )


def test_litellm_down_and_model_down_circuits_counted_separately(monkeypatch):
    """vad-89r regression: connection-level failures count toward the
    litellm-down circuit, model-level failures toward the all-models circuit,
    and neither blocks a successful request."""
    monkeypatch.setattr(proxy, "model_health", proxy.ModelHealthTracker())
    _reset_circuit(monkeypatch)
    _fast_retry(monkeypatch)
    monkeypatch.setattr(
        proxy.watcher_allocator, "get_candidate_order", lambda wid, c: list(c)
    )

    def conn_boom(body):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(proxy, "_post_to_litellm", conn_boom)

    outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert outcome[1] == 502
    assert proxy._litellm_down_failures >= 1
    assert proxy._circuit_failures == 0, (
        "connection-level exhaustion must not count as model-down"
    )

    # Now a request with real model-level failures (fake _try_candidate None).
    monkeypatch.setattr(
        proxy, "_try_candidate", lambda payload, model, label, deadline=None: None
    )
    outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert outcome[1] == 502
    assert proxy._circuit_failures >= 1, "model-level exhaustion must count as model-down"

    # Success resets both counters.
    monkeypatch.setattr(
        proxy, "_try_candidate",
        lambda payload, model, label, deadline=None: (200, b"{}"),
    )
    outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert outcome[1] == 200
    assert proxy._litellm_down_failures == 0 and proxy._circuit_failures == 0


def test_litellm_down_circuit_reports_reason(monkeypatch):
    """vad-89r regression: a circuit opened by litellm-down failures reports
    reason=litellm_down in the 503 circuit body."""
    monkeypatch.setattr(proxy, "model_health", proxy.ModelHealthTracker())
    _reset_circuit(monkeypatch)
    _fast_retry(monkeypatch)
    monkeypatch.setattr(
        proxy.watcher_allocator, "get_candidate_order", lambda wid, c: list(c)
    )

    def conn_boom(body):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(proxy, "_post_to_litellm", conn_boom)

    # Threshold requests, each failing on every candidate at the connection
    # level, must open the circuit with the litellm_down reason.
    for _ in range(proxy.CIRCUIT_FAILURE_THRESHOLD):
        outcome = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
        assert outcome[1] == 502

    outcome2 = proxy.route_chat_completions(json.dumps({"model": "m-a"}).encode(), {})
    assert outcome2[1] == 503
    circuit_body = json.loads(outcome2[2])
    assert circuit_body.get("reason") == "litellm_down"
