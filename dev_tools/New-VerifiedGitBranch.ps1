# dev_tools/New-VerifiedGitBranch.ps1
# mcpw-sr4: slash-named branches are silently discarded on the J: volume.
#
# `git branch fix-tests/2026-09-18-120000 HEAD` exits 0 and prints nothing.
# The reflog is written (.git/logs/refs/heads/fix-tests/2026-09-18-120000,
# including the intermediate directory) but .git/refs/heads/fix-tests/ is never
# created, so the branch does not exist. Every later command reports it as
# missing with no error at the point of failure.
#
# Measured 2026-09-18, git 2.55.0.windows.3:
#   - fresh scratch repos on C: work, including 6 directory levels deep
#   - fresh scratch repos on J: fail, at the drive root and nested
#   - `git update-ref refs/heads/a/b HEAD` fails the same way, so it is not the
#     `branch` command
#   - a manual mkdir plus file write under .git/refs/heads/ succeeds, so the
#     filesystem accepts the layout; it is git's loose-ref write that no-ops
#   - not fixable by git config: core.logAllRefUpdates=false, pre-creating the
#     parent directory, and pack-refs first were all tried and all still fail
# The defect is intermittent: probes at 22:05 and 23:55 on this box created
# slash-named refs without incident. It cannot be relied on to fail or to work.
#
# This script creates a branch and then VERIFIES the ref exists. A missing ref
# is a hard failure with the flat-name guidance, never a silent success.
#
# Usage (script):
#   .\dev_tools\New-VerifiedGitBranch.ps1 -Name fixtests-20260918-105800
#   .\dev_tools\New-VerifiedGitBranch.ps1 -Name feature/x -Repo J:\audio\VAD -Checkout
#
# Usage (dot-source, for tests and other scripts - defines functions, no-op):
#   . .\dev_tools\New-VerifiedGitBranch.ps1

param(
    [string] $Name,
    [string] $StartPoint = 'HEAD',
    [string] $Repo = (Get-Location).Path,
    [switch] $Checkout
)

function Test-GitBranchRefExists {
    # True only when git itself reports the ref. `git branch --list` is not
    # enough: on the affected volume the branch never appears anywhere, so a
    # negative result here is the whole point.
    # Not [Parameter(Mandatory)]: callers pass through values they did not
    # validate, and an empty answer must be $false, not a binding error.
    param(
        [string] $Repo,
        [string] $Name
    )
    if ([string]::IsNullOrWhiteSpace($Repo)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    # mcpw-9lf: Windows PowerShell 5.1 drops a null operand handed to a native
    # command, so both operands are non-empty before git is called.
    & git -C "$Repo" show-ref --verify --quiet "refs/heads/$Name" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Assert-GitBranchRef {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Name
    )
    if (Test-GitBranchRefExists -Repo $Repo -Name $Name) { return $true }

    $msg = "git branch '$Name' does not exist in '$Repo': no ref refs/heads/$Name."
    $reflog = Join-Path $Repo (Join-Path '.git' (Join-Path 'logs' (Join-Path 'refs' (Join-Path 'heads' $Name))))
    if (Test-Path -LiteralPath $reflog -ErrorAction SilentlyContinue) {
        $msg += " A reflog was written ($reflog) but no ref file - this is the mcpw-sr4 J: volume defect, where slash-named refs are discarded with exit code 0 and no output."
    }
    $msg += " Use a FLAT branch name on this volume (for example 'fixtests-20260918-105800'), or create the branch on C: and move the work across."
    throw $msg
}

function New-VerifiedGitBranch {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $StartPoint = 'HEAD',
        [string] $Repo = (Get-Location).Path,
        [switch] $Checkout
    )
    if ([string]::IsNullOrWhiteSpace($Repo)) { throw 'Repo path is empty.' }
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Branch name is empty.' }
    if ($Name.EndsWith('/') -or $Name.StartsWith('/')) { throw "Branch name '$Name' is malformed." }
    if ($Name.Contains('/')) {
        Write-Warning "Branch name '$Name' contains a slash. On the J: volume slash-named refs are silently discarded (mcpw-sr4). Use a flat name unless you have verified this volume."
    }
    if ([string]::IsNullOrWhiteSpace($StartPoint)) { $StartPoint = 'HEAD' }

    if ($Checkout) {
        & git -C "$Repo" checkout -b $Name $StartPoint 2>&1 | Out-Null
    } else {
        & git -C "$Repo" branch $Name $StartPoint 2>&1 | Out-Null
    }
    Assert-GitBranchRef -Repo $Repo -Name $Name
    return $true
}

# Script mode only. Dot-sourcing stops here with the functions defined.
if (-not [string]::IsNullOrWhiteSpace($Name)) {
    New-VerifiedGitBranch -Name $Name -StartPoint $StartPoint -Repo $Repo -Checkout:$Checkout | Out-Null
    Write-Host "branch '$Name' created and verified in '$Repo'."
}
