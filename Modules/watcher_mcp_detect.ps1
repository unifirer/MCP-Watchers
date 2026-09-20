# Modules/watcher_mcp_detect.ps1
# MCP "is it initialized?" detection contract (bead mcpw-rkg.1, epic mcpw-rkg).
#
# WHY THIS EXISTS
# ---------------
# The launcher (###1.watchers_....ps1) must bootstrap all six watched MCPs in
# ANY repository it is started from, and a bootstrap step must never re-run an
# expensive build it does not need: `gm run`, `graphify-rs build`, `graft
# build` and `repowise update --full` all take minutes. This module is the
# DETECTION LAYER ONLY - one probe per MCP answering "is this repo already
# initialized for that tool?". No probe builds, indexes, repairs or spawns
# anything persistent. Init code lives in mcpw-rkg.2, not here.
#
# CONTRACT (identical shape for all six probes)
# --------------------------------------------
#   Test-<Mcp>Initialized -Path <repoRoot> [-Reason ([ref]$s)] [-ProbeOutput <text>]
#     -> [bool]   $true  = initialized, the caller may skip the build
#                 $false = not initialized (or cannot tell) -> bootstrap runs
#     -> -Reason  receives a one-line human-readable why, for the log. Pass a
#                 [ref] to a string:  $r = ''; Test-X -Path $p -Reason ([ref]$r)
#                 Omitting it entirely is fine and is a silent no-op - a probe
#                 never throws for a caller that does not want the reason.
#                 Do NOT pass a literal $null: PowerShell rejects that at
#                 binding time ("Reference type is expected in argument"),
#                 before any probe code runs. That is a caller bug, not a probe
#                 bug, and it is the price of the idiomatic out-variable.
#     -> -ProbeOutput, when supplied, is pre-captured stdout of the tool's own
#                 status/doctor command. It lets the caller reuse a capture it
#                 already made instead of spawning the tool a second time. The
#                 four probes whose signal is a file on disk ignore it.
#
# RULES EVERY PROBE OBEYS
# -----------------------
#   * Everything is rooted at the passed -Path. No absolute repository path, no
#     assumption about WHICH repository this is, and no assumption that it is a
#     git repository (a plain directory must work).
#   * A MISSING BINARY is a normal answer, never an exception: $false with
#     reason "binary not found: <name>". Probes never throw. This check runs
#     FIRST, so a probe answers "can this repo be initialized for that tool at
#     all?" before it inspects any artifact.
#   * A signal that is only PARTLY present is NOT initialized. Every partial
#     case below was measured on 2026-09-20 and is deliberately encoded; see
#     reports/2026-09-20-mcpw-rkg1-detection-contract.md for the evidence.
#
# Safe to dot-source: function definitions only, no top-level side effects.

