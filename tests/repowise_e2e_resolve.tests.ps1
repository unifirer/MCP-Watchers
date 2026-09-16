# tests/repowise_e2e_resolve.tests.ps1
# Pester 3.4.0 idiom. Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests/repowise_e2e_resolve.tests.ps1"
# EXECUTION test: generates the REAL repowise tailer via the shipped
# New-WatcherPaneScript, then runs the tailer's real changed-files resolution
# logic end-to-end against a prepopulated repowise.log (containing a
# "N changed file(s)" line plus a non-matching "Watching ..." line)
# and a real source file in the repo root. Asserts the real tailer prints
# "-> changed file: <resolved path>" for the change line, and does NOT print it
# for the non-matching line (no false positive) nor for gm/grepai inline-path
# lines (no mis-fire).
#
# We do NOT run the whole generated tailer (it contains `while ($true)` and WT
# pane launch). Instead a tiny e2e_runner.ps1 (written to a Windows-visible temp
# path, NOT /tmp) dot-sources the REAL functions extracted from the generated
# tailer and re-implements ONLY the seed-loop iteration, capturing stdout via a
# temp out file. This exercises the real shipped resolver code path.
$paneModule = Join-Path $PSScriptRoot '..\Modules\watcher_pane_scripts.ps1'
if (-not $env:VAD_WORKSPACE_ROOT) { $env:VAD_WORKSPACE_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
# Pin any installed Pester 3.x explicitly BEFORE anything else: some hosts leak
# pwsh7 module dirs onto PSModulePath, and 5.1 auto-load then picks Pester 6.x,
# whose Should does not bind the legacy positional form used here.
$pesterLegacy = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -lt 4 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pesterLegacy) { Import-Module $pesterLegacy.Path -DisableNameChecking }
$ErrorActionPreference = 'SilentlyContinue'

function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { throw "file missing: $Path" }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "parse errors in $Path" }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

# The real resolution harness, written to a Windows-visible temp path at runtime
# and executed via powershell.exe. It dot-sources the REAL functions extracted
# from the generated tailer and replays the tailer's seed-loop body.
$runnerSrc = @'
param([string]$TailerPath, [string]$RepoRoot, [string]$LogPath, [string]$ChangedPath)
$ErrorActionPreference = 'SilentlyContinue'

function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    return $func.Extent.Text
}

# Extract the REAL functions from the generated tailer and dot-source them so
# Show-ChangedFiles / Resolve-ChangedFiles / CleanLogLine are in scope.
$fnFile = Join-Path $env:TEMP ("rp_e2e_fn_" + [guid]::NewGuid().ToString("N") + ".ps1")
Set-Content -LiteralPath $fnFile -Value (
    (Extract-FunctionAst $TailerPath "ScrubNulBytes") + "`n" +
    (Extract-FunctionAst $TailerPath "CleanLogLine") + "`n" +
    (Extract-FunctionAst $TailerPath "Read-WatcherLogTail") + "`n" +
    (Extract-FunctionAst $TailerPath "Resolve-ChangedFiles") + "`n" +
    (Extract-FunctionAst $TailerPath "Add-RecentChange") + "`n" +
    (Extract-FunctionAst $TailerPath "Show-ChangedFiles")
) -Encoding UTF8
. $fnFile

# Resolver scope state (mirrors the tailer's launch-time setup). repowise counts
# changes against its OWN content index and self-commits, so `git status` is
# misaligned with what it reports; the path is resolved from the in-memory
# recentChanges set (Resolve-ChangedFiles) fed by the FileSystemWatcher. The
# changed file is edited and then registered via Add-RecentChange, so its
# canonicalized path is surfaced by the resolver.
$log = $LogPath
$backlogLines = 30
$repo = $RepoRoot
& git -C $repo init -q 2>$null
& git -C $repo config user.email 'test@local' 2>$null
& git -C $repo config user.name 'test' 2>$null
& git -C $repo add real_src.py 2>$null
& git -C $repo commit -q -m 'init' 2>$null
# Mirror the launcher's resolver scope: the FSW action (and therefore
# Add-RecentChange) writes to $global:recentChanges, NOT $script:, because the
# FileSystemWatcher event pump runs on a SEPARATE runspace whose $script: scope is
# disjoint from the foreground poll loop. The seed loop here runs in the main
# runspace, so it must seed $global: to match what the real pane does.
$global:recentChanges = @{}
if ($ChangedPath -and (Test-Path -LiteralPath $ChangedPath)) {
    Set-Content -Path $ChangedPath -Value 'def a(): return 1'
    Add-RecentChange $ChangedPath
}

# Extract the REAL seed-loop body verbatim from the generated tailer (the
# `if (Test-Path -LiteralPath $log) { ... }` block) via brace-balanced scan and
# run it. This exercises the ACTUAL shipped wiring inside the generated tailer
# (CleanLogLine + the unconditional `Show-ChangedFiles -Label '__LABEL__'`
# call), so reverting the repowise call site back to graphify-rs-only makes the
# test go RED. __LABEL__ is already substituted to "repowise" in $tailer.
function Extract-SeedLoop {
    param([string]$Path)
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $start = -1
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match 'if \(Test-Path -LiteralPath \$log\) \{') { $start = $k; break }
    }
    if ($start -lt 0) { throw "seed loop not found in generated tailer" }
    $depth = 0
    $end = -1
    for ($k = $start; $k -lt $lines.Count; $k++) {
        $line = $lines[$k]
        # crude brace accounting (no strings/braces in these lines)
        foreach ($c in $line.ToCharArray()) {
            if ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth-- }
        }
        if ($depth -eq 0) { $end = $k; break }
    }
    if ($end -lt 0) { throw "seed loop end not found" }
    return ($lines[$start..$end] -join "`n")
}
$seedBlock = Extract-SeedLoop $TailerPath

