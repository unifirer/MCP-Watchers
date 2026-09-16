# tests/repowise_changed_files.tests.ps1
# Pester 3.4.0 idiom. Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/repowise_changed_files.tests.ps1
# Exercises the REAL generated tailer: New-WatcherPaneScript (top-level in
# Modules/watcher_pane_scripts.ps1 after the vad-uzb split) is AST-extracted and
# dot-sourced, then called to GENERATE a tailer file. Show-ChangedFiles /
# Resolve-ChangedFiles live INSIDE the template here-string, so they only exist
# as real functions inside the generated file. We AST-extract them from the
# generated file and dot-source them, then assert the changed-file resolution
# behavior. This tracks the shipped code (no copy).
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

Describe 'repowise changed-files resolution (ported from graphify-rs)' {
    BeforeEach {
        $script:scratch = Join-Path $env:TEMP ('rp_cf_test_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null
        # distractor under an excluded scratch dir (must NEVER be reported)
        New-Item -ItemType Directory -Path (Join-Path $script:scratch 'temp') -Force | Out-Null
        Set-Content -Path (Join-Path $script:scratch 'temp\distractor.txt') -Value 'x'
        # the real source edit we expect to be reported
        Set-Content -Path (Join-Path $script:scratch 'real_src.py') -Value 'def a(): pass'
        (Get-ChildItem (Join-Path $script:scratch 'real_src.py')).LastWriteTime = (Get-Date)
        # The scratch is a REAL git repo. repowise counts changes against its own
        # content index and self-commits, so `git status` is misaligned with what
        # it reports -- therefore repowise paths are resolved via the SAME
        # in-memory recentChanges set (Resolve-ChangedFiles) as graphify-rs, which
        # surfaces the user's actual recent edit regardless of git.
        & git -C $script:scratch init -q 2>$null
        & git -C $script:scratch config user.email 'test@local' 2>$null
        & git -C $script:scratch config user.name 'test' 2>$null
        & git -C $script:scratch add real_src.py 2>$null
        & git -C $script:scratch commit -q -m 'init' 2>$null

        # Generate a REAL repowise tailer via the shipped New-WatcherPaneScript.
        $genDir = Join-Path $env:TEMP ('rp_gen_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $genDir -Force | Out-Null
        $wtPaneDir = Join-Path $genDir 'panes'
        New-Item -ItemType Directory -Path $wtPaneDir -Force | Out-Null
        # Extract New-WatcherPaneScript (Modules/watcher_pane_scripts.ps1) + dot-source.
        $nsTmp = Join-Path $genDir ('ns_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $nsTmp -Value (Extract-FunctionAst $paneModule 'New-WatcherPaneScript') -Encoding UTF8
        . $nsTmp
        $script:tailer = New-WatcherPaneScript -Label 'repowise' -LogPath (Join-Path $genDir 'rep.log') -ErrPath (Join-Path $genDir 'rep.log.err') -RepoRoot $script:scratch
        if (-not (Test-Path -LiteralPath $script:tailer)) { throw "tailer not generated: $script:tailer" }
        # Extract the REAL functions from the generated tailer.
        $fnTmp = Join-Path $genDir ('fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $fnTmp -Value ((Extract-FunctionAst $script:tailer 'Show-ChangedFiles') + "`n" + (Extract-FunctionAst $script:tailer 'Resolve-ChangedFiles') + "`n" + (Extract-FunctionAst $script:tailer 'Add-RecentChange') + "`n" + (Extract-FunctionAst $script:tailer 'Read-WatcherLogTail')) -Encoding UTF8
        . $fnTmp
        # Resolver scope state. The launcher's Add-RecentChange / Resolve-ChangedFiles
        # use $global:recentChanges (NOT $script:) because the FileSystemWatcher event
        # pump runs on a SEPARATE runspace whose $script: scope is disjoint from the
        # foreground poll loop. In these tests we call Add-RecentChange directly to
        # simulate the watcher seeing a write; $global: is shared with the dot-sourced
        # resolver, so the set stays small and faithful to real usage.
        $global:recentChanges = @{}
        $repo = $script:scratch
    }
    AfterEach {
        if ($script:scratch) { Remove-Item -LiteralPath $script:scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'repowise "<workspace>: N changed file(s)" line resolves and prints the changed source file (current format)' {
        # repowise prints ONLY a count; the real source edit surfaces via the in-memory
        # recentChanges set (Resolve-ChangedFiles) -- the same resolver graphify-rs uses.
        # repowise is git-unaware here: it counts against its own content index and
        # self-commits, so `git status` is misaligned and must not be the resolver.
        # Current repowise (after the format drift) emits
        # "<workspace>: N changed file(s), updating..." (e.g. "vad: 2 changed
        # file(s)"). This is the exact shape the live pane was regressed against.
        Set-Content -Path (Join-Path $script:scratch 'real_src.py') -Value 'def a(): return 1'
        Add-RecentChange (Join-Path $script:scratch 'real_src.py')   # simulate the FSW seeing the write
        $captured = & { Show-ChangedFiles -Label 'repowise' -Line 'vad: 1 changed file(s), updating...' } 6>&1 | Out-String
        $captured | Should Match 'changed file:'
        $captured | Should Match 'real_src\.py'
    }
    It 'repowise legacy "Detected N changed file(s)" line still resolves (old-format guard)' {
        # repowise's wording has drifted across versions. The resolver must still
        # handle the older "Detected N changed file(s)" form so a future revert
        # to that wording does not regress silently.
        Set-Content -Path (Join-Path $script:scratch 'real_src.py') -Value 'def a(): return 1'
        Add-RecentChange (Join-Path $script:scratch 'real_src.py')   # simulate the FSW seeing the write
        $captured = & { Show-ChangedFiles -Label 'repowise' -Line 'Detected 1 changed file(s), updating...' } 6>&1 | Out-String
        $captured | Should Match 'changed file:'
        $captured | Should Match 'real_src\.py'
    }
    It 'repowise N=4 (boundary) still resolves and prints the changed source file' {
        # Mirrors the graphify-rs N<5 gate: the GATE is N >= 5, so N=4 is the
        # largest count that should still print individual paths.
        Set-Content -Path (Join-Path $script:scratch 'real_src.py') -Value 'def a(): return 1'
        Add-RecentChange (Join-Path $script:scratch 'real_src.py')   # simulate the FSW seeing the write
        $captured = & { Show-ChangedFiles -Label 'repowise' -Line 'vad: 4 changed file(s), updating...' } 6>&1 | Out-String
        $captured | Should Match 'changed file:'
        $captured | Should Match 'real_src\.py'
    }
    It 'repowise N>=5 prints NO paths (pane stays readable, mirrors graphify-rs gate)' {
        # Repowise's own count line already summarizes big bursts; listing every
        # path for N >= 5 would flood the pane. Assert NOTHING is printed for a
        # "N changed file(s)" line with N >= 5 (current AND legacy wording).
        Set-Content -Path (Join-Path $script:scratch 'real_src.py') -Value 'def a(): return 1'
        $cur = & { Show-ChangedFiles -Label 'repowise' -Line 'vad: 7 changed file(s), updating...' } 6>&1 | Out-String
        $cur | Should Not Match 'changed file:'
        $leg = & { Show-ChangedFiles -Label 'repowise' -Line 'Detected 12 changed file(s), updating...' } 6>&1 | Out-String
        $leg | Should Not Match 'changed file:'
    }
    It 'mtime resolver surfaces ALL recently-edited files (multi-file burst regression)' {
        # Root-cause regression for the "inconsistent / not showing all paths" bug:
        # the OLD mtime baseline diff pre-filtered with a 60s time floor, so after a
        # slow full-repo scan the user's real edit had aged past the floor and the
        # resolver returned nothing. The CURRENT resolver drops that floor and diffs
        # purely against the previous baseline, so a multi-file edit surfaces all of
        # its files (here we edit 3 files and expect all 3), not just the few
        # rewritten in the last poll window. The >50 stale-baseline guard still
        # suppresses background-tooling storms rather than flooding the pane.
        $f1 = Join-Path $script:scratch 'real_src.py'
        $f2 = Join-Path $script:scratch 'mod_a.py'
        $f3 = Join-Path $script:scratch 'mod_b.py'
        Set-Content -Path $f2 -Value 'x = 1'
        Set-Content -Path $f3 -Value 'y = 2'
        & git -C $script:scratch add $f2 $f3 2>$null
        & git -C $script:scratch commit -q -m 'add mods' 2>$null
        # Now edit all three files AFTER the launch-time baseline was captured.
        Set-Content -Path $f1 -Value 'def a(): return 1'
        Set-Content -Path $f2 -Value 'x = 10'
        Set-Content -Path $f3 -Value 'y = 20'
        Add-RecentChange $f1; Add-RecentChange $f2; Add-RecentChange $f3   # simulate the FSW seeing all three writes
        $files = Resolve-ChangedFiles -MaxFiles 3
        ($files | Where-Object { $_ -match 'real_src\.py' }) | Should Not BeNullOrEmpty
        ($files | Where-Object { $_ -match 'mod_a\.py' }) | Should Not BeNullOrEmpty
        ($files | Where-Object { $_ -match 'mod_b\.py' }) | Should Not BeNullOrEmpty
        $files.Count | Should BeGreaterThan 2
    }
    It 'Resolve-ChangedFiles returns an array (no single-element unroll to a char)' {
        # PowerShell 5.1 unrolls a 1-element array on `return`, turning the single
        # path into its first CHAR ("J") -- which would break $files[0] in
        # Show-ChangedFiles. The fix returns via Write-Output -NoEnumerate.
        (Get-ChildItem (Join-Path $script:scratch 'real_src.py')).LastWriteTime = (Get-Date).AddSeconds(5)
        Add-RecentChange (Join-Path $script:scratch 'real_src.py')   # simulate the FSW seeing the write
        $files = Resolve-ChangedFiles -MaxFiles 1
        $files -is [System.Collections.ArrayList] | Should Be $true
        $files[0] | Should Match 'real_src\.py'
        $files[0].Length | Should BeGreaterThan 1
    }
    It 'suppresses files under excluded dirs (temp/distractor)' {
        # A write under an excluded dir must NEVER be reported, even though it is
        # newer than the baseline.
        (Get-ChildItem (Join-Path $script:scratch 'temp\distractor.txt')).LastWriteTime = (Get-Date).AddSeconds(5)
        Add-RecentChange (Join-Path $script:scratch 'temp\distractor.txt')   # excluded at ingest: must NOT enter the set
        $files = Resolve-ChangedFiles -MaxFiles 20
        ($files | Where-Object { $_ -match 'distractor' }) | Should BeNullOrEmpty
    }
    It 'reports only the real edit, not the excluded distractor' {
        (Get-ChildItem (Join-Path $script:scratch 'real_src.py')).LastWriteTime = (Get-Date).AddSeconds(5)
        (Get-ChildItem (Join-Path $script:scratch 'temp\distractor.txt')).LastWriteTime = (Get-Date).AddSeconds(5)
        Add-RecentChange (Join-Path $script:scratch 'real_src.py')
        Add-RecentChange (Join-Path $script:scratch 'temp\distractor.txt')   # excluded at ingest: must NOT enter the set
        $files = Resolve-ChangedFiles -MaxFiles 20
        ($files | Where-Object { $_ -match 'distractor' }) | Should BeNullOrEmpty
        ($files | Where-Object { $_ -match 'real_src\.py' }) | Should Not BeNullOrEmpty
    }
    It 'graphify-rs still resolves (regression guard)' {
        (Get-ChildItem (Join-Path $script:scratch 'real_src.py')).LastWriteTime = (Get-Date).AddSeconds(5)
        Add-RecentChange (Join-Path $script:scratch 'real_src.py')   # simulate the FSW seeing the write
        $captured = & { Show-ChangedFiles -Label 'graphify-rs' -Line 'Files changed (1), triggering incremental rebuild...' } 6>&1 | Out-String
        $captured | Should Match 'changed file:'
        $captured | Should Match 'real_src\.py'
    }
    It 'gm/graphenium inline-path line is a no-op (would mis-fire the resolver)' {
        $captured = & { Show-ChangedFiles -Label 'graphenium' 'changed (code): J:\audio\VAD\.\real_src.py' } 6>&1 | Out-String
        $captured | Should Not Match 'changed file:'
    }
    It 'grepai inline-path line is a no-op (would mis-fire the resolver)' {
        $captured = & { Show-ChangedFiles -Label 'grepai' 'Indexed real_src.py (0 chunks)' } 6>&1 | Out-String
        $captured | Should Not Match 'changed file:'
    }
    It 'REGRESSION: last log line without trailing newline is NOT suppressed' {
        # Real repowise log: "Watching ..." + "<workspace>: N changed file(s)"
        # (current wording; historically "Detected N changed file(s)") with NO
        # trailing newline. The byte-offset reader (leak fix 2026-09-06) must
        # surface that final unterminated line exactly like the old whole-file
        # reader did - suppressing it would hide the change-event line forever.
        $tmp = Join-Path $env:TEMP ('rp_noeol_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $lp = Join-Path $tmp 'r.log'
        # Write exactly like repowise: two lines, last line has NO trailing CR/LF.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("Watching J:\repo... Ctrl+C to stop`nvad: 2 changed file(s), updating...")
        [System.IO.File]::WriteAllBytes($lp, $bytes)
        $r = Read-WatcherLogTail -Path $lp -Offset 0
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        # Both lines must be surfaced, including the unterminated last one.
        $r.Lines.Count | Should Be 2
        ($r.Lines -join '|') | Should Match 'vad: 2 changed file\(s\), updating\.\.\.'
    }
    It 'REGRESSION: no-trailing-newline log still surfaces the change-count line in the seed loop' {
        # End-to-end-ish: seed read over the real-shaped log must surface the
        # "vad: 2 changed file(s)" line (not just the "Watching" banner).
        $tmp = Join-Path $env:TEMP ('rp_seed_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $lp = Join-Path $tmp 'r.log'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("Watching J:\repo... Ctrl+C to stop`nvad: 2 changed file(s), updating...")
        [System.IO.File]::WriteAllBytes($lp, $bytes)
        # Replicate the seed read's decision: which lines get printed.
        $seed = Read-WatcherLogTail -Path $lp -Offset 0
        $printed = ($seed.Lines | Where-Object { $_ -match 'changed file\(s\)' })
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        $printed | Should Not BeNullOrEmpty
    }
}

if (-not $env:RP_CF_TEST_RAN) {
    $env:RP_CF_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
