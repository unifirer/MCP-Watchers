# modules/graphify_ignore_gate.ps1
# Decide whether a changed path should be excluded from a graphify-rs rebuild.
# Primary path: `git check-ignore` (verbatim .gitignore + .graphifyignore semantics).
# Fallback: parse .gitignore / .graphifyignore with git-style negation if git is absent.
function Convert-IgnoreGlobToRegexBody {
    # Translate one gitignore glob (leading '!' already stripped) into a regex
    # body over forward-slash paths. '*' and '?' never cross '/'. '**' spans
    # directories: 'a/**/b' allows zero or more middle dirs, '/**' eats the
    # remainder, leading '**/' matches at any depth. Everything else is literal.
    param([Parameter(Mandatory)][string] $Glob)
    $out = ''
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*') {
            $j = $i
            while ($j -lt $Glob.Length -and $Glob[$j] -eq '*') { $j++ }
            if (($j - $i) -ge 2) {
                $prevSlash = ($i -gt 0 -and $Glob[$i - 1] -eq '/')
                $nextSlash = ($j -lt $Glob.Length -and $Glob[$j] -eq '/')
                if ($prevSlash -and $nextSlash) { $out += '(?:.*/)?'; $i = $j + 1; continue }
                elseif ($prevSlash)             { $out += '.*';       $i = $j;     continue }
                elseif ($nextSlash)             { $out += '(?:.*/)?'; $i = $j + 1; continue }
                else                            { $out += '.*';       $i = $j;     continue }
            }
            $out += '[^/]*'
            $i = $j
        }
        elseif ($c -eq '?') { $out += '[^/]'; $i++ }
        else { $out += [regex]::Escape([string]$c); $i++ }
    }
    return $out
}

function Test-PathIgnoredByGraphify {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $RelativePath,
        [string] $GitExe = 'git'
    )
    $rel = $RelativePath -replace '\\', '/'
    # 0) Always-excluded graphify-rs output dirs (the behavior graphify-rs's own
    #    `watch` lacked — it fired rebuilds on these). Applied regardless of git
    #    presence so the watcher never rebuilds on its own output. Task 2's
    #    wrapper also auto-excludes these; this is the canonical gate for them.
    $safe = @('graphenium-out', 'graphify-rs-out', '.pytest_cache', 'tests/pytest.log', 'tests/_full_run_v2.txt')
    foreach ($d in $safe) {
        if ($rel -eq $d -or $rel.StartsWith("$d/")) { return $true }
    }
    # 1) git is present -> authoritative ignore check
    try {
        $out = & $GitExe -C $Repo check-ignore --quiet $rel 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }   # git says ignored
        if ($LASTEXITCODE -eq 1) { return $false }  # git says NOT ignored
    } catch {}
    # 2) git unavailable -> regex fallback over ignore files. Git-style
    #    semantics: leading '!' negates, and the LAST matching pattern wins
    #    (so '!important.log' after '*.log' un-ignores that file).
    $patterns = @()
    foreach ($f in @('.gitignore', '.graphifyignore')) {
        $p = Join-Path $Repo $f
        if (Test-Path -LiteralPath $p) {
            $patterns += (Get-Content -LiteralPath $p | Where-Object { $_ -and -not $_.StartsWith('#') })
        }
    }
    # Track decision separately from "any match seen": an unmatched negation at
    # the end must NOT force a positive answer.
    $decided = $false
    $ignored = $false
    foreach ($pat in $patterns) {
        $negated = $false
        $g = $pat
        if ($g.StartsWith('!')) { $negated = $true; $g = $g.Substring(1) }
        if ($g.StartsWith('/')) { $g = $g.Substring(1) }  # repo-root anchored; same as our rel-path match
        $body = Convert-IgnoreGlobToRegexBody -Glob ($g.TrimEnd())
        if ($rel -match "^$body`$|^$body`/") {
            $ignored = -not $negated
            $decided = $true
        }
    }
    if ($decided) { return $ignored }
    return $false
}

