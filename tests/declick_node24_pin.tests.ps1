# tests/declick_node24_pin.tests.ps1
# Pester 3.4.0 (pinned). Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/declick_node24_pin.tests.ps1
#
# declick 0.7.2 declares engines.node ">=24": its sqlite engine uses node:sqlite.
# Two faults were fixed on 2026-09-19.
#
#   1. `declick` was not on PATH. J:\Programs\npm-global (the npm prefix) held
#      node_modules\declick but no bin shim, so `command -v declick` returned
#      nothing. Fix: ~\.local\bin\declick and declick.cmd pin Node 24 by
#      absolute path, because declick exposes no env override for the runtime.
#
#   2. All 31 generated adapter launchers in ~\.declick\bin called bare `node`.
#      WorkBuddy prepends its managed Node 22.22.2 runtime to PATH, so every
#      launcher answered:
#        {"ok":false,"error":"declick needs Node 24 or newer (found v22.22.2);
#         the sqlite engine uses node:sqlite","exit":1}
#      Fix: dev_tools/repin_declick_node.py rewrites them to the Node 24 path.
#
# This suite guards both fixes. It also guards the re-pin tool itself, because
# `declick add` and `declick build` regenerate launchers with bare `node`.
Import-Module Pester -RequiredVersion 3.4.0 -Force

$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$declickBin = Join-Path $env:USERPROFILE '.declick\bin'
$shimDir    = Join-Path $env:USERPROFILE '.local\bin'
$repinTool  = Join-Path $repoRoot 'dev_tools\repin_declick_node.py'
$node24     = 'C:\nvm4w\nodejs\node.exe'
$marker     = 'declick launcher'

# declick's own launchers carry this marker. A foreign file dropped in the same
# directory is not ours to police.
function Get-DeclickLaunchers {
    Get-ChildItem -LiteralPath $declickBin -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '' -or $_.Extension -eq '.cmd' -or $_.Extension -eq '.bat' } |
        Where-Object {
            $raw = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
            $raw -and $raw.Contains($marker)
        }
}

Describe 'declick Node 24 pinning' {

    It 'installs the declick shim in ~\.local\bin, in both shell forms' {
        (Test-Path -LiteralPath (Join-Path $shimDir 'declick'))     | Should Be $true
        (Test-Path -LiteralPath (Join-Path $shimDir 'declick.cmd')) | Should Be $true
    }

    It 'the bash shim execs the Node 24 runtime by absolute path, not bare node' {
        $raw = Get-Content -LiteralPath (Join-Path $shimDir 'declick') -Raw
        $raw | Should Match 'C:/nvm4w/nodejs/node\.exe'
        # A bare `node` would pick up the managed Node 22 and fail the gate.
        $raw | Should Not Match '(?m)^exec node '
    }

    It 'the .cmd shim calls the Node 24 runtime by absolute path, not bare node' {
        $raw = Get-Content -LiteralPath (Join-Path $shimDir 'declick.cmd') -Raw
        $raw | Should Match 'C:\\nvm4w\\nodejs\\node\.exe'
        $raw | Should Not Match '(?m)^node '
    }

    It 'declick resolves on PATH and reports a Node 24 or newer runtime' {
        $cmd = Get-Command declick -ErrorAction SilentlyContinue
        $cmd | Should Not BeNullOrEmpty
        $json = & (Join-Path $shimDir 'declick.cmd') version 2>&1 | Out-String
        $json | Should Match '"ok":true'
        $parsed = $json | ConvertFrom-Json
        $major = [int]($parsed.data.node -split '\.')[0]
        $major | Should BeGreaterThan 23
    }

    It 'every declick launcher pins Node 24 and none calls bare node' {
        $launchers = @(Get-DeclickLaunchers)
        # Guard against a silent no-op: an empty set would pass vacuously.
        $launchers.Count | Should BeGreaterThan 0

        $bare = @()
        foreach ($f in $launchers) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw
            if ($f.Extension -eq '') {
                if ($raw -match '(?m)^exec node ') { $bare += $f.Name }
                elseif ($raw -notmatch [regex]::Escape('C:/nvm4w/nodejs/node.exe')) { $bare += $f.Name }
            } else {
                if ($raw -match '(?m)^node ') { $bare += $f.Name }
                elseif ($raw -notmatch [regex]::Escape($node24)) { $bare += $f.Name }
            }
        }
        ($bare -join ', ') | Should BeNullOrEmpty
    }

    It 'a representative launcher runs without hitting the Node version gate' {
        # Must be the .cmd form: PowerShell refuses to execute the extensionless
        # bash launcher ("cannot run a document in the middle of a pipeline").
        $target = Join-Path $declickBin 'graphiti.cmd'
        if (-not (Test-Path -LiteralPath $target)) {
            $target = (Get-DeclickLaunchers | Where-Object { $_.Extension -eq '.cmd' } | Select-Object -First 1).FullName
        }
        $target | Should Not BeNullOrEmpty
        $out = & $target --help 2>&1 | Out-String
        $out | Should Not Match 'needs Node 24'
        $out | Should Match '"ok":true'
    }

    It 'the re-pin tool reports every launcher already pinned (idempotent)' {
        (Test-Path -LiteralPath $repinTool) | Should Be $true
        & python $repinTool --check 2>&1 | Out-Null
        # 0 = nothing left to pin. 1 = an unpinned launcher survived, which means
        # `declick add` or `declick build` regenerated one behind our back.
        $LASTEXITCODE | Should Be 0
    }
}

if (-not $env:DECLICK_PIN_TEST_RAN) {
    $env:DECLICK_PIN_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
