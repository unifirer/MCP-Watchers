Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_sweep_attribution.tests.ps1 (mcpw-ybs.2b)
# Pester 3.4.0 (pinned). Guards the FAIL-SAFE contract of the launcher's startup
# orphan sweep, which is the tail of Stop-PriorLauncherInstances.
#
# Background: that sweep is a FALLBACK for orphans the PID-scoped
# Stop-AllWatchers could not reach. Before mcpw-ybs.2 it terminated ANY
# machine-wide process matching a sweep pattern, and the graphify-rs.exe entry
# carries an EMPTY pattern, i.e. a match-all kill. Two repositories running at
# once could therefore kill each other's watchers.
#
# The sweep now terminates a match ONLY when the candidate's command line is
# attributable to THIS workspace, and SKIPS it otherwise. A skipped process may
# remain as an orphan. That is the deliberate trade: an orphan is harmless, a
# sibling repository's live watcher is not.
#
# No real process is spawned or terminated. Get-CimInstance and Invoke-CimMethod
# are stubbed, and the sweep block is EXTRACTED from the launcher source, so the
# assertions run against the real branch logic rather than a hand-copy.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$workspaceModule = Join-Path $repo 'Modules\watcher_workspace.ps1'
$patternsModule = Join-Path $repo 'Modules\watcher_patterns.ps1'

# The real keys on this box, used to build realistic command lines.
$KEY_THIS = '77442b14'
$KEY_OTHER = 'ad90e3fb'
$ROOT_THIS = 'J:\audio\VAD'
$ROOT_OTHER = 'J:\audio\SOME-OTHER-REPO'
$PANE_DIR = "C:\Temp\vad-watchers\$KEY_THIS\panes"

function Get-LauncherSource {
    Get-Content -LiteralPath $launcher -Raw
}

function Get-SweepBlock {
    # Anchor on the mcpw-ybs.2 skip counter, and stop before the next top-level
    # section. Both anchors are unique in the launcher.
    $src = Get-LauncherSource
    $a = $src.IndexOf('    $sweepSkipped = 0')
    $b = $src.IndexOf('# Write the launcher lock (FIRST-WINS entry point).')
    if ($a -lt 0 -or $b -le $a) { return $null }
    return $src.Substring($a, $b - $a)
}

# Run the extracted sweep against a stubbed process table. Returns the PIDs the
# sweep asked to terminate, plus its skip counter.
function Invoke-Sweep {
    param(
        [object[]]$Processes,
        [string]$Key,
        [string]$Root,
        [object[]]$Patterns
    )
    $script:SweepProcs = @($Processes)
    $script:SweepKilled = @()

    # Stub the process table. Filter by image name exactly as the real cmdlet
    # would, so a wrong -Filter in the sweep shows up as a wrong candidate set.
    function Get-CimInstance {
        param($Class, $Filter, $ErrorAction)
        $wanted = $Filter -replace "^Name='", '' -replace "'$", ''
        return @($script:SweepProcs | Where-Object { $_.Name -eq $wanted })
    }
    function Invoke-CimMethod {
        param($InputObject, $MethodName, $ErrorAction)
        if ($MethodName -eq 'Terminate') { $script:SweepKilled += [int]$InputObject.ProcessId }
        return $null
    }

    $script:WatcherSweepPatterns = @($Patterns)
    $workspaceKey = $Key
    $watchersWorkspaceRoot = $Root
    $sweepSkipped = 0
    $WarningPreference = 'SilentlyContinue'

    $block = Get-SweepBlock
    if (-not $block) { throw 'sweep block not found in the launcher source' }
    Invoke-Expression $block

    return [PSCustomObject]@{
        Killed  = @($script:SweepKilled)
        Skipped = [int]$sweepSkipped
    }
}

