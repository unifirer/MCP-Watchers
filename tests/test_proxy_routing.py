import json
import importlib.util
import os
import sys
from unittest.mock import patch

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# The proxy ships as "###2.llm_fallback_proxy.py" at the repo root. The leading
# "#" characters make it an invalid Python identifier, so no sys.path entry can
# ever reach it -- a plain `import llm_fallback_proxy` raises ModuleNotFoundError
# and, because that happens at collection time, it aborts the WHOLE pytest run
# instead of failing one test. That is how this file died in VAD on 2026-09-05,
# when fcbfde29 moved the proxy out of dev_tools/ and left the old
# sys.path.insert(0, dev_tools) behind. Load it by file location instead, and
# register it in sys.modules under its plain name so any
# patch("llm_fallback_proxy...") call below keeps working.
try:
    from llm_fallback_proxy import (  # noqa: E402
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
    model_health = llm_fallback_proxy.model_health  # noqa: E402
    watcher_allocator = llm_fallback_proxy.watcher_allocator  # noqa: E402
    route_chat_completions = llm_fallback_proxy.route_chat_completions  # noqa: E402


def setup_function():
    model_health.reset()
    watcher_allocator.reset()


def test_route_chat_completions_uses_watcher_primary_model():
    payload = json.dumps({"messages": [{"role": "user", "content": "hello"}]}).encode()
    headers_w1 = {"X-MCP-Watcher": "watcher-alpha"}
    headers_w2 = {"X-MCP-Watcher": "watcher-beta"}

    called_models = []

    def mock_post(body):
        data = json.loads(body)
        called_models.append(data["model"])
        return 200, b'{"choices":[{"message":{"content":"ok"}}]}'

    with patch("llm_fallback_proxy._post_to_litellm", side_effect=mock_post):
        upstream1, status1, _, _ = route_chat_completions(payload, headers=headers_w1)
        upstream2, status2, _, _ = route_chat_completions(payload, headers=headers_w2)

    assert status1 == 200
    assert status2 == 200
    assert upstream1 != upstream2
    assert called_models[0] != called_models[1]


# NOT PORTED: test_route_chat_completions_falls_back_and_records_health.
# It asserted that a failing upstream makes the proxy fall back and then call
# model_health.record_failure for that model. Both halves are now wrong:
#   1. it raised a bare Exception("Connection error"), which the proxy has
#      never caught - _try_model catches (urllib.error.HTTPError) and
#      (urllib.error.URLError, OSError, TimeoutError) only.
#   2. even with a caught type, vad-89r deliberately does NOT cool the model on
#      a connection-level failure - litellm being unreachable is not a verdict
#      on the model. _try_model returns _LITELLM_CONN_FAILED instead.
# tests/test_llm_fallback_proxy.py pins that behaviour explicitly (URLError ->
# result is proxy._LITELLM_CONN_FAILED, no model failure recorded), so this
# test would contradict a test that is already here.
