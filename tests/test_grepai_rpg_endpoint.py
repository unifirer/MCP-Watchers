# tests/test_grepai_rpg_endpoint.py
import os
import re

CONFIG = open(os.path.join(os.path.dirname(__file__), "..", ".grepai", "config.yaml"), encoding="utf-8").read()


def test_rpg_llm_endpoint_points_at_cloud_proxy():
    rpg = CONFIG.split("rpg:")[-1]
    assert re.search(r'llm_endpoint:\s*http://127\.0\.0\.1:11436/v1', rpg), "rpg llm_endpoint not at cloud proxy"
    assert re.search(r'^    provider:\s*ollama', CONFIG, re.M), "embedder provider changed"
    assert "sk-nous-" not in CONFIG, "real Nous key must not be in grepai config"


def test_rpg_is_enabled():
    assert re.search(r'rpg:\s*\n\s+enabled:\s*true', CONFIG), "rpg.enabled must be true for cloud LLM"
