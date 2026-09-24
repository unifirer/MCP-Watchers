# tests/mcpw_ymo2_single_starter.tests.ps1
# Bead mcpw-ymo.2 (parent epic mcpw-ymo): :8765 must have EXACTLY ONE supervised
# starter.
#
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/mcpw_ymo2_single_starter.tests.ps1
#
# WHY THIS EXISTS. Between 2026-09-15 and 09-22 the mail backend logged 9,657
# relaunches / 4,624 duplicate reaps because TWO starters coexisted for :8765:
#   (1) a mail start job ($mailMcpJobScript) that launched run_server.cmd
#       immediately, and
#   (2) Start-BackendSupervisor -Name 'mail' -Port 8765, which sleeps 30s before
#       its first probe and then launched a SECOND daemon on the same port when a
#       slow bind looked like "down".
# The start job was removed by mcpw-ymo.2, leaving the supervisor as the single
# owner (its relaunch path is Start-MailBackend; its duplicate reaper is the
# safety net). This suite is the SOURCE-LEVEL guard - like
# tests/test_launcher_autostart.py is for :8787 - and it pins the ACTUAL starter
# call sites, not a bare word, so a reintroduced second starter fails it.
#
# The behavioural half of the same invariant (the surviving supervisor's reaper
# never kills a healthy singleton) lives in
# tests/mcpw_ymo5_single_owner_reaper.tests.ps1 - do not duplicate it here.
#
# Pester 3.4.0 pinned (v3 positional `Should Match` / `Should Be` idiom). A
# *.tests.ps1 that itself calls Invoke-Pester loops forever under Pester 3.x
# rediscovery, so the run at the bottom is guarded by *_TEST_RAN.

Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
# MCPW_YMO2_LAUNCHER exists only so a scratch COPY of the launcher (with a second
# starter re-added) can be run through this suite to prove the suite is not
# vacuous. Normal runs use the real launcher.
$launcher = if ($env:MCPW_YMO2_LAUNCHER) {
    $env:MCPW_YMO2_LAUNCHER
} else {
    Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'
}
$src = Get-Content -LiteralPath $launcher -Raw

# Call-site counting must IGNORE COMMENTS: the SINGLE-OWNER INVARIANT / history
# comments quote the very text being counted (`Start-BackendSupervisor -Name
# 'mail' -Port 8765`), so a raw -match would count prose as a starter. $code is
# the launcher with whole-line comments removed; $src is kept for assertions
# that the comment block itself still exists.
$code = (($src -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"

# The mail daemon is launched by `cmd.exe /c run_server.cmd`. After mcpw-ymo.2
# there is exactly ONE such Start-Process call in the whole launcher: inside
# Start-MailBackend, which only the supervisor's dispatch reaches. Counting this
# literal is the sharpest "a second starter came back" tripwire, because a
# re-added start job would necessarily add a second cmd.exe launch.
$cmdExeLaunches = ([regex]::Matches($code, 'Start-Process -FilePath "cmd\.exe"')).Count
$startMailBackendDefs = ([regex]::Matches($code, [regex]::Escape('function Start-MailBackend {'))).Count

# Strongest anti-reintroduction check: EVERY reference to the mail launcher
# script (run_server.cmd) must live inside the single Start-MailBackend body.
# A second starter of ANY shape - not just the removed cmd.exe start job - has
# to resolve or launch run_server.cmd somewhere else, and would fail this.
$smbStart = $code.IndexOf('function Start-MailBackend {')
$smbEnd = if ($smbStart -ge 0) { $code.IndexOf("`n    function ", $smbStart + 1) } else { -1 }
$smbBody = if ($smbStart -ge 0 -and $smbEnd -gt $smbStart) { $code.Substring($smbStart, $smbEnd - $smbStart) } else { '' }
$runServerTotal = ([regex]::Matches($code, [regex]::Escape('run_server.cmd'))).Count
$runServerInSmb = ([regex]::Matches($smbBody, [regex]::Escape('run_server.cmd'))).Count

Describe 'mcpw-ymo.2: :8765 has exactly one supervised starter' {

    It 'registers exactly ONE supervised starter for :8765' {
        $m = [regex]::Matches($code, "Start-BackendSupervisor\s+-Name\s+'mail'\s+-Port\s+8765")
        $m.Count | Should Be 1
    }

    It 'the removed second starter (the mail start job) is gone' {
        # Each identifier below is specific to the deleted start job; the
        # history comment may still NAME it, but nothing may DEFINE or BIND it.
        $code | Should Not Match ([regex]::Escape('$mailMcpJobScript = {'))
        $code | Should Not Match ([regex]::Escape('$script:mailMcpStartJob'))
        $code | Should Not Match ([regex]::Escape('Start-ThreadJob -ScriptBlock $mailMcpJobScript'))
        $code | Should Not Match ([regex]::Escape('Start-Job -ScriptBlock $mailMcpJobScript'))
    }

    It 'exactly one mail-launch primitive remains' {
        $cmdExeLaunches | Should Be 1
        $startMailBackendDefs | Should Be 1
    }

    It 'that one launcher is reached only from the supervisor dispatch' {
        $code | Should Match ([regex]::Escape("if (`$BackendName -eq 'mail') { `$newPid = Start-MailBackend }"))
    }

    It 'every run_server.cmd reference lives inside the single Start-MailBackend' {
        ($runServerInSmb -gt 0) | Should Be $true
        $runServerInSmb | Should Be $runServerTotal
    }

    It 'keeps the duplicate reaper and the single-owner invariant (anti-no-op)' {
        $src | Should Match 'SINGLE-OWNER INVARIANT'
        $code | Should Match ([regex]::Escape('if (($supLoop % 4) -eq 0) {'))
        $code | Should Match ([regex]::Escape('$script:mailSupJob = Start-BackendSupervisor -Name ''mail'' -Port 8765'))
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard with
# an env var so the rediscovery child skips the second Invoke-Pester. -Path keeps
# the run scoped to THIS file (no cross-file contamination).
if (-not $env:MCPW_YMO2_STARTER_TEST_RAN) {
    $env:MCPW_YMO2_STARTER_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
