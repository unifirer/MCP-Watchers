# tests/launcher_port_autheal.tests.ps1
# Pester 3.4.0 (pinned). Regression: Test-PortHeldByLauncherDaemon must be callable
# WITHOUT -OwningPid (Exit-IfPortHeldByLauncherDaemon's AUTO-HEAL port-free recheck
# loop calls it that way). Declaring '[ref]$OwningPid = $null' made every such call
# throw ParameterBindingArgumentTransformationException ("Reference type is expected
# in argument"), aborting AUTO-HEAL into the FIRST-WINS exit (observed 2026-08-25,
# PID 45492 holding memtrace port 50051). An omitted [ref] param binds as $null
# cleanly when NO default value is declared - dropping the default is the fix, and
# these tests pin that contract for both call shapes.
#
# mcpw-d0m (2026-09-18): the second Describe covers the PERSISTENT-SINGLETON
# staleness rule. Port auto-heal must ADOPT a healthy, answering resident
# instead of killing it. The resident here is a REAL child process serving real
# HTTP on a dynamic loopback port - no mock. Ports 8420/8080/8765 are never
# touched; no privileged port is bound.
#
# Run (single pass, reliable exit code):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
#     "if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }; Invoke-Pester -Path 'tests\launcher_port_autheal.tests.ps1' -EnableExit"
if (-not (Get-Module Pester)) { Import-Module Pester -RequiredVersion 3.4.0 -Force }

$repo     = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

function Get-LauncherFunctionText {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "launcher parse error: $($errors[0].Message)" }
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)
    if ($fn.Count -ne 1) { throw "expected exactly 1 definition of $Name, found $($fn.Count)" }
    return $fn[0].Extent.Text
}

# Define the REAL production functions in this scope so every It block sees it.
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Test-PortHeldByLauncherDaemon')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Test-HttpPortAnswering')))
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Exit-IfPortHeldByLauncherDaemon')))

Describe 'Test-PortHeldByLauncherDaemon OwningPid binding' {
    It 'calls without -OwningPid without throwing (AUTO-HEAL recheck shape)' {
        { Test-PortHeldByLauncherDaemon -Port 59999 -DaemonProcessNames @('zzz-no-such-daemon') } | Should Not Throw
        Test-PortHeldByLauncherDaemon -Port 59999 -DaemonProcessNames @('zzz-no-such-daemon') | Should Be $false
    }

    It 'calls with -OwningPid [ref] and resets it to 0 when port is free' {
        $ownerPid = 123456
        $held = Test-PortHeldByLauncherDaemon -Port 59999 -DaemonProcessNames @('zzz-no-such-daemon') -OwningPid ([ref]$ownerPid)
        $held | Should Be $false
        $ownerPid | Should Be 0
    }
}

# ---------------------------------------------------------------------------
# mcpw-d0m: PERSISTENT-SINGLETON staleness rule.
#
# A daemon that holds the port AND answers HTTP is NOT stale. Auto-heal must
# adopt it, not kill it. The resident below is a real child process running a
# real HTTP responder on a dynamic loopback port - not a mock.
#
# The responder lives in its OWN process for two reasons: the owning PID must
# be identifiable by Test-PortHeldByLauncherDaemon (its command line carries
# the token below), and a regression that kills the resident kills a throwaway
# child instead of the Pester host.
#
# Deviation: the bead suggested System.Net.HttpListener. HttpListener is not
# usable here - it failed to bind three arbitrary high ports on this box with
# "The process cannot access the file because it is being used by another
# process", and those same ports also fail for a raw socket bind (WSAEADDRINUSE,
# reserved by the OS). The listener therefore binds a DYNAMIC port (port 0) and
# reports it back through a marker file, and it answers with a hand-rolled
# HTTP/1.1 response. The client side is unchanged: a real HttpWebRequest.
# ---------------------------------------------------------------------------
$script:probeToken = 'mcpw-d0m-probe-listener'
$script:probeListener = Join-Path $env:TEMP "$($script:probeToken).ps1"
$script:probeMarker   = Join-Path $env:TEMP "$($script:probeToken).port"
$script:probeErr      = Join-Path $env:TEMP "$($script:probeToken).err"
$script:probePort     = 0
$script:probeProc     = $null

