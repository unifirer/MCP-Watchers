# Modules/watcher_mcp_provision.ps1
# MCP initialization ("provision") layer (bead mcpw-rkg.2, epic mcpw-rkg).
#
# WHY THIS EXISTS
# ---------------
# The launcher (###1.watchers_....ps1) must bring all seven watched MCPs up in
# ANY repository it is started from - a foreign repo has none of the per-repo
# artifacts the tools need. This module runs the seven init steps. It is the
# WRITE side of the pair whose READ side is Modules/watcher_mcp_detect.ps1
# (mcpw-rkg.1): detection answers "is this repo already initialized?", provision
# answers "then make it so, or explain why it cannot be".
#
# CONTRACT
# --------
#   Invoke-McpProvisionForRepo -Path <repoRoot> [...]
#     -> one summary object the launcher can log (never throws):
#        .Path .StateDir .Started .Finished .Total .Done .Stamped .Planned
#        .Skipped .ReportOnly
#        .Results[]  where each row is
#                    .Mcp .Status .Reason .Tool .Stamp .Optional .Phase
#        .Status is one of exactly four values:
#           'done'    the init step ran, exited 0, AND the matching detection
#                     probe then confirmed the repository is really initialized
#           'stamped' nothing to do - already initialized (detection), or a
#                     stamp from an earlier successful run
#           'skipped' the step did NOT run, or ran without provisioning: binary
#                     absent, optional input missing, launch failure, timeout, a
#                     non-zero exit, or an exit 0 the post-command probe refused
#                     to confirm. There is no 'failed' status on purpose - a
#                     provision problem degrades to a logged skip and the other
#                     six MCPs still get their chance.
#           'planned' -ReportOnly ONLY: this step WOULD run. No provisioning
#                      command ran and no stamp was written. (A detection probe
#                      may still shell out to confirm an existing artifact - see
#                      .PARAMETER ReportOnly for the measured cost.)
#
#   Initialize-<Mcp>ForRepo -Path <repoRoot> [-StateDir] [-ToolPath] [-Force]
#                           [-TimeoutMs] [-FirstScanTimeoutMs]
#     -> one row, callable on its own (the tests need that). Never throws.
#        Initialize-MemtraceForRepo / -GrepaiForRepo / -GrapheniumForRepo /
#        -GraphifyRsForRepo / -RepowiseForRepo / -GraftForRepo /
#        -AtlasForRepo
#
#        Initialize-AtlasForRepo is the ONE step that takes no -ToolPath and no
#        -TimeoutMs: it spawns nothing and writes a file itself. Passing it a
#        -ToolPath would be dead weight, and the plan row marks it FileOnly so
#        the callers can branch on that instead of on the function's name.
#
# HARD RULES ENCODED HERE
# -----------------------
#   * IDEMPOTENT. A successful (or already-initialized) step writes a STAMP -
#     one key inside <repo>/.mcpw-provision/state.json. The stamp is checked
#     BEFORE anything else, so a second run re-runs no build and spawns no
#     probe. -Force re-runs everything. The tests assert on the stamp file.
#   * THE STAMP IS EARNED, NEVER ASSUMED. Set-McpProvisionStamp is called only
#     after the matching Test-<Mcp>Initialized probe has confirmed the
#     repository is initialized - either BEFORE the command (already done) or
#     AFTER it (Get-McpProvisionPostCommandGate, bead mcpw-0zo.1). An exit code
#     of 0 is never on its own enough: gm init exits 0 without the graph, graft
#     build exits 0 without --deep, and a stamp on the exit code alone records a
#     repository as provisioned that never was, after which every launch skips
#     it silently.
#   * NON-INTERACTIVE, unconditionally. Every child gets stdin CLOSED, so a
#     prompt reads EOF instead of blocking the launcher forever; children run
#     with CreateNoWindow and a hard timeout, and are killed on timeout. On top
#     of that each tool gets the non-interactive flag it actually has
#     (`grepai init --yes`, `grepai watch --no-ui`, `repowise agents add --yes`,
#     `graphify-rs build --no-llm`). No Read-Host, no -Confirm, anywhere.
#   * DEGRADES. A missing binary, a missing optional input, a launch failure, a
#     timeout or a non-zero exit all become a 'skipped' row with a one-line
#     reason. A provision problem can never abort the launcher.
#   * REPO-AGNOSTIC. Every path is derived from -Path. There is no absolute
#     reference to any particular repository (the tests assert that).
#   * ORDERED CHEAP-FIRST: the cheapest step of all (atlas, a single file write)
#     first, then config-only steps (gm init, repowise agents add) before build
#     steps (graphify-rs, graft) before index steps (memtrace, grepai). See
#     Get-McpProvisionPlan.
#
# MEASURED FACTS ENCODED (2026-09-20 - do not re-derive)
# ------------------------------------------------------
#   memtrace  There is NO `memtrace build` verb (bead mcpw-i25); the real
#             equivalent is `memtrace index [PATH]`. `memtrace start` from a
#             member cwd FAILS PERMANENTLY (it derives a 1-member scope while
#             the store declares 8) and `memtrace mcp` can take the shared
#             daemon down for all 8 workspaces - neither is invoked here.
#   grepai    `.grepai/config.yaml` is already correct on this box (ollama
#             nomic-embed-text @ 127.0.0.1:12134, qdrant localhost:16334), so
#             `grepai init` runs ONLY when the config is absent - it must never
#             clobber a correct config with defaults. What is missing is the
#             INDEX; grepai has no `index` verb, the scan belongs to
#             `grepai watch`, so the first scan is finished by a bounded
#             foreground watch. Keeping that daemon alive across the
#             supervisor's idle-TTL reap is bead mcpw-rkg.4 - deliberately NOT
#             attempted here.
#   gm        The workspace marker is `.grapheniumignore` - the FILE `gm init`
#             writes, and the only artifact it produces. `gm init [PATH]`
#             defaults to ".", so the root is always passed explicitly. It does
#             NOT create a `.graphenium/` dir; gm only ever READS policy.json
#             from there. Detection keys on `.grapheniumignore` plus
#             graphenium-out/graph.json. The graph is `gm run`, which the
#             launcher's own watcher owns.
#   graphify-rs  `graphify-rs.toml` now EXISTS (bead mcpw-01g, OPTIONAL/P3).
#             `graphify-rs init` (0.8.1) is non-interactive and key-free - the
#             template it writes has every [llm] line commented out - so the
#             config was created rather than skipped. One key is PINNED in it:
#             `output = "graphify-out"`. Measured 2026-09-21 in scratch repos:
#             graphify-rs 0.8.1's built-in default is NOT repo-local, a bare
#             build writes to the machine-global store
#             C:\Users\<user>\.graphify-rs\<repo>-<hash>\, so without the pin
#             `graphify-out/graph.json` never appears and detection cannot
#             converge. `no_llm = true` is pinned too (AGENTS.md 3.3.3). The
#             step still skips as optional when the config is absent, which is
#             the foreign-repo case. Rebuild argv comes from
#             Get-GraphifyRebuildArgs (--update --no-llm).
#   repowise  `.repowise/` store exists (47 pages) but the Claude Code MCP entry
#             is NOT registered, and that registration is what detection keys
#             on. The uv-tool venv was repaired today (mcpw-a0g), so the REAL
#             binary is invoked by absolute path - the PATH `repowise` is a
#             declick MCP engine shim with no `agents`/`update` verb. The
#             targeted, cheap, non-interactive verb is `repowise agents add`
#             (--yes), NOT `repowise init`, which regenerates the wiki with a
#             model and can prompt for a key.
#   graft     Plain `graft build <dir>` is the $0 no-key tier and writes
#             graft/.graph/wiring.json, graft/INDEX.md and graft/.cache/*.
#             It NEVER writes graft/manifest.json - that is the --deep
#             (LLM-key) artifact - so detection keys on wiring.json +
#             INDEX.md together, not on the manifest. --deep is NEVER passed:
#             it needs an LLM key.
#
# Safe to dot-source: function definitions plus one sibling dot-source (the
# detection module), matching Modules/watcher_teardown.ps1. No launches, no
# writes, at load time.

$mcpProvisionDetectModule = Join-Path $PSScriptRoot 'watcher_mcp_detect.ps1'
if (Test-Path -LiteralPath $mcpProvisionDetectModule) { . $mcpProvisionDetectModule }