# Run the REAL seed-loop body; Write-Host (info stream 6) is merged into the
# output via 6>&1 so the real "[repowise]   -> changed file:" line is captured.
$seed = & { Invoke-Expression $seedBlock } 6>&1
$seed | ForEach-Object { Write-Output $_ }

# Inline-path lines for OTHER labels must be no-ops (they would mis-fire the
# resolver). The real functions return immediately for non-graphify-rs/repowise
# labels, so no "-> changed file:" is emitted.
Write-Output "=== NOOP graphenium ==="
& { Show-ChangedFiles -Label "graphenium" "[graphenium] changed (code): J:\x\real_src.py" } 6>&1 | ForEach-Object { Write-Output $_ }
Write-Output "=== NOOP grepai ==="
& { Show-ChangedFiles -Label "grepai" "Indexed real_src.py (0 chunks)" } 6>&1 | ForEach-Object { Write-Output $_ }
Write-Output "=== END ==="
'@

Describe 'repowise tailer end-to-end changed-files resolution' {
    It 'runs the real generated tailer to resolve the changed file, no false positives' {
        $root = Join-Path $env:TEMP ('rp_e2e_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            # Repo root is a SUBDIR so the log file (written outside it) is never
            # itself reported as a changed file by the resolver's repo scan.
            $repoRoot = Join-Path $root 'repo'
            New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
            # the real source edit we expect to be reported
            Set-Content -Path (Join-Path $repoRoot 'real_src.py') -Value 'def a(): pass'
            (Get-ChildItem (Join-Path $repoRoot 'real_src.py')).LastWriteTime = (Get-Date)
            # distractor under an excluded dir (must NEVER be reported)
            New-Item -ItemType Directory -Path (Join-Path $repoRoot 'temp') -Force | Out-Null
            Set-Content -Path (Join-Path $repoRoot 'temp\distractor.txt') -Value 'x'

            # Generate the REAL repowise tailer via the shipped New-WatcherPaneScript.
            $wtPaneDir = Join-Path $root 'panes'
            New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
            $nsTmp = Join-Path $root ('ns_' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $nsTmp -Value (Extract-FunctionAst $paneModule 'New-WatcherPaneScript') -Encoding UTF8
            . $nsTmp
            $logPath = Join-Path $root 'repowise.log'
            $tailer = New-WatcherPaneScript -Label 'repowise' -LogPath $logPath -ErrPath '' -RepoRoot $repoRoot
            if (-not (Test-Path -LiteralPath $tailer)) { throw "tailer not generated: $tailer" }

            # Real repowise log shape: a Watching banner + a change COUNT only.
            # repowise NEVER emits an inline path list, and it counts against its
            # OWN content index and self-commits -- so `git status` is misaligned
            # and must NOT be the resolver. Instead the path is resolved from the
            # in-memory recentChanges set (Resolve-ChangedFiles) fed by the
            # FileSystemWatcher: the user's real edit is registered as the most
            # recent change via Add-RecentChange. The current repowise wording is
            # "<workspace>: N changed file(s), updating..." (e.g. "vad: 1 changed
            # file(s)") -- the form the live pane regressed against. The resolver
            # anchors on "<N> changed file(s)".
            Set-Content -LiteralPath $logPath -Value 'Watching J:\repo... Ctrl+C to stop' -Encoding UTF8
            Add-Content -LiteralPath $logPath -Value 'vad: 1 changed file(s), updating...' -Encoding UTF8
            Add-Content -LiteralPath $logPath -Value 'Already up to date.' -Encoding UTF8

            # Write the e2e runner to a Windows-visible temp path and execute it.
            $runnerPath = Join-Path $root 'e2e_runner.ps1'
            Set-Content -LiteralPath $runnerPath -Value $runnerSrc -Encoding UTF8
            $outFile = Join-Path $root 'out.txt'
            $changedArg = Join-Path $repoRoot 'real_src.py'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$runnerPath' '$tailer' '$repoRoot' '$logPath' '$changedArg' 6>&1" | Set-Content -LiteralPath $outFile -Encoding UTF8
            $out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue

            # Real resolution happened: the changed file is printed with its path.
            $out | Should Match 'changed file:'
            $out | Should Match 'real_src\.py'
            # No false positive from the non-matching "Watching" line.
            $out | Should Not Match 'distractor\.txt'
            # Exactly one "-> changed file:" line: the repowise resolution, and
            # the gm/grepai inline-path lines must NOT have mis-fired the resolver.
            ([regex]::Matches($out, 'changed file:').Count) | Should Be 1
        }
        finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

if (-not $env:RP_E2E_TEST_RAN) {
    $env:RP_E2E_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
