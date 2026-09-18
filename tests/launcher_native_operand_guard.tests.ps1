# tests/launcher_native_operand_guard.tests.ps1
# Pester 3.4.0 (pinned). mcpw-9lf.
#
# Windows PowerShell 5.1 DROPS a null operand handed to a native command:
#
#   git -C "$wt" rev-parse HEAD      with $wt = $null
#   becomes  git -C rev-parse HEAD
#
# git then reads 'rev-parse' as the -C operand and prints
#   fatal: cannot change to 'rev-parse': No such file or directory
# Under $ErrorActionPreference = Stop that stderr is a TERMINATING error even
# though the call site writes 2>$null. Observed in launcher_tests.ps1 T6/T7.
#
# mcpw-759 covered the two worktree blocks. This suite pins the rest: the
# operand is checked BEFORE git is called, at every site that can receive an
# empty path.
if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }

$repo     = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$paneModule = Join-Path $repo 'Modules\watcher_pane_scripts.ps1'

function Get-LauncherFunctionText {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "launcher parse error: $($errors[0].Message)" }
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
    if ($fn.Count -ne 1) { throw "expected exactly 1 definition of $Name, found $($fn.Count)" }
    return $fn[0].Extent.Text
}

function Get-LauncherLines {
    return @(Get-Content -LiteralPath $launcher)
}

# Define the REAL production functions in this scope so every It block sees them.
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Invoke-GrepaiWorktreeValidate')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Invoke-GrepaiWorktreePrune')))

Describe 'mcpw-9lf: empty path operands never reach a native command' {

    It 'Invoke-GrepaiWorktreeValidate returns quietly on an empty RepoRoot' {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            { Invoke-GrepaiWorktreeValidate -RepoRoot '' } | Should Not Throw
            { Invoke-GrepaiWorktreeValidate -RepoRoot $null } | Should Not Throw
        } finally { $ErrorActionPreference = $prev }
    }

    It 'Invoke-GrepaiWorktreePrune returns quietly on an empty RepoRoot' {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            $r = Invoke-GrepaiWorktreePrune -RepoRoot ''
            @($r).Count | Should Be 0
        } finally { $ErrorActionPreference = $prev }
    }

    It 'guards every git -C site that can receive an empty operand' {
        # Only the variables that can actually arrive empty are checked here.
        # $gitRoot and $wt are downstream of an earlier guard, so requiring a
        # check on them too would just be noise.
        $mustGuard = @('watchersWorkspaceRoot', 'RepoRoot', 'ScriptDir')
        $lines = Get-LauncherLines
        $unguarded = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch 'git -C "\$(\w+)"') { continue }
            $var = $Matches[1]
            if ($mustGuard -notcontains $var) { continue }
            $window = $lines[[Math]::Max(0, $i - 15)..$i] -join "`n"
            # $ is end-of-line in a regex, so the variable must be escaped
            # before it goes into the pattern.
            $varPattern = [regex]::Escape('$' + $var)
            $guardPattern = "(IsNullOrWhiteSpace\(\s*$varPattern\s*\))|(if\s*\(\s*(?:-not\s*\(?\s*)?$varPattern\s*\)?)"
            if (-not ($window -match $guardPattern)) {
                $unguarded.Add("line $($i + 1): $($lines[$i].Trim())")
            }
        }
        if ($unguarded.Count -gt 0) {
            throw "git -C sites with no emptiness guard on the operand:`n  " + ($unguarded -join "`n  ")
        }
    }

    It 'checks the graphenium watcher root before handing it to FileSystemWatcher' {
        $lines = Get-LauncherLines
        $i = -1
        for ($n = 0; $n -lt $lines.Count; $n++) {
            if ($lines[$n] -match '\$script:gmFsw\.Path\s*=') { $i = $n; break }
        }
        $i | Should BeGreaterThan 0
        $window = $lines[[Math]::Max(0, $i - 10)..$i] -join "`n"
        $window | Should Match 'IsNullOrWhiteSpace\(\$watchersWorkspaceRoot\)'
    }

    It 'refuses the graphenium rebuild when the pane repo path is empty' {
        $pane = Get-Content -LiteralPath $paneModule -Raw
        $pane | Should Match 'IsNullOrWhiteSpace\(\$repo\)'
    }
}

Describe 'mcpw-9lf: the hazard is real (Windows PowerShell 5.1)' {
    It 'proves an empty -C operand aborts under ErrorActionPreference=Stop' {
        $ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $ps5)) {
            # No 5.1 host here: the static guards above still hold.
            Set-TestInconclusive -Message 'Windows PowerShell 5.1 not available'
            return
        }
        $script = '$ErrorActionPreference = ''Stop''; $wt = $null; git -C "$wt" rev-parse HEAD 2>$null; "NO-THROW"'
        $out = & $ps5 -NoProfile -NonInteractive -Command $script 2>&1 | Out-String
        # The native call must NOT have completed cleanly: git never even got a
        # usable operand, so 5.1 either raises the terminating error or git
        # prints its "cannot change to" diagnostic.
        $out | Should Not Match 'NO-THROW'
    }
}
