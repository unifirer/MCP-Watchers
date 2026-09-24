# tests/launcher_gm_semantic_pane.tests.ps1
# Pester 3.4.0 idiom (same as launcher_gm_semantic_toggle.tests.ps1): run via
#   python dev_tools/run_pester_suite.py tests/launcher_gm_semantic_pane.tests.ps1
#   (or: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_gm_semantic_pane.tests.ps1)

# Pin Pester 3.4.0 (this file uses the v3 positional `Should Match` idiom).
# Without this, a newer Pester (6.x) auto-loads and rejects the syntax.
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
#
# Locks the mcpw-b81.10 graphenium pane indicator. Before it, the live semantic
# toggle was SILENT: the only evidence that the running launcher picked up a
# flip was the "[gm-semantic] running FULL ... semantic mode ..." line, which is
# written INTO the pane the operator is watching, so it scrolls away. The pane
# must therefore SHOW the effective mode, read from the SAME per-repo switch the
# build obeys:
#   <repo>\.mcpw-provision\gm-semantic.mode   ("on" | "off"), absent = OFF.
# Because it reads the same file with the same vocabulary as Test-GmSemanticMode
# (the pane-local reader the stale-graph auto-fix already uses), the indicator
# can never disagree with what a rebuild will do.
#
# The suite materializes the REAL tailer through the production generator
# (New-WatcherPaneScript) and then RUNS it headless against a temp repo, so the
# behavioural case exercises production code, not a copy that can drift.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$paneModule = Join-Path $repo 'Modules\watcher_pane_scripts.ps1'
if (-not $env:VAD_WORKSPACE_ROOT) { $env:VAD_WORKSPACE_ROOT = "$repo" }

# AST-based extraction of the embedded generator (quote/comment-aware: the
# single-quoted here-string template inside it is full of literal { } braces).
function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { throw "pane module missing: $Path" }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "parse errors in $Path" }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

# Materialize a REAL tailer for $Label via the shipped generator, out-of-repo.
# The generator resolves $wtPaneDir from its CALLER's scope, so it is bound as a
# local here (same contract the existing pane suites rely on).
function New-TailerFor {
    param([string]$Label, [string]$RepoRoot)
    $dir = Join-Path $env:TEMP ('vad-gmsempane-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $fnTmp = Join-Path $dir 'ns.ps1'
    Set-Content -LiteralPath $fnTmp -Value (Extract-FunctionAst -Path $paneModule -Name 'New-WatcherPaneScript') -Encoding utf8
    $wtPaneDir = $dir
    . $fnTmp
    $tailer = New-WatcherPaneScript -Label $Label `
        -LogPath (Join-Path $dir "$Label.log") `
        -ErrPath (Join-Path $dir "$Label.log.err") `
        -RepoRoot $RepoRoot `
        -HeartbeatPath (Join-Path $dir "$Label.hb")
    return @{ Dir = $dir; Tailer = $tailer }
}

Describe 'graphenium pane semantic-mode indicator (mcpw-b81.10)' {

    It 'generates a graphenium tail whose status line reports the active mode' {
        $gen = New-TailerFor -Label 'graphenium' -RepoRoot 'J:\fake\repo'
        try {
            $body = Get-Content -LiteralPath $gen.Tailer -Raw
            # Label-gated, so only the graphenium pane carries it.
            $body | Should Match ([regex]::Escape("'graphenium' -eq 'graphenium'"))
            # Reads the SAME switch the build reads (Test-GmSemanticMode, inlined).
            $body | Should Match ([regex]::Escape('Test-GmSemanticMode -RepoRoot $repo'))
            # The displayed line itself, plus the change-guard that keeps the
            # update on the existing poll tick without flooding the pane.
            $body | Should Match ([regex]::Escape('| semantic: '))
            $body | Should Match ([regex]::Escape('$script:semModeShown'))
        } finally {
            Remove-Item -LiteralPath $gen.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not arm the indicator in a non-graphenium pane' {
        # The template is ONE shared body, so the status TEXT exists verbatim in
        # every generated tail (as dead code) - it is the GATE that must be
        # label-specific. Only the graphenium tail may carry the true-evaluating
        # gate, so no other pane can ever print the line. Same idiom as
        # launcher_graphenium_autofix.tests.ps1's "does not arm any trigger".
        $gen = New-TailerFor -Label 'repowise' -RepoRoot 'J:\fake\repo'
        try {
            $body = Get-Content -LiteralPath $gen.Tailer -Raw
            $body | Should Not Match ([regex]::Escape("'graphenium' -eq 'graphenium'"))
        } finally {
            Remove-Item -LiteralPath $gen.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'shows semantic: off, then flips to semantic: on within one poll tick' {
        # The acceptance case: default OFF, then ON after a flip with NO restart.
        # Drives the REAL generated tailer against a temp repo and flips the same
        # file the build daemon reads.
        $fx = Join-Path $env:TEMP ('vad-gmsempane-repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $fx '.mcpw-provision') -Force | Out-Null
        $modeFile = Join-Path $fx '.mcpw-provision\gm-semantic.mode'
        Set-Content -LiteralPath $modeFile -Value 'off' -Encoding ASCII
        $gen = New-TailerFor -Label 'graphenium' -RepoRoot $fx
        $cap = Join-Path $gen.Dir 'cap.txt'
        # Merge the tailer's information stream (Write-Host) into stdout via 6>&1
        # so Start-Process -RedirectStandardOutput captures it. The tailer loops
        # forever, so it is killed in finally.
        $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-Command', "& '$($gen.Tailer)' 6>&1") `
            -RedirectStandardOutput $cap
        try {
            $offSeen = $false
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
                $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
                if ($out -match [regex]::Escape('| semantic: off')) { $offSeen = $true; break }
            }
            $offSeen | Should Be $true
            # Flip the live switch. No restart, no launcher involvement: the pane
            # must pick this up on its own next poll tick.
            Set-Content -LiteralPath $modeFile -Value 'on' -Encoding ASCII
            $onSeen = $false
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
                $out = Get-Content -LiteralPath $cap -Raw -ErrorAction SilentlyContinue
                if ($out -match [regex]::Escape('| semantic: on')) { $onSeen = $true; break }
            }
            $onSeen | Should Be $true
        } finally {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 200
            Remove-Item -LiteralPath $gen.Dir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'scratch hygiene' {
    It 'removes every scratch tree this suite created' {
        Get-ChildItem -Path $env:TEMP -Filter 'vad-gmsempane-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        @(Get-ChildItem -Path $env:TEMP -Filter 'vad-gmsempane-*' -Directory -ErrorAction SilentlyContinue).Count | Should Be 0
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard with
# an env var so the rediscovery child skips the second Invoke-Pester. -Path keeps
# the run scoped to THIS file (no cross-file contamination).
if (-not $env:GM_SEM_PANE_TEST_RAN) {
    $env:GM_SEM_PANE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
