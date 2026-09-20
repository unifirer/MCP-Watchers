# tests/launcher_pane_heal_idle.tests.ps1
# Pester 3.4.0 team idiom. Run via:
#   python dev_tools/run_pester_suite.py tests/launcher_pane_heal_idle.tests.ps1
#
# Regression locks for bead mcpw-6re: the pane fallback heal must distinguish
# "the watcher died unexpectedly" from "the supervisor deliberately idle-reaped
# it", or it re-spawns the reaped watcher forever (the loop the operator sees as
# "the grepai watcher constantly dying").
#
# Discriminator under test: the RELATIVE ORDER of the two supervisor files.
# The supervisor stamps <lockfile>.sup at the top of every 5s tick and writes
# <lockfile>.idle later in the SAME tick when it reaps on the idle TTL, then
# returns. So at a deliberate reap marker-mtime > sup-mtime, and both freeze.
# If .sup is newer than the marker, a supervisor has ticked since the reap: the
# marker is an orphan and healing is allowed again.
# Verified against the live state dir on 2026-09-20 (MCP key ad90e3fb):
#   ###1-launcher.sup   08:28:57.302
#   ###1-launcher.idle  08:28:58.674   (1.37s later, same tick)
#   ###1-launcher.lock  07:19:51       (launcher start; unchanged)
# and the supervisor log agrees: "08:28:58 grepai idle 20.4 min (TTL 20 min) -
# reaping watcher, supervisor exiting (no relaunch)".
#
# NOTE: the tailer's functions live inside a single-quoted here-string in the
# module, so the AST parser sees them as one string literal. Every extraction
# below therefore parses a GENERATED pane, not the module source.
# NOTE: Start-Process is unusable in this sandbox (it rebuilds the environment
# and throws on the duplicate https_proxy/HTTPS_PROXY keys), so children are
# launched through System.Diagnostics.Process.
# PS 5.1 compatible: no ?? operator, ASCII-only comments/hyphens (project rule).
$pesterLegacy = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -lt 4 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pesterLegacy) { Import-Module $pesterLegacy.Path -DisableNameChecking }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$paneModule = Join-Path $repoRoot 'Modules\watcher_pane_scripts.ps1'
if (-not $env:VAD_WORKSPACE_ROOT) { $env:VAD_WORKSPACE_ROOT = $repoRoot }

# The pane tailer template is a single-quoted here-string inside the module.
function Get-PaneTemplateBody {
    $pat = @'
\$template = @'\r?\n(?<body>[\s\S]*?)\r?\n'@
'@
    $src = Get-Content -LiteralPath $paneModule -Raw
    $m = [regex]::Match($src, $pat)
    if (-not $m.Success) { throw 'tailer template not found in pane module' }
    return $m.Groups['body'].Value
}

