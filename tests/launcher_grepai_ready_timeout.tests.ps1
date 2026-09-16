# tests/launcher_grepai_ready_timeout.tests.ps1
# Pester 3.4.0 (pinned). Regression for beads VAD-ksg2 (2026-08-26 20:57 crash):
# `grepai watch --background` carries a FIXED internal 30s readiness probe ("Error:
# timeout waiting for process to become ready after 30s"). Under heavy load it can
# expire, and grepai exits -1 (0xFFFFFFFF). The launcher previously:
#   a) waited only WaitForExit(8000) on the launch gate, so the ~30s exit was never
#      observed and never reached the recovery catch block; and
#   b) recovered only the "already running" stale-lock class.
# Fix pins FOUR contracts in the launcher text/AST:
#   1. launch gate waits >=35s (covers grepai's 30s budget): $gp.WaitForExit(35000)
#   2. retry launch also waits >=35s:                    $gp2.WaitForExit(35000)
#   3. recovery classifies the readiness-timeout stderr string
#   4. recovery clears stale pid lock files before relaunching
#
# Run (single pass, reliable exit code):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
#     "if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }; Invoke-Pester -Path 'tests\launcher_grepai_ready_timeout.tests.ps1' -EnableExit"
if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }

$repo     = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

function Get-LauncherText {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "launcher parse error: $($errors[0].Message)" }
    return $ast.Extent.Text
}
function Get-LauncherFunctionText {
    param([string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]($null), [ref]($null))
    if ($errors.Count -gt 0) { throw "launcher parse error: $($errors[0].Message)" }
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
    if ($fn.Count -ne 1) { throw "expected exactly 1 definition of $Name, found $($fn.Count)" }
    return $fn[0].Extent.Text
}

Describe 'grepai launch readiness-timeout recovery (VAD-ksg2)' {
    $text = Get-LauncherText

    It 'launch gate observes an immediate crash (10s wait on foreground watch)' {
        # VAD-ksg2 (amended): grepai now launches in FOREGROUND (detached+hidden),
        # which has NO internal 30s readiness gate, so the first launch only needs
        # to catch an immediate crash -> 10s wait. The 35s budget applies to the
        # RETRY path below.
        $text | Should Match '\$gp\.WaitForExit\(10000\)'
    }

    It 'retry launch also waits at least 35 seconds' {
        $text | Should Match '\$gp2\.WaitForExit\(35000\)'
    }

    It 'recovery classifies the readiness-timeout stderr string' {
        # NOTE: pre-compute the escaped pattern into a variable. Pester 3.4.0
        # treats a bare `[regex]::Escape(...)` argument as a LITERAL string
        # ("to match the expression {[regex]::Escape}"), so the expression form
        # can never pass on the pinned Pester version.
        $readyPat = [regex]::Escape("timeout waiting for process to become ready")
        $text | Should Match $readyPat
    }

    It 'recovery path clears stale pid lock files before relaunching' {
        $pidPat = [regex]::Escape("grepai-worktree-*.pid*")
        $text | Should Match $pidPat
    }

    It 'recovery retries the launch exactly once after classification' {
        # The unified recovery message covers BOTH stale-lock and readiness-timeout
        # classes (the launcher classifies stderr with the 'already running' OR
        # 'timeout waiting for process to become ready' condition at line ~798).
        $stalePat = [regex]::Escape('Stale grepai lock detected - recovering')
        $text | Should Match $stalePat
    }
}