# ---------------------------------------------------------------------------
# root + state (stamp) plumbing
# ---------------------------------------------------------------------------
function Get-McpProvisionRoot {
    # Normalise the caller's -Path. Mirrors Get-McpDetectRoot's trailing-
    # separator rule, and falls back to the detect module's implementation when
    # it is loaded so the two layers cannot disagree about what the root is.
    param([string]$Path)
    if (Get-Command Get-McpDetectRoot -ErrorAction SilentlyContinue) {
        return (Get-McpDetectRoot -Path $Path)
    }
    if ($Path) { return $Path.TrimEnd('\', '/') }
    $loc = (Get-Location).ProviderPath
    if (-not $loc) { $loc = (Get-Location).Path }
    if (-not $loc) { return '' }
    return $loc.TrimEnd('\', '/')
}

function Get-McpProvisionStateDir {
    <#
    .SYNOPSIS
        Where the provision stamp for one repository lives.
    .DESCRIPTION
        Resolution order:
          1. the explicit -StateDir argument (tests, and a launcher that wants
             its state elsewhere)
          2. MCPW_PROVISION_STATE_DIR
          3. <repo>/.mcpw-provision - the default. Rooted at -Path, so the
             stamp travels with the repository it describes and two repos on
             one machine can never share a stamp.

        The directory used to be .mcpw-bootstrap, from before the
        bootstrap-to-provision rename. A repo stamped by the old launcher is
        migrated on first read - see Import-McpProvisionLegacyStamp. A bare
        rename without that migration would invalidate every existing stamp
        and force a full seven-step re-provision, including the grepai first
        scan.
    #>
    param([string]$Path, [string]$StateDir)
    if ($StateDir) { return $StateDir.TrimEnd('\', '/') }
    if ($env:MCPW_PROVISION_STATE_DIR) { return $env:MCPW_PROVISION_STATE_DIR.TrimEnd('\', '/') }
    $root = Get-McpProvisionRoot -Path $Path
    if (-not $root) { return '' }
    return (Join-Path $root '.mcpw-provision')
}

function Import-McpProvisionLegacyStamp {
    <#
    .SYNOPSIS
        One-time migration of the pre-rename .mcpw-bootstrap stamp.
    .DESCRIPTION
        Copies <repo>/.mcpw-bootstrap/state.json to <repo>/.mcpw-provision/
        state.json when the new file is absent and the old one exists, then
        removes the old directory. Never throws: a repo that has no legacy
        stamp simply gets nothing, and a failed migration costs at most one
        extra provision run.
    #>
    param([string]$StateDir)
    if (-not $StateDir) { return }
    $newFile = Get-McpProvisionStateFile -StateDir $StateDir
    if (-not $newFile) { return }
    if (Test-Path -LiteralPath $newFile -PathType Leaf) { return }

    # Only the default layout is migrated. An explicit -StateDir (the tests
    # use one) is whatever the caller asked for and must not be invented from.
    if ((Split-Path -Leaf $StateDir) -ne '.mcpw-provision') { return }
    $root = Split-Path -Parent $StateDir
    if (-not $root) { return }
    $legacyFile = Join-Path (Join-Path $root '.mcpw-bootstrap') 'state.json'
    if (-not (Test-Path -LiteralPath $legacyFile -PathType Leaf)) { return }

    try {
        if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $legacyFile -Destination $newFile -Force
        Remove-Item -LiteralPath (Join-Path $root '.mcpw-bootstrap') -Recurse -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Get-McpProvisionStateFile {
    param([string]$StateDir)
    if (-not $StateDir) { return '' }
    return (Join-Path $StateDir 'state.json')
}

function Read-McpProvisionState {
    # The stamp file as a hashtable keyed by MCP name. A missing, empty or
    # corrupt file reads as an empty hashtable - never throws, so a truncated
    # stamp can only cause one extra (safe) provision run, never a crash.
    param([string]$StateDir)
    # Migrate a pre-rename .mcpw-bootstrap stamp before the first read, so a
    # repo provisioned by the old launcher is not re-provisioned from scratch.
    Import-McpProvisionLegacyStamp -StateDir $StateDir
    $state = @{}
    $file = Get-McpProvisionStateFile -StateDir $StateDir
    if (-not $file) { return $state }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $state }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $state }
    if (-not $doc) { return $state }
    foreach ($p in $doc.PSObject.Properties) { $state[$p.Name] = $p.Value }
    return $state
}

function Test-McpProvisionStamp {
    # Is there a recorded successful provision for this MCP in this repo? This
    # is the idempotence gate, and it is deliberately the FIRST thing every
    # initializer checks: it costs one file read and spawns nothing.
    param([string]$Path, [string]$Mcp, [string]$StateDir)
    if (-not $Mcp) { return $false }
    $dir = Get-McpProvisionStateDir -Path $Path -StateDir $StateDir
    $state = Read-McpProvisionState -StateDir $dir
    if (-not $state.ContainsKey($Mcp)) { return $false }
    $entry = $state[$Mcp]
    if (-not $entry) { return $false }
    if (-not $entry.At) { return $false }
    return $true
}

function Set-McpProvisionStamp {
    # Record a successful provision for one MCP. Written temp-then-move so a
    # crash mid-write cannot leave a half-parsed stamp that would be read as
    # "not initialized" forever. Returns $true when the stamp is on disk.
    param(
        [string]$Path,
        [string]$Mcp,
        [string]$Detail,
        [string]$Tool,
        [string]$StateDir
    )
    if (-not $Mcp) { return $false }
    $dir = Get-McpProvisionStateDir -Path $Path -StateDir $StateDir
    if (-not $dir) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    } catch { return $false }

    # mcpw-0zo.5: also record the repo HEAD, so a stamp can be traced back to a
    # commit instead of only to a moment. Best-effort and deliberately cheap:
    # git is asked ONLY when the path really is a git repo, so synthetic and
    # scratch directories pay nothing and never depend on git being installed.
    $head = ''
    if ($Path -and (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        try {
            $h = & git -C $Path rev-parse HEAD 2>$null
            if ($h) { $head = ([string]$h).Trim() }
        } catch { }
    }
    $state = Read-McpProvisionState -StateDir $dir
    $state[$Mcp] = [pscustomobject]@{
        At     = (Get-Date).ToString('o')
        Tool   = [string]$Tool
        Detail = [string]$Detail
        Head   = $head
    }
    $json = $null
    try { $json = $state | ConvertTo-Json -Depth 6 } catch { return $false }
    if (-not $json) { return $false }

    $file = Join-Path $dir 'state.json'
    $tmp  = "$file.tmp-$PID"
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $file -Force
        return $true
    } catch {
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } } catch { }
        return $false
    }
}

# ---------------------------------------------------------------------------
# plan + command surface
# ---------------------------------------------------------------------------
function Get-McpProvisionPlan {
    <#
    .SYNOPSIS
        The seven provision steps in the order they must run.
    .DESCRIPTION
        Ordered CHEAP-FIRST, which is the ordering contract the launcher relies
        on (provision finishes before any watcher spawns - mcpw-rkg.3):
          Phase 'config' - atlas .env (a file write), gm init, repowise agents add
          Phase 'build'  - graphify-rs (optional), graft build
          Phase 'index'  - memtrace index, grepai first scan (minutes)
        The launcher must not depend on a different order than this one.

        Nothing keys off the literal Order values - the list order IS the
        contract, and Order is a readable restatement of it. Adding atlas at the
        front (bead mcpw-cnc.7) therefore renumbers 1-6 to 2-7 without changing
        any behaviour that depends on the sequence.

        FileOnly marks a step that spawns NO external command because it writes
        its artifact itself. Only atlas is one. It exists so the callers can
        branch on the row instead of on the initializer's name: a FileOnly step
        must not be reported 'skipped: no runnable tool', which is what the
        binary-resolution path would say about it forever. Tool is '' for such a
        step, and honestly so - there is no binary to name.
    #>
    return @(
        [pscustomobject]@{ Order = 1; Mcp = 'atlas';       Phase = 'config'; Optional = $false; Tool = '';            Fn = 'Initialize-AtlasForRepo';       FileOnly = $true  }
        [pscustomobject]@{ Order = 2; Mcp = 'graphenium';  Phase = 'config'; Optional = $false; Tool = 'gm';          Fn = 'Initialize-GrapheniumForRepo';  FileOnly = $false }
        [pscustomobject]@{ Order = 3; Mcp = 'repowise';    Phase = 'config'; Optional = $false; Tool = 'repowise';    Fn = 'Initialize-RepowiseForRepo';    FileOnly = $false }
        [pscustomobject]@{ Order = 4; Mcp = 'graphify-rs'; Phase = 'build';  Optional = $true;  Tool = 'graphify-rs'; Fn = 'Initialize-GraphifyRsForRepo';  FileOnly = $false }
        [pscustomobject]@{ Order = 5; Mcp = 'graft';       Phase = 'build';  Optional = $false; Tool = 'graft';       Fn = 'Initialize-GraftForRepo';       FileOnly = $false }
        [pscustomobject]@{ Order = 6; Mcp = 'memtrace';    Phase = 'index';  Optional = $false; Tool = 'memtrace';    Fn = 'Initialize-MemtraceForRepo';    FileOnly = $false }
        [pscustomobject]@{ Order = 7; Mcp = 'grepai';      Phase = 'index';  Optional = $false; Tool = 'grepai';      Fn = 'Initialize-GrepaiForRepo';      FileOnly = $false }
    )
}

function Get-McpProvisionArgv {
    <#
    .SYNOPSIS
        The exact argument vector for one provision step.
    .DESCRIPTION
        One place for every command line, so the non-interactive flags are
        assertable in a test instead of being buried in seven function bodies.
        $Step only disambiguates grepai, which needs three different commands
        (config / scan / status).

        atlas is the first step with NO command at all. Its artifact is a file
        this module writes itself, so it returns an empty vector and is listed
        here EXPLICITLY rather than falling through to the unknown-MCP default:
        the empty vector is a deliberate contract for that step, not the "I do
        not know this MCP" answer, and the two must not be confused when reading
        a call site. The plan row's FileOnly flag is what callers branch on.
    #>
    param(
        [string]$Mcp,
        [string]$Path,
        [string]$Step
    )
    switch ($Mcp) {
        'atlas' {
            # No external command. Initialize-AtlasForRepo writes <repo>/.env
            # directly; there is nothing to spawn.
            return @()
        }
        'memtrace' {
            # `memtrace index [PATH]`. --allow-non-git makes the step work in a
            # plain directory too; memtrace's own help says it does NOT change
            # which files are indexed inside a real repository. No --workspace:
            # that is a machine-global manifest path, and indexing by PATH is
            # the repo-agnostic form.
            return @('index', $Path, '--allow-non-git')
        }
        'grepai' {
            if ($Step -eq 'status') { return @('status', '--no-ui') }
            if ($Step -eq 'config') { return @('init', '--yes') }
            # Foreground: performs the initial scan, then stays up. Bounded by
            # the caller's timeout.
            return @('watch', '--no-ui')
        }
        'graphenium' { return @('init', $Path) }
        'graphify-rs' {
            # Reuse the launcher's own rebuild argv (which unconditionally
            # carries --no-llm) when that module is loaded, so the two cannot
            # drift. Fall back to the same literal.
            if (Get-Command Get-GraphifyRebuildArgs -ErrorAction SilentlyContinue) {
                return @(Get-GraphifyRebuildArgs)
            }
            return @('build', '--path', '.', '--update', '--no-llm')
        }
        'repowise' {
            # Register the Claude Code MCP entry - the piece detection keys on.
            # --yes means "never prompt". No model, no key, no wiki generation.
            return @('agents', 'add', $Path, '--target', 'claude-code', '--scope', 'project', '--yes', '--format', 'json')
        }
        'graft' {
            # $0 no-key tier. NEVER --deep (needs an LLM key).
            return @('build', $Path)
        }
    }
    return @()
}

function Resolve-McpProvisionTool {
    # Resolve a runnable command for a tool. An explicit -ToolPath wins and is
    # used verbatim: that is how repowise is pinned to its absolute uv-tool
    # binary, and how the tests inject a fake tool. A supplied -ToolPath that
    # does not exist resolves to '' (skip) - it is NEVER silently downgraded to
    # PATH lookup, because the PATH entry can be a different, wrong install.
    param([string]$Name, [string]$ToolPath)
    if ($ToolPath) {
        if (Test-Path -LiteralPath $ToolPath -PathType Leaf) { return $ToolPath }
        return ''
    }
    if (Get-Command Resolve-McpDetectTool -ErrorAction SilentlyContinue) {
        return (Resolve-McpDetectTool -Name $Name)
    }
    if (-not $Name) { return '' }
    foreach ($cand in @("$Name.exe", "$Name.cmd", "$Name.bat", $Name)) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue
        if ($c -and $c.Source) { return [string]$c.Source }
    }
    return ''
}

# ---------------------------------------------------------------------------
# process runner
# ---------------------------------------------------------------------------
function ConvertTo-McpProvisionArgLine {
    # Join an argument vector into one command line, quoting only what needs it.
    param([string[]]$Arguments)
    $parts = @()
    foreach ($a in @($Arguments)) {
        if ($null -eq $a) { continue }
        $s = [string]$a
        if ($s -eq '') { $parts += '""'; continue }
        if ($s -match '[\s"]') {
            $parts += ('"' + ($s -replace '"', '\"') + '"')
        } else {
            $parts += $s
        }
    }
    return ($parts -join ' ')
}

function Invoke-McpProvisionCommand {
    <#
    .SYNOPSIS
        Run one provision command, bounded and non-interactive. Never throws.
    .DESCRIPTION
        Returns an object:
            .Launched  [bool]   the child actually started
            .TimedOut  [bool]   it was killed at the timeout
            .ExitCode  [int]    exit code, or $null when it did not exit
            .Output    [string] stdout
            .Error     [string] stderr, or the failure text when not launched
        Three things here are load-bearing:
          * stdin is REDIRECTED AND CLOSED immediately. That is the universal
            non-interactive guarantee: a tool that decides to prompt reads EOF
            and exits instead of hanging the launcher with no window to type in.
          * a .cmd/.bat shim is launched through cmd.exe /d /s /c (CreateProcess
            cannot execute a batch file directly) and a .ps1 shim through
            powershell -NonInteractive -File. memtrace and graft are npm shims
            on this box, so this branch is the normal path, not an edge case.
          * stdout and stderr are drained CONCURRENTLY before WaitForExit -
            WaitForExit before ReadToEnd deadlocks once a child writes past the
            ~4 KB pipe buffer.
        A fourth, added 2026-09-24 (mcpw-jt5.1 follow-up): the timeout kills the
        whole process TREE, not just the direct child. See the comment at the
        kill site for the measurement.
    #>
    param(
        [string]   $FilePath,
        [string[]] $Arguments,
        [string]   $WorkingDirectory,
        [int]      $TimeoutMs = 1800000
    )
    $result = [pscustomobject]@{
        Launched = $false
        TimedOut = $false
        ExitCode = $null
        Output   = ''
        Error    = ''
    }
    if (-not $FilePath) { $result.Error = 'no command path supplied'; return $result }
    if ($TimeoutMs -le 0) { $TimeoutMs = 1800000 }

    $proc = $null
    try {
        $exe = $FilePath
        $argLine = ''
        $ext = ''
        try { $ext = [System.IO.Path]::GetExtension($FilePath) } catch { }
        $ext = ([string]$ext).ToLowerInvariant()
        $argv = @($Arguments)

        if ($ext -eq '.cmd' -or $ext -eq '.bat') {
            $exe = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
            $inner = '"' + $FilePath + '"'
            if ($argv.Count -gt 0) { $inner += ' ' + (ConvertTo-McpProvisionArgLine -Arguments $argv) }
            $argLine = '/d /s /c "' + $inner + '"'
        } elseif ($ext -eq '.ps1') {
            $exe = 'powershell.exe'
            $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $FilePath + '"'
            if ($argv.Count -gt 0) { $argLine += ' ' + (ConvertTo-McpProvisionArgLine -Arguments $argv) }
        } else {
            $argLine = ConvertTo-McpProvisionArgLine -Arguments $argv
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $argLine
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) {
            $result.Error = "failed to start: $FilePath"
            return $result
        }
        $result.Launched = $true
        try { $proc.StandardInput.Close() } catch { }

        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $result.TimedOut = $true
            # Kill the WHOLE TREE, not just the direct child (mcpw-jt5.1 follow-up).
            # A .cmd/.bat shim is launched as cmd.exe and the real work is a
            # GRANDCHILD (npm shim -> node/python, exactly how memtrace and graft
            # are installed here). Killing only the direct child orphans that
            # grandchild: it runs out its full duration with the working
            # directory still held, which (a) blocks any later delete of that
            # directory and (b) is the orphan-sprawl class tracked by mcpw-nzc.
            # Measured 2026-09-24 (temp/_kill_probe.ps1): cmd.exe -> ping.exe -n 60,
            # plain Kill() left ping.exe alive and the sandbox directory
            # undeletable; Kill($true) left 0 survivors and the directory deleted
            # cleanly. The plain-Kill fallback below exists only for a host
            # without the Kill(bool) overload (.NET Framework / Windows
            # PowerShell 5.1, reachable via the .bat's powershell.exe branch).
            $treeKilled = $false
            try { $proc.Kill($true); $treeKilled = $true } catch { }
            if (-not $treeKilled) {
                try { $proc.Kill() } catch { }
                try {
                    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
                    if (Test-Path -LiteralPath $taskkill) {
                        & $taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
                    }
                } catch { }
            }
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        } else {
            # Documented .NET requirement: after a TIMED WaitForExit returns
            # true, call it again (no timeout) so the async output handlers have
            # flushed before the streams are read.
            try { $proc.WaitForExit() } catch { }
        }
        # Only touch .Result when the task is COMPLETE - .Result on an
        # incomplete task BLOCKS, and after a kill the reader may never finish
        # (a descendant that outlived the tree kill, or a handle released late,
        # can still hold the write end). Losing the tail of a timed-out
        # command's output is fine; hanging is not.
        try { if ($outTask.IsCompleted) { $result.Output = [string]$outTask.Result } } catch { }
        try { if ($errTask.IsCompleted) { $result.Error  = [string]$errTask.Result } } catch { }
        if (-not $result.TimedOut) {
            try { $result.ExitCode = [int]$proc.ExitCode } catch { }
        }
        return $result
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
}

function Get-McpProvisionFailureReason {
    # One-line "why did this step not complete" for the log. Truncated on
    # purpose: a tool that dumps 200 lines of stack trace must not blow up the
    # launcher's log line.
    param($Result, [int]$TimeoutMs, [string]$Label)
    if (-not $Result) { return "$Label produced no result" }
    if (-not $Result.Launched) {
        $why = [string]$Result.Error
        if (-not $why) { $why = 'could not be launched' }
        return "$Label could not be launched: $why"
    }
    if ($Result.TimedOut) { return "$Label timed out after ${TimeoutMs}ms" }
    $tail = [string]$Result.Error
    if (-not $tail) { $tail = [string]$Result.Output }
    $tail = ($tail -split "`r?`n" | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if ($tail) {
        if ($tail.Length -gt 200) { $tail = $tail.Substring(0, 200) }
        return "$Label exited $($Result.ExitCode): $tail"
    }
    return "$Label exited $($Result.ExitCode)"
}

# ---------------------------------------------------------------------------
# shared step prologue
# ---------------------------------------------------------------------------
function New-McpProvisionRow {
    param(
        [string]$Mcp,
        [string]$Status,
        [string]$Reason,
        [string]$Tool,
        [string]$Stamp
    )
    return [pscustomobject]@{
        Mcp    = $Mcp
        Status = $Status
        Reason = $Reason
        Tool   = $Tool
        Stamp  = $Stamp
    }
}

function Start-McpProvisionStep {
    <#
    .SYNOPSIS
        The prologue every initializer shares.
    .DESCRIPTION
        Returns a hashtable:
            .Root .StateDir .Tool   - resolved inputs for the real work
            .Skip                   - a ready-made row when the step must NOT
                                      run, or $null when the caller should
        Order is deliberate and cheap-first: stamp (a file read, and the whole
        point of idempotence), then the root, then the binary. The stamp is
        checked before the binary so a second run does not even resolve a tool.

        -FileOnly (bead mcpw-cnc.7) is for a step that spawns NOTHING because
        it writes its artifact itself. It keeps everything above - the stamp,
        the stale-stamp probe agreement, the root checks - and skips only the
        binary resolution, which for such a step could never succeed. Without
        it, atlas would be reported 'skipped: binary not found: atlas' on every
        single launch, forever, and would never provision anything.
    #>
    param(
        [string]$Mcp,
        [string]$ToolName,
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$FileOnly,
        [switch]$Force
    )
    $root = Get-McpProvisionRoot -Path $Path
    $dir  = Get-McpProvisionStateDir -Path $root -StateDir $StateDir
    $out  = @{ Root = $root; StateDir = $dir; Tool = ''; Skip = $null }

    if (-not $Force) {
        if (Test-McpProvisionStamp -Path $root -Mcp $Mcp -StateDir $dir) {
            # mcpw-0zo.5: a stamp no longer AUTHORIZES a skip by itself.
            #
            # mcpw-0zo.1 made the stamp honest to EARN (nothing stamps without
            # the post-command probe agreeing), but a stamp that was honest once
            # can still go STALE: delete the artifact, or check out a branch
            # without it, and this step used to report "already provisioned"
            # forever, until -Force or a hand-pruned stamp. So the SAME probe
            # the initializer would run is asked here first, and the stamp holds
            # only while the probe agrees.
            #
            # The probe stays the single source of truth: this function knows no
            # artifact paths, so there is no second copy of them to drift out of
            # sync with the detection module.
            #
            # Two failure directions, deliberately different:
            #   probe ran and said "initialized"  -> hold the stamp (the normal
            #                                        idempotent path);
            #   probe ran and said "not initialized" -> the stamp IS stale: warn
            #                                        and fall through so the
            #                                        initializer really runs;
            #   probe could not answer (Answered=$false) -> that is silence, not
            #                                        evidence, so the stamp still
            #                                        holds. Otherwise a grepai
            #                                        that is briefly down would
            #                                        trigger a full re-index on
            #                                        every single launch.
            if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
                $v = Get-McpProvisionAlreadyReason -Mcp $Mcp -Root $root
                if ($v.Ok) {
                    $out.Skip = New-McpProvisionRow -Mcp $Mcp -Status 'stamped' `
                        -Reason "already provisioned (stamp present and the probe agrees: $($v.Reason); use -Force to re-run)" `
                        -Tool '' -Stamp $dir
                    return $out
                }
                if (-not $v.Answered) {
                    $out.Skip = New-McpProvisionRow -Mcp $Mcp -Status 'stamped' `
                        -Reason "already provisioned (stamp present; the probe could not answer: $($v.Reason); use -Force to re-run)" `
                        -Tool '' -Stamp $dir
                    return $out
                }
                Write-Warning "MCP provision: the '$Mcp' stamp is stale - $($v.Reason). Re-running the initializer."
            }
        }
    }
    if (-not $root) {
        $out.Skip = New-McpProvisionRow -Mcp $Mcp -Status 'skipped' `
            -Reason 'no repository path supplied' -Tool '' -Stamp $dir
        return $out
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $out.Skip = New-McpProvisionRow -Mcp $Mcp -Status 'skipped' `
            -Reason "path not found: $root" -Tool '' -Stamp $dir
        return $out
    }

    if ($FileOnly) {
        # The step writes its own artifact and spawns no command, so there is no
        # binary to resolve. Deliberately NOT worked around by handing the step
        # a fake tool name: that would resolve to a real unrelated executable and
        # put a command line in the log that never runs. Tool stays '' because
        # there genuinely is no tool, and the row's Reason carries the meaning.
        $out.Tool = ''
        return $out
    }

    $tool = Resolve-McpProvisionTool -Name $ToolName -ToolPath $ToolPath
    $out.Tool = $tool
    if (-not $tool) {
        $reason = if ($ToolPath) { "binary not found: $ToolPath" } else { "binary not found: $ToolName" }
        $out.Skip = New-McpProvisionRow -Mcp $Mcp -Status 'skipped' `
            -Reason $reason -Tool '' -Stamp $dir
        return $out
    }
    return $out
}

function Get-McpProvisionAlreadyReason {
    # Run the detection module's probe for one MCP. Returns a hashtable
    # @{ Ok = [bool]; Answered = [bool]; Reason = <text> }. Never throws: a
    # probe that cannot answer counts as "not initialized", which is the safe
    # direction.
    #
    # `Answered` (mcpw-0zo.5) separates the two ways Ok can be $false:
    #   Answered=$true  -> the probe ran and returned a real verdict, and the
    #                      verdict is "not initialized";
    #   Answered=$false -> the probe could not run at all (no such probe, the
    #                      function is not loaded, or it threw). That is
    #                      SILENCE, not evidence.
    # Callers that invalidate a stamp must honour the difference: only a real
    # verdict proves the artifact is gone. Treating silence as "gone" would
    # re-run an expensive initializer on every launch merely because its tool
    # was momentarily unavailable.
    param([string]$Mcp, [string]$Root, [string]$ProbeOutput)
    $probe = @{
        'memtrace'    = 'Test-MemtraceInitialized'
        'grepai'      = 'Test-GrepaiInitialized'
        'graphenium'  = 'Test-GrapheniumInitialized'
        'graphify-rs' = 'Test-GraphifyRsInitialized'
        'repowise'    = 'Test-RepowiseInitialized'
        'graft'       = 'Test-GraftInitialized'
        'atlas'       = 'Test-AtlasInitialized'
    }
    $fn = $probe[$Mcp]
    if (-not $fn) { return @{ Ok = $false; Answered = $false; Reason = "no probe for $Mcp" } }
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Answered = $false; Reason = "detection probe $fn not available" }
    }
    $reason = ''
    $ok = $false
    try {
        if ($ProbeOutput) { $ok = [bool](& $fn -Path $Root -Reason ([ref]$reason) -ProbeOutput $ProbeOutput) }
        else              { $ok = [bool](& $fn -Path $Root -Reason ([ref]$reason)) }
    } catch {
        return @{ Ok = $false; Answered = $false; Reason = "detection probe threw: $($_.Exception.Message)" }
    }
    return @{ Ok = $ok; Answered = $true; Reason = $reason }
}

function Get-McpProvisionPostCommandGate {
    <#
    .SYNOPSIS
        The post-command gate: did the command that just exited 0 actually
        provision the repository?
    .DESCRIPTION
        Exit code 0 is NOT proof of provisioning (bead mcpw-0zo.1). Measured on
        this box: `gm init` exits 0 having written only `.grapheniumignore`,
        `graft build` exits 0 having written graft/.graph/wiring.json +
        graft/INDEX.md, and neither produces everything its own detection probe
        requires. A stamp written on the exit code alone records a repository as
        provisioned that never was, and every later launch then SKIPS it - the
        operator sees a clean launch and the watchers start against an
        unprovisioned repo.

        So the SAME probe the pre-command gate uses
        (Get-McpProvisionAlreadyReason, which dispatches to the matching
        Test-<Mcp>Initialized) is asked a SECOND time, after the command, and
        the caller stamps ONLY on a confirmed Ok. When it is not Ok the returned
        Reason names the probe's own verdict, prefixed with the command that
        exited 0, so the honest no-op shows up in the launcher log instead of
        being laundered into a stamp.

        Returns @{ Ok = [bool]; Reason = <text> }. Never throws: the probe it
        wraps never throws, and a probe that cannot answer counts as
        not-initialized - the safe direction.
    #>
    param(
        [string]$Mcp,
        [string]$Root,
        [string]$Label,
        [string]$ProbeOutput
    )
    $d = Get-McpProvisionAlreadyReason -Mcp $Mcp -Root $Root -ProbeOutput $ProbeOutput
    if ($d.Ok) { return @{ Ok = $true; Reason = [string]$d.Reason } }
    $why = [string]$d.Reason
    if (-not $why) { $why = 'the probe reports the repository is still not initialized' }
    return @{ Ok = $false; Reason = "$Label exited 0 but the probe still reports: $why" }
}

# ---------------------------------------------------------------------------
# graphenium (gm) - Phase: config (cheap)
# ---------------------------------------------------------------------------
function Initialize-GrapheniumForRepo {
    <#
    .SYNOPSIS
        Ensure this repository has a graphenium workspace config.
    .DESCRIPTION
        `gm init [PATH]` exits 0 having written `.grapheniumignore` - a FILE, and
        the only artifact it produces. Measured in a scratch repo, it does NOT
        create the `.graphenium/` directory; gm only ever READS
        `.graphenium/policy.json` from there. The root is always passed
        explicitly because the command defaults to "." and the provision must
        not depend on the caller's cwd.

        Detection wants BOTH `.grapheniumignore` and `graphenium-out/graph.json`
        (Test-GrapheniumInitialized keys on the file this step writes, so the two
        agree). This step can only claim the config half - the graph is
        `gm run`, which the launcher's own watcher owns, and running the full
        pipeline here would be an expensive duplicate. So the post-command gate
        (Get-McpProvisionPostCommandGate) sees the config but not the graph and
        reports the step 'skipped' with the probe's verdict rather than stamping
        it; that is the documented division of labour, not a probe/tool
        mismatch. The step still converges: once the watcher has run gm the
        pre-command probe stamps the repo and gm init is never spawned again.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$TimeoutMs = 1800000
    )
    $pre = Start-McpProvisionStep -Mcp 'graphenium' -ToolName 'gm' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpProvisionAlreadyReason -Mcp 'graphenium' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'graphenium' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'graphenium' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpProvisionCommand -FilePath $pre.Tool `
            -Arguments (Get-McpProvisionArgv -Mcp 'graphenium' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        # Exit 0 is NOT proof (bead mcpw-0zo.1). gm init writes only
        # .grapheniumignore while the probe also wants
        # graphenium-out/graph.json, which is `gm run` and belongs to the
        # launcher's watcher. So a repo with the config but no graph is reported
        # 'skipped' carrying the probe's own verdict instead of being stamped as
        # done; the step then re-runs gm init (cheap, idempotent) on the next
        # launch and earns its stamp as soon as the watcher has produced the
        # graph.
        $g = Get-McpProvisionPostCommandGate -Mcp 'graphenium' -Root $pre.Root -Label 'gm init'
        if (-not $g.Ok) {
            return New-McpProvisionRow -Mcp 'graphenium' -Status 'skipped' `
                -Reason $g.Reason -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'graphenium' -Detail 'gm init completed (wrote .grapheniumignore)' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'graphenium' -Status 'done' `
            -Reason 'gm init wrote .grapheniumignore - it does NOT create .graphenium/ (graph is gm run, owned by the launcher watcher)' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpProvisionRow -Mcp 'graphenium' -Status 'skipped' `
        -Reason (Get-McpProvisionFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'gm init') `
        -Tool $pre.Tool -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# repowise - Phase: config (cheap)
# ---------------------------------------------------------------------------
function Initialize-RepowiseForRepo {
    <#
    .SYNOPSIS
        Register the repowise Claude Code MCP entry for this repository.
    .DESCRIPTION
        The store (`.repowise/`) is not the whole signal: detection also wants
        the Claude Code MCP entry REGISTERED. That registration is what this
        step adds, via `repowise agents add <PATH> --target claude-code --yes`
        - a targeted, non-interactive write. `repowise init` is deliberately NOT
        used: it regenerates the wiki with a model, can prompt for a key, and
        the store here is already populated.

        The binary is pinned to its absolute uv-tool path. The PATH `repowise`
        on this box is a declick MCP engine shim with no `agents` verb, so a
        PATH lookup would silently target the wrong program. A missing pinned
        binary is a skip, never a PATH fallback.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$TimeoutMs = 300000
    )
    if (-not $ToolPath -and $env:APPDATA) {
        $ToolPath = Join-Path $env:APPDATA 'uv\tools\repowise\Scripts\repowise.exe'
    }
    $pre = Start-McpProvisionStep -Mcp 'repowise' -ToolName 'repowise' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpProvisionAlreadyReason -Mcp 'repowise' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'repowise' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'repowise' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpProvisionCommand -FilePath $pre.Tool `
            -Arguments (Get-McpProvisionArgv -Mcp 'repowise' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        # Exit 0 is NOT proof (bead mcpw-0zo.1): the probe still has to see the
        # Claude Code MCP entry registered.
        $g = Get-McpProvisionPostCommandGate -Mcp 'repowise' -Root $pre.Root -Label 'repowise agents add'
        if (-not $g.Ok) {
            return New-McpProvisionRow -Mcp 'repowise' -Status 'skipped' `
                -Reason $g.Reason -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'repowise' -Detail 'agents add completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'repowise' -Status 'done' `
            -Reason 'repowise agents add --target claude-code --scope project --yes' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpProvisionRow -Mcp 'repowise' -Status 'skipped' `
        -Reason (Get-McpProvisionFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'repowise agents add') `
        -Tool $pre.Tool -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# graphify-rs - Phase: build (OPTIONAL)
# ---------------------------------------------------------------------------
function Initialize-GraphifyRsForRepo {
    <#
    .SYNOPSIS
        Build the graphify-rs graph, when this repository is configured for it.
    .DESCRIPTION
        OPTIONAL (bead mcpw-01g, P3). The config gate is the whole reason this
        step is optional: `graphify-rs.toml` is the repo's opt-in, so a
        repository that has none is skipped as optional rather than having a
        config invented for it. This repo now HAS one (committed with mcpw-01g),
        so the step runs here; a foreign repo without one still skips.

        When the config IS absent the reason is a single clear line naming the
        file, and the summary row carries Optional=$true so the launcher does
        not warn. A genuinely absent BINARY is reported first and honestly as
        "binary not found: graphify-rs" (Start-McpProvisionStep resolves the
        tool before the config gate).

        Rebuild argv comes from the launcher's own Get-GraphifyRebuildArgs, which
        unconditionally carries --no-llm.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$TimeoutMs = 1800000
    )
    $pre = Start-McpProvisionStep -Mcp 'graphify-rs' -ToolName 'graphify-rs' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    if (-not (Test-Path -LiteralPath (Join-Path $pre.Root 'graphify-rs.toml') -PathType Leaf)) {
        return New-McpProvisionRow -Mcp 'graphify-rs' -Status 'skipped' `
            -Reason 'optional: graphify-rs.toml missing (bead mcpw-01g, P3) - nothing to configure' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $d = Get-McpProvisionAlreadyReason -Mcp 'graphify-rs' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'graphify-rs' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'graphify-rs' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    # --path . resolves against the child's cwd, so the cwd must be the root.
    $r = Invoke-McpProvisionCommand -FilePath $pre.Tool `
            -Arguments (Get-McpProvisionArgv -Mcp 'graphify-rs' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        # Exit 0 is NOT proof (bead mcpw-0zo.1): the probe still has to see the
        # built graphify-out/graph.json.
        $g = Get-McpProvisionPostCommandGate -Mcp 'graphify-rs' -Root $pre.Root -Label 'graphify-rs build'
        if (-not $g.Ok) {
            return New-McpProvisionRow -Mcp 'graphify-rs' -Status 'skipped' `
                -Reason $g.Reason -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'graphify-rs' -Detail 'build completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'graphify-rs' -Status 'done' `
            -Reason 'graphify-rs build --path . --update --no-llm' -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpProvisionRow -Mcp 'graphify-rs' -Status 'skipped' `
        -Reason (Get-McpProvisionFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'graphify-rs build') `
        -Tool $pre.Tool -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# graft - Phase: build
# ---------------------------------------------------------------------------
function Initialize-GraftForRepo {
    <#
    .SYNOPSIS
        Build graft/'s wiring graph and per-file cards for this repository.
    .DESCRIPTION
        Plain `graft build <dir>` ($0, no key) writes graft/.graph/wiring.json,
        graft/INDEX.md and graft/.cache/*, and is what runs. It NEVER writes
        graft/manifest.json - that is the --deep artifact - so the probe pairs
        wiring.json with INDEX.md. --deep is NEVER passed: it needs an LLM key,
        and swapping in a key or a model is out of bounds for this harness.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$TimeoutMs = 1800000
    )
    $pre = Start-McpProvisionStep -Mcp 'graft' -ToolName 'graft' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpProvisionAlreadyReason -Mcp 'graft' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'graft' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'graft' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpProvisionCommand -FilePath $pre.Tool `
            -Arguments (Get-McpProvisionArgv -Mcp 'graft' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        # Exit 0 is NOT proof (bead mcpw-0zo.1): the probe still has to see
        # graft/.graph/wiring.json AND graft/INDEX.md together.
        $g = Get-McpProvisionPostCommandGate -Mcp 'graft' -Root $pre.Root -Label 'graft build'
        if (-not $g.Ok) {
            return New-McpProvisionRow -Mcp 'graft' -Status 'skipped' `
                -Reason $g.Reason -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'graft' -Detail 'build completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'graft' -Status 'done' `
            -Reason 'graft build (wiring graph + per-file cards; $0 no-key tier, no --deep)' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpProvisionRow -Mcp 'graft' -Status 'skipped' `
        -Reason (Get-McpProvisionFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'graft build') `
        -Tool $pre.Tool -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# memtrace - Phase: index (expensive)
# ---------------------------------------------------------------------------
function Initialize-MemtraceForRepo {
    <#
    .SYNOPSIS
        Index this repository into the memtrace MemDB store.
    .DESCRIPTION
        There is NO `memtrace build` verb (bead mcpw-i25). The real equivalent is
        `memtrace index [PATH]`, which is what runs. Two things are deliberately
        NOT run:
          * `memtrace start` - from a member cwd it FAILS PERMANENTLY (it derives
            a 1-member scope while the union store declares 8). The launcher owns
            the daemon and always passes --workspace <manifest>; provision does
            not start it.
          * `memtrace mcp` - kill-on-job-close can take the shared daemon down
            for all 8 workspaces.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$TimeoutMs = 1800000
    )
    $pre = Start-McpProvisionStep -Mcp 'memtrace' -ToolName 'memtrace' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpProvisionAlreadyReason -Mcp 'memtrace' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'memtrace' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'memtrace' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpProvisionCommand -FilePath $pre.Tool `
            -Arguments (Get-McpProvisionArgv -Mcp 'memtrace' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        # Exit 0 is NOT proof (bead mcpw-0zo.1): the probe still has to see this
        # repo listed in .memdb/.memtrace-store-scope.json.
        $g = Get-McpProvisionPostCommandGate -Mcp 'memtrace' -Root $pre.Root -Label 'memtrace index'
        if (-not $g.Ok) {
            return New-McpProvisionRow -Mcp 'memtrace' -Status 'skipped' `
                -Reason $g.Reason -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'memtrace' -Detail 'index completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'memtrace' -Status 'done' `
            -Reason 'memtrace index <path> --allow-non-git (no build verb; start/mcp deliberately not run)' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpProvisionRow -Mcp 'memtrace' -Status 'skipped' `
        -Reason (Get-McpProvisionFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'memtrace index') `
        -Tool $pre.Tool -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# grepai - Phase: index (expensive)
# ---------------------------------------------------------------------------
function Initialize-GrepaiForRepo {
    <#
    .SYNOPSIS
        Finish grepai's first scan for this repository.
    .DESCRIPTION
        Two sub-steps:
          1. CONFIG (cheap): `grepai init --yes` runs ONLY when
             `.grepai/config.yaml` is absent. The config measured in this repo is
             already correct (ollama nomic-embed-text @ 127.0.0.1:12134, qdrant
             localhost:16334) and `grepai init` would replace it with defaults,
             so an existing config is left untouched.
          2. FIRST SCAN (expensive): grepai has no `index` verb - the scan
             belongs to `grepai watch`. It runs in FOREGROUND (bounded by
             -FirstScanTimeoutMs): if it exits on its own the scan is done;
             otherwise it is stopped at the timeout and the DETECTION PROBE
             (Test-GrepaiInitialized, via Get-McpProvisionAlreadyReason) is asked
             once whether the index now has content.

        The probe decides on the CHUNK count, not "Files indexed" - grepai never
        computes a file count (measured 2026-09-21: "Files indexed: 0" beside
        "Total chunks: 1399"), so keying on files left this step permanently
        'skipped' and re-ran the 15-minute scan on EVERY launch (beads mcpw-4ci /
        mcpw-vrf). Because the probe is now satisfiable, a repo with a populated
        index stamps here and no watch is launched at all.

        -FirstScanTimeoutMs default is 300000 ms (5 min), down from 900000 (15
        min). `grepai watch` scans and then STAYS UP, so a foreground call always
        burns its whole timeout; 15 min of launcher silence is not worth it. The
        tradeoff: a first scan that genuinely needs longer than 5 min is stopped
        early and this step returns 'skipped' with no stamp - but the scan is
        incremental, the launcher's own detached watcher continues it, and bead
        mcpw-rkg.4 holds the supervisor's idle reap while it runs. The next launch
        then sees chunks > 0 and stamps. Deferring the scan entirely to that
        rkg.4 hold is a possible follow-up, deliberately NOT done here to avoid
        duplicating mcpw-rkg.4 / mcpw-kwa.

        Keeping the daemon alive across the supervisor's idle-TTL reap is bead
        mcpw-rkg.4. This step deliberately does not try: it only makes sure the
        first scan is finished.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$ConfigTimeoutMs = 120000,
        [int]$FirstScanTimeoutMs = 300000
    )
    $pre = Start-McpProvisionStep -Mcp 'grepai' -ToolName 'grepai' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpProvisionAlreadyReason -Mcp 'grepai' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'grepai' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'grepai' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    # --- 1. config, only when absent -----------------------------------------
    $configNote = 'config already present (left untouched)'
    $cfg = Join-Path $pre.Root '.grepai\config.yaml'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) {
        $r1 = Invoke-McpProvisionCommand -FilePath $pre.Tool `
                -Arguments (Get-McpProvisionArgv -Mcp 'grepai' -Step 'config') `
                -WorkingDirectory $pre.Root -TimeoutMs $ConfigTimeoutMs
        if (-not ($r1.Launched -and -not $r1.TimedOut -and $r1.ExitCode -eq 0)) {
            return New-McpProvisionRow -Mcp 'grepai' -Status 'skipped' `
                -Reason (Get-McpProvisionFailureReason -Result $r1 -TimeoutMs $ConfigTimeoutMs -Label 'grepai init --yes') `
                -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $configNote = 'config created by grepai init --yes'
    }

    # --- 2. first scan -------------------------------------------------------
    $scanNote = ''
    $r2 = Invoke-McpProvisionCommand -FilePath $pre.Tool `
            -Arguments (Get-McpProvisionArgv -Mcp 'grepai' -Step 'scan') `
            -WorkingDirectory $pre.Root -TimeoutMs $FirstScanTimeoutMs
    if ($r2.Launched -and -not $r2.TimedOut -and $r2.ExitCode -eq 0) {
        # Exit 0 is NOT proof of an index either (bead mcpw-0zo.1): a watch that
        # comes back immediately having indexed nothing must not be stamped. The
        # same probe the pre-command gate uses decides, and it spawns its own
        # `grepai status --no-ui`.
        $g = Get-McpProvisionPostCommandGate -Mcp 'grepai' -Root $pre.Root -Label 'grepai watch'
        if (-not $g.Ok) {
            return New-McpProvisionRow -Mcp 'grepai' -Status 'skipped' `
                -Reason "$configNote; $($g.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $scanNote = "first scan complete ($($g.Reason))"
    } else {
        # The watch was stopped at the timeout (or died). Ask the SAME probe the
        # detection layer uses - the tool this step resolved, but the shared
        # parse. Calling the probe instead of re-matching "Files indexed" here is
        # what stops the two layers drifting about what "indexed" means
        # (bead mcpw-4ci): the file counter is never computed by grepai, so the
        # probe now decides on the chunk count.
        $r3 = Invoke-McpProvisionCommand -FilePath $pre.Tool `
                -Arguments (Get-McpProvisionArgv -Mcp 'grepai' -Step 'status') `
                -WorkingDirectory $pre.Root -TimeoutMs 30000
        $text = ''
        if ($r3.Launched) { $text = [string]$r3.Output + [string]$r3.Error }
        $d2 = Get-McpProvisionAlreadyReason -Mcp 'grepai' -Root $pre.Root -ProbeOutput $text
        if ($d2.Ok) {
            $scanNote = "first scan complete ($($d2.Reason))"
        } else {
            $why = Get-McpProvisionFailureReason -Result $r2 -TimeoutMs $FirstScanTimeoutMs -Label 'grepai watch'
            return New-McpProvisionRow -Mcp 'grepai' -Status 'skipped' `
                -Reason "$configNote; $why; $($d2.Reason)" `
                -Tool $pre.Tool -Stamp $pre.StateDir
        }
    }

    $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'grepai' -Detail "$configNote; $scanNote" -Tool $pre.Tool -StateDir $pre.StateDir
    return New-McpProvisionRow -Mcp 'grepai' -Status 'done' `
        -Reason "$configNote; $scanNote" -Tool $pre.Tool -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# atlas (Neo4j knowledge graph) - Phase: config, and the one FileOnly step
# ---------------------------------------------------------------------------
function Get-AtlasEnvDefaults {
    <#
    .SYNOPSIS
        The canonical atlas .env values, read from the compose directory.
    .DESCRIPTION
        ONE source of truth, not a copy. Bead mcpw-cnc.1 captured the running
        container as docker/neo4j-atlas/, and .env.example there is the
        documented record of all three keys. This function READS that file
        rather than repeating the literals here, so a password rotation has
        exactly one file to edit and the compose directory and this module
        cannot drift apart.

        Resolved relative to THIS module ($PSScriptRoot\..), so the pair travels
        together and no absolute workspace path is hardcoded (AGENTS.md).

        Returns @{ Ok = [bool]; Reason = <text>; Values = @{ KEY = value } }.

        When the file is missing or short a key this returns Ok = $false and the
        caller SKIPS. It deliberately does NOT fall back to built-in literals:
        inventing a password here would produce a .env that cannot
        authenticate, which is strictly worse than a visible skip naming the
        file to restore - atlas would fail with an opaque credential error
        instead of the operator being told what to put back.
    #>
    $rel  = 'docker\neo4j-atlas\.env.example'
    $file = ''
    if ($PSScriptRoot) {
        $file = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'docker\neo4j-atlas') '.env.example'
    }
    if (-not (Get-Command Read-AtlasEnvFile -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Values = @{}
                  Reason = 'Modules\watcher_mcp_detect.ps1 is not loaded, so the canonical atlas values cannot be parsed' }
    }
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        return @{ Ok = $false; Values = @{}
                  Reason = "the canonical atlas values file is missing: <MCP-Watchers>\$rel" }
    }
    $map = Read-AtlasEnvFile -File $file
    if ($null -eq $map) {
        return @{ Ok = $false; Values = @{}
                  Reason = "the canonical atlas values file could not be read: $file" }
    }
    $vals    = @{}
    $missing = @()
    foreach ($k in @(Get-AtlasEnvKeyNames)) {
        $v = ''
        if ($map.ContainsKey($k)) { $v = [string]$map[$k] }
        if ($v) { $vals[$k] = $v } else { $missing += $k }
    }
    if ($missing.Count -gt 0) {
        return @{ Ok = $false; Values = @{}
                  Reason = ("the canonical atlas values file is short key(s): " + ($missing -join ', ') + " ($rel)") }
    }
    return @{ Ok = $true; Values = $vals; Reason = "read $rel" }
}

function Test-McpProvisionPathIgnored {
    <#
    .SYNOPSIS
        Ask git whether one repository-relative path is ignored. Never throws.
    .DESCRIPTION
        Returns @{ Answered = [bool]; Ignored = [bool]; Reason = <text> }.

        Answered separates the two ways Ignored can be $false - the same
        distinction Get-McpProvisionAlreadyReason draws for stamps:
          Answered = $true  -> git ran and produced a verdict, which is Ignored.
          Answered = $false -> git could not be asked at all (no repository
                               here, or no git binary). That is SILENCE, not
                               evidence that the path is safe.

        Callers must honour the difference: only a real "not ignored" verdict is
        grounds to refuse a write. Reading silence as "unsafe" would make the
        step skip on any box without git.
    #>
    param([string]$Root, [string]$RelPath)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @{ Answered = $false; Ignored = $false; Reason = 'no repository root' }
    }
    $git = Resolve-McpProvisionTool -Name 'git'
    if (-not $git) {
        return @{ Answered = $false; Ignored = $false; Reason = 'git not found on PATH' }
    }
    # `git check-ignore` exits 0 when the path IS ignored, 1 when it is NOT, and
    # 128 on a hard error such as "not a git repository". So the exit code is
    # the verdict and the output text is not needed. -q keeps it quiet; 2>$null
    # stops a legitimate "not ignored" verdict writing to the error stream.
    $null = & $git -C $Root check-ignore -q -- $RelPath 2>$null
    $code = $LASTEXITCODE
    if ($code -eq 0) { return @{ Answered = $true; Ignored = $true;  Reason = "$RelPath is ignored" } }
    if ($code -eq 1) { return @{ Answered = $true; Ignored = $false; Reason = "$RelPath is NOT ignored" } }
    return @{ Answered = $false; Ignored = $false; Reason = "git check-ignore exited $code for $Root" }
}

function Test-McpProvisionIgnoreRulePresent {
    # Does this ignore-file text already carry a rule covering <Pattern>?
    # Exact match on a trimmed, non-comment line: '.env', '/.env' and '**/.env'
    # all cover the file, and any of the three counts. Deliberately NOT a
    # general gitignore matcher - the caller asks git itself for the real
    # verdict afterwards, so this only has to avoid appending a redundant line.
    param([string]$Text, [string]$Pattern)
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith('#')) { continue }
        if ($s -eq $Pattern -or $s -eq "/$Pattern" -or $s -eq "**/$Pattern") { return $true }
    }
    return $false
}

function Enable-McpProvisionEnvIgnore {
    <#
    .SYNOPSIS
        Make <Root>/.env un-committable, or explain why that could not be done.
    .DESCRIPTION
        Bead mcpw-cnc.7 acceptance: "No .env is ever committed in any repo the
        provisioner touches." The provisioner writes a plaintext database
        password into the single most commonly committed credential filename
        there is, so the ignore rule is not a nicety - it is part of writing the
        file at all.

        Two records, deliberately different in scope:
          1. <gitdir>/info/exclude - local to this clone. It is never committed,
             so it cannot itself become a diff, and it applies even to a
             repository that has no .gitignore. The gitdir is resolved with
             `git rev-parse --absolute-git-dir` so a linked worktree (where .git
             is a FILE pointing elsewhere) lands in the right place instead of a
             path that does not exist.
          2. <Root>/.gitignore - committed, so it protects every other clone and
             every other machine. Created only when absent; otherwise the rule
             is appended only when it is not already covered, under a marked
             block so the edit is attributable.

        Returns @{ Ok = [bool]; Changed = [bool]; Reason = <text> }. Never
        throws. Ok means the rule has been recorded; it does NOT mean git has
        confirmed it, because a later negation in the same .gitignore can
        override an earlier rule. The caller verifies separately with
        Test-McpProvisionPathIgnored - which is why this function does not
        pretend to be the last word.
    #>
    param([string]$Root, [string]$RelPath = '.env')
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @{ Ok = $false; Changed = $false; Reason = 'no repository root' }
    }

    # --- locate the real gitdir, and bail out cleanly when there is none -----
    $git    = Resolve-McpProvisionTool -Name 'git'
    $gitDir = ''
    if ($git) {
        $gd = & $git -C $Root rev-parse --absolute-git-dir 2>$null
        if ($LASTEXITCODE -eq 0 -and $gd) { $gitDir = ([string]$gd).Trim() }
    }
    if (-not $gitDir) {
        $cand = Join-Path $Root '.git'
        if (Test-Path -LiteralPath $cand -PathType Container) { $gitDir = $cand }
    }
    if (-not $gitDir) {
        return @{ Ok = $true; Changed = $false
                  Reason = 'not a git repository - a .env here cannot be committed' }
    }

    $changed = $false
    $notes   = @()

    # --- 1. the clone-local exclude -----------------------------------------
    $exclude = Join-Path (Join-Path $gitDir 'info') 'exclude'
    try {
        $infoDir = Join-Path $gitDir 'info'
        if (-not (Test-Path -LiteralPath $infoDir -PathType Container)) {
            New-Item -ItemType Directory -Path $infoDir -Force | Out-Null
        }
        $text = ''
        if (Test-Path -LiteralPath $exclude -PathType Leaf) {
            $text = [string](Get-Content -LiteralPath $exclude -Raw -ErrorAction SilentlyContinue)
        }
        if (-not (Test-McpProvisionIgnoreRulePresent -Text $text -Pattern $RelPath)) {
            $block = "# MCP-Watchers provision (bead mcpw-cnc.7): never commit the atlas Neo4j credentials.`r`n$RelPath`r`n"
            Add-Content -LiteralPath $exclude -Value $block -Encoding UTF8 -ErrorAction Stop
            $changed = $true
            $notes += 'added to .git/info/exclude'
        } else {
            $notes += 'already in .git/info/exclude'
        }
    } catch {
        $notes += "could not write .git/info/exclude: $($_.Exception.Message)"
    }

    # --- 2. the committed .gitignore ----------------------------------------
    $gi = Join-Path $Root '.gitignore'
    try {
        $text = ''
        $exists = Test-Path -LiteralPath $gi -PathType Leaf
        if ($exists) {
            $text = [string](Get-Content -LiteralPath $gi -Raw -ErrorAction SilentlyContinue)
        }
        if (-not (Test-McpProvisionIgnoreRulePresent -Text $text -Pattern $RelPath)) {
            $block = "# MCP-Watchers provision (bead mcpw-cnc.7): the atlas Neo4j credentials are`r`n# written into .env per repository and must never be committed.`r`n$RelPath`r`n"
            if (-not $exists) {
                Set-Content -LiteralPath $gi -Value $block -Encoding UTF8 -ErrorAction Stop
            } else {
                if (-not $text.EndsWith("`n")) { Add-Content -LiteralPath $gi -Value '' -Encoding UTF8 }
                Add-Content -LiteralPath $gi -Value $block -Encoding UTF8 -ErrorAction Stop
            }
            $changed = $true
            $notes += 'added to .gitignore'
        } else {
            $notes += 'already in .gitignore'
        }
    } catch {
        $notes += "could not write .gitignore: $($_.Exception.Message)"
    }

    return @{ Ok = $true; Changed = $changed; Reason = ($notes -join '; ') }
}

function Initialize-AtlasForRepo {
    <#
    .SYNOPSIS
        Write this repository's atlas (Neo4j) .env and make sure it cannot be
        committed.
    .DESCRIPTION
        The one provision step that spawns NOTHING. It is the program-managed
        form of step 3 of the atlas-mcp-server setup guide ("create your .env
        file and set NEO4J_URI / NEO4J_USER / NEO4J_PASSWORD"), which could not
        be done by hand because atlas is installed as the prebuilt npm global
        package rather than a git clone - there was no project root to put one
        in. Bead mcpw-cnc.7 makes the program do it for every target repository.

        THE THREE VALUES ARE IDENTICAL IN EVERY REPO, and the header written
        into the file says so. Neo4j 5 Community - the container's image -
        supports exactly ONE database; SHOW DATABASES on this instance returns
        only 'neo4j' and 'system'. Every repo writes into the same graph, so
        this file carries connection credentials only and CANNOT isolate one
        repository's graph from another's. Writing a per-repo password would be
        actively harmful: a repo with a different password simply cannot
        authenticate. See bead mcpw-cnc.8 for what real isolation would cost.

        Order of operations, and why:
          1. Start-McpProvisionStep -FileOnly - the shared prologue. It keeps
             the stamp, the stale-stamp probe agreement and the root checks;
             only the binary resolution is skipped, because there is no binary.
          2. probe - already initialized? stamp it and stop. This is what makes
             a second run a no-op.
          3. canonical values - read from docker/neo4j-atlas/.env.example. If
             they cannot be read, SKIP rather than invent them.
          4. ignore rule FIRST, then the file. Writing the credential and only
             then arranging for it to be ignored leaves a window in which a
             `git add -A` commits it.
          5. write, temp-then-move, so a crash mid-write cannot leave a
             half-written .env that the probe would read as a valid artifact.
          6. post-command gate - the same probe again. Exit codes are irrelevant
             here (nothing exits) but the principle is not: the write is not
             proof the file is right, so the probe still has to agree before the
             stamp is earned (bead mcpw-0zo.1).

        Takes no -ToolPath and no -TimeoutMs: there is no command to point at
        and none to bound. The plan row marks the step FileOnly so callers
        branch on that instead of on this function's name.

        WHEN THE .env TAKES EFFECT. Not immediately. atlas reads it once at
        startup through dotenv.config(), so an already-running atlas keeps its
        old environment until the Toolport gateway serving this repository is
        restarted. The launcher's own provisioning happens before the watchers
        spawn, which is the intended moment.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [switch]$Force
    )
    $pre = Start-McpProvisionStep -Mcp 'atlas' -Path $Path -StateDir $StateDir -Force:$Force -FileOnly
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpProvisionAlreadyReason -Mcp 'atlas' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'atlas' -Detail $d.Reason -Tool '' -StateDir $pre.StateDir
        return New-McpProvisionRow -Mcp 'atlas' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool '' -Stamp $pre.StateDir
    }

    # --- the canonical values, or a loud skip -------------------------------
    $def = Get-AtlasEnvDefaults
    if (-not $def.Ok) {
        return New-McpProvisionRow -Mcp 'atlas' -Status 'skipped' `
            -Reason ("cannot write .env - " + $def.Reason) -Tool '' -Stamp $pre.StateDir
    }

    # --- the ignore rule, BEFORE the credential is on disk -------------------
    $ign = Enable-McpProvisionEnvIgnore -Root $pre.Root -RelPath '.env'
    if (-not $ign.Ok) {
        return New-McpProvisionRow -Mcp 'atlas' -Status 'skipped' `
            -Reason ("refusing to write a credential that could be committed - " + $ign.Reason) `
            -Tool '' -Stamp $pre.StateDir
    }
    $verdict = Test-McpProvisionPathIgnored -Root $pre.Root -RelPath '.env'
    if ($verdict.Answered -and -not $verdict.Ignored) {
        # A real "not ignored" verdict, not silence: something in the repository
        # (a negation later in .gitignore) overrides the rule we just recorded.
        # Do not write the password.
        return New-McpProvisionRow -Mcp 'atlas' -Status 'skipped' `
            -Reason ("refusing to write a credential that could be committed - " + $verdict.Reason) `
            -Tool '' -Stamp $pre.StateDir
    }
    $ignoreNote = $ign.Reason
    if (-not $verdict.Answered) { $ignoreNote += " (unverified: $($verdict.Reason))" }

    # --- write it ------------------------------------------------------------
    $file = Join-Path $pre.Root '.env'
    $body = @(
        '# atlas-mcp-server (Neo4j knowledge graph) - repository connection settings.'
        '#'
        '# Written by the MCP-Watchers provision step (Initialize-AtlasForRepo,'
        '# bead mcpw-cnc.7). Re-running provisioning rewrites this file; hand'
        '# edits are lost. Change the canonical values in'
        '# docker/neo4j-atlas/.env.example instead.'
        '#'
        '# THESE ARE LOCAL DATABASE CREDENTIALS, not a vendor API key: they are the'
        '# credentials for the neo4j-atlas-mcp-server container on this machine.'
        '#'
        '# THE SAME THREE VALUES ARE WRITTEN INTO EVERY REPOSITORY. Neo4j 5'
        '# Community supports exactly ONE database, so every repo writes into the'
        '# same graph. This file carries connection credentials only and cannot'
        '# isolate one repository from another.'
        '#'
        '# NEO4J_PASSWORD must equal NEO4J_AUTH in'
        '# docker/neo4j-atlas/docker-compose.yml and the Toolport registry env'
        '# block for server id ''atlas''. One password, three places.'
        ''
        "NEO4J_URI=$($def.Values['NEO4J_URI'])"
        "NEO4J_USER=$($def.Values['NEO4J_USER'])"
        "NEO4J_PASSWORD=$($def.Values['NEO4J_PASSWORD'])"
        ''
    ) -join "`r`n"

    try {
        $tmp = "$file.tmp-mcpw"
        Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8 -NoNewline -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
    } catch {
        try { if (Test-Path -LiteralPath "$file.tmp-mcpw") { Remove-Item -LiteralPath "$file.tmp-mcpw" -Force } } catch { }
        return New-McpProvisionRow -Mcp 'atlas' -Status 'skipped' `
            -Reason ("could not write ${file}: " + $_.Exception.Message) -Tool '' -Stamp $pre.StateDir
    }

    # --- earn the stamp ------------------------------------------------------
    $g = Get-McpProvisionPostCommandGate -Mcp 'atlas' -Root $pre.Root -Label 'the .env write'
    if (-not $g.Ok) {
        return New-McpProvisionRow -Mcp 'atlas' -Status 'skipped' `
            -Reason $g.Reason -Tool '' -Stamp $pre.StateDir
    }
    $null = Set-McpProvisionStamp -Path $pre.Root -Mcp 'atlas' -Detail 'wrote .env' -Tool '' -StateDir $pre.StateDir
    return New-McpProvisionRow -Mcp 'atlas' -Status 'done' `
        -Reason ("wrote .env with NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD from " +
                 "docker/neo4j-atlas/.env.example; $ignoreNote") `
        -Tool '' -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# aggregate
# ---------------------------------------------------------------------------
function Invoke-McpProvisionForRepo {
    <#
    .SYNOPSIS
        Provision all seven watched MCPs for one repository.
    .DESCRIPTION
        Runs Get-McpProvisionPlan in order and returns a summary object. NEVER
        throws: every step is isolated, and a step that throws is recorded as a
        'skipped' row. That is the whole point - a provision problem in a foreign
        repository must never abort the launcher.
    .PARAMETER Path
        The repository root. Everything is derived from it.
    .PARAMETER StateDir
        Where the idempotence stamp lives. Defaults to <Path>/.mcpw-provision.
    .PARAMETER ToolPaths
        Per-MCP binary overrides, keyed by MCP name (e.g.
        @{ repowise = 'C:\...\repowise.exe' }). Used by the tests to inject
        fakes, and by a caller that has a tool installed off PATH.
    .PARAMETER Only
        Restrict the run to these MCP names. Omitted = all seven.
    .PARAMETER Force
        Ignore the stamp and re-run every step.
    .PARAMETER ReportOnly
        Answer "what would provisioning do?" without doing it. Runs the seven
        detection probes and returns one row per MCP: 'stamped' when the probe
        already reports provisioned, 'skipped' when no runnable tool was found
        or an optional opt-in file is missing, and 'planned' when a step would
        execute its command. No PROVISIONING command runs and no stamp is
        written, so it is safe to point at a repository you do not own.

        Honest cost, measured on this repo 2026-09-21: the call took 39.9s.
        "No tool runs" would be a lie - a probe whose artifact already exists
        shells out to CONFIRM it (grepai status, repowise doctor). Those are
        read-only queries, not provisioning, and a probe whose artifact is
        absent short-circuits without spawning anything; but they are not free,
        and this is still ~15x cheaper than the memtrace index and grepai first
        scan a real run would spend (mcpw-vrf).

        Note this reports ground truth from the probes, not the stamp shortcut:
        a step whose stamp says done but whose artifact is missing is reported
        'planned', which is exactly the Mode A case the stamp gate hides.
    #>
    param(
        [string]    $Path,
        [string]    $StateDir,
        [hashtable] $ToolPaths,
        [string[]]  $Only,
        [switch]    $Force,
        [switch]    $ReportOnly,
        [int]       $TimeoutMs = 1800000,
        [int]       $FirstScanTimeoutMs = 300000
    )
    $root    = Get-McpProvisionRoot -Path $Path
    $dir     = Get-McpProvisionStateDir -Path $root -StateDir $StateDir
    $started = Get-Date
    $rows    = New-Object System.Collections.Generic.List[object]

    # Opt-in config file per OPTIONAL step, mirroring the gate each real
    # initializer applies. Used by -ReportOnly so the report cannot claim it
    # plans a step the real run would skip.
    $optionalConfigGate = @{ 'graphify-rs' = 'graphify-rs.toml' }

    foreach ($step in @(Get-McpProvisionPlan)) {
        if ($Only -and ($Only -notcontains $step.Mcp)) { continue }
        $tp = ''
        if ($ToolPaths -and $ToolPaths.ContainsKey($step.Mcp)) { $tp = [string]$ToolPaths[$step.Mcp] }

        $row = $null
        if ($ReportOnly) {
            # mcpw-0zo.6: answer "what would this do?" without doing it. The
            # probes are the ground truth here, deliberately NOT the stamp: a
            # step whose stamp says done but whose artifact is gone is reported
            # 'planned', which is exactly the case the stamp gate hides.
            $tool = Resolve-McpProvisionTool -Name $step.Mcp -ToolPath $tp
            $gate = $optionalConfigGate[$step.Mcp]
            if ($step.Optional -and $gate -and -not (Test-Path -LiteralPath (Join-Path $root $gate) -PathType Leaf)) {
                # Mirror the real initializer's opt-in gate, or the report would
                # claim it plans a step that would actually be skipped.
                $row = New-McpProvisionRow -Mcp $step.Mcp -Status 'skipped' `
                    -Reason "report-only: optional - $gate missing (bead mcpw-01g, P3) - nothing to configure" -Tool $tool -Stamp $dir
            } elseif (-not $tool -and -not $step.FileOnly) {
                # A FileOnly step has no tool BY DESIGN, so its absence is not a
                # reason to skip it - it would make the report claim atlas is
                # never planned on any repository. Such a step falls through to
                # the probe below, which is the same ground truth the real run
                # would consult.
                $row = New-McpProvisionRow -Mcp $step.Mcp -Status 'skipped' `
                    -Reason "report-only: no runnable tool for $($step.Mcp) - this step would be skipped" -Tool '' -Stamp $dir
            } else {
                $already = Get-McpProvisionAlreadyReason -Mcp $step.Mcp -Root $root
                if ($already.Ok -and -not $Force) {
                    $row = New-McpProvisionRow -Mcp $step.Mcp -Status 'stamped' `
                        -Reason ("report-only: already provisioned - " + $already.Reason + " - nothing to run") -Tool $tool -Stamp $dir
                } else {
                    $row = New-McpProvisionRow -Mcp $step.Mcp -Status 'planned' `
                        -Reason ("report-only: would run the $($step.Phase) step for $($step.Mcp)") -Tool $tool -Stamp $dir
                }
            }
        } else {
            try {
                switch ($step.Mcp) {
                    'atlas'       { $row = Initialize-AtlasForRepo       -Path $root -StateDir $dir -Force:$Force }
                    'graphenium'  { $row = Initialize-GrapheniumForRepo  -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                    'repowise'    { $row = Initialize-RepowiseForRepo    -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                    'graphify-rs' { $row = Initialize-GraphifyRsForRepo  -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                    'graft'       { $row = Initialize-GraftForRepo       -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                    'memtrace'    { $row = Initialize-MemtraceForRepo    -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                    'grepai'      { $row = Initialize-GrepaiForRepo      -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -FirstScanTimeoutMs $FirstScanTimeoutMs }
                }
            } catch {
                $row = New-McpProvisionRow -Mcp $step.Mcp -Status 'skipped' `
                    -Reason ("initializer threw: " + $_.Exception.Message) -Tool '' -Stamp $dir
            }
        }
        if (-not $row) {
            $row = New-McpProvisionRow -Mcp $step.Mcp -Status 'skipped' `
                -Reason 'initializer returned no result' -Tool '' -Stamp $dir
        }
        $row | Add-Member -NotePropertyName Optional -NotePropertyValue ([bool]$step.Optional) -Force
        $row | Add-Member -NotePropertyName Phase    -NotePropertyValue ([string]$step.Phase) -Force
        [void]$rows.Add($row)
    }

    $done    = @($rows | Where-Object { $_.Status -eq 'done' }).Count
    $stamped = @($rows | Where-Object { $_.Status -eq 'stamped' }).Count
    $planned = @($rows | Where-Object { $_.Status -eq 'planned' }).Count
    $skipped = @($rows | Where-Object { $_.Status -eq 'skipped' }).Count

    # Snapshot the list into a plain object[] BEFORE the [pscustomobject] cast.
    # Measured on this box (Windows PowerShell 5.1 and pwsh 7.6.6): casting a
    # hashtable literal to [pscustomobject] whose value is `@($genericList)`
    # throws System.ArgumentException "Argument types do not match". ToArray()
    # is the same array without the bug.
    $results = $rows.ToArray()

    return [pscustomobject]@{
        Path     = $root
        StateDir = $dir
        Started  = $started.ToString('o')
        Finished = (Get-Date).ToString('o')
        Total    = $rows.Count
        Done     = $done
        Stamped  = $stamped
        Planned  = $planned
        Skipped  = $skipped
        ReportOnly = [bool]$ReportOnly
        Results  = $results
    }
}