Describe 'startup orphan sweep attribution (mcpw-ybs.2b)' {

    It 'the workspace module defines the attribution helper' {
        Test-Path -LiteralPath $workspaceModule | Should Be $true
        { . $workspaceModule } | Should Not Throw
        # Assert FUNCTIONALLY, not with Get-Command: this proves the helper is
        # callable from the test scope, which is what the sweep relies on.
        (Test-WatchersProcessAttribution -CommandLine 'cmd -File C:\x\77442b14\y' `
            -WorkspaceKey $KEY_THIS -WorkspaceRoot '') | Should Be $true
        (Test-WatchersProcessAttribution -CommandLine 'cmd -File C:\x\nothing\y' `
            -WorkspaceKey $KEY_THIS -WorkspaceRoot '') | Should Be $false
    }

    It 'extracts the real sweep block from the launcher source' {
        $block = Get-SweepBlock
        $block | Should Not BeNullOrEmpty
        $block | Should Match 'Test-WatchersProcessAttribution'
        $block | Should Match '\$sweepSkipped\+\+'
    }

    It 'the sweep consults the helper, not the raw pattern alone' {
        # Without this the gate could be deleted while the tests still passed.
        $block = Get-SweepBlock
        $block | Should Match '\$attributed = Test-WatchersProcessAttribution'
        $block | Should Match 'if \(-not \$attributed\)'
    }

    It 'the launcher derives the workspace key before the sweep can run' {
        $src = Get-LauncherSource
        $keyIdx = $src.IndexOf('$workspaceKey = Get-WatchersWorkspaceKey')
        $sweepIdx = $src.IndexOf('$sweepSkipped = 0')
        ($keyIdx -ge 0) | Should Be $true
        ($sweepIdx -gt $keyIdx) | Should Be $true
    }

    It 'terminates a pane tailer whose command line carries THIS workspace key' {
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 4201
                CommandLine = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -File $PANE_DIR\tail_grepai.ps1"
            })
        $r.Killed.Count | Should Be 1
        $r.Killed[0] | Should Be 4201
        $r.Skipped | Should Be 0
    }

    It 'SKIPS a match-all graphify-rs.exe that carries no workspace marker' {
        # The regression this whole gate exists for. The graphify-rs.exe entry has
        # an empty Pattern, so it matches on image name alone.
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{
                Name = 'graphify-rs.exe'; ProcessId = 4301
                CommandLine = "C:\Users\someone\.cargo\bin\graphify-rs.exe watch --repo $ROOT_OTHER"
            })
        $r.Killed.Count | Should Be 0
        $r.Skipped | Should Be 1
    }

    It 'SKIPS a pane tailer that belongs to ANOTHER workspace key' {
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 4401
                CommandLine = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -File C:\Temp\vad-watchers\$KEY_OTHER\panes\tail_repowise.ps1"
            })
        $r.Killed.Count | Should Be 0
        $r.Skipped | Should Be 1
    }

    It 'terminates a process attributable by the workspace ROOT instead of the key' {
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 4501
                CommandLine = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command graphify-watch-wrapper -RepoRoot $ROOT_THIS"
            })
        $r.Killed.Count | Should Be 1
        $r.Killed[0] | Should Be 4501
    }

    It 'still honours the pattern filter: a non-matching command line is not a candidate' {
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 4601
                # Carries the key, but matches NO pattern in the list.
                CommandLine = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -File $PANE_DIR\unrelated.ps1"
            })
        $r.Killed.Count | Should Be 0
        $r.Skipped | Should Be 0
    }

    It 'never terminates a candidate with an empty command line' {
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{ Name = 'graphify-rs.exe'; ProcessId = 4701; CommandLine = '' })
        $r.Killed.Count | Should Be 0
        $r.Skipped | Should Be 1
    }

    It 'never terminates a Persistent (port-singleton) backend' {
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{
                Name = 'python.exe'; ProcessId = 4801
                CommandLine = "C:\Python311\python.exe C:\Users\someone\.local\mcp-agent-mail\mcp_agent_mail\server.py --port 8765"
            })
        $r.Killed.Count | Should Be 0
        $r.Skipped | Should Be 0
    }

    It 'counts every skip so the operator sees the residual orphans' {
        . $workspaceModule
        . $patternsModule
        $r = Invoke-Sweep -Key $KEY_THIS -Root $ROOT_THIS -Patterns $script:WatcherSweepPatterns -Processes @(
            [PSCustomObject]@{ Name = 'graphify-rs.exe'; ProcessId = 4901; CommandLine = "C:\bin\graphify-rs.exe watch" },
            [PSCustomObject]@{ Name = 'graphify-rs.exe'; ProcessId = 4902; CommandLine = "C:\bin\graphify-rs.exe watch" },
            [PSCustomObject]@{
                Name = 'powershell.exe'; ProcessId = 4903
                CommandLine = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -File $PANE_DIR\tail_graphenium.ps1"
            })
        $r.Killed.Count | Should Be 1
        $r.Skipped | Should Be 2
    }

    It 'attributes case-insensitively, because Windows paths and keys are' {
        . $workspaceModule
        (Test-WatchersProcessAttribution -CommandLine 'cmd -File C:\TEMP\VAD-WATCHERS\77442B14\PANES\TAIL_GREPAI.PS1' `
            -WorkspaceKey $KEY_THIS -WorkspaceRoot $ROOT_THIS) | Should Be $true
        (Test-WatchersProcessAttribution -CommandLine 'cmd --repo j:\AUDIO\vad' `
            -WorkspaceKey $KEY_THIS -WorkspaceRoot $ROOT_THIS) | Should Be $true
    }

    It 'ignores a workspace root shorter than 4 characters' {
        . $workspaceModule
        # A drive root would otherwise attribute every process on the machine.
        (Test-WatchersProcessAttribution -CommandLine 'cmd -c C:\anything' `
            -WorkspaceKey '' -WorkspaceRoot 'C:\') | Should Be $false
        (Test-WatchersProcessAttribution -CommandLine 'cmd -c C:\anything' `
            -WorkspaceKey '' -WorkspaceRoot 'C:') | Should Be $false
    }

    It 'returns false when there is nothing to attribute with' {
        . $workspaceModule
        (Test-WatchersProcessAttribution -CommandLine '' -WorkspaceKey $KEY_THIS -WorkspaceRoot $ROOT_THIS) | Should Be $false
        (Test-WatchersProcessAttribution -CommandLine 'cmd' -WorkspaceKey '' -WorkspaceRoot '') | Should Be $false
        (Test-WatchersProcessAttribution -CommandLine $null -WorkspaceKey $KEY_THIS -WorkspaceRoot $ROOT_THIS) | Should Be $false
    }
}

if (-not $env:SWEEP_ATTRIBUTION_TEST_RAN) {
    $env:SWEEP_ATTRIBUTION_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
