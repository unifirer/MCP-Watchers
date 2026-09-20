"""End-to-end diversity tests for the watcher-aware fallback proxy.

These drive route_chat_completions() with the REAL ALL_CANDIDATES list and only
mock the HTTP hop (_post_to_litellm). That is the level tests/test_watcher_allocator.py
does not reach: it unit-tests WatcherModelAllocator against three synthetic
fixtures. Keeping both means a shrinking ALL_CANDIDATES, or a routing change that
breaks the full request path, is still caught.
"""
import importlib.util
import json
import os
import sys
from unittest.mock import patch

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# The proxy ships as "###2.llm_fallback_proxy.py" at the repo root. The leading
# "#" characters make it an invalid Python identifier, so no sys.path entry can
# ever reach it -- a plain `import llm_fallback_proxy` raises ModuleNotFoundError
# and, because that happens at collection time, it aborts the WHOLE pytest run
# (Interrupted: 1 error during collection) instead of failing one test. That is
# exactly how this file died in VAD on 2026-09-05, when fcbfde29 moved the proxy
# out of dev_tools/ and left the old sys.path.insert(0, dev_tools) behind.
# Load it by file location instead. Registering it in sys.modules under its plain
# name is what keeps patch("llm_fallback_proxy._post_to_litellm") working below.
try:
    from llm_fallback_proxy import (  # noqa: E402
        ALL_CANDIDATES,
        model_health,
        watcher_allocator,
        route_chat_completions,
    )
except ModuleNotFoundError:
    _proxy_path = os.path.join(REPO_ROOT, "###2.llm_fallback_proxy.py")
    _spec = importlib.util.spec_from_file_location(
        "llm_fallback_proxy", _proxy_path
    )
    if _spec is None or _spec.loader is None:
        raise ImportError(
            f"cannot load the fallback proxy from {_proxy_path}"
        ) from None
    llm_fallback_proxy = importlib.util.module_from_spec(_spec)
    sys.modules.setdefault("llm_fallback_proxy", llm_fallback_proxy)
    _spec.loader.exec_module(llm_fallback_proxy)
    ALL_CANDIDATES = llm_fallback_proxy.ALL_CANDIDATES  # noqa: E402
    model_health = llm_fallback_proxy.model_health  # noqa: E402
    watcher_allocator = llm_fallback_proxy.watcher_allocator  # noqa: E402
    route_chat_completions = llm_fallback_proxy.route_chat_completions  # noqa: E402


def setup_function():
    model_health.reset()
    watcher_allocator.reset()


def test_n_watchers_get_n_distinct_models():
    """Verify up to N watchers get N unique models when N <= len(ALL_CANDIDATES)."""
    payload = json.dumps({"messages": [{"role": "user", "content": "hi"}]}).encode()
    watchers = [f"mcp-watcher-{i}" for i in range(len(ALL_CANDIDATES))]

    used_upstreams = set()

    def mock_post(body):
        return 200, b'{"choices":[{"message":{"content":"ok"}}]}'

    with patch("llm_fallback_proxy._post_to_litellm", side_effect=mock_post):
        for w in watchers:
            upstream, status, _, _ = route_chat_completions(payload, headers={"X-MCP-Watcher": w})
            assert status == 200
            used_upstreams.add(upstream)

    # Every single watcher received a unique model
    assert len(used_upstreams) == len(ALL_CANDIDATES)


def test_graceful_model_sharing_when_models_fail():
    """Verify that when models fail, watchers share surviving healthy models without request failure."""
    payload = json.dumps({"messages": [{"role": "user", "content": "hi"}]}).encode()
    watchers = ["w1", "w2", "w3", "w4", "w5"]

    # Mark all models except 2 as failed/unhealthy
    surviving = ["nous_laguna-s", "nous_laguna-xs"]
    for c in ALL_CANDIDATES:
        if c["label"] not in surviving:
            model_health.record_failure(c["label"])

    assigned_upstreams = []

    def mock_post(body):
        return 200, b'{"choices":[{"message":{"content":"ok"}}]}'

    with patch("llm_fallback_proxy._post_to_litellm", side_effect=mock_post):
        for w in watchers:
            upstream, status, _, _ = route_chat_completions(payload, headers={"X-MCP-Watcher": w})
            assert status == 200
            assigned_upstreams.append(upstream)

    # All 5 requests succeeded and were served by the 2 surviving models
    assert len(assigned_upstreams) == 5
    assert set(assigned_upstreams).issubset(set(surviving))
