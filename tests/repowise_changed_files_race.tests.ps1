# tests/repowise_changed_files_race.tests.ps1
# RED-first tests for the three failure modes of the repowise / graphify-rs
# changed-file resolver:
#   FM1 - pane stalls / paths lag because every "N changed file(s)" event re-scans
#        the whole repo
#   FM2 - the SAME file is displayed with inconsistent path strings (".\" segment and
#        drive-letter case differ between the Get-ChildItem baseline and the watcher
#        path)
#   FM3 - the same physical change reported multiple times across a cascade yields
#        duplicate / inconsistent output
#
# These must be RED against the current repo-scan resolver (no Add-RecentChange,
# Resolve-ChangedFiles ignores $global:recentChanges) and GREEN after the
# FileSystemWatcher + recentChanges rewrite.

$repo = Split-Path (Resolve-Path $PSScriptRoot)
$paneModule = Join-Path (Split-Path $PSScriptRoot) 'Modules\watcher_pane_scripts.ps1'
if (-not $env:VAD_WORKSPACE_ROOT) { $env:VAD_WORKSPACE_ROOT = "$repo" }
# Pin any installed Pester 3.x explicitly BEFORE anything else: some hosts leak
# pwsh7 module dirs onto PSModulePath, and 5.1 auto-load then picks Pester 6.x,
# whose Should does not bind the legacy positional form used here.
$pesterLegacy = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -lt 4 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pesterLegacy) { Import-Module $pesterLegacy.Path -DisableNameChecking }

function Get-FunctionDefinitionByName {
    param([string]$Name, [System.Management.Automation.Language.Token[]]$Tokens, [System.Management.Automation.Language.Ast[]]$Asts)
    $func = $Asts.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { return $null }
    return $func
}

