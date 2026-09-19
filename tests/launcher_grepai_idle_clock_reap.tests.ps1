# mcpw-0k7 — regression test for the grepai idle-TTL reap deadlock.
#
# The supervisor reaps the watcher when Get-GrepaiIdleMinutes exceeds the TTL.
# A watcher that has just been spawned still carries the PREVIOUS instance's
# last_index_time while it runs its initial scan, so the reaper judges it
# against a clock it has not had a chance to advance. It gets killed about a
# minute after start, the pane heals, the scan restarts, and the clock never
# advances — a bootstrap deadlock that survives a perfectly healthy backend.
#
# These tests pin the behaviour without needing a real outage or a running
# grepai: they call the real helpers from Modules\watcher_job_helpers.ps1
# against synthetic configs in a temp directory.
#
# Companion beads: mcpw-0k7 (root cause), mcpw-3si (proposed fix).

BeforeAll {
    $script:Helpers = Join-Path $PSScriptRoot '..\Modules\watcher_job_helpers.ps1'
    if (Test-Path -LiteralPath $script:Helpers) { . $script:Helpers }

    $script:ProbeDir = Join-Path ([System.IO.Path]::GetTempPath()) "mcpw-0k7-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path (Join-Path $script:ProbeDir 'logs') -Force | Out-Null

    function New-StaleConfig {
        param([int]$HoursAgo = 9)
        $stamp = (Get-Date).AddHours(-$HoursAgo).ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz')
        $path = Join-Path $script:ProbeDir 'config.yaml'
        @"
version: 1
watch:
    debounce_ms: 500
    last_index_time: $stamp
"@ | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }

    function New-FreshConfig {
        param([int]$MinutesAgo = 1)
        $stamp = (Get-Date).AddMinutes(-$MinutesAgo).ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz')
        $path = Join-Path $script:ProbeDir 'config-fresh.yaml'
        @"
version: 1
watch:
    debounce_ms: 500
    last_index_time: $stamp
"@ | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }
}

AfterAll {
    if ($script:ProbeDir -and (Test-Path -LiteralPath $script:ProbeDir)) {
        Remove-Item -LiteralPath $script:ProbeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'grepai idle clock (mcpw-0k7)' {

    It 'helpers are available' {
        (Get-Command Get-GrepaiIdleMinutes -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Get-GrepaiIdleTimeoutMinutes -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'defaults the TTL to 20 minutes when idle_timeout_minutes is absent' {
        # The key is absent from the real .grepai\config.yaml, so 20 is what
        # actually governs production. Any change here changes the reap rate.
        Get-GrepaiIdleTimeoutMinutes -ConfigPath (New-StaleConfig) | Should -Be 20
    }

    It 'does NOT reap a freshly spawned watcher whose config clock is stale' {
        # mcpw-3si (2026-09-20): inverted. This used to be a CHARACTERIZATION
        # TEST asserting the BUG WAS PRESENT - it reproduced the live outage,
        # where 540 minutes were measured against a 20 minute TTL for a watcher
        # that had started seconds ago, because last_index_time still carried
        # the DEAD instance's stamp.
        #
        # Get-GrepaiIdleMinutesFromConfig now returns $null when
        # last_index_time predates Get-GrepaiWatchStartTime, so a stamp left by
        # a dead instance can no longer arm a reap: Get-GrepaiIdleMinutes
        # reports -1 (UNKNOWN = do not reap) instead of an inherited age.
        # Measured on landing: -1, not 540.
        $idle = Get-GrepaiIdleMinutes -LogDir (Join-Path $script:ProbeDir 'logs') -ConfigPath (New-StaleConfig)
        $ttl  = Get-GrepaiIdleTimeoutMinutes -ConfigPath (New-StaleConfig)
        $idle | Should -BeLessThan $ttl
    }

    It 'does NOT reap once the clock is fresh' {
        # Control: the healthy case observed after the 06:09 NZT self-heal.
        $idle = Get-GrepaiIdleMinutes -LogDir (Join-Path $script:ProbeDir 'logs') -ConfigPath (New-FreshConfig)
        $ttl  = Get-GrepaiIdleTimeoutMinutes -ConfigPath (New-FreshConfig)
        $idle | Should -BeLessThan $ttl
    }

    It 'the log clock reports UNKNOWN rather than a stale age when there is no log' {
        # VAD-1ak guards the log clock but not the config clock, which is why
        # the config clock alone is enough to trip the TTL.
        Get-GrepaiIdleMinutesFromLog -LogDir (Join-Path $script:ProbeDir 'logs') | Should -Be -1
    }
}
