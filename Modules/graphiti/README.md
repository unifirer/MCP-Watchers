# Modules\graphiti — vendored graphiti glue

The `###1` launcher supervises one graphiti service:

| Service | Port | File |
|---------|------|------|
| graphiti embed proxy | 8003 | `embed_server.py` |

`graphiti-mcp` (:8002) is a Docker container (`restart: always`, native HTTP
container :8000 -> host :8002). Toolport reaches it at
`http://127.0.0.1:8002/mcp`. The old Windows python bridge
(`mcp_proxy.py`, stdio `main.py`, `config-litellm.yaml`) was deleted
2026-09-18. The launcher never spawns or supervises :8002; it only probes
the port and tells the operator to `docker start graphiti-mcp` when down.

## What is vendored here

One file. It is ours, not upstream graphiti code.

| File | Purpose |
|------|---------|
| `embed_server.py` | OpenAI-compatible embeddings proxy on :8003. Serves `all-MiniLM-L6-v2`. |

The Docker container's embedder points at
`http://host.docker.internal:8003/v1`, so this host proxy must stay up.

## What stays in the install

The embed venv stays under:

```
%LOCALAPPDATA%\Programs\graphiti-mcp\mcp_server\
```

A venv cannot be relocated by copy. Its `Scripts\*.exe` shims embed
absolute paths.

## Precedence in the launcher

The launcher resolves `embed_server.py` through a candidate list:

1. `<launcher directory>\Modules\graphiti\` — this repo copy
2. `<install>\` — the `%LOCALAPPDATA%` copy

The repo copy wins. The install copy is the fallback for a bare install with no
repo. The launcher prints which copy it resolved.

## Dependency chain

The :8002 container needs three host services before it can serve:

| Dependency | Endpoint from container |
|------------|-------------------------|
| embed proxy | `host.docker.internal:8003` |
| litellm | `host.docker.internal:4000` |
| FalkorDB | `host.docker.internal:6379` |

Cold start is slow (roughly two minutes while graphiti builds FalkorDB
indices). Docker `restart: always` rides that out.

## Why this file is copied here

It originally lived only inside the graphiti install, untracked. That left
it exposed to `git clean -xdf` and to any cleanup of a `Temp` directory.
Copying it into the repo puts it under version control.

## Logs

| Service | Log | Error log |
|---------|-----|-----------|
| :8003 | `%LOCALAPPDATA%\graphiti-embed\embed-8003.log` | `embed-8003.log.err` |

The supervisor writes its own log:

| Supervisor | Log |
|------------|-----|
| :8003 | `%LOCALAPPDATA%\graphiti-embed\supervisor.log` |

:8002 logs live in Docker (`docker logs graphiti-mcp`).
