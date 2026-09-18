# tests/test_grepai_rpg_endpoint.py
import os
import re

import pytest

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "..", ".grepai", "config.yaml")


def _config():
    """Read the local grepai config, or skip if it is not provisioned.

    .grepai/ is gitignored tool state -- grepai owns and rewrites config.yaml
    (see .gitignore and the Ollama port notes). It is never committed, so a
    fresh clone has none and this module must not explode at import time the
    way it used to (it opened the file at module scope).
    """
    if not os.path.exists(CONFIG_PATH):
        pytest.skip(
            "no .grepai/config.yaml - grepai is not initialized in this checkout "
            "(tool state, gitignored). Nothing to assert."
        )
    with open(CONFIG_PATH, encoding="utf-8") as fh:
        return fh.read()


def test_rpg_llm_endpoint_points_at_cloud_proxy():
    config = _config()
    rpg = config.split("rpg:")[-1]
    assert re.search(r'llm_endpoint:\s*http://127\.0\.0\.1:11436/v1', rpg), "rpg llm_endpoint not at cloud proxy"
    assert re.search(r'^    provider:\s*ollama', config, re.M), "embedder provider changed"
    assert "sk-nous-" not in config, "real Nous key must not be in grepai config"


def test_rpg_is_enabled():
    config = _config()
    assert re.search(r'rpg:\s*\n\s+enabled:\s*true', config), "rpg.enabled must be true for cloud LLM"
