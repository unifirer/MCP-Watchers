# Modules\graphiti — vendored graphiti glue

The `###1` launcher supervises two graphiti services:

| Service | Port | File |
|---------|------|------|
| graphiti embed proxy | 8003 | `embed_server.py` |
| graphiti MCP proxy | 8002 | `mcp_proxy.py` |

Both are port-singleton persistent backends. `graphiti-mcp` (:8002) is what
Toolport reaches at `http://127.0.0.1:8002/mcp`. It wraps graphiti's
stdio-only MCP server in an HTTP JSON-RPC endpoint.

## What is vendored here

These three files are ours. They are not upstream graphiti code.

| File | Purpose |
|------|---------|
| `mcp_proxy.py` | HTTP JSON-RPC wrapper for the stdio MCP server. Exposes 13 tools. |
| `embed_server.py` | OpenAI-compatible embeddings proxy on :8003. Serves `all-MiniLM-L6-v2`. |
| `config-litellm.yaml` | Graphiti config: LLM, embedder, and database endpoints. |

## What stays in the install

The graphiti clone, its virtual environment, and `main.py` stay under:

```
%LOCALAPPDATA%\Programs\graphiti-mcp\mcp_server\
```

That tree is upstream and re-clonable. It holds the `.venv` and `main.py`.
`mcp_proxy.py` spawns `<install>\.venv\Scripts\python.exe main.py --transport
stdio`. The virtual environment must stay install-resident. A venv cannot be
moved by copying it. Its `Scripts\*.exe` shims embed absolute paths.

## Path resolution

`mcp_proxy.py` locates its two inputs at run time. It does not hardcode them.

**Config** — first existing candidate wins:

1. `<this directory>\config-litellm.yaml` — repo layout
2. `<this directory>\config\config-litellm.yaml` — install layout
3. `<install>\config\config-litellm.yaml` — absolute fallback

**Server** — the install path, derived from `%LOCALAPPDATA%`:

```
<LOCALAPPDATA>\Programs\graphiti-mcp\mcp_server\.venv\Scripts\python.exe
```

The proxy prints the resolved script, config, and server paths at startup. The
precedence is never a silent guess.

## Precedence in the launcher

The launcher resolves `mcp_proxy.py` and `embed_server.py` through a candidate
list:

1. `<launcher directory>\Modules\graphiti\` — this repo copy
2. `<install>\` — the `%LOCALAPPDATA%` copy

The repo copy wins. The install copy is the fallback for a bare install with no
repo. The launcher prints which copy it resolved.

## Dependency chain

:8002 needs three services before it can serve:

| Dependency | Port |
|------------|------|
| embed proxy | 8003 |
| litellm | 4000 |
| FalkorDB | 6379 |

Cold start is slow. It takes roughly two minutes, while graphiti builds the
FalkorDB indices. The launcher gates only on the HTTP listener. It lets the
stdio handshake warm in the background.

## Why these files are copied here

The files originally lived only inside the graphiti clone, untracked. That left
them exposed to `git clean -xdf` and to any cleanup of a `Temp` directory. No
backup existed. Copying them into the repo puts them under version control and
gives them a second physical location.

## Keeping the copies in sync

Three copies exist. They must stay byte-identical:

- `<install>\` — the copy the install runs
- `J:\audio\VAD\Modules\graphiti\`
- `J:\audio\MCP-Watchers\Modules\graphiti\`

Edit the repo copy first. Then copy it to the other two. Verify with SHA-256:

```bash
python - <<'PY'
import hashlib
for p in (r"C:\Users\yuni\AppData\Local\Programs\graphiti-mcp\mcp_server\mcp_proxy.py",
          r"J:\audio\VAD\Modules\graphiti\mcp_proxy.py",
          r"J:\audio\MCP-Watchers\Modules\graphiti\mcp_proxy.py"):
    print(hashlib.sha256(open(p, "rb").read()).hexdigest()[:16], p)
PY
```

All three hashes must match.

## Logs

| Service | Log | Error log |
|---------|-----|-----------|
| :8002 | `%LOCALAPPDATA%\graphiti-mcp\mcp-8002.log` | `mcp-8002.log.err` |
| :8003 | `%LOCALAPPDATA%\graphiti-embed\embed-8003.log` | `embed-8003.log.err` |

The supervisors write their own logs:

| Supervisor | Log |
|------------|-----|
| :8002 | `%LOCALAPPDATA%\graphiti-mcp\supervisor.log` |
| :8003 | `%LOCALAPPDATA%\graphiti-embed\supervisor.log` |