function Get-McpDetectRoot {
    # Normalise the caller's -Path. Falls back to the current location so a
    # launcher that forgets the argument still gets a usable root rather than
    # an exception. Mirrors Get-WatchersWorkspaceRoot's trailing-separator rule.
    param([string]$Path)
    if ($Path) { return $Path.TrimEnd('\', '/') }
    $loc = (Get-Location).ProviderPath
    if (-not $loc) { $loc = (Get-Location).Path }
    if (-not $loc) { return '' }
    return $loc.TrimEnd('\', '/')
}

function Set-McpDetectReason {
    # Write the human-readable verdict into the caller's -Reason out variable.
    #
    # ALWAYS CALL THIS POSITIONALLY, and keep the parameter typed [object].
    # Measured on Pester 6.1.0 / Windows PowerShell 5.1:
    #   [object] param + POSITIONAL ([ref]$x)  -> the ref survives, the write lands
    #   [object] param + NAMED -R ([ref]$x)    -> PowerShell UNWRAPS the ref, the
    #                                             callee sees a plain String and
    #                                             the reason is silently dropped
    #   [object] param + omitted / $null       -> skipped, no throw
    # A [ref]-typed parameter would preserve the ref under named binding too, but
    # it THROWS when a probe forwards its own possibly-$null -Reason. [object] +
    # positional is the only shape that is correct in all three cases.
    param([object]$Reason, [string]$Text)
    if ($Reason -is [System.Management.Automation.PSReference]) { $Reason.Value = $Text }
}

function ConvertTo-McpDetectComparePath {
    # Normalise a repository path so two spellings of the same repo compare
    # equal. memtrace writes its scope file with FORWARD slashes and the casing
    # it captured at index time (measured: "path": "j:/audio/MCP-Watchers"),
    # so a plain -eq against the caller's -Path fails on Windows.
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = $Path
    try { $p = [System.IO.Path]::GetFullPath($Path) } catch { }
    $p = $p -replace '\\', '/'
    while ($p.Length -gt 1 -and $p.EndsWith('/')) { $p = $p.Substring(0, $p.Length - 1) }
    return $p.ToLowerInvariant()
}

function Resolve-McpDetectTool {
    # Resolve a tool's runnable command the same way the launcher does
    # (Start-WatcherDetached / Get-MemtraceLaunchSpec): <name>.exe, then
    # <name>.cmd/.bat, then the bare <name>. Returns the full path, or $null
    # when the tool is not on PATH. Never throws.
    #
    # The bare-name fallback is not decoration: on this box `memtrace` and
    # `graft` are npm shims (memtrace.ps1 / graft.ps1) with NO .exe on PATH, so
    # a .exe-only lookup would report "binary not found" for two tools that are
    # in fact installed. It also avoids PowerShell's `gm` alias for Get-Member,
    # which has no .Source.
    param([string]$Name)
    if (-not $Name) { return $null }
    foreach ($cand in @("$Name.exe", "$Name.cmd", "$Name.bat", $Name)) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue
        if ($c -and $c.Source) { return [string]$c.Source }
    }
    return $null
}

function Invoke-McpDetectCommand {
    # Run a tool's read-only status command and return stdout+stderr as one
    # string, or $null when it cannot be launched. Mirrors the launcher's
    # Get-GrepaiStatusText: drain BOTH pipes concurrently (WaitForExit before
    # ReadToEnd deadlocks once the child writes past the ~4 KB pipe buffer) and
    # kill on timeout, so a wedged tool can never hang the launcher. The exit
    # code is deliberately ignored: `repowise doctor` exits 0 while reporting
    # FAILing checks, so the TEXT is the signal, not the status.
    param(
        [string] $FilePath,
        [string] $Arguments,
        [string] $WorkingDirectory,
        [int]    $TimeoutMs = 60000
    )
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { return $null }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch { }
            return $null
        }
        return ($outTask.Result + [Environment]::NewLine + $errTask.Result)
    } catch { return $null }
    finally { if ($proc) { try { $proc.Dispose() } catch { } } }
}

function Test-McpDetectRootUsable {
    # Shared guard: the repository root must exist as a directory. Returns the
    # reason string when it does NOT, or '' when the root is fine.
    param([string]$Root)
    if (-not $Root) { return 'no repository path supplied' }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return "path not found: $Root" }
    return ''
}

# ---------------------------------------------------------------------------
# memtrace
# ---------------------------------------------------------------------------
function Test-MemtraceInitialized {
    <#
    .SYNOPSIS
        Is this repository a member of the memtrace store scope?
    .DESCRIPTION
        PRIMARY signal: <Path>/.memdb/.memtrace-store-scope.json exists, parses,
        and one of its members[].path entries equals the repository path.

        Measured 2026-09-20: the file carries
        {"version":1,"members":[{"repo_id":"mcp-watchers","path":"j:/audio/MCP-Watchers"}]}.

        Why NOT `memtrace status`: it prints "Graph counts: not loaded (status
        never opens a local MemDB store)", so it CANNOT confirm membership.
        Why NOT a live node count: that needs memcore-server.exe to answer, and
        the MCP call timed out (memcore-server.exe ~3.8 GB, mcpw-rkg.7). The
        scope file is written by memtrace itself and is the authoritative
        membership record, so it is the signal. A live count is best-effort and
        deliberately NOT required here.

        Matching is by PATH only. repo_id is not usable repo-agnostically (it is
        a hand-authored slug such as "mcp-watchers", not derivable from a path).
    #>
    param(
        [string] $Path,
        [ref]    $Reason,
        [string] $ProbeOutput   # unused: this signal is a file on disk
    )
    $root = Get-McpDetectRoot -Path $Path
    if (-not (Resolve-McpDetectTool -Name 'memtrace')) {
        Set-McpDetectReason $Reason 'binary not found: memtrace'; return $false
    }
    $bad = Test-McpDetectRootUsable -Root $root
    if ($bad) { Set-McpDetectReason $Reason $bad; return $false }

    $rel  = '.memdb/.memtrace-store-scope.json'
    $file = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Set-McpDetectReason $Reason "scope file missing: $rel"; return $false
    }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Set-McpDetectReason $Reason "scope file unreadable: $($_.Exception.Message)"; return $false }
    if (-not $doc) { Set-McpDetectReason $Reason 'scope file is empty'; return $false }

    $members = @($doc.members)
    if ($members.Count -eq 0) { Set-McpDetectReason $Reason 'scope file has no members[]'; return $false }

    $want = ConvertTo-McpDetectComparePath -Path $root
    foreach ($m in $members) {
        if (-not $m) { continue }
        $have = ConvertTo-McpDetectComparePath -Path ([string]$m.path)
        if ($have -and $have -eq $want) {
            Set-McpDetectReason $Reason "repo is a member of the memtrace store scope ($($members.Count) member(s))"
            return $true
        }
    }
    Set-McpDetectReason $Reason "repo path is not a member of the memtrace store scope ($($members.Count) member(s))"
    return $false
}