function Test-PathsIgnoredByGraphify {
    # Batch form of Test-PathIgnoredByGraphify (2026-09-06, beads VAD-iuyp).
    # The per-path gate spawns ONE `git check-ignore` subprocess per changed
    # path; a rebuild cascade flushes hundreds of paths, which measured at
    # ~1.2 CPU-cores average on the watcher process. This version pipes the
    # whole batch through ONE `git check-ignore --stdin` call.
    #
    # Returns a HashSet[string] (forward-slash relative paths) containing the
    # INPUT paths that are ignored. Falls back to the per-path function when
    # git is absent or the batch call fails, so the answer set matches
    # Test-PathIgnoredByGraphify exactly.
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RelativePaths,
        [string] $GitExe = 'git'
    )
    $ignored = New-Object 'System.Collections.Generic.HashSet[string]'
    if (-not $RelativePaths -or $RelativePaths.Count -eq 0) {
        Write-Output -NoEnumerate $ignored
        return
    }
    # Apply the same always-excluded safe-list as the per-path gate BEFORE
    # hitting git (those are ignored even without git present).
    $safe = @('graphenium-out', 'graphify-rs-out', '.pytest_cache', 'tests/pytest.log', 'tests/_full_run_v2.txt')
    $toCheck = New-Object System.Collections.Generic.List[string]
    foreach ($p in $RelativePaths) {
        $rel = $p -replace '\\', '/'
        $isSafe = $false
        foreach ($d in $safe) {
            if ($rel -eq $d -or $rel.StartsWith("$d/")) { $isSafe = $true; break }
        }
        if ($isSafe) { $null = $ignored.Add($rel) } else { $null = $toCheck.Add($rel) }
    }
    if ($toCheck.Count -gt 0) {
        # Batch the whole flush through as few git calls as possible. Paths go
        # as ARGUMENTS (chunked - a single command line caps out around 32k
        # chars), NOT via `--stdin`: PowerShell 5.1 pipes CRLF-terminated text
        # to native stdin and git treats the trailing CR as part of the path,
        # so nothing ever matches. check-ignore prints each IGNORED path on
        # stdout; exit 0 = some ignored, 1 = none ignored - both valid. 2+ =
        # git error -> fall back to the per-path gate.
        $batched = $true
        $chunkSize = 200
        try {
            for ($i = 0; $batched -and $i -lt $toCheck.Count; $i += $chunkSize) {
                $count = [Math]::Min($chunkSize, $toCheck.Count - $i)
                $chunk = $toCheck.GetRange($i, $count).ToArray()
                $out = @(& $GitExe -C $Repo check-ignore -- $chunk 2>$null)
                if ($LASTEXITCODE -ge 2) {
                    $batched = $false
                } else {
                    foreach ($line in $out) {
                        if ($line) { $null = $ignored.Add(($line -replace '\\', '/')) }
                    }
                }
            }
        } catch { $batched = $false }
        if (-not $batched) {
            foreach ($rel in $toCheck) {
                if (Test-PathIgnoredByGraphify -Repo $Repo -RelativePath $rel -GitExe $GitExe) {
                    $null = $ignored.Add($rel)
                }
            }
        }
    }
    # Write-Output -NoEnumerate keeps the HashSet intact on the output stream:
    # a plain `return` would unroll it (empty set -> $null, one item -> string).
    Write-Output -NoEnumerate $ignored
}

function Get-GraphifyRebuildArgs {
    param([switch] $NoLlm)
    # AGENTS.md §3.3.3 / global constraint: rebuilds MUST use --no-llm. We always
    # include it (the $NoLlm switch is retained only for call-compatibility with
    # later tasks; the flag is unconditional so a bare call still rebuilds without
    # the LLM). --update is shipped by graphify-rs 0.8.1 (verified via `build --help`).
    # We DO NOT probe a live `graphify-rs build --help` at runtime: that subprocess is
    # slow and under load its redirected stdout can arrive truncated, which would make
    # a "support" check flaky and intermittently drop --update. If a FUTURE graphify-rs
    # drops --update, the bare fallback `build --path . --no-llm` still works — update
    # this single line then. Returning the supported form directly keeps tests stable.
    return @('build', '--path', '.', '--update', '--no-llm')
}
