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

# Define the REAL production function in this scope so every It block sees it.
. ([scriptblock]::Create((Get-LauncherFunctionText -Name 'Test-PortHeldByLauncherDaemon')))

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