# ---------------------------------------------------------------------------
# grepai
# ---------------------------------------------------------------------------
function Test-GrepaiInitialized {
    <#
    .SYNOPSIS
        Does this repository have a grepai index with files in it?
    .DESCRIPTION
        Signals, in order:
          1. the grepai CLI is on PATH;
          2. <Path>/.grepai/config.yaml exists;
          3. `grepai status` reports "Files indexed" > 0.

        A CORRECT CONFIG IS NOT ENOUGH. Measured 2026-09-20 in this repo: the
        config was already right (ollama embedder nomic-embed-text at
        127.0.0.1:12134, qdrant backend localhost:16334) and `grepai status`
        still reported "Files indexed: 0 / Total chunks: 892". That is NOT
        initialized - there is nothing to search.

        The liveness clock is deliberately NOT a signal. `watch.last_index_time`
        is written at scan/checkpoint boundaries, not per write, so a stale
        clock is not by itself proof of a dead write path - and the inverse
        holds too: measured "Last updated: 2026-09-20 14:31:22" (fresh) with
        "Files indexed: 0". Only the file count decides.
    #>
    param(
        [string] $Path,
        [ref]    $Reason,
        [string] $ProbeOutput   # pre-captured `grepai status --no-ui` text
    )
    $root = Get-McpDetectRoot -Path $Path
    $tool = Resolve-McpDetectTool -Name 'grepai'
    if (-not $tool) { Set-McpDetectReason $Reason 'binary not found: grepai'; return $false }
    $bad = Test-McpDetectRootUsable -Root $root
    if ($bad) { Set-McpDetectReason $Reason $bad; return $false }

    $rel = '.grepai/config.yaml'
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel) -PathType Leaf)) {
        Set-McpDetectReason $Reason "config missing: $rel"; return $false
    }

    $text = $ProbeOutput
    if (-not $text) {
        $text = Invoke-McpDetectCommand -FilePath $tool -Arguments 'status --no-ui' `
                    -WorkingDirectory $root -TimeoutMs 30000
    }
    if (-not $text) { Set-McpDetectReason $Reason 'grepai status produced no output'; return $false }

    $m = [regex]::Match($text, 'Files indexed\s*:\s*(\d+)')
    if (-not $m.Success) {
        Set-McpDetectReason $Reason 'grepai status did not report "Files indexed"'; return $false
    }
    $n = [int]$m.Groups[1].Value
    if ($n -le 0) {
        Set-McpDetectReason $Reason 'grepai status reports Files indexed: 0 (config present, index empty)'
        return $false
    }
    Set-McpDetectReason $Reason "grepai status reports Files indexed: $n"
    return $true
}

# ---------------------------------------------------------------------------
# graphenium (gm)
# ---------------------------------------------------------------------------
function Test-GrapheniumInitialized {
    <#
    .SYNOPSIS
        Does this repository have a graphenium workspace (config AND graph)?
    .DESCRIPTION
        Signals, in order:
          1. the gm CLI is on PATH;
          2. <Path>/.graphenium/ (the workspace config dir) exists;
          3. <Path>/graphenium-out/graph.json exists.

        BOTH artifacts are required. Measured 2026-09-20 in this repo: the graph
        was present (graphenium-out/graph.json, 241 nodes, from an earlier
        `gm run`) while .graphenium/ did NOT exist, because `gm init` was never
        run. That state is NOT initialized - the MCP server is not wired to the
        workspace. The config is therefore the discriminating signal, and it is
        checked first so the reason names it.
    #>
    param(
        [string] $Path,
        [ref]    $Reason,
        [string] $ProbeOutput   # unused: this signal is a file on disk
    )
    $root = Get-McpDetectRoot -Path $Path
    if (-not (Resolve-McpDetectTool -Name 'gm')) {
        Set-McpDetectReason $Reason 'binary not found: gm'; return $false
    }
    $bad = Test-McpDetectRootUsable -Root $root
    if ($bad) { Set-McpDetectReason $Reason $bad; return $false }

    if (-not (Test-Path -LiteralPath (Join-Path $root '.graphenium') -PathType Container)) {
        Set-McpDetectReason $Reason 'workspace config missing: .graphenium/ (gm init never ran)'
        return $false
    }
    $rel = 'graphenium-out/graph.json'
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel) -PathType Leaf)) {
        Set-McpDetectReason $Reason "graph missing: $rel"; return $false
    }
    Set-McpDetectReason $Reason '.graphenium/ workspace config present and graphenium-out/graph.json present'
    return $true
}

# ---------------------------------------------------------------------------
# graphify-rs
# ---------------------------------------------------------------------------
function Test-GraphifyRsInitialized {
    <#
    .SYNOPSIS
        Does this repository have a built graphify-rs graph?
    .DESCRIPTION
        Signals, in order:
          1. the graphify-rs CLI is on PATH;
          2. <Path>/graphify-out/graph.json exists.

        graphify-out/ is the graphify-rs build output directory (it is the entry
        in this repo's .gitignore, and it is the directory the ignore gate keeps
        out of rebuild triggers). graph.json is the artifact the mandated
        rebuild form writes - `graphify-rs build --path . --update --no-llm`
        (Get-GraphifyRebuildArgs, Modules/graphify_ignore_gate.ps1) - and the
        file `graphify-rs serve --graph <...>` loads. Measured on the sibling
        repo J:/audio/VAD: graphify-out/ contains graph.json (2.4 MB) alongside
        graph.graphml / graph.html / .graphify_manifest.json.

        An empty graphify-out/ is NOT initialized: a build that died partway
        leaves the directory behind. Measured 2026-09-20 in this repo: there is
        no graphify-out/ at all and no graphify-rs.toml.
    #>
    param(
        [string] $Path,
        [ref]    $Reason,
        [string] $ProbeOutput   # unused: this signal is a file on disk
    )
    $root = Get-McpDetectRoot -Path $Path
    if (-not (Resolve-McpDetectTool -Name 'graphify-rs')) {
        Set-McpDetectReason $Reason 'binary not found: graphify-rs'; return $false
    }
    $bad = Test-McpDetectRootUsable -Root $root
    if ($bad) { Set-McpDetectReason $Reason $bad; return $false }

    $rel = 'graphify-out/graph.json'
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel) -PathType Leaf)) {
        if (Test-Path -LiteralPath (Join-Path $root 'graphify-out') -PathType Container) {
            Set-McpDetectReason $Reason "graphify-out/ exists but holds no built graph: $rel"
        } else {
            Set-McpDetectReason $Reason "output dir missing: graphify-out/ (no $rel)"
        }
        return $false
    }
    Set-McpDetectReason $Reason "built graph present: $rel"
    return $true
}

# ---------------------------------------------------------------------------
# repowise
# ---------------------------------------------------------------------------
function Test-RepowiseInitialized {
    <#
    .SYNOPSIS
        Does this repository have a repowise store AND a registered MCP entry?
    .DESCRIPTION
        Signals, in order:
          1. the repowise CLI is on PATH;
          2. <Path>/.repowise/ (the store) exists;
          3. `repowise doctor` does not report the Claude Code MCP entry as
             "not registered".

        THE STORE IS NOT THE WHOLE SIGNAL. Measured 2026-09-20 in this repo:
        the store was fine (47 pages) while doctor printed
        "Claude Code MCP entry | OK | not registered (repowise init registers it)"
        and, separately,
        "MCP server responds | OK | not registered - nothing to launch".
        `repowise init` is what registers the entry, so an unregistered store is
        NOT initialized.

        Note the doctor STATUS column says OK for that row - the registration
        state is in the DETAIL column, so the check is on the whole LINE, and
        only the line naming "Claude Code MCP entry" (the `Agent: claude-code`
        row also contains the words "not registered" and must not be confused
        with it). doctor exits 0 while reporting FAILing checks, so the exit
        code is not consulted.
    #>
    param(
        [string] $Path,
        [ref]    $Reason,
        [string] $ProbeOutput   # pre-captured `repowise doctor` text
    )
    $root = Get-McpDetectRoot -Path $Path
    $tool = Resolve-McpDetectTool -Name 'repowise'
    if (-not $tool) { Set-McpDetectReason $Reason 'binary not found: repowise'; return $false }
    $bad = Test-McpDetectRootUsable -Root $root
    if ($bad) { Set-McpDetectReason $Reason $bad; return $false }

    if (-not (Test-Path -LiteralPath (Join-Path $root '.repowise') -PathType Container)) {
        Set-McpDetectReason $Reason 'store missing: .repowise/'; return $false
    }

    $text = $ProbeOutput
    if (-not $text) {
        $text = Invoke-McpDetectCommand -FilePath $tool -Arguments 'doctor' `
                    -WorkingDirectory $root -TimeoutMs 120000
    }
    if (-not $text) { Set-McpDetectReason $Reason 'repowise doctor produced no output'; return $false }

    $row = [regex]::Match($text, 'Claude Code MCP entry[^\r\n]*')
    if (-not $row.Success) {
        Set-McpDetectReason $Reason 'repowise doctor did not report a "Claude Code MCP entry" row'
        return $false
    }
    if ($row.Value -match 'not registered') {
        Set-McpDetectReason $Reason '.repowise/ store present but the Claude Code MCP entry is not registered'
        return $false
    }
    Set-McpDetectReason $Reason '.repowise/ store present and the Claude Code MCP entry is registered'
    return $true
}

