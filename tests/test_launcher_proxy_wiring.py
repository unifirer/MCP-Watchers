# tests/test_launcher_proxy_wiring.py
import pathlib, re, yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
BRIDGE = ROOT / "dev_tools/gm-ollama-bridge.ps1"
START = ROOT / "###2.llm_fallback_proxy.py"
REPOWISE_CFG = ROOT / ".repowise/config.yaml"

def _read(p): return p.read_text(encoding="utf-8", errors="ignore")

def test_gm_semantic_build_uses_proxy_not_direct_nous():
    src = _read(LAUNCHER)
    # Desired: gm run talks to fallback proxy at 11436, not inference-api.nousresearch.com
    assert '127.0.0.1:11436' in src or 'LLM_PROXY_PORT' in src or 'LLM_PROXY_BASE' in src, \
        "launcher must route gm through fallback proxy (11436), not direct NOUS_BASE_URL"
    # Must not hard-wire direct Nous base inside Invoke-GmSemanticBuild after fix
    block = re.search(r'function Invoke-GmSemanticBuild[\s\S]{0,4000}?\$runArgs\s*=\s*@\([^)]*\)', src)
    assert block, "Invoke-GmSemanticBuild block not found"
    snippet = block.group(0)
    assert 'NOUS_BASE_URL' not in snippet or '11436' in snippet, \
        "Invoke-GmSemanticBuild still points at NOUS_BASE_URL instead of proxy"

def test_repowise_watch_wired_to_proxy():
    src = _read(LAUNCHER)
    # Repowise must be launched after Ensure-LlmProxyRunning and its config base_url is 11436
    cfg = yaml.safe_load(_read(REPOWISE_CFG))
    assert cfg.get("litellm", {}).get("base_url") == "http://127.0.0.1:11436/v1"
    # Launcher must gate proxy before repowise watch (not fire repowise watch blindly)
    assert "Ensure-LlmProxyRunning" in src, "launcher must gate fallback proxy before repowise watch"
    gw_idx = src.find("Ensure-LlmProxyRunning")
    rw_idx = src.find('Start-WatcherDetached "repowise"')
    assert gw_idx != -1 and rw_idx != -1 and gw_idx < rw_idx, "proxy gate must precede repowise watch"

def test_bridge_upstream_points_to_proxy():
    src = _read(BRIDGE)
    assert '127.0.0.1:11436' in src, "gm-ollama-bridge UPSTREAM must be 11436 (fallback proxy)"
    assert '127.0.0.1:13000' not in src, "bridge still points at stale 13000"

def test_start_script_probes_canonical_port():
    src = _read(START)
    assert '11436' in src or 'LLM_PROXY_PORT' in src, "###2.llm_fallback_proxy.py must use canonical port 11436"
