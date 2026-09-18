<#
.SYNOPSIS
    Graphenium (gm) bridge: forwards gm's LLM calls to the local
    Nous/Ollama fallback proxy (###2.llm_fallback_proxy.py) and rewrites
    the response into gm's strict semantic schema.

.DESCRIPTION
    gm 0.18.0 cannot talk to a local Ollama directly for its LLM "semantic
    extraction" stage. Two bugs in gm:

      1. gm POSTs to the bare --api-base path (e.g. /v1) instead of
         /v1/chat/completions, which Ollama rejects with 404.
      2. gm's parser (src/semantic/parse.rs) only accepts a bare JSON object
         with its exact schema (nodes: id/label/source_file; edges:
         source/target/relation/confidence; hyperedges: 3+ nodes). Local models
         like qwen2.5:7b wrap the JSON in ```json fences, add prose, invent
         their own keys, and emit an absolute/verbatim source_file path that
         gm's filter_by_file() then rejects -> 0 semantic nodes.

    This proxy:
      * maps gm's bare /v1 POST -> the fallback proxy's /v1/chat/completions
      * rewrites the model's loosely-formatted reply into gm's exact schema,
        forcing source_file to a bare filename (so gm's filename match works)
      * adds a bearer key so gm's "no API key" gate is satisfied

    Verified: `gm run . --provider openai-compatible --api-base
    http://localhost:13001/v1 --model qwen2.5:7b --api-key ollama-local --no-viz`
    reports "Semantic: N nodes, M edges".

.PARAMETER Port        Local port the proxy listens on (default 13001).
.PARAMETER Model       Default model name (informational; gm passes its own).
#>
param(
    [int]$Port = 13001,
    [string]$Model = "qwen2.5:7b"
)

$ErrorActionPreference = 'Stop'
# gm talks to the local fallback proxy (###2.llm_fallback_proxy.py on port 11436),
# which itself routes Nous (primary) -> Ollama (fallback) and normalizes
# the response below for gm's strict parser.

# ---- inline Python proxy (no extra file needed) ----
$py = @'
import http.server, socketserver, urllib.request, json, re, sys

UPSTREAM = "http://127.0.0.1:11436"

def rewrite_response(raw_text, fallback_source="source.ext", override_source=None):
    # gm's own parser (parse.rs) uses three layers: direct parse, fenced
    # code block, then first-{ to last-} brace slice. Mirror that last,
    # most-robust strategy: grab the full JSON object even when the model
    # wraps it in ```json fences or adds trailing prose.
    # Local models (qwen2.5:7b) frequently embed Windows paths with raw
    # backslashes inside the JSON string values (e.g. "C:\Users\...\auth.py"
    # or the "\\?\" long-path prefix). Those are INVALID JSON escapes and make
    # json.loads fail -> gm would drop the whole graph. Since we override
    # source_file anyway, just turn every backslash that is NOT a valid JSON
    # escape into a forward slash (always valid JSON, harmless here).
    sanitized = re.sub(r'\\(?!["\\/bfnrtu])', '/', raw_text)
    s = sanitized.find("{"); e = sanitized.rfind("}")
    js = sanitized[s:e+1] if (s != -1 and e != -1 and e > s) else sanitized
    try:
        obj = json.loads(js)
    except Exception:
        return raw_text
    # gm's semantic prompt can list MULTIPLE files (=== FILE: <path> ===
    # markers), so the prompt-derived override_source is unreliable (it grabs
    # the first marker, which is often not the file being analyzed). The model,
    # however, returns the source_file of the file it actually analyzed (full
    # path). Normalize THAT to a bare basename and stamp it; fall back to the
    # prompt marker only if the model omitted source_file. gm's filter_by_file()
    # keeps nodes whose source_file == the corpus basename, so it must match.
    def basename(p):
        p = (p or "").replace("\\","/").rstrip("/")
        return p.split("/")[-1] if p else ""
    nodes = obj.get("nodes", []) or []
    seen = set(); out_nodes = []
    for n in nodes:
        if not isinstance(n, dict): continue
        nid = str(n.get("id") or n.get("name") or n.get("label") or "").strip()
        if not nid: continue
        nid = re.sub(r"[^a-z0-9_]", "_", nid.lower())
        if nid in seen: continue
        seen.add(nid)
        label = str(n.get("label") or n.get("name") or nid).strip() or nid
        sf = basename(n.get("source_file")) or basename(override_source) or fallback_source
        out_nodes.append({"id": nid, "label": label, "file_type": "code", "source_file": sf})
    node_sf = {n["id"]: n["source_file"] for n in out_nodes}
    edges = obj.get("edges", []) or []; out_edges = []
    for ed in edges:
        if not isinstance(ed, dict): continue
        src = str(ed.get("source") or ed.get("from") or "").strip()
        tgt = str(ed.get("target") or ed.get("to") or "").strip()
        if not src or not tgt: continue
        src = re.sub(r"[^a-z0-9_]", "_", src.lower())
        tgt = re.sub(r"[^a-z0-9_]", "_", tgt.lower())
        rel = str(ed.get("relation") or ed.get("relationship") or ed.get("type") or "uses").strip() or "uses"
        # Prefer the model's own edge source_file; otherwise inherit it from the
        # connected node(s) so it always matches the real corpus file even when
        # the prompt has multiple === FILE: === markers (override_source lies).
        esf = (basename(ed.get("source_file")) or node_sf.get(src)
               or node_sf.get(tgt) or basename(override_source) or fallback_source)
        out_edges.append({"source": src, "target": tgt, "relation": rel,
                          "confidence": "INFERRED", "confidence_score": 1.0,
                          "source_file": esf})
    hes = obj.get("hyperedges", []) or []; out_hes = []
    valid_ids = {n["id"] for n in out_nodes}
    for h in hes:
        if not isinstance(h, dict): continue
        members = [re.sub(r"[^a-z0-9_]", "_", str(x).lower()) for x in (h.get("nodes") or [])]
        members = [x for x in members if x in valid_ids]
        if len(members) < 3: continue
        hid = str(h.get("id") or ("he_" + str(len(out_hes)))).strip() or ("he_" + str(len(out_hes)))
        # Inherit the source_file from the first valid member node (the model
        # rarely tags hyperedges with source_file, and override_source is wrong
        # under multi-file prompts).
        hsf = (basename(h.get("source_file")) or node_sf.get(members[0])
               or basename(override_source) or fallback_source)
        out_hes.append({"id": hid, "label": str(h.get("label") or "group"),
                        "nodes": members, "relation": "participate_in",
                        "confidence": "INFERRED", "confidence_score": 0.7,
                        "source_file": hsf})
    return json.dumps({"nodes": out_nodes, "edges": out_edges, "hyperedges": out_hes}, ensure_ascii=False)

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        # gm (reqwest) sends "Expect: 100-continue" for its large
        # prompt body. SoupServer's BaseHTTPRequestHandler does NOT
        # auto-ack it, which deadlocks: gm waits for "100 Continue"
        # before sending the body, while we block reading the body. Send
        # the continue response first so gm streams the body.
        if self.headers.get('Expect', '').lower() == '100-continue':
            self.send_response_only(100)
            self.end_headers()
        length = int(self.headers.get('Content-Length', 0))
        if length <= 0:
            # fall back to reading the whole stream (chunked / no Content-Length)
            body = self.rfile.read()
        else:
            body = self.rfile.read(length)
        target = "/v1/chat/completions" if (self.path.rstrip('/') in ('/v1','') or self.path.endswith('/chat/completions')) else self.path
        # The authoritative source filename is in gm's prompt as
        # "=== FILE: <absolute_path> ===". gm's filter_by_file() keeps only
        # nodes whose source_file matches that name, so we must stamp it on
        # every item we return. Default to a harmless placeholder.
        override_source = None
        try:
            reqobj = json.loads(body)
            # gm asks for up to 8192 completion tokens; on a local model
            # (qwen2.5:7b) that generation takes many minutes and trips gm's
            # own retry/502 path. Cap it so a local model returns in time
            # (gm allows <=50 nodes/edges, easily within 1200 tokens).
            if isinstance(reqobj.get("max_completion_tokens"), int) and reqobj["max_completion_tokens"] > 1200:
                reqobj["max_completion_tokens"] = 1200
            # Local models (qwen2.5:7b via Ollama) default to temperature ~0.8,
            # which makes extraction NON-DETERMINISTIC and frequently returns an
            # empty "nodes":[] graph -> gm reports 0 nodes. Force temperature 0
            # so the model reliably emits the graph it can see in the source.
            reqobj["temperature"] = 0
            # Pull the corpus filename out of the user prompt.
            full_text = ""
            for msg in reqobj.get("messages", []):
                c = msg.get("content")
                if isinstance(c, str):
                    full_text += c + "\n"
                elif isinstance(c, list):
                    for part in c:
                        if isinstance(part, dict) and isinstance(part.get("text"), str):
                            full_text += part["text"] + "\n"
            m = re.search(r"=== FILE:\s*(\S+?)\s*===", full_text)
            if m:
                override_source = m.group(1).replace("\\", "/").rstrip("/").split("/")[-1]
            body = json.dumps(reqobj).encode()
        except Exception:
            pass
        try:
            req = urllib.request.Request(UPSTREAM + target, data=body,
                                          headers={'Content-Type': 'application/json'}, method='POST')
            resp = urllib.request.urlopen(req, timeout=1800)
            data = resp.read()
            try:
                parsed = json.loads(data)
                if isinstance(parsed, dict) and "choices" in parsed:
                    content = parsed["choices"][0]["message"]["content"]
                    rewritten = rewrite_response(content, override_source=override_source)
                    parsed["choices"][0]["message"]["content"] = rewritten
                    data = json.dumps(parsed, ensure_ascii=False).encode()
            except Exception:
                pass
            self.send_response(resp.status)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)
        except urllib.error.HTTPError as e:
            err = e.read()
            self.send_response(e.code); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(err)
        except Exception as e:
            sys.stderr.write("proxy err %s\n" % e); self.send_response(502); self.end_headers()
    def log_message(self, *a): pass

