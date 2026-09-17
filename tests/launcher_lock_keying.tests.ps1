Import-Module Pester -RequiredVersion 3.4.0 -Force
# tests/launcher_lock_keying.tests.ps1 (mcpw-ybs.4)
# Pester 3.4.0 (pinned). Guards the PER-WORKSPACE keying of the launcher's
# single-instance guard: the FIRST-WINS lock file and the two launcher mutexes.
#
# Background: the lock file was a fixed name under %LOCALAPPDATA%\watchers and
# the mutexes were the bare names Global\VAD_Watchers_Launcher /
# Global\VAD_Watchers_Takeover, i.e. machine-global. A launcher started for a
# SECOND repository therefore contended with the first repository's live
# launcher: it either exited 0 and never opened its own pane grid, or (through
# Stop-PriorLauncherInstances) took the lock over and killed the other repo's
# watchers. FIRST-WINS must hold WITHIN one workspace only.
#
# The key is a DIRECTORY component and the lock FILE NAME is unchanged:
#   %LOCALAPPDATA%\watchers\<key>\###1-launcher.lock
# matching Modules\watcher_teardown.ps1 (watchers\<key>\teardown-state.json) so
# the two never drift into different key conventions.
#
# No mutex is created, no lock file is written and no process is spawned. The
# keying lines are EXTRACTED from the launcher source and executed, so the
# assertions run against the real code rather than a hand-copy.

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
$workspaceModule = Join-Path $repo 'Modules\watcher_workspace.ps1'
$teardownModule = Join-Path $repo 'Modules\watcher_teardown.ps1'

# The real keys on this box, so a drift in the derivation shows up as a failure.
$KEY_VAD = '77442b14'          # J:\audio\VAD
$KEY_MCPW = 'ad90e3fb'         # J:\audio\MCP-Watchers
$ROOT_VAD = 'J:\audio\VAD'
$ROOT_MCPW = 'J:\audio\MCP-Watchers'

function Get-LauncherSource {
    Get-Content -LiteralPath $launcher -Raw
}

function Get-LineStartingWith {
    param([string]$Source, [string]$Anchor)
    # Return the single source line that begins with $Anchor (trimmed).
    $idx = $Source.IndexOf($Anchor)
    if ($idx -lt 0) { return $null }
    $eol = $Source.IndexOf("`n", $idx)
    if ($eol -lt 0) { $eol = $Source.Length }
    return $Source.Substring($idx, $eol - $idx).TrimEnd("`r")
}

function Get-KeyGuardLine {
    # The empty-key guard that keeps Join-Path from throwing and keeps the mutex
    # from collapsing back onto one machine-global name.
    $src = Get-LauncherSource
    return Get-LineStartingWith -Source $src -Anchor 'if (-not $workspaceKey) { $workspaceKey = '
}

function Get-LockKeyingBlock {
    # The lock dir / lock file / mutex-name block, straight out of the launcher.
    $src = Get-LauncherSource
    $a = $src.IndexOf('$lockDir = Join-Path (Join-Path $env:LOCALAPPDATA ')
    if ($a -lt 0) { return $null }
    $b = $src.IndexOf('$takeoverMutexName = "Global\VAD_Watchers_Takeover_$workspaceKey"')
    if ($b -le $a) { return $null }
    $eol = $src.IndexOf("`n", $b)
    if ($eol -lt 0) { $eol = $src.Length }
    return $src.Substring($a, $eol - $a)
}

function Invoke-LockKeying {
    param([string]$Key)
    $guard = Get-KeyGuardLine
    $block = Get-LockKeyingBlock
    if (-not $guard) { throw 'empty-key guard not found in the launcher source' }
    if (-not $block) { throw 'lock keying block not found in the launcher source' }
    # Strip the directory creation so the suite stays PURE (no filesystem writes).
    $pure = ($block -split "`r?`n" | Where-Object { $_ -notmatch 'New-Item' }) -join "`n"
    $workspaceKey = $Key
    Invoke-Expression ($guard + "`n" + $pure)
    return [PSCustomObject]@{
        LockDir       = $lockDir
        LockFile      = $lockFile
        LauncherMutex = $launcherMutexName
        TakeoverMutex = $takeoverMutexName
    }
}

