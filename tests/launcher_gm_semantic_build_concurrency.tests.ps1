# tests/launcher_gm_semantic_build_concurrency.tests.ps1
# Tests proving the INLINE Invoke-GmSemanticBuild (consolidated from the deleted
# ###5 into ###1, 2026-08-27) allows at most ONE concurrent gm semantic build,
# via the machine-wide mutex Global\VAD_GmSemanticBuild_<key>.
#
# Two complementary checks:
#   1. STATIC: the launcher acquires the named mutex with WaitOne(0) (fail-fast,
#      never queues) and releases it in a finally block.
#   2. EXECUTION: the named mutex actually serializes two concurrent processes
#      when they both try to acquire the identical name — proving the contract.
#
# LOAD SENSITIVITY (observed 2026-09-19): check 2 spawns two real processes and
# races them on the mutex, so it depends on scheduling. It failed once inside a
# 35-suite sweep and passed twice when this file ran on its own. Re-run it alone
# before believing a failure — under a loaded box the loser can miss the window
# for reasons that have nothing to do with the mutex contract.
#
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_gm_semantic_build_concurrency.tests.ps1

# Pin Pester 3.4.0 (this file uses the v3 positional `Should Match` idiom).
# Without this, a newer Pester (6.x) auto-loads and rejects the syntax.
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop

$repo     = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

Describe 'gm semantic build concurrency guard (inline)' {

    It 'acquires the named build mutex with fail-fast WaitOne(0) and releases in finally (static)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        # Mutex name contract.
        $c | Should Match 'Global\\VAD_GmSemanticBuild'
        # Fail-fast acquire (WaitOne(0)) and a held flag.
        $c | Should Match 'WaitOne\(0\)'
        $c | Should Match 'buildLockHeld'
        # Released in a finally block (so a contested/early-exit build never orphans it).
        $c | Should Match 'finally'
        $c | Should Match 'ReleaseMutex'
        # Skips (does not queue) when the mutex is already held.
        $c | Should Match 'already running'
    }

    It 'named mutex serializes two concurrent processes (execution)' {
        $mutexName = 'Global\VAD_GmSemanticBuild_CONC_TEST_' + [guid]::NewGuid().ToString('N')
        $scriptBlock = {
            param($Name)
            $mtx = New-Object System.Threading.Mutex($false, $Name)
            $held = $mtx.WaitOne(0)
            if ($held) {
                try { Start-Sleep -Seconds 2; 'ACQUIRED' }
                finally { try { $mtx.ReleaseMutex() } catch {} try { $mtx.Dispose() } catch {} }
            } else { 'SKIPPED' }
        }
        # Instance A acquires; Instance B (launched while A holds it) must skip.
        $jobA = Start-Job -ScriptBlock $scriptBlock -ArgumentList $mutexName
        Start-Sleep -Milliseconds 500
        $jobB = Start-Job -ScriptBlock $scriptBlock -ArgumentList $mutexName
        $bResult = $jobB | Wait-Job | Receive-Job
        $aResult = $jobA | Wait-Job -Timeout 10 | Receive-Job
        @($aResult) | Should Match 'ACQUIRED'
        @($bResult) | Should Match 'SKIPPED'
        $jobA, $jobB | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

if (-not $env:GM_SEM_CONC_TEST_RAN) {
    $env:GM_SEM_CONC_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