function Dot-SourceFunction {
    param($Ast)
    # $Ast.Extent.Text is the full "function Name { ... }" (WITH its braces).
    # Qualify the name with script: so it lands in the root script scope and is
    # visible to the calling It block. Do NOT use $Ast.Body.ToString() -- a
    # ScriptBlockAst's .ToString() already wraps the body in { }, which would
    # produce a double-brace function whose real code never executes.
    $func = $Ast.Extent.Text -replace "^function\s+$($Ast.Name)\b", "function script:$($Ast.Name)"
    $tmp = Join-Path $env:TEMP ('rp_race_fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $tmp -Value $func -Encoding UTF8
    . $tmp
}

function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

function New-TailerScript {
    param([string]$Label)
    # Extract the REAL New-WatcherPaneScript from the pane module and call it to
    # generate the real tailer file (mirrors the e2e runner path). This avoids
    # the brittle in-body $template statement extraction.
    $nsTmp = Join-Path $env:TEMP ('rp_race_ns_' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $nsTmp -Value (Extract-FunctionAst $paneModule 'New-WatcherPaneScript') -Encoding UTF8
    . $nsTmp
    # New-WatcherPaneScript writes the tailer under module-scoped $wtPaneDir;
    # point it at a temp dir so the generated file does not pollute the repo.
    $script:wtPaneDir = Join-Path $env:TEMP ('rp_race_panes_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:wtPaneDir -Force | Out-Null
    $tailer = New-WatcherPaneScript -Label $Label -LogPath (Join-Path $env:TEMP ('rp_race_' + [guid]::NewGuid().ToString('N') + '.log')) -ErrPath '' -RepoRoot $repo
    if (-not (Test-Path -LiteralPath $tailer)) { throw "tailer not generated: $tailer" }
    return $tailer
}

Describe 'repowise changed-file resolver: 3 failure modes' {
    BeforeEach {
        $global:recentChanges = @{}
    }

    It 'FM1 resolves from recentChanges without a full-repo re-scan (no pane stall)' {
        $tailer = New-TailerScript -Label 'repowise'
        $tokens = $null; $errors = $null
        $asts = [System.Management.Automation.Language.Parser]::ParseFile($tailer, [ref]$tokens, [ref]$errors)
        $changedDef = Get-FunctionDefinitionByName -Name 'Resolve-ChangedFiles' -Tokens $tokens -Asts $asts
        $addDef = Get-FunctionDefinitionByName -Name 'Add-RecentChange' -Tokens $tokens -Asts $asts
        if (-not $addDef) { throw 'Add-RecentChange not found in generated tailer (FSW feed not implemented yet)' }
        Dot-SourceFunction $changedDef
        Dot-SourceFunction $addDef

        $oldRepo = $repo
        $repo = ''
        try {
            Add-RecentChange 'J:\audio\VAD\real_src.py'
            $elapsed = Measure-Command { $files = Resolve-ChangedFiles -MaxFiles 1 }
            $files.Count | Should BeExactly 1
            $files[0] | Should Match 'real_src\.py'
            # A full-repo scan on this repo takes seconds; resolving from the in-memory
            # feed must be sub-second.
            $elapsed.TotalMilliseconds | Should BeLessThan 2000
        } finally {
            $repo = $oldRepo
        }
    }

    It 'FM2 normalizes ".\" and drive-case to a single canonical path (the reported bug)' {
        $tailer = New-TailerScript -Label 'repowise'
        $tokens = $null; $errors = $null
        $asts = [System.Management.Automation.Language.Parser]::ParseFile($tailer, [ref]$tokens, [ref]$errors)
        $changedDef = Get-FunctionDefinitionByName -Name 'Resolve-ChangedFiles' -Tokens $tokens -Asts $asts
        $addDef = Get-FunctionDefinitionByName -Name 'Add-RecentChange' -Tokens $tokens -Asts $asts
        if (-not $addDef) { throw 'Add-RecentChange not found in generated tailer (FSW feed not implemented yet)' }
        Dot-SourceFunction $changedDef
        Dot-SourceFunction $addDef

        $expected = Join-Path $repo 'real_src.py'
        # Same physical file, three path spellings the watcher / baseline can produce:
        Add-RecentChange (Join-Path $repo 'real_src.py')
        Add-RecentChange (Join-Path $repo '.\real_src.py')
        Add-RecentChange ('j:' + (Split-Path $repo -NoQualifier) + '\real_src.py')

        # Ingest dedupes to exactly one canonical entry:
        $global:recentChanges.Count | Should BeExactly 1
        $files = Resolve-ChangedFiles -MaxFiles 1
        $files.Count | Should BeExactly 1
        # The displayed path is the single canonical form - no ".\", uniform drive case:
        $files[0] | Should BeExactly $expected
        $files[0] | Should Not Match '\\\.'
    }

    It 'FM3 same file changed multiple times resolves to one entry (no duplicate across cascade)' {
        $tailer = New-TailerScript -Label 'repowise'
        $tokens = $null; $errors = $null
        $asts = [System.Management.Automation.Language.Parser]::ParseFile($tailer, [ref]$tokens, [ref]$errors)
        $changedDef = Get-FunctionDefinitionByName -Name 'Resolve-ChangedFiles' -Tokens $tokens -Asts $asts
        $addDef = Get-FunctionDefinitionByName -Name 'Add-RecentChange' -Tokens $tokens -Asts $asts
        if (-not $addDef) { throw 'Add-RecentChange not found in generated tailer (FSW feed not implemented yet)' }
        Dot-SourceFunction $changedDef
        Dot-SourceFunction $addDef

        Add-RecentChange (Join-Path $repo 'a.py')
        Add-RecentChange (Join-Path $repo 'a.py')   # changed again in the cascade
        Add-RecentChange (Join-Path $repo 'b.py')

        $global:recentChanges.Count | Should BeExactly 2
        $files = Resolve-ChangedFiles -MaxFiles 50
        $files.Count | Should BeExactly 2
        ($files | Sort-Object -Unique).Count | Should BeExactly 2
    }
}

if (-not $env:RP_RACE_TEST_RAN) {
    $env:RP_RACE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