# Single-instance guard: if something is already listening on our port
# (e.g. a stale bridge left over from a previous run), gm would connect to
# THAT instead of us and get garbage/refused. Kill the squatter so we own
# the port exclusively. We find the PID via a netstat parse.
import subprocess as _sp
def _free_port(port):
    try:
        out = _sp.run(["netstat", "-ano"], capture_output=True, text=True,
                       timeout=10).stdout
        for line in out.splitlines():
            cols = line.split()
            if len(cols) >= 5 and (":" + str(port)) in cols[1] and cols[3] == "LISTENING":
                pid = cols[4]
                if pid.isdigit() and pid != str(_sp.current_process().pid):
                    try:
                        _sp.run(["taskkill", "/f", "/pid", pid], capture_output=True, timeout=10)
                    except Exception:
                        pass
    except Exception:
        pass

_free_port(%PORT%)

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", %PORT%), H) as httpd:
    sys.stderr.write("gm-ollama-bridge listening on %PORT% -> %s\n" % UPSTREAM)
    sys.stderr.flush()
    httpd.serve_forever()
'@

# substitute port tokens
$py = $py -replace '%PORT%', [string]$Port
# resolve python: prefer the one on PATH, else the hermes venv
$pyExe = $null
if (Get-Command python -ErrorAction SilentlyContinue) { $pyExe = (Get-Command python).Source }
elseif (Test-Path "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\python.exe") {
    $pyExe = "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\python.exe"
}
if (-not $pyExe) { Write-Error "python not found"; exit 1 }

# Write the proxy to a temp .py file and run it. Using `python -c <inline
# string>` on Windows mangles the multi-line source (regex backticks, quotes)
# and breaks the server at runtime; a temp file avoids all quoting issues.
$tmpPy = Join-Path $env:TEMP ("gm-ollama-bridge-" + $Port + ".py")
Set-Content -Path $tmpPy -Value $py -Encoding UTF8
try {
    & $pyExe $tmpPy
} finally {
    if (Test-Path $tmpPy) { Remove-Item $tmpPy -Force }
}
