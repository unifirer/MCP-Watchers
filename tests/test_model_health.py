import importlib.util
import os
import sys
import time

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
    from llm_fallback_proxy import ModelHealthTracker  # noqa: E402

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
    ModelHealthTracker = llm_fallback_proxy.ModelHealthTracker  # noqa: E402


def test_model_health_initial_state():
    tracker = ModelHealthTracker(cooldown_sec=5.0)
    assert tracker.is_healthy("nous_laguna-s") is True


def test_model_health_failure_enters_cooldown():
    tracker = ModelHealthTracker(cooldown_sec=2.0)
    tracker.record_failure("nous_laguna-s")
    assert tracker.is_healthy("nous_laguna-s") is False


def test_model_health_cooldown_expires():
    tracker = ModelHealthTracker(cooldown_sec=0.1)
    tracker.record_failure("nous_laguna-s")
    assert tracker.is_healthy("nous_laguna-s") is False
    time.sleep(0.15)
    assert tracker.is_healthy("nous_laguna-s") is True


def test_model_health_success_resets():
    tracker = ModelHealthTracker(cooldown_sec=5.0)
    tracker.record_failure("nous_laguna-s")
    assert tracker.is_healthy("nous_laguna-s") is False
    tracker.record_success("nous_laguna-s")
    assert tracker.is_healthy("nous_laguna-s") is True


def test_get_healthy_models_filters_unhealthy():
    tracker = ModelHealthTracker(cooldown_sec=5.0)
    candidates = [
        {"model": "poolside/laguna-s-2.1:free", "label": "nous_laguna-s"},
        {"model": "poolside/laguna-xs-2.1:free", "label": "nous_laguna-xs"},
    ]
    tracker.record_failure("nous_laguna-s")
    healthy = tracker.get_healthy_models(candidates)
    assert len(healthy) == 1
    assert healthy[0]["label"] == "nous_laguna-xs"