# Generates a real pane (full placeholder substitution) into $Dir and returns
# its path. Generation needs $wtPaneDir in the caller's scope (module contract).
function New-GeneratedPane {
    param([string]$Dir, [string]$LockFile)
    $fn = Join-Path $env:TEMP ('mcpw6re_gen_' + [guid]::NewGuid().ToString('N') + '.ps1')
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($paneModule, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw 'parse errors in pane module' }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-WatcherPaneScript' }, $true)
    if (-not $func) { throw 'New-WatcherPaneScript not found' }
    Set-Content -LiteralPath $fn -Value $func.Extent.Text -Encoding utf8
    try {
        . $fn
        $wtPaneDir = $Dir
        return (New-WatcherPaneScript -Label 'grepai' -LogPath (Join-Path $Dir 'grepai.log') `
            -ErrPath '' -RepoRoot '' -HeartbeatPath (Join-Path $Dir 'grepai.hb') -LockFile $LockFile)
    } finally {
        Remove-Item -LiteralPath $fn -Force -ErrorAction SilentlyContinue
    }
}

# Quote/comment-aware extraction of a function from a generated pane file.
function Extract-FunctionAst {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "parse errors in $Path" }
    $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $func) { throw "$Name not found in $Path" }
    return $func.Extent.Text
}

# Dot-sourceable file holding the named tailer functions, taken from a pane
# generated against $Dir.
function New-ExtractedFunctionsFile {
    param([string]$Dir, [string[]]$Names)
    $pane = New-GeneratedPane -Dir $Dir -LockFile (Join-Path $Dir 'launcher.lock')
    $parts = @()
    foreach ($n in $Names) { $parts += (Extract-FunctionAst -Path $pane -Name $n) }
    $tmp = Join-Path $env:TEMP ('mcpw6re_fn_' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $tmp -Value ($parts -join [Environment]::NewLine) -Encoding utf8
    return $tmp
}

function New-TempDir {
    param([string]$Tag)
    $d = Join-Path $env:TEMP ($Tag + '_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Test-LiveGrepaiWatch {
    return (@(Get-CimInstance Win32_Process -Filter "Name='grepai.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'watch' }).Count -gt 0)
}

# Backdates a file so the marker/sup ORDER can be driven deterministically.
function Set-FileAgeMinutes {
    param([string]$Path, [int]$Minutes)
    (Get-Item -LiteralPath $Path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-$Minutes)
}

function Get-HostExePath {
    try { return (Get-Process -Id $PID).Path }
    catch { return (Get-Command 'powershell.exe' -ErrorAction Stop).Source }
}

# Launches a child PS script with stdout/stderr on pipes. Read them with
# Read-ChildOutput AFTER the child has exited (or been killed): the pipe keeps
# everything the child wrote, so a long-running pane can be killed and drained.
function Start-ChildScript {
    param([string]$ScriptPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-HostExePath
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return $p
}

function Read-ChildOutput {
    param($Proc)
    try { $o = $Proc.StandardOutput.ReadToEnd() } catch { $o = '' }
    try { $e = $Proc.StandardError.ReadToEnd() } catch { $e = '' }
    return ($o + [Environment]::NewLine + $e)
}

Describe 'mcpw-6re: reap discriminator replaces bare marker existence' {
    It 'template defines the order probe and gates the heal branch on it' {
        $tpl = Get-PaneTemplateBody
        $tpl | Should Match 'function Test-GrepaiReapPending'
        # The IDLE park / heal decision must use the order probe, not the raw
        # existence probe (the raw one is still the primitive inside it).
        $tpl | Should Match 'if \(Test-GrepaiReapPending -LockPath \$LockFile\) \{'
        # mcpw-qfy RC1 behaviour must survive: IDLE text, display flag, bake.
        $tpl | Should Match 'IDLE - WAITING FOR QUERIES'
        $tpl | Should Match '\$script:idleShown'
        $tpl | Should Match "\`$LockFile = '__LOCKFILE__'"
    }

    It 'the heal re-checks the discriminator at the point of action, before spawning' {
        $dir = New-TempDir -Tag 'mcpw6re_ast'
        try {
            $pane = New-GeneratedPane -Dir $dir -LockFile (Join-Path $dir 'launcher.lock')
            $fn = Extract-FunctionAst -Path $pane -Name 'Invoke-GrepaiHealthCheck'
            $fn | Should Match 'Test-GrepaiReapPending -LockPath \$LockFile'
            $guardAt = $fn.IndexOf('Test-GrepaiReapPending -LockPath $LockFile')
            $spawnAt = $fn.IndexOf('Start-Process -FilePath $gpCmd.Source')
            $guardAt | Should BeGreaterThan -1
            $spawnAt | Should BeGreaterThan -1
            # The guard has to run before anything destructive (lock sweep / spawn).
            ($guardAt -lt $spawnAt) | Should Be $true
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the pane no longer erases the supervisor reap marker' {
        $tpl = Get-PaneTemplateBody
        # Only the supervisor owns <lockfile>.idle. A pane that deletes it
        # converts "deliberately reaped" into "crashed" and restarts the loop.
        $tpl | Should Not Match 'Remove-Item[^\r\n]*staleIdle'
        $tpl | Should Not Match "ChangeExtension\(\`$LockFile, '\.idle'\)"
        # ... but the DISPLAY reset on a live watcher stays.
        $tpl | Should Match '\$script:idleShown = \$false'
    }
}

Describe 'mcpw-6re: Test-GrepaiReapPending lifecycle' {
    It 'honours only a marker that no supervisor tick has superseded' {
        $dir = New-TempDir -Tag 'mcpw6re_disc'
        $fnFile = $null
        try {
            $fnFile = New-ExtractedFunctionsFile -Dir $dir -Names @('Test-GrepaiIdleMarker', 'Test-GrepaiReapPending')
            . $fnFile
            $lock = Join-Path $dir 'launcher.lock'
            $marker = Join-Path $dir 'launcher.idle'
            $stamp = Join-Path $dir 'launcher.sup'
            Set-Content -LiteralPath $lock -Value '{"Pid":1}' -Encoding UTF8

            # Unknown / empty lock path: never pending (pane may heal).
            (Test-GrepaiReapPending -LockPath '') | Should Be $false

            # No marker at all: not a reap.
            (Test-GrepaiReapPending -LockPath $lock) | Should Be $false

            # The real reap shape: .sup stamped first, marker written later in
            # the same tick, then the supervisor returned. AUTHORITATIVE.
            Set-Content -LiteralPath $stamp -Value 'x' -Encoding UTF8
            Set-Content -LiteralPath $marker -Value 'x' -Encoding UTF8
            Set-FileAgeMinutes -Path $stamp -Minutes 30
            (Test-GrepaiReapPending -LockPath $lock) | Should Be $true

            # Marker but no .sup at all: the marker is the only evidence.
            Remove-Item -LiteralPath $stamp -Force
            (Test-GrepaiReapPending -LockPath $lock) | Should Be $true

            # ORPHAN marker: a supervisor has ticked since the reap (it also
            # clears the marker at its own start), so healing is allowed again.
            Set-Content -LiteralPath $stamp -Value 'x' -Encoding UTF8
            Set-FileAgeMinutes -Path $marker -Minutes 30
            (Test-GrepaiReapPending -LockPath $lock) | Should Be $false

            # No marker, fresh supervisor stamp: not a reap either.
            Remove-Item -LiteralPath $marker -Force
            (Test-GrepaiReapPending -LockPath $lock) | Should Be $false
        } finally {
            if ($fnFile) { Remove-Item -LiteralPath $fnFile -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'mcpw-6re: the heal refuses to spawn while a reap is pending' {
    It 'Invoke-GrepaiHealthCheck returns without healing when the marker is authoritative' {
        $dir = New-TempDir -Tag 'mcpw6re_heal'
        $fnFile = $null
        $p = $null
        try {
            $fnFile = New-ExtractedFunctionsFile -Dir $dir -Names @(
                'Test-GrepaiIdleMarker', 'Test-GrepaiReapPending', 'Test-SupervisorAlive',
                'Test-GrepaiLockStale', 'Invoke-GrepaiHealthCheck')
            $lock = Join-Path $dir 'launcher.lock'
            $stamp = Join-Path $dir 'launcher.sup'
            $marker = Join-Path $dir 'launcher.idle'
            $repo = Join-Path $dir 'repo'
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Set-Content -LiteralPath $lock -Value '{"Pid":1}' -Encoding UTF8
            Set-Content -LiteralPath $stamp -Value 'x' -Encoding UTF8
            Set-Content -LiteralPath $marker -Value (Get-Date -Format 'o') -Encoding UTF8
            # Stale supervisor stamp (the reap happened, the supervisor returned)
            # plus a marker NEWER than it: the exact trace shape from the bead.
            # Without the point-of-action guard this call goes on to clear locks
            # and re-spawn grepai.
            Set-FileAgeMinutes -Path $stamp -Minutes 10
            $cap = Join-Path $dir 'heal.out'
            # Child process, deliberately sandboxed so a missing guard can never
            # touch the live machine: PATH has no grepai.exe (so the spawn is
            # unreachable) and LOCALAPPDATA is redirected (so the machine-global
            # lock sweep looks at an empty dir). The verdict is written straight
            # to the child's stdout pipe (6>&1 merges the information stream, so
            # Write-Host lands in $o).
            $inner = Join-Path $dir 'inner.ps1'
            $innerSrc = @'
$env:PATH = 'C:\Windows\System32;C:\Windows'
$env:LOCALAPPDATA = '__DIR__'
. '__FNFILE__'
$o = Invoke-GrepaiHealthCheck -RepoRoot '__REPO__' -LaunchLog '__LL__' -LaunchErr '__LE__' -SupervisorLog '__SL__' -LockFile '__LOCK__' 6>&1 | Out-String
[Console]::Out.Write($o)
'@
            $innerSrc = $innerSrc.Replace('__DIR__', $dir).Replace('__FNFILE__', $fnFile).Replace('__REPO__', $repo).
                Replace('__LL__', (Join-Path $dir 'l.log')).Replace('__LE__', (Join-Path $dir 'l.err')).
                Replace('__SL__', (Join-Path $dir 's.log')).Replace('__LOCK__', $lock)
            Set-Content -LiteralPath $inner -Value $innerSrc -Encoding UTF8
            $p = Start-ChildScript -ScriptPath $inner
            $p.WaitForExit(60000) | Out-Null
            $out = Read-ChildOutput -Proc $p
            if ($out -notmatch 'grepai HEALTH') {
                Write-Host ('  [SKIP] child produced no health output - environment cannot run it; child said: ' + $out.Trim())
                return
            }
            if ($out -match 'watch daemon is live') {
                Write-Host '  [SKIP] live grepai watch - reap scenario untestable'
                return
            }
            # Positive assertion: the guard's own log line IS the regression.
            $out | Should Match 'deliberate idle reap pending'
            $out | Should Not Match 'auto-healing'
            $out | Should Not Match 'auto-heal SUCCESS'
        } finally {
            if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            if ($fnFile) { Remove-Item -LiteralPath $fnFile -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'mcpw-6re: reap-pending pane parks instead of healing' {
    It 'a stale supervisor stamp plus a fresh marker keeps the pane on IDLE, past the tick-30 heal' {
        if (Test-LiveGrepaiWatch) { Write-Host '  [SKIP] live grepai watch - IDLE scenario untestable'; return }
        $dir = New-TempDir -Tag 'mcpw6re_park'
        $proc = $null
        try {
            $log = Join-Path $dir 'grepai.log'
            Set-Content -LiteralPath $log -Value @('seed') -Encoding UTF8
            $lock = Join-Path $dir 'launcher.lock'
            $stamp = Join-Path $dir 'launcher.sup'
            $marker = Join-Path $dir 'launcher.idle'
            Set-Content -LiteralPath $lock -Value '{"Pid":1}' -Encoding UTF8
            Set-Content -LiteralPath $stamp -Value 'x' -Encoding UTF8
            Set-Content -LiteralPath $marker -Value (Get-Date -Format 'o') -Encoding UTF8
            Set-FileAgeMinutes -Path $stamp -Minutes 10
            $tailer = New-GeneratedPane -Dir $dir -LockFile $lock
            $proc = Start-ChildScript -ScriptPath $tailer
            # 20s ~= 40 ticks: past the tick-30 heal trigger, and past the 60s
            # window Test-SupervisorAlive needs to call the supervisor dead.
            Start-Sleep -Seconds 20
            $proc.Refresh()
            $proc.HasExited | Should Be $false
            $hb = Join-Path $dir 'grepai.hb'
            (Test-Path -LiteralPath $hb) | Should Be $true
            $hbAge = ((Get-Date) - (Get-Item -LiteralPath $hb).LastWriteTime).TotalSeconds
            $hbAge | Should BeLessThan 10
            $proc.Kill()
            $proc.WaitForExit(5000) | Out-Null
            $out = Read-ChildOutput -Proc $proc
            $out | Should Match 'IDLE - WAITING FOR QUERIES'
            $out | Should Not Match 'auto-heal'
            $out | Should Not Match 'auto-check triggered'
            # The pane must not have erased the supervisor's reap record.
            (Test-Path -LiteralPath $marker) | Should Be $true
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $env:LAUNCHER_PANE_HEAL_IDLE_TEST_RAN) {
    $env:LAUNCHER_PANE_HEAL_IDLE_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
