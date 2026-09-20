# Modules/watcher_mcp_bootstrap.ps1
# MCP initialization ("bootstrap") layer (bead mcpw-rkg.2, epic mcpw-rkg).
#
# WHY THIS EXISTS
# ---------------
# The launcher (###1.watchers_....ps1) must bring all six watched MCPs up in ANY
# repository it is started from - a foreign repo has none of the per-repo
# artifacts the tools need. This module runs the six init steps. It is the
# WRITE side of the pair whose READ side is Modules/watcher_mcp_detect.ps1
# (mcpw-rkg.1): detection answers "is this repo already initialized?", bootstrap
# answers "then make it so, or explain why it cannot be".
#
# CONTRACT
# --------
#   Invoke-McpBootstrapForRepo -Path <repoRoot> [...]
#     -> one summary object the launcher can log (never throws):
#        .Path .StateDir .Started .Finished .Total .Done .Stamped .Skipped
#        .Results[]  where each row is
#                    .Mcp .Status .Reason .Tool .Stamp .Optional .Phase
#        .Status is one of exactly three values:
#           'done'    the init step ran and exited 0
#           'stamped' nothing to do - already initialized (detection), or a
#                     stamp from an earlier successful run
#           'skipped' the step did NOT run: binary absent, optional input
#                     missing, launch failure, timeout, or a non-zero exit.
#                     There is no 'failed' status on purpose - a bootstrap
#                     problem degrades to a logged skip and the other five MCPs
#                     still get their chance.
#
#   Initialize-<Mcp>ForRepo -Path <repoRoot> [-StateDir] [-ToolPath] [-Force]
#                           [-TimeoutMs] [-FirstScanTimeoutMs]
#     -> one row, callable on its own (the tests need that). Never throws.
#        Initialize-MemtraceForRepo / -GrepaiForRepo / -GrapheniumForRepo /
#        -GraphifyRsForRepo / -RepowiseForRepo / -GraftForRepo
#
# HARD RULES ENCODED HERE
# -----------------------
#   * IDEMPOTENT. A successful (or already-initialized) step writes a STAMP -
#     one key inside <repo>/.mcpw-bootstrap/state.json. The stamp is checked
#     BEFORE anything else, so a second run re-runs no build and spawns no
#     probe. -Force re-runs everything. The tests assert on the stamp file.
#   * NON-INTERACTIVE, unconditionally. Every child gets stdin CLOSED, so a
#     prompt reads EOF instead of blocking the launcher forever; children run
#     with CreateNoWindow and a hard timeout, and are killed on timeout. On top
#     of that each tool gets the non-interactive flag it actually has
#     (`grepai init --yes`, `grepai watch --no-ui`, `repowise agents add --yes`,
#     `graphify-rs build --no-llm`). No Read-Host, no -Confirm, anywhere.
#   * DEGRADES. A missing binary, a missing optional input, a launch failure, a
#     timeout or a non-zero exit all become a 'skipped' row with a one-line
#     reason. A bootstrap problem can never abort the launcher.
#   * REPO-AGNOSTIC. Every path is derived from -Path. There is no absolute
#     reference to any particular repository (the tests assert that).
#   * ORDERED CHEAP-FIRST: config-only steps (gm init, repowise agents add)
#     before build steps (graphify-rs, graft) before index steps (memtrace,
#     grepai). See Get-McpBootstrapPlan.
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
#   gm        No `.graphenium/` config dir exists; `gm init [PATH]` defaults to
#             ".", so the root is always passed explicitly. `gm init` writes the
#             config only - the graph is `gm run`, which the launcher's own
#             watcher owns.
#   graphify-rs  `graphify-rs.toml` is missing (bead mcpw-01g, OPTIONAL/P3).
#             Without the config file there is nothing to bootstrap, so the step
#             skips as optional rather than inventing a config. Rebuild argv
#             comes from Get-GraphifyRebuildArgs (--update --no-llm).
#   repowise  `.repowise/` store exists (47 pages) but the Claude Code MCP entry
#             is NOT registered, and that registration is what detection keys
#             on. The uv-tool venv was repaired today (mcpw-a0g), so the REAL
#             binary is invoked by absolute path - the PATH `repowise` is a
#             declick MCP engine shim with no `agents`/`update` verb. The
#             targeted, cheap, non-interactive verb is `repowise agents add`
#             (--yes), NOT `repowise init`, which regenerates the wiki with a
#             model and can prompt for a key.
#   graft     `graft/manifest.json` can be missing ENTIRELY. Plain
#             `graft build <dir>` is the $0 no-key tier (wiring graph +
#             per-file cards). --deep is NEVER passed: it needs an LLM key.
#
# Safe to dot-source: function definitions plus one sibling dot-source (the
# detection module), matching Modules/watcher_teardown.ps1. No launches, no
# writes, at load time.