# ---------------------------------------------------------------------------
# graft
# ---------------------------------------------------------------------------
function Test-GraftInitialized {
    <#
    .SYNOPSIS
        Does this repository have a graft manifest?
    .DESCRIPTION
        Signals, in order:
          1. the graft CLI is on PATH;
          2. <Path>/graft/manifest.json exists.

        The manifest can be MISSING ENTIRELY, not merely stale. Measured
        2026-09-20 in this repo: graft_check_freshness reported
        "No graft/manifest.json found. Run graft build --deep first", and the
        MCP tool separately reported "NO GRAPH". graft/.graph/wiring.json
        existed at the time and is NOT sufficient - it is the wiring cache, not
        the graph.
    #>
    param(
        [string] $Path,
        [ref]    $Reason,
        [string] $ProbeOutput   # unused: this signal is a file on disk
    )
    $root = Get-McpDetectRoot -Path $Path
    if (-not (Resolve-McpDetectTool -Name 'graft')) {
        Set-McpDetectReason $Reason 'binary not found: graft'; return $false
    }
    $bad = Test-McpDetectRootUsable -Root $root
    if ($bad) { Set-McpDetectReason $Reason $bad; return $false }

    $rel = 'graft/manifest.json'
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel) -PathType Leaf)) {
        if (Test-Path -LiteralPath (Join-Path $root 'graft/.graph/wiring.json') -PathType Leaf) {
            Set-McpDetectReason $Reason "manifest missing: $rel (graft/.graph/wiring.json alone is not a graph)"
        } else {
            Set-McpDetectReason $Reason "manifest missing: $rel (run graft build --deep)"
        }
        return $false
    }
    Set-McpDetectReason $Reason "manifest present: $rel"
    return $true
}

# ---------------------------------------------------------------------------
# aggregate
# ---------------------------------------------------------------------------
function Get-McpInitializationReport {
    <#
    .SYNOPSIS
        Run all six probes against one repository and return one row per MCP.
    .DESCRIPTION
        The shape the bootstrap layer (mcpw-rkg.2) consumes: a fixed-order list
        of objects with .Mcp, .Ok and .Reason. Never throws - a probe that
        cannot answer reports Ok=$false with its reason, which is exactly the
        "warn and skip" input the launcher wants for a foreign repo that does
        not have every tool installed.
    #>
    param([string]$Path)
    $probes = [ordered]@{
        'memtrace'    = 'Test-MemtraceInitialized'
        'grepai'      = 'Test-GrepaiInitialized'
        'graphenium'  = 'Test-GrapheniumInitialized'
        'graphify-rs' = 'Test-GraphifyRsInitialized'
        'repowise'    = 'Test-RepowiseInitialized'
        'graft'       = 'Test-GraftInitialized'
    }
    foreach ($name in $probes.Keys) {
        $reason = ''
        $ok = [bool](& $probes[$name] -Path $Path -Reason ([ref]$reason))
        [pscustomobject]@{ Mcp = $name; Ok = $ok; Reason = $reason }
    }
}
