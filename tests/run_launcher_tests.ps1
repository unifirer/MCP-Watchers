# tests/run_launcher_tests.ps1
# Convenience runner for the launcher test suite.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_launcher_tests.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_launcher_tests.ps1 -SkipSmoke
#
# Arguments are forwarded to launcher_tests.ps1, which declares
# `param([switch]$SkipSmoke)`.
#
# WHY -SkipSmoke MATTERS: T20 and T21 are END-TO-END launch smokes. T20 spawns
# the REAL launcher, which opens a Windows Terminal window and starts the
# backend daemons (litellm :4000, mail :8765, claude-mcp,
# memtrace :3030). Use -SkipSmoke for an unattended, repeated, or CI run.
#
# T20 also self-skips, and counts the skip as a PASS, when either of these is
# already true:
#   - a live ###1 launcher session exists (a second instance would FIRST-WINS exit)
#   - memtrace / claude-mcp already hold their ports
# So a run without -SkipSmoke is not automatically destructive - but it is not
# something to run casually either.
#
# The remaining suites spawn only hidden scratch processes (dummy sleepers and
# their own tailers) and reap them. T6/T7 auto-SKIP when grepai is not already
# running; they never start it.
#
# Without the `@args` below, -SkipSmoke was silently DROPPED and the full smoke
# ran regardless - the runner had no way to reach the switch it advertises.
#
# mcpw-tao: PowerShell resolves a bare executable name through $env:PATHEXT.
# Hosts that export an unset or truncated PATHEXT (observed: '.CPL') cannot
# resolve 'powershell' even when the binary is on PATH and spawnable, so the
# spawn below died with CommandNotFoundException. Restore the standard
# extension set, then resolve the host through PATH (no hardcoded System32
# path) before invoking it.
$stdExt = @('.COM', '.EXE', '.BAT', '.CMD', '.VBS', '.VBE', '.JS', '.JSE', '.WSF', '.WSH', '.MSC', '.CPL')
$haveExt = @()
if ($env:PATHEXT) { $haveExt = @($env:PATHEXT -split ';' | Where-Object { $_.Trim() }) }
$missExt = @($stdExt | Where-Object { $haveExt -notcontains $_ })
if ($missExt.Count -gt 0) { $env:PATHEXT = (($haveExt + $missExt) -join ';') }

$hostPath = $null
foreach ($n in @('powershell', 'pwsh')) {
    $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($c) { $hostPath = $c.Source; break }
}
if (-not $hostPath) { throw "no PowerShell host found on PATH (tried: powershell, pwsh)" }

& $hostPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'launcher_tests.ps1') @args
exit $LASTEXITCODE
