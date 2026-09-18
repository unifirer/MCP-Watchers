# tests/launcher_workspace_root.tests.ps1
# Pester 3.4.0 idiom. Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_workspace_root.tests.ps1
# Static source-wiring locks for beads mcpw-ybs.1: the launcher must open its
# panes at the CALLER's repository ($watchersWorkspaceRoot, captured from the
# invocation directory) while module loads keep resolving from its own folder
# ($scriptDir). ASCII-only comments/hyphens (project rule). PS 5.1 compatible.
$pesterLegacy = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -lt 4 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pesterLegacy) { Import-Module $pesterLegacy.Path -DisableNameChecking }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher = Join-Path $repoRoot '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

Describe 'mcpw-ybs.1: panes follow the workspace, modules follow the launcher' {
    It 'no longer forces the working directory to the launcher folder' {
        $c = Get-Content -LiteralPath $launcher -Raw
        ($c -split "`n" | Where-Object { $_ -match 'Set-Location -LiteralPath \$scriptDir' }) | Should BeNullOrEmpty
    }

    It 'captures the invocation directory as the workspace root' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match '\$watchersWorkspaceRoot = \(Get-Location\)\.ProviderPath'
    }

    It 'all four grid steps open panes at the workspace root' {
        $c = Get-Content -LiteralPath $launcher -Raw
        ([regex]::Matches($c, "'-d', \`$watchersWorkspaceRoot")).Count | Should Be 4
        ([regex]::Matches($c, "'-d', '\.'")).Count | Should Be 0
    }

    It 'all four pane tailers work at the workspace root (grepai heals at its index dir)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        # mcpw-ybs.1 originally sent only the THREE non-grepai tailers to the
        # workspace and pinned grepai's to $scriptDir. Grepai's heal was then
        # moved to its index dir (020c191, "heal at index dir, not workspace
        # root"), after which grepai's pane tailer takes the workspace root too
        # and no tailer is pinned to the launcher folder at all. Count the
        # New-WatcherPaneScript lines rather than every occurrence, so unrelated
        # -RepoRoot uses (worktree validate) cannot move the number.
        $paneLines = @($c -split "`n" | Where-Object {
            $_ -match 'New-WatcherPaneScript' -and $_ -match '-RepoRoot \$watchersWorkspaceRoot'
        })
        $paneLines.Count | Should Be 4
        ([regex]::Matches($c, '-RepoRoot \$scriptDir')).Count | Should Be 0
    }

    It 'module loads still resolve from the launcher folder' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match "Join-Path \`$scriptDir 'Modules\\watcher_workspace\.ps1'"
        $c | Should Match "Join-Path \`$scriptDir 'Modules\\watcher_teardown\.ps1'"
        $c | Should Match "Join-Path \`$scriptDir 'Modules\\watcher_job_helpers\.ps1'"
        $c | Should Match "Join-Path \`$scriptDir 'Modules\\watcher_patterns\.ps1'"
        $c | Should Match "Join-Path \`$scriptDir 'Modules\\watcher_pane_scripts\.ps1'"
    }

    It 'an empty workspace root degrades visibly, never to machine-global' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'if \(-not \$watchersWorkspaceRoot\) \{ \$watchersWorkspaceRoot = \$scriptDir \}'
    }
}

if (-not $env:LAUNCHER_WORKSPACE_ROOT_TEST_RAN) {
    $env:LAUNCHER_WORKSPACE_ROOT_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