$mcpBootstrapDetectModule = Join-Path $PSScriptRoot 'watcher_mcp_detect.ps1'
if (Test-Path -LiteralPath $mcpBootstrapDetectModule) { . $mcpBootstrapDetectModule }

# ---------------------------------------------------------------------------
# root + state (stamp) plumbing
# ---------------------------------------------------------------------------
function Get-McpBootstrapRoot {
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

function Get-McpBootstrapStateDir {
    <#
    .SYNOPSIS
        Where the bootstrap stamp for one repository lives.
    .DESCRIPTION
        Resolution order:
          1. the explicit -StateDir argument (tests, and a launcher that wants
             its state elsewhere)
          2. MCPW_BOOTSTRAP_STATE_DIR
          3. <repo>/.mcpw-bootstrap - the default. Rooted at -Path, so the
             stamp travels with the repository it describes and two repos on
             one machine can never share a stamp.
    #>
    param([string]$Path, [string]$StateDir)
    if ($StateDir) { return $StateDir.TrimEnd('\', '/') }
    if ($env:MCPW_BOOTSTRAP_STATE_DIR) { return $env:MCPW_BOOTSTRAP_STATE_DIR.TrimEnd('\', '/') }
    $root = Get-McpBootstrapRoot -Path $Path
    if (-not $root) { return '' }
    return (Join-Path $root '.mcpw-bootstrap')
}

function Get-McpBootstrapStateFile {
    param([string]$StateDir)
    if (-not $StateDir) { return '' }
    return (Join-Path $StateDir 'state.json')
}

function Read-McpBootstrapState {
    # The stamp file as a hashtable keyed by MCP name. A missing, empty or
    # corrupt file reads as an empty hashtable - never throws, so a truncated
    # stamp can only cause one extra (safe) bootstrap run, never a crash.
    param([string]$StateDir)
    $state = @{}
    $file = Get-McpBootstrapStateFile -StateDir $StateDir
    if (-not $file) { return $state }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $state }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $state }
    if (-not $doc) { return $state }
    foreach ($p in $doc.PSObject.Properties) { $state[$p.Name] = $p.Value }
    return $state
}

function Test-McpBootstrapStamp {
    # Is there a recorded successful bootstrap for this MCP in this repo? This
    # is the idempotence gate, and it is deliberately the FIRST thing every
    # initializer checks: it costs one file read and spawns nothing.
    param([string]$Path, [string]$Mcp, [string]$StateDir)
    if (-not $Mcp) { return $false }
    $dir = Get-McpBootstrapStateDir -Path $Path -StateDir $StateDir
    $state = Read-McpBootstrapState -StateDir $dir
    if (-not $state.ContainsKey($Mcp)) { return $false }
    $entry = $state[$Mcp]
    if (-not $entry) { return $false }
    if (-not $entry.At) { return $false }
    return $true
}

function Set-McpBootstrapStamp {
    # Record a successful bootstrap for one MCP. Written temp-then-move so a
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
    $dir = Get-McpBootstrapStateDir -Path $Path -StateDir $StateDir
    if (-not $dir) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    } catch { return $false }

    $state = Read-McpBootstrapState -StateDir $dir
    $state[$Mcp] = [pscustomobject]@{
        At     = (Get-Date).ToString('o')
        Tool   = [string]$Tool
        Detail = [string]$Detail
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
function Get-McpBootstrapPlan {
    <#
    .SYNOPSIS
        The six bootstrap steps in the order they must run.
    .DESCRIPTION
        Ordered CHEAP-FIRST, which is the ordering contract the launcher relies
        on (bootstrap finishes before any watcher spawns - mcpw-rkg.3):
          Phase 'config' - gm init, repowise agents add   (seconds, no index)
          Phase 'build'  - graphify-rs (optional), graft build
          Phase 'index'  - memtrace index, grepai first scan (minutes)
        The launcher must not depend on a different order than this one.
    #>
    return @(
        [pscustomobject]@{ Order = 1; Mcp = 'graphenium';  Phase = 'config'; Optional = $false; Tool = 'gm';          Fn = 'Initialize-GrapheniumForRepo'  }
        [pscustomobject]@{ Order = 2; Mcp = 'repowise';    Phase = 'config'; Optional = $false; Tool = 'repowise';    Fn = 'Initialize-RepowiseForRepo'    }
        [pscustomobject]@{ Order = 3; Mcp = 'graphify-rs'; Phase = 'build';  Optional = $true;  Tool = 'graphify-rs'; Fn = 'Initialize-GraphifyRsForRepo'  }
        [pscustomobject]@{ Order = 4; Mcp = 'graft';       Phase = 'build';  Optional = $false; Tool = 'graft';       Fn = 'Initialize-GraftForRepo'       }
        [pscustomobject]@{ Order = 5; Mcp = 'memtrace';    Phase = 'index';  Optional = $false; Tool = 'memtrace';    Fn = 'Initialize-MemtraceForRepo'    }
        [pscustomobject]@{ Order = 6; Mcp = 'grepai';      Phase = 'index';  Optional = $false; Tool = 'grepai';      Fn = 'Initialize-GrepaiForRepo'      }
    )
}

function Get-McpBootstrapArgv {
    <#
    .SYNOPSIS
        The exact argument vector for one bootstrap step.
    .DESCRIPTION
        One place for every command line, so the non-interactive flags are
        assertable in a test instead of being buried in six function bodies.
        $Step only disambiguates grepai, which needs three different commands
        (config / scan / status).
    #>
    param(
        [string]$Mcp,
        [string]$Path,
        [string]$Step
    )
    switch ($Mcp) {
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

function Resolve-McpBootstrapTool {
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
function ConvertTo-McpBootstrapArgLine {
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

function Invoke-McpBootstrapCommand {
    <#
    .SYNOPSIS
        Run one bootstrap command, bounded and non-interactive. Never throws.
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
            if ($argv.Count -gt 0) { $inner += ' ' + (ConvertTo-McpBootstrapArgLine -Arguments $argv) }
            $argLine = '/d /s /c "' + $inner + '"'
        } elseif ($ext -eq '.ps1') {
            $exe = 'powershell.exe'
            $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $FilePath + '"'
            if ($argv.Count -gt 0) { $argLine += ' ' + (ConvertTo-McpBootstrapArgLine -Arguments $argv) }
        } else {
            $argLine = ConvertTo-McpBootstrapArgLine -Arguments $argv
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
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        } else {
            # Documented .NET requirement: after a TIMED WaitForExit returns
            # true, call it again (no timeout) so the async output handlers have
            # flushed before the streams are read.
            try { $proc.WaitForExit() } catch { }
        }
        # Only touch .Result when the task is COMPLETE - .Result on an
        # incomplete task BLOCKS, and after a kill the reader may never finish
        # (a killed shim can leave a grandchild holding the write end). Losing
        # the tail of a timed-out command's output is fine; hanging is not.
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

function Get-McpBootstrapFailureReason {
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
function New-McpBootstrapRow {
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

function Start-McpBootstrapStep {
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
    #>
    param(
        [string]$Mcp,
        [string]$ToolName,
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force
    )
    $root = Get-McpBootstrapRoot -Path $Path
    $dir  = Get-McpBootstrapStateDir -Path $root -StateDir $StateDir
    $out  = @{ Root = $root; StateDir = $dir; Tool = ''; Skip = $null }

    if (-not $Force) {
        if (Test-McpBootstrapStamp -Path $root -Mcp $Mcp -StateDir $dir) {
            $out.Skip = New-McpBootstrapRow -Mcp $Mcp -Status 'stamped' `
                -Reason 'already bootstrapped (stamp present; use -Force to re-run)' `
                -Tool '' -Stamp $dir
            return $out
        }
    }
    if (-not $root) {
        $out.Skip = New-McpBootstrapRow -Mcp $Mcp -Status 'skipped' `
            -Reason 'no repository path supplied' -Tool '' -Stamp $dir
        return $out
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $out.Skip = New-McpBootstrapRow -Mcp $Mcp -Status 'skipped' `
            -Reason "path not found: $root" -Tool '' -Stamp $dir
        return $out
    }

    $tool = Resolve-McpBootstrapTool -Name $ToolName -ToolPath $ToolPath
    $out.Tool = $tool
    if (-not $tool) {
        $reason = if ($ToolPath) { "binary not found: $ToolPath" } else { "binary not found: $ToolName" }
        $out.Skip = New-McpBootstrapRow -Mcp $Mcp -Status 'skipped' `
            -Reason $reason -Tool '' -Stamp $dir
        return $out
    }
    return $out
}

function Get-McpBootstrapAlreadyReason {
    # Run the detection module's probe for one MCP. Returns a hashtable
    # @{ Ok = [bool]; Reason = <text> }. Never throws: a probe that cannot
    # answer counts as "not initialized", which is the safe direction.
    param([string]$Mcp, [string]$Root, [string]$ProbeOutput)
    $probe = @{
        'memtrace'    = 'Test-MemtraceInitialized'
        'grepai'      = 'Test-GrepaiInitialized'
        'graphenium'  = 'Test-GrapheniumInitialized'
        'graphify-rs' = 'Test-GraphifyRsInitialized'
        'repowise'    = 'Test-RepowiseInitialized'
        'graft'       = 'Test-GraftInitialized'
    }
    $fn = $probe[$Mcp]
    if (-not $fn) { return @{ Ok = $false; Reason = "no probe for $Mcp" } }
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Reason = "detection probe $fn not available" }
    }
    $reason = ''
    $ok = $false
    try {
        if ($ProbeOutput) { $ok = [bool](& $fn -Path $Root -Reason ([ref]$reason) -ProbeOutput $ProbeOutput) }
        else              { $ok = [bool](& $fn -Path $Root -Reason ([ref]$reason)) }
    } catch {
        return @{ Ok = $false; Reason = "detection probe threw: $($_.Exception.Message)" }
    }
    return @{ Ok = $ok; Reason = $reason }
}

# ---------------------------------------------------------------------------
# graphenium (gm) - Phase: config (cheap)
# ---------------------------------------------------------------------------
function Initialize-GrapheniumForRepo {
    <#
    .SYNOPSIS
        Ensure this repository has a graphenium workspace config.
    .DESCRIPTION
        `gm init [PATH]` writes the `.graphenium/` config directory. The root is
        always passed explicitly because the command defaults to "." and the
        bootstrap must not depend on the caller's cwd.

        Detection wants BOTH `.graphenium/` and `graphenium-out/graph.json`;
        `gm init` writes only the config, so this step's contract is "config
        exists". The graph is `gm run`, which the launcher's own watcher owns -
        running the full pipeline here would be an expensive duplicate.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$TimeoutMs = 1800000
    )
    $pre = Start-McpBootstrapStep -Mcp 'graphenium' -ToolName 'gm' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpBootstrapAlreadyReason -Mcp 'graphenium' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'graphenium' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'graphenium' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
            -Arguments (Get-McpBootstrapArgv -Mcp 'graphenium' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'graphenium' -Detail 'gm init completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'graphenium' -Status 'done' `
            -Reason 'gm init wrote the .graphenium/ workspace config (graph is gm run, owned by the launcher watcher)' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpBootstrapRow -Mcp 'graphenium' -Status 'skipped' `
        -Reason (Get-McpBootstrapFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'gm init') `
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
    $pre = Start-McpBootstrapStep -Mcp 'repowise' -ToolName 'repowise' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpBootstrapAlreadyReason -Mcp 'repowise' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'repowise' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'repowise' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
            -Arguments (Get-McpBootstrapArgv -Mcp 'repowise' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'repowise' -Detail 'agents add completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'repowise' -Status 'done' `
            -Reason 'repowise agents add --target claude-code --scope project --yes' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpBootstrapRow -Mcp 'repowise' -Status 'skipped' `
        -Reason (Get-McpBootstrapFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'repowise agents add') `
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
        OPTIONAL (bead mcpw-01g, P3). `graphify-rs.toml` is missing in this repo
        and has never existed; without it there is nothing to build against, and
        inventing a config would be worse than skipping. So the step skips as
        optional when the config file is absent, and is marked Optional=$true in
        the summary so the launcher does not warn about it.

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
    $pre = Start-McpBootstrapStep -Mcp 'graphify-rs' -ToolName 'graphify-rs' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    if (-not (Test-Path -LiteralPath (Join-Path $pre.Root 'graphify-rs.toml') -PathType Leaf)) {
        return New-McpBootstrapRow -Mcp 'graphify-rs' -Status 'skipped' `
            -Reason 'optional: graphify-rs.toml missing (bead mcpw-01g, P3) - nothing to configure' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $d = Get-McpBootstrapAlreadyReason -Mcp 'graphify-rs' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'graphify-rs' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'graphify-rs' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    # --path . resolves against the child's cwd, so the cwd must be the root.
    $r = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
            -Arguments (Get-McpBootstrapArgv -Mcp 'graphify-rs' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'graphify-rs' -Detail 'build completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'graphify-rs' -Status 'done' `
            -Reason 'graphify-rs build --path . --update --no-llm' -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpBootstrapRow -Mcp 'graphify-rs' -Status 'skipped' `
        -Reason (Get-McpBootstrapFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'graphify-rs build') `
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
        `graft/manifest.json` can be missing ENTIRELY, and `graft/.graph/
        wiring.json` alone is not a graph - so the plain `graft build <dir>`
        ($0, no key) is what runs. --deep is NEVER passed: it needs an LLM key,
        and swapping in a key or a model is out of bounds for this harness.
    #>
    param(
        [string]$Path,
        [string]$StateDir,
        [string]$ToolPath,
        [switch]$Force,
        [int]$TimeoutMs = 1800000
    )
    $pre = Start-McpBootstrapStep -Mcp 'graft' -ToolName 'graft' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpBootstrapAlreadyReason -Mcp 'graft' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'graft' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'graft' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
            -Arguments (Get-McpBootstrapArgv -Mcp 'graft' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'graft' -Detail 'build completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'graft' -Status 'done' `
            -Reason 'graft build (wiring graph + per-file cards; $0 no-key tier, no --deep)' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpBootstrapRow -Mcp 'graft' -Status 'skipped' `
        -Reason (Get-McpBootstrapFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'graft build') `
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
            the daemon and always passes --workspace <manifest>; bootstrap does
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
    $pre = Start-McpBootstrapStep -Mcp 'memtrace' -ToolName 'memtrace' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpBootstrapAlreadyReason -Mcp 'memtrace' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'memtrace' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'memtrace' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    $r = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
            -Arguments (Get-McpBootstrapArgv -Mcp 'memtrace' -Path $pre.Root) `
            -WorkingDirectory $pre.Root -TimeoutMs $TimeoutMs
    if ($r.Launched -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'memtrace' -Detail 'index completed' -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'memtrace' -Status 'done' `
            -Reason 'memtrace index <path> --allow-non-git (no build verb; start/mcp deliberately not run)' `
            -Tool $pre.Tool -Stamp $pre.StateDir
    }
    return New-McpBootstrapRow -Mcp 'memtrace' -Status 'skipped' `
        -Reason (Get-McpBootstrapFailureReason -Result $r -TimeoutMs $TimeoutMs -Label 'memtrace index') `
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
             otherwise it is stopped at the timeout and `grepai status --no-ui`
             is asked once whether Files indexed is now > 0.

        A correct config with Files indexed: 0 is NOT initialized (measured), so
        the status file count - not the config, not the liveness clock - decides.

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
        [int]$FirstScanTimeoutMs = 900000
    )
    $pre = Start-McpBootstrapStep -Mcp 'grepai' -ToolName 'grepai' -Path $Path `
               -StateDir $StateDir -ToolPath $ToolPath -Force:$Force
    if ($pre.Skip) { return $pre.Skip }

    $d = Get-McpBootstrapAlreadyReason -Mcp 'grepai' -Root $pre.Root
    if ($d.Ok) {
        $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'grepai' -Detail $d.Reason -Tool $pre.Tool -StateDir $pre.StateDir
        return New-McpBootstrapRow -Mcp 'grepai' -Status 'stamped' `
            -Reason "already initialized: $($d.Reason)" -Tool $pre.Tool -Stamp $pre.StateDir
    }

    # --- 1. config, only when absent -----------------------------------------
    $configNote = 'config already present (left untouched)'
    $cfg = Join-Path $pre.Root '.grepai\config.yaml'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) {
        $r1 = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
                -Arguments (Get-McpBootstrapArgv -Mcp 'grepai' -Step 'config') `
                -WorkingDirectory $pre.Root -TimeoutMs $ConfigTimeoutMs
        if (-not ($r1.Launched -and -not $r1.TimedOut -and $r1.ExitCode -eq 0)) {
            return New-McpBootstrapRow -Mcp 'grepai' -Status 'skipped' `
                -Reason (Get-McpBootstrapFailureReason -Result $r1 -TimeoutMs $ConfigTimeoutMs -Label 'grepai init --yes') `
                -Tool $pre.Tool -Stamp $pre.StateDir
        }
        $configNote = 'config created by grepai init --yes'
    }

    # --- 2. first scan -------------------------------------------------------
    $scanNote = ''
    $r2 = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
            -Arguments (Get-McpBootstrapArgv -Mcp 'grepai' -Step 'scan') `
            -WorkingDirectory $pre.Root -TimeoutMs $FirstScanTimeoutMs
    if ($r2.Launched -and -not $r2.TimedOut -and $r2.ExitCode -eq 0) {
        $scanNote = 'grepai watch finished the initial scan'
    } else {
        # The watch was stopped at the timeout (or died). Ask the index itself.
        $r3 = Invoke-McpBootstrapCommand -FilePath $pre.Tool `
                -Arguments (Get-McpBootstrapArgv -Mcp 'grepai' -Step 'status') `
                -WorkingDirectory $pre.Root -TimeoutMs 30000
        $indexed = 0
        $text = ''
        if ($r3.Launched) { $text = [string]$r3.Output + [string]$r3.Error }
        $m = [regex]::Match($text, 'Files indexed\s*:\s*(\d+)')
        if ($m.Success) { $indexed = [int]$m.Groups[1].Value }
        if ($indexed -gt 0) {
            $scanNote = "first scan complete (Files indexed: $indexed)"
        } else {
            $why = Get-McpBootstrapFailureReason -Result $r2 -TimeoutMs $FirstScanTimeoutMs -Label 'grepai watch'
            return New-McpBootstrapRow -Mcp 'grepai' -Status 'skipped' `
                -Reason "$configNote; $why; Files indexed: $indexed" `
                -Tool $pre.Tool -Stamp $pre.StateDir
        }
    }

    $null = Set-McpBootstrapStamp -Path $pre.Root -Mcp 'grepai' -Detail "$configNote; $scanNote" -Tool $pre.Tool -StateDir $pre.StateDir
    return New-McpBootstrapRow -Mcp 'grepai' -Status 'done' `
        -Reason "$configNote; $scanNote" -Tool $pre.Tool -Stamp $pre.StateDir
}

# ---------------------------------------------------------------------------
# aggregate
# ---------------------------------------------------------------------------
function Invoke-McpBootstrapForRepo {
    <#
    .SYNOPSIS
        Bootstrap all six watched MCPs for one repository.
    .DESCRIPTION
        Runs Get-McpBootstrapPlan in order and returns a summary object. NEVER
        throws: every step is isolated, and a step that throws is recorded as a
        'skipped' row. That is the whole point - a bootstrap problem in a foreign
        repository must never abort the launcher.
    .PARAMETER Path
        The repository root. Everything is derived from it.
    .PARAMETER StateDir
        Where the idempotence stamp lives. Defaults to <Path>/.mcpw-bootstrap.
    .PARAMETER ToolPaths
        Per-MCP binary overrides, keyed by MCP name (e.g.
        @{ repowise = 'C:\...\repowise.exe' }). Used by the tests to inject
        fakes, and by a caller that has a tool installed off PATH.
    .PARAMETER Only
        Restrict the run to these MCP names. Omitted = all six.
    .PARAMETER Force
        Ignore the stamp and re-run every step.
    #>
    param(
        [string]    $Path,
        [string]    $StateDir,
        [hashtable] $ToolPaths,
        [string[]]  $Only,
        [switch]    $Force,
        [int]       $TimeoutMs = 1800000,
        [int]       $FirstScanTimeoutMs = 900000
    )
    $root    = Get-McpBootstrapRoot -Path $Path
    $dir     = Get-McpBootstrapStateDir -Path $root -StateDir $StateDir
    $started = Get-Date
    $rows    = New-Object System.Collections.Generic.List[object]

    foreach ($step in @(Get-McpBootstrapPlan)) {
        if ($Only -and ($Only -notcontains $step.Mcp)) { continue }
        $tp = ''
        if ($ToolPaths -and $ToolPaths.ContainsKey($step.Mcp)) { $tp = [string]$ToolPaths[$step.Mcp] }

        $row = $null
        try {
            switch ($step.Mcp) {
                'graphenium'  { $row = Initialize-GrapheniumForRepo  -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                'repowise'    { $row = Initialize-RepowiseForRepo    -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                'graphify-rs' { $row = Initialize-GraphifyRsForRepo  -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                'graft'       { $row = Initialize-GraftForRepo       -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                'memtrace'    { $row = Initialize-MemtraceForRepo    -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -TimeoutMs $TimeoutMs }
                'grepai'      { $row = Initialize-GrepaiForRepo      -Path $root -StateDir $dir -ToolPath $tp -Force:$Force -FirstScanTimeoutMs $FirstScanTimeoutMs }
            }
        } catch {
            $row = New-McpBootstrapRow -Mcp $step.Mcp -Status 'skipped' `
                -Reason ("initializer threw: " + $_.Exception.Message) -Tool '' -Stamp $dir
        }
        if (-not $row) {
            $row = New-McpBootstrapRow -Mcp $step.Mcp -Status 'skipped' `
                -Reason 'initializer returned no result' -Tool '' -Stamp $dir
        }
        $row | Add-Member -NotePropertyName Optional -NotePropertyValue ([bool]$step.Optional) -Force
        $row | Add-Member -NotePropertyName Phase    -NotePropertyValue ([string]$step.Phase) -Force
        [void]$rows.Add($row)
    }

    $done    = @($rows | Where-Object { $_.Status -eq 'done' }).Count
    $stamped = @($rows | Where-Object { $_.Status -eq 'stamped' }).Count
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
        Skipped  = $skipped
        Results  = $results
    }
}
