# neo4j-atlas — the Neo4j backend for atlas-mcp-server

`docker-compose.yml` here is the **source of truth** for the Neo4j container that
atlas-mcp-server (Toolport server id `atlas`) talks to. It was reverse-engineered
from the live container on 2026-09-23 — see bead `mcpw-cnc.1`.

## Why this file exists

The upstream guide (cyanheads/atlas-mcp-server) says to clone the repo and run
`docker-compose up -d` from the project root. That did not happen here:

- atlas was installed as the **prebuilt npm global package** at
  `J:\Programs\npm-global\node_modules\atlas-mcp-server` (v2.8.15), not a git clone.
  The package ships no `docker-compose.yml` (only `atlas-backups/ dist/ logs/
  node_modules/ LICENSE README.md package.json`).
- The container was created with plain `docker run` — `docker inspect` shows no
  `com.docker.compose.*` labels.

So the container existed as a running process with no definition anywhere on disk,
and could not be reproduced on a clean machine.

## Live state (as captured)

| | |
|---|---|
| Container | `neo4j-atlas-mcp-server` |
| Image | `neo4j:5-community` (Neo4j 5.26.30) |
| Ports | `7474:7474` HTTP, `7687:7687` Bolt |
| Auth | `neo4j` / `password2` (`NEO4J_AUTH`) |
| Plugins | `["apoc"]` |
| Restart | `unless-stopped` |
| Data | **anonymous** volume -> `/data` |
| Logs | **anonymous** volume -> `/logs` |

Anonymous volume names, needed for the migration below:

```
0c92eccdfbec72a39deafcf5cbf752f8601ccb28598d644b0ce45d77dde937b1   ->  /data
f5bd562053da5e9393216cbd2f0c6bc36ed2e06d4216d8e7791afb3855cd8443   ->  /logs
```

## Do NOT just run `docker compose up -d`

The live container already owns the name `neo4j-atlas-mcp-server` and both ports,
so compose will refuse with a name conflict. **That failure is the safe outcome** —
do not "fix" it by deleting things.

The trap: if you `docker compose down -v` first and then `up -d`, compose starts on
the *named* volumes from this file, which are empty, while the real graph sits in
the two anonymous volumes above. You would get a running Neo4j with an empty
database and a healthy-looking healthcheck. That is data loss disguised as success.

## Migration (only when you actually want the compose-managed container)

1. Stop the server so nothing writes mid-copy:
   `docker stop neo4j-atlas-mcp-server`
2. Create the target volumes:
   `docker volume create neo4j-atlas-data`
   `docker volume create neo4j-atlas-logs`
3. Copy the data across (a throwaway container mounting both sides is the simplest
   route — mount the anonymous volumes read-only):
   `docker run --rm -v 0c92eccdfbec72a39deafcf5cbf752f8601ccb28598d644b0ce45d77dde937b1:/from:ro -v neo4j-atlas-data:/to alpine sh -c "cp -a /from/. /to/"`
   repeat for the logs volume.
4. Verify the copy before removing anything. Compare `ls /data/databases` on both.
5. Only then: `docker rm neo4j-atlas-mcp-server`, `docker compose up -d`.
6. Confirm with `docker compose ps` that the healthcheck reports `healthy`, and
   that `cypher-shell -u neo4j -p password2 'MATCH (n) RETURN count(n);'` returns
   the node count you expect.
7. Keep the old anonymous volumes until you are satisfied. They are not deleted by
   `docker rm`.

## Backup and restore: the npm scripts do NOT work in this install

The upstream guide's data steps call the package's own npm scripts
(`README.md` in the package, ~L353/L363):

```
npm run db:backup
npm run db:import <path_to_backup_directory>
```

Those cannot run here. `package.json` points them at TypeScript entry points
under `src/` and loads them with `--loader ts-node/esm`, but the published package
ships **only `dist/`** — there is no `src/`, no `tsconfig.json`, and `ts-node` is
not installed. Both scripts die before doing any work (verified 2026-09-24,
Node v22.22.2 / npm 12.0.2):

```
$ npm run db:backup            # cwd = J:\Programs\npm-global\node_modules\atlas-mcp-server
Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'ts-node' imported from J:\Programs\npm-global\node_modules\atlas-mcp-server\
    code: 'ERR_MODULE_NOT_FOUND'
--- EXIT=1 ---
```

`npm run db:import <path>` fails the same way; `npm run build` fails with
`'tsc' is not recognized`; `npm run webui` targets the missing `src/webui`.

**Use the compiled equivalents in `dist/` instead** — same scripts, already built:

```
cd J:\Programs\npm-global\node_modules\atlas-mcp-server

set NEO4J_PASSWORD=password2
node dist\services\neo4j\backupRestoreService\scripts\db-backup.js

:: import is DESTRUCTIVE — overwrites all data
node dist\services\neo4j\backupRestoreService\scripts\db-import.js <path_to_backup_directory>
```

Verified: the backup command exited 0 and wrote
`atlas-backups\atlas-backup-20260924150733\` (`full-export.json` plus
projects/tasks/knowledges/relationships/… `.json`), and `logs\combined.log`
recorded `"Manual backup completed successfully. Backup created at: …\atlas-backup-20260924150733"`.
`db-import.js` was checked without mutating data (no argument → exits 1; an
out-of-root path is rejected before any write). It has **no dry-run and no
`--help`**.

Constraints, all enforced by the scripts themselves:

- **`NEO4J_PASSWORD=password2` is required.** Without it the driver falls back to
  the default `password` and the container rejects it
  (`Neo.ClientError.Security.Unauthorized`). `NEO4J_URI`/`NEO4J_USER` default to
  `bolt://localhost:7687` / `neo4j`.
- **The path must stay inside the package root.** `db-import.js` refuses any path
  outside `J:\Programs\npm-global\node_modules\atlas-mcp-server`, and backups are
  written to `BACKUP_FILE_DIR` — the package's own `atlas-backups\`. Neither
  operation can be pointed at another drive.

The container-level alternative, `neo4j-admin database dump`, is **not** usable
while atlas is up — Neo4j 5.26 states it "is not possible to dump a database that
is mounted in a running Neo4j server". Since this container must stay running, the
`dist` JSON export above is the supported backup path.

## Related beads

- `mcpw-cnc.1` — this capture (done)
- `mcpw-cnc.2` — cold-start guard: Docker Desktop + this container up before atlas
- `mcpw-cnc.3` — `Test-Neo4jReady` gate in the watcher launcher
- `mcpw-cnc.6` — this backup/restore section (the npm `db:*` scripts cannot run here)
