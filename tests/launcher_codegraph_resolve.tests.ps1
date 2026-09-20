# tests/launcher_codegraph_resolve.tests.ps1
# Pester 3.4.0 (pinned). Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_codegraph_resolve.tests.ps1
#
# Resolve-CodegraphLaunch must survive BOTH shim shapes that exist on this box:
#   (a) npm bin shim = the REAL CLI (`npm install -g @optave/codegraph`, 3.17.0)
#       -> re-expressed as `node.exe <cli.js> <args>`, NO adapter name
#   (b) declick's MCP adapter launcher (35 MCP tool verbs, no build/watch)
#       -> re-expressed as `node.exe <run.mjs> codegraph <args>`
# and must refuse a stale shim whose entrypoint no longer exists.
#
# Regression guard for the 2026-09-19 codegraph outage: the adapter shim had taken
# the name of the CLI it wraps, so `codegraph build` answered
# `unknown verb build; ... did you mean brief?` (exit 2). `watch` is also an
# upstream verb, so shape (a) is the only shape the watcher can actually launch.
Import-Module Pester -RequiredVersion 3.4.0 -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher = Join-Path $repoRoot '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

# Lift ONE function out of the monolithic launcher without executing the launcher
# (dot-sourcing the file would run every watcher). The closing brace of a
# top-level function sits at column 0, so the first "`n}" after the signature is
# the end of the function.
function Get-LauncherFunctionSource {
    param([Parameter(Mandatory = $true)][string]$Name)
    $src = Get-Content -LiteralPath $launcher -Raw
    $start = $src.IndexOf("function $Name {")
    if ($start -lt 0) { throw "function $Name not found in launcher" }
    $rest = $src.Substring($start)
    $end = $rest.IndexOf("`n}")
    if ($end -lt 0) { throw "closing brace for $Name not found" }
    return $rest.Substring(0, $end + 2)
}

. ([scriptblock]::Create((Get-LauncherFunctionSource -Name 'Resolve-CodegraphLaunch')))

# Fixture root: two fake shim dirs plus the stub entrypoints they point at.
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('cg-resolve-' + [guid]::NewGuid().ToString('N'))
$npmDir = Join-Path $scratch 'npm'
$decDir = Join-Path $scratch 'declick\bin'
$null = New-Item -ItemType Directory -Path $npmDir -Force
$null = New-Item -ItemType Directory -Path $decDir -Force

# Shape (a): npm's real bin shim, byte-shape copied from J:\Programs\npm-global\codegraph.cmd.
$npmJs = Join-Path $npmDir 'node_modules\@optave\codegraph\dist\cli.js'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $npmJs) -Force
Set-Content -LiteralPath $npmJs -Value '// stub entrypoint' -Encoding ASCII
@"
@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0
IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
)
endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@optave\codegraph\dist\cli.js" %*
"@ | Set-Content -LiteralPath (Join-Path $npmDir 'codegraph.cmd') -Encoding ASCII

# Shape (b): declick's adapter launcher, byte-shape copied from ~\.declick\bin\codegraph.cmd.
$decJs = Join-Path $scratch 'declick\bin\run.mjs'
Set-Content -LiteralPath $decJs -Value '// stub declick entrypoint' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $decDir 'codegraph.cmd') -Encoding ASCII -Value (
    "@echo off`nrem declick launcher`nnode `"$decJs`" codegraph %*")

function Invoke-ResolveWithPath {
    param([Parameter(Mandatory = $true)][string]$PrependDir)
    $old = $env:PATH
    try {
        $env:PATH = "$PrependDir;$old"
        return Resolve-CodegraphLaunch
    } finally { $env:PATH = $old }
}

Describe 'Resolve-CodegraphLaunch shim handling' {
    It 'resolves the npm bin shim to node.exe <cli.js> with NO adapter-name prefix' {
        $r = Invoke-ResolveWithPath -PrependDir $npmDir
        $r | Should Not BeNullOrEmpty
        $r.Exe | Should Match 'node\.exe$'
        # Exactly one prefix element: the entrypoint. An adapter name here would be
        # passed to the real CLI as a bogus first argument.
        $r.Prefix.Count | Should Be 1
        $r.Prefix[0] | Should Be $npmJs
        # %dp0% must have been expanded, not passed through literally.
        $r.Prefix[0] | Should Not Match '%dp0%'
    }

    It 'resolves the declick shim to node.exe <run.mjs> codegraph (adapter name kept)' {
        $r = Invoke-ResolveWithPath -PrependDir $decDir
        $r | Should Not BeNullOrEmpty
        $r.Exe | Should Match 'node\.exe$'
        $r.Prefix.Count | Should Be 2
        $r.Prefix[0] | Should Be $decJs
        $r.Prefix[1] | Should Be 'codegraph'
    }

    It 'prefers the npm shim when both shapes are on PATH (npm ahead of declick)' {
        $old = $env:PATH
        try {
            $env:PATH = "$npmDir;$decDir;$old"
            $r = Resolve-CodegraphLaunch
            $r.Prefix.Count | Should Be 1
            $r.Prefix[0] | Should Be $npmJs
        } finally { $env:PATH = $old }
    }

    It 'refuses a stale shim whose entrypoint no longer exists' {
        $staleDir = Join-Path $scratch 'stale'
        $null = New-Item -ItemType Directory -Path $staleDir -Force
        Set-Content -LiteralPath (Join-Path $staleDir 'codegraph.cmd') -Encoding ASCII -Value (
            "@echo off`nnode `"$scratch\gone\dist\cli.js`" %*")
        # A dead entrypoint would register a dead PID in teardown-state.json and
        # print a false "launched" line, so the resolver must return $null and let
        # the caller warn instead.
        Invoke-ResolveWithPath -PrependDir $staleDir | Should BeNullOrEmpty
    }

    It 'the watcher command line it produces is sweep-matched but the MCP backend is not' {
        . (Join-Path $repoRoot 'Modules\watcher_patterns.ps1')
        $r = Invoke-ResolveWithPath -PrependDir $npmDir
        $watcherCmd = "$($r.Exe) $(($r.Prefix + @('watch', $repoRoot)) -join ' ')"
        Test-WatcherSweepMatch -CommandLine $watcherCmd -Pattern 'codegraph\dist\cli.js watch' | Should Be $true
        # The MCP backend runs the same cli.js with `mcp --multi-repo`.
        $backend = '"node"   "J:\Programs\npm-global\_npx\3739334a42fe877a\node_modules\.bin\..\@optave\codegraph\dist\cli.js" mcp --multi-repo'
        Test-WatcherSweepMatch -CommandLine $backend -Pattern 'codegraph\dist\cli.js watch' | Should Be $false
    }
}

Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue

if (-not $env:CG_RESOLVE_TEST_RAN) {
    $env:CG_RESOLVE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