function New-ProbeListenerScript {
    param([string]$Path)
    # Single-quoted here-string: the child keeps its own $ variables.
    $text = @'
param([int]$Port = 0, [string]$MarkerPath)
$listener = New-Object System.Net.Sockets.TcpListener -ArgumentList @([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$actual = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
# Marker carries port|pid|timestamp: the reader only trusts a marker whose PID
# is the child it just started, so a stale file can never be mistaken for a
# fresh one.
Set-Content -LiteralPath $MarkerPath -Value "$actual|$PID|$(Get-Date -Format o)" -Encoding ASCII
while ($true) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 2000
        $client.SendTimeout = 2000
        $stream = $client.GetStream()
        $buf = New-Object byte[] 4096
        try { [void]$stream.Read($buf, 0, 4096) } catch {}
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('OK')
        $head = "HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}
'@
    Set-Content -LiteralPath $Path -Value $text -Encoding ASCII
}

function Start-ProbeListener {
    param([int]$TimeoutMs = 25000)
    New-ProbeListenerScript -Path $script:probeListener
    # Delete each stale file individually: the array form of Remove-Item did
    # NOT delete them here, and a stale marker made the wait below return a
    # port that nothing was listening on.
    foreach ($f in @($script:probeMarker, $script:probeErr)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    $script:probePort = 0
    $script:probeProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:probeListener, '-Port', '0', '-MarkerPath', $script:probeMarker) `
        -RedirectStandardError $script:probeErr
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path -LiteralPath $script:probeMarker) {
            $raw = (Get-Content -LiteralPath $script:probeMarker -Raw -ErrorAction SilentlyContinue)
            $parts = @()
            if ($raw) { $parts = @($raw.Trim() -split '\|') }
            # Only accept a marker written by THIS child.
            if ($parts.Count -eq 3 -and $parts[0] -match '^\d+$' -and $parts[1] -eq ([string]$script:probeProc.Id)) {
                $script:probePort = [int]$parts[0]
                return $true
            }
        }
        if ($script:probeProc.HasExited) { return $false }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Stop-ProbeListener {
    if ($script:probeProc -and -not $script:probeProc.HasExited) {
        $script:probeProc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # Reap: wait until the port is genuinely free again (up to 10s).
    if ($script:probePort -gt 0) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 10000) {
            if (-not (Get-NetTCPConnection -LocalPort $script:probePort -State Listen -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
    }
    foreach ($f in @($script:probeListener, $script:probeMarker, $script:probeErr)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    $script:probeProc = $null
}

Describe 'Exit-IfPortHeldByLauncherDaemon -AutoHeal with a healthy resident (mcpw-d0m)' {
    BeforeEach {
        $up = Start-ProbeListener
        if (-not $up) {
            $err = ''
            if (Test-Path -LiteralPath $script:probeErr) { $err = Get-Content -LiteralPath $script:probeErr -Raw }
            throw "probe listener did not come up. stderr: $err"
        }
    }
    AfterEach { Stop-ProbeListener }

    It 'sees the resident as an answering HTTP endpoint' {
        Test-HttpPortAnswering -Port $script:probePort | Should Be $true
    }

    It 'leaves the healthy answering endpoint alive instead of killing it' {
        # Pre-condition: the holding PID really is identified as the daemon.
        $ownerPid = 0
        $held = Test-PortHeldByLauncherDaemon -Port $script:probePort -DaemonProcessNames @($script:probeToken) -OwningPid ([ref]$ownerPid)
        $held | Should Be $true
        $ownerPid | Should Be $script:probeProc.Id

        { Exit-IfPortHeldByLauncherDaemon -Port $script:probePort -DaemonProcessNames @($script:probeToken) -Label 'probe' -AutoHeal -DeferToHealthy } | Should Not Throw

        # The whole point: the resident was adopted, not killed.
        $still = Get-Process -Id $script:probeProc.Id -ErrorAction SilentlyContinue
        $still | Should Not BeNullOrEmpty
        $conn = @(Get-NetTCPConnection -LocalPort $script:probePort -State Listen -ErrorAction SilentlyContinue)
        $conn.Count | Should Be 1
        $conn[0].OwningProcess | Should Be $script:probeProc.Id

        # Cleanup: the child is reaped by AfterEach; release it explicitly here
        # so a failed assertion cannot leak the process into the next test.
    }
}

Describe 'Exit-IfPortHeldByLauncherDaemon -AutoHeal with the port free (mcpw-d0m)' {
    It 'proceeds without exiting and reports nothing answering' {
        # Guard: the port used by the previous Describe must be free now.
        $free = -not (Get-NetTCPConnection -LocalPort $script:probePort -State Listen -ErrorAction SilentlyContinue)
        $free | Should Be $true
        Test-HttpPortAnswering -Port $script:probePort | Should Be $false

        $script:probePort -gt 0 | Should Be $true
        $script:reached = $false
        { Exit-IfPortHeldByLauncherDaemon -Port $script:probePort -DaemonProcessNames @($script:probeToken) -Label 'probe' -AutoHeal -DeferToHealthy
          $script:reached = $true } | Should Not Throw
        # Reaching this line proves the function returned instead of taking the
        # FIRST-WINS exit path.
        $script:reached | Should Be $true
    }
}