function Get-FunctionBlock {
    param([string]$Source, [string]$Name)
    # From "function <Name> {" up to the first line that is exactly "}".
    $a = $Source.IndexOf("function $Name {")
    if ($a -lt 0) { return $null }
    $b = $Source.IndexOf("`n}", $a)
    if ($b -le $a) { return $null }
    return $Source.Substring($a, $b - $a + 2)
}

Describe 'launcher lock + mutex keying (mcpw-ybs.4)' {

    It 'the workspace module derives the documented keys' {
        Test-Path -LiteralPath $workspaceModule | Should Be $true
        . $workspaceModule
        # Guards the keys the rest of this suite - and the handover - rely on.
        (Get-WatchersWorkspaceKey -Path $ROOT_VAD) | Should Be $KEY_VAD
        (Get-WatchersWorkspaceKey -Path $ROOT_MCPW) | Should Be $KEY_MCPW
    }

    It 'the launcher derives its key before it derives the lock path' {
        $src = Get-LauncherSource
        $keyIdx = $src.IndexOf('$workspaceKey = Get-WatchersWorkspaceKey')
        $lockIdx = $src.IndexOf('$lockDir = Join-Path (Join-Path $env:LOCALAPPDATA ')
        ($keyIdx -ge 0) | Should Be $true
        ($lockIdx -gt $keyIdx) | Should Be $true
    }

    It 'the lock dir carries the workspace key as a DIRECTORY component' {
        $r = Invoke-LockKeying -Key $KEY_VAD
        $r.LockDir | Should Be (Join-Path $env:LOCALAPPDATA "watchers\$KEY_VAD")
        # EndsWith, not -match: 'Should Match [regex]::Escape(...)' parses the
        # type literal as the pattern in Pester 3.4.0 and asserts nothing.
        $r.LockDir.EndsWith("watchers\$KEY_VAD") | Should Be $true
    }

    It 'the lock FILE NAME is unchanged so the tailers and tests still match it' {
        $r = Invoke-LockKeying -Key $KEY_VAD
        $r.LockFile | Should Be (Join-Path $env:LOCALAPPDATA "watchers\$KEY_VAD\###1-launcher.lock")
        # The key must never become a filename suffix - that would break every
        # literal '###1-launcher.lock' match in the pane tailers and the tests.
        $r.LockFile | Should Not Match "\###1-launcher\.$KEY_VAD\.lock"
    }

    It 'two workspaces get two different lock files' {
        $a = Invoke-LockKeying -Key $KEY_VAD
        $b = Invoke-LockKeying -Key $KEY_MCPW
        $a.LockFile | Should Not Be $b.LockFile
        $a.LockDir | Should Not Be $b.LockDir
    }

    It 'the launcher mutex is keyed per workspace' {
        $a = Invoke-LockKeying -Key $KEY_VAD
        $b = Invoke-LockKeying -Key $KEY_MCPW
        $a.LauncherMutex | Should Be "Global\VAD_Watchers_Launcher_$KEY_VAD"
        $b.LauncherMutex | Should Be "Global\VAD_Watchers_Launcher_$KEY_MCPW"
        $a.LauncherMutex | Should Not Be $b.LauncherMutex
    }

    It 'the takeover mutex is keyed per workspace' {
        $a = Invoke-LockKeying -Key $KEY_VAD
        $b = Invoke-LockKeying -Key $KEY_MCPW
        $a.TakeoverMutex | Should Be "Global\VAD_Watchers_Takeover_$KEY_VAD"
        $b.TakeoverMutex | Should Be "Global\VAD_Watchers_Takeover_$KEY_MCPW"
        $a.TakeoverMutex | Should Not Be $b.TakeoverMutex
    }

    It 'no bare machine-global mutex name survives in the launcher' {
        # A quoted bare name would mean a mutex is still created or opened
        # machine-wide. The commented mention is parenthesised, not quoted.
        $src = Get-LauncherSource
        $src.Contains("'Global\VAD_Watchers_Launcher'") | Should Be $false
        $src.Contains("'Global\VAD_Watchers_Takeover'") | Should Be $false
    }

    It 'an empty key degrades to a placeholder, never to the bare name' {
        $r = Invoke-LockKeying -Key ''
        $r.LockDir | Should Be (Join-Path $env:LOCALAPPDATA 'watchers\default')
        $r.LauncherMutex | Should Be 'Global\VAD_Watchers_Launcher_default'
        $r.TakeoverMutex | Should Be 'Global\VAD_Watchers_Takeover_default'
    }

    It 'Acquire-LauncherLock creates the PASSED-IN mutex, not a fixed name' {
        $src = Get-LauncherSource
        $fn = Get-FunctionBlock -Source $src -Name 'Acquire-LauncherLock'
        $fn | Should Not BeNullOrEmpty
        $fn | Should Match '\[string\]\$MutexName'
        $fn | Should Match 'New-Object System\.Threading\.Mutex\(\$true, \$MutexName, \[ref\]\$createdNew\)'
        # An absent name is rebuilt from the environment, never left bare.
        $fn | Should Match '\$env:VAD_WATCHERS_WORKSPACE_KEY'
        $fn | Should Match "Global\\VAD_Watchers_Launcher_"
    }

    It 'Write-LauncherLock forwards the mutex name at both the definition and the call' {
        $src = Get-LauncherSource
        $fn = Get-FunctionBlock -Source $src -Name 'Write-LauncherLock'
        $fn | Should Not BeNullOrEmpty
        $fn | Should Match '\$MutexName'
        $fn | Should Match 'Acquire-LauncherLock -LockFile \$LockFile -LauncherName \$LauncherName -MutexName \$MutexName'
        $src | Should Match 'Write-LauncherLock -LockFile \$lockFile -LauncherName \$launcherName -MutexName \$launcherMutexName'
    }

    It 'Stop-PriorLauncherInstances takes the keyed takeover mutex' {
        $src = Get-LauncherSource
        $fn = Get-FunctionBlock -Source $src -Name 'Stop-PriorLauncherInstances'
        $fn | Should Not BeNullOrEmpty
        $fn | Should Match '\[string\]\$TakeoverMutexName'
        $fn | Should Match 'New-Object System\.Threading\.Mutex\(\$false, \$TakeoverMutexName\)'
        $src | Should Match 'Stop-PriorLauncherInstances -LockDir \$lockDir -CurrentPid \$PID -TakeoverMutexName \$takeoverMutexName'
        # The prior-instance lock it inspects is the keyed one by construction.
        $fn | Should Match 'Join-Path \$LockDir "###1-launcher\.lock"'
    }

    It 'the PowerShell.Exiting handler releases the KEYED mutex' {
        # It runs in a fresh runspace, so the name is baked into the scriptblock
        # at creation time. A bare name here would release ANOTHER repo's mutex.
        $src = Get-LauncherSource
        $needle = '`$mutexName = ' + "'" + '$launcherMutexName' + "'"
        $src.Contains($needle) | Should Be $true
        $legacy = '`$mutexName = ' + "'" + 'Global\VAD_Watchers_Launcher' + "'"
        $src.Contains($legacy) | Should Be $false
    }

    It 'the teardown state file uses the SAME keyed directory convention' {
        # Two conventions for one key is how a gate silently stops matching.
        $td = Get-Content -LiteralPath $teardownModule -Raw
        $td | Should Match 'watchers\\\$wsKey\\teardown-state\.json'
        $src = Get-LauncherSource
        $src | Should Match 'Join-Path \$env:LOCALAPPDATA "watchers\\\$workspaceKey"'
    }

    It 'the keyed lock dir is created before the lock file is used' {
        $block = Get-LockKeyingBlock
        $block | Should Not BeNullOrEmpty
        $block | Should Match 'New-Item -ItemType Directory -Path \$lockDir -Force'
    }

    It 'the pane tailers receive the keyed lock file by variable, not by literal' {
        $src = Get-LauncherSource
        $src | Should Match 'New-WatcherPaneScript .*-LockFile \$lockFile'
        $src | Should Not Match "watchers\\\\###1-launcher\.lock"
    }
}

if (-not $env:LOCK_KEYING_TEST_RAN) {
    $env:LOCK_KEYING_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
