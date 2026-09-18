import importlib.util
import os
import sys

import pytest

ROOT = os.path.join(os.path.dirname(__file__), "..", "dev_tools")
sys.path.insert(0, ROOT)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# The proxy ships as "###2.llm_fallback_proxy.py" at the repo root. The leading
# "#" characters make it an invalid Python identifier, so no sys.path entry can
# ever reach it -- a plain `import llm_fallback_proxy` raises ModuleNotFoundError
# and, because that happens at collection time, it aborts the WHOLE pytest run
# (Interrupted: 1 error during collection) instead of failing one test. Load it
# by file location when the plain import cannot find it.
try:
    from llm_fallback_proxy import (  # noqa: E402
        ModelHealthTracker,
        WatcherModelAllocator,
        extract_watcher_id,
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
    ModelHealthTracker = llm_fallback_proxy.ModelHealthTracker  # noqa: E402
    WatcherModelAllocator = llm_fallback_proxy.WatcherModelAllocator  # noqa: E402
    extract_watcher_id = llm_fallback_proxy.extract_watcher_id  # noqa: E402

ALL_TEST_CANDIDATES = [
    {"model": "m1", "label": "model_1"},
    {"model": "m2", "label": "model_2"},
    {"model": "m3", "label": "model_3"},
]


def test_extract_watcher_id_from_headers():
    assert extract_watcher_id({"X-MCP-Watcher": "watcher-git"}) == "watcher-git"
    assert extract_watcher_id({"X-Watcher-ID": "watcher-fs"}) == "watcher-fs"
    assert extract_watcher_id({"X-Client-ID": "watcher-db"}) == "watcher-db"
    assert extract_watcher_id({"User-Agent": "mcp-watcher-logs/1.0"}) == "mcp-watcher-logs/1.0"
    assert extract_watcher_id({}) == "default"


def test_extract_watcher_id_from_payload():
    assert extract_watcher_id({}, payload={"watcher_id": "watcher-payload"}) == "watcher-payload"
    assert extract_watcher_id({}, payload={"client_id": "client-payload"}) == "client-payload"


def test_unique_model_assigned_per_watcher():
    health = ModelHealthTracker(cooldown_sec=5.0)
    allocator = WatcherModelAllocator(health_tracker=health, lease_ttl_sec=60.0)

    order1 = allocator.get_candidate_order("watcher-1", ALL_TEST_CANDIDATES)
    order2 = allocator.get_candidate_order("watcher-2", ALL_TEST_CANDIDATES)
    order3 = allocator.get_candidate_order("watcher-3", ALL_TEST_CANDIDATES)

    primary1 = order1[0]["label"]
    primary2 = order2[0]["label"]
    primary3 = order3[0]["label"]

    assert len({primary1, primary2, primary3}) == 3
    assert {primary1, primary2, primary3} == {"model_1", "model_2", "model_3"}


def test_same_watcher_retains_primary_model_while_healthy():
    health = ModelHealthTracker(cooldown_sec=5.0)
    allocator = WatcherModelAllocator(health_tracker=health, lease_ttl_sec=60.0)

    primary_first = allocator.get_candidate_order("watcher-1", ALL_TEST_CANDIDATES)[0]["label"]
    primary_second = allocator.get_candidate_order("watcher-1", ALL_TEST_CANDIDATES)[0]["label"]

    assert primary_first == primary_second


def test_model_failure_reassigns_watcher_to_next_unique():
    health = ModelHealthTracker(cooldown_sec=5.0)
    allocator = WatcherModelAllocator(health_tracker=health, lease_ttl_sec=60.0)

    order_w1 = allocator.get_candidate_order("watcher-1", ALL_TEST_CANDIDATES)
    w1_initial = order_w1[0]["label"]

    health.record_failure(w1_initial)

    new_order_w1 = allocator.get_candidate_order("watcher-1", ALL_TEST_CANDIDATES)
    assert new_order_w1[0]["label"] != w1_initial
    assert health.is_healthy(new_order_w1[0]["label"]) is True


def test_scarcity_sharing_when_watchers_exceed_healthy_models():
    health = ModelHealthTracker(cooldown_sec=5.0)
    allocator = WatcherModelAllocator(health_tracker=health, lease_ttl_sec=60.0)

    order1 = allocator.get_candidate_order("w1", ALL_TEST_CANDIDATES)
    order2 = allocator.get_candidate_order("w2", ALL_TEST_CANDIDATES)
    order3 = allocator.get_candidate_order("w3", ALL_TEST_CANDIDATES)
    order4 = allocator.get_candidate_order("w4", ALL_TEST_CANDIDATES)

    assert len(order1) == 3
    assert len(order2) == 3
    assert len(order3) == 3
    assert len(order4) == 3

    assigned = [order1[0]["label"], order2[0]["label"], order3[0]["label"], order4[0]["label"]]
    assert all(label in {"model_1", "model_2", "model_3"} for label in assigned)
