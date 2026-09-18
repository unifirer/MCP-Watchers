#!/usr/bin/env python3
"""Tiny OpenAI-compatible /embeddings proxy backed by sentence-transformers."""
import json
import os
import sys
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler

# Force local model cache. Resolved from the user profile at runtime -- this
# checkout is scanned by tests/test_launcher_portable_paths.py, which fails on
# any literal "C:\Users\<name>" / "C:/Users/<name>" string in the tree.
os.environ.setdefault(
    "SENTENCE_TRANSFORMERS_HOME",
    os.path.join(str(Path.home()), ".cache", "torch", "sentence_transformers"),
)

MODEL_NAME = os.environ.get("EMBED_MODEL", "all-MiniLM-L6-v2")
_model = None

def get_model():
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        print(f"Loading embedding model: {MODEL_NAME}", flush=True)
        _model = SentenceTransformer(MODEL_NAME)
        print(f"Model loaded", flush=True)
    return _model

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/v1/embeddings":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
            inp = body.get("input", "")
            if isinstance(inp, str):
                inp = [inp]
            model = get_model()
            embeddings = model.encode(inp, show_progress_bar=False)
            dims = embeddings.shape[1]
            resp = {
                "object": "list",
                "data": [
                    {"object": "embedding", "index": i, "embedding": emb.tolist()}
                    for i, emb in enumerate(embeddings)
                ],
                "model": MODEL_NAME,
                "usage": {"prompt_tokens": 0, "total_tokens": 0},
            }
            out = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == "/v1/models":
            resp = {
                "object": "list",
                "data": [{
                    "id": MODEL_NAME,
                    "object": "model",
                    "created": 0,
                    "owned_by": "local",
                }]
            }
            out = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        elif self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        sys.stderr.write("[embed] " + (fmt % args) + "\n")

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"Embedding server listening on :{port}", flush=True)
    server.serve_forever()
