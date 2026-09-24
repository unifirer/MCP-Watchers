# heimdall's Graft backend: a supervised graftd starter, and why the reconciler is inert on Windows

**Bead:** mcpw-qxj.3 (P1, child of mcpw-qxj)
**Date:** 2026-09-24
**Verdict:** the backend is up and now has a supervised starter. The *reconciler*,
however, cannot be made to work from this repo — it is inert upstream, in an
off-limits installed package. Both halves are recorded below.

## What the bead asked for

Bring up the Graft backend (its daemon binary `graftd`) and the reconciler on
Windows, with no `launchd` to lean on.

## 1. The daemon: a supervised starter

heimdall's reconciler projects into the **Graft** backend, whose daemon binary is
`graftd.exe`. Until that daemon is listening, reconciliation has nowhere to land.

`graftd` had **no keeper of its own**: the old `~/.graft/start-graftd.bat` was a bare
launch with no supervisor and an unreliable shell redirect. So the launcher is now its
**one supervised starter** — added to `###1.watchers_for_...ps1` just before the
heimdall daemon block:

    $graftdLog = Join-Path $logsDir 'graftd.log'
    $graftdExe = Join-Path $env:USERPROFILE '.local\bin\graftd.exe'
    $graftdCfg = Join-Path $env:USERPROFILE '.graft\config.yaml'
    if (-not (Test-Path -LiteralPath $graftdExe)) {
        Write-Host "graftd.exe not found at $graftdExe. ..."
    } else {
        $script:graftdProc = Start-WatcherDetached 'graftd' 'graftd' `
            @('--config', $graftdCfg, '--foreground') $graftdLog -ExePath $graftdExe
    }

Two Windows-specific points are load-bearing:

- **`--foreground` is mandatory.** `graftd`'s default daemonize mode loads the model
  and then exits *silently* with no socket. There is no error to catch — it just does
  not listen.
- **Native Windows paths.** `--config` takes `C:\Users\yuni\.graft\config.yaml`, not a
  POSIX path (mcpw-qxj.1).

`Modules/watcher_patterns.ps1` gained a matching entry so the sweeper can see the
process:

    @{ Name = 'graftd.exe';      Pattern = '' },

Matched by **image name** with an empty pattern (same shape as `graphify-rs.exe`),
deliberately **not** by a `graft` token: the two unrelated programs also called
"graft" — the npm `graft` CLI and this repo's own graft MCP — both run as `node.exe`,
so an image-name match on `graftd.exe` can never reach them.

## 2. The heimdall launcher path was wrong

The old code walked **two** parents up from the npm shim:

    $hdRoot = Split-Path (Split-Path $hdCmd.Source -Parent) -Parent
    $hdCand = Join-Path $hdRoot 'node_modules\@arihantdeva\heimdall\bin\heimdall.js'

That lands on `J:\Programs\node_modules\...` — a directory that does not exist, so
`$heimdallJs` was never set and the daemon was launched through the shell shim
instead. The fix walks the shim's own directory **and** its parent, which is what
actually resolves to `J:\Programs\npm-global\node_modules\@arihantdeva\heimdall\bin\heimdall.js`.

Launching the entry JS under `node.exe` directly (rather than through the shim) is
what gives an attributable, sweepable process whose command line carries
`heimdall.js daemon` — which is what the `watcher_patterns.ps1` entry matches on.

## 3. Verified live (2026-09-24)

    graftd.exe            PID 19416  C:\Users\yuni\.local\bin\graftd.exe
      cmd: "C:\Users\yuni\.local\bin\graftd.exe" --config "C:\Users\yuni\.graft\config.yaml" --foreground
    heimdall daemon       PID 84500  "C:\nvm4w\nodejs\node.exe" "...\@arihantdeva\heimdall\bin\heimdall.js" daemon
    graft socket          C:\Users\yuni\AppData\Local\Temp\graft-default.sock  (exists)
    daemon self-report    "depth cap graph (tree-sitter available)", "watching 2 root(s)"

`~/.heimdall/config.json`'s `watch_roots` was restored (backup:
`.bak-qxj3-20260924-152949`).

Note: the **live launcher predates this fix**. The running processes were brought up
by hand; the starter block takes effect on the next launcher start.

## 4. The honest limit: the reconciler is inert upstream

`bin/lib/reconcile.mjs:17`:

    if (!path.startsWith("/")) return true;

Every **Windows** path fails that test and is skipped before it is considered. A
0-roots-looking symptom therefore cannot be fixed from this repo — the file lives in
the installed npm package (`J:\Programs\npm-global\node_modules\@arihantdeva\heimdall`),
which is off limits. Separately, `GraftSink.available` probes `~/.local/bin/graft`,
which does not exist in this install (the binary is `graftd.exe`).

This is the same class of finding as mcpw-qxj.7: the defect is upstream, and the
correct action here is to document it, not to patch a vendored copy.

## Files changed

- `###1.watchers_for_...ps1` — supervised `graftd` starter; heimdall JS path walk fixed.
- `Modules/watcher_patterns.ps1` — `graftd.exe` sweep entry.
