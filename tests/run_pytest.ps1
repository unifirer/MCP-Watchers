<#
.SYNOPSIS
Runs the MCP-Watchers pytest suite with an interpreter that actually has pytest.

.DESCRIPTION
mcpw-3nq: pytest 8.4.2 is installed in exactly ONE interpreter on this machine.
`python`, `python3` and `py` all resolve to interpreters without pytest, so the
suite looks unrunnable and the failure wastes a whole cycle. This runner probes
candidate interpreters for `import pytest`, uses the first one that answers, and
runs pytest from this script's own directory with the bare `-c pytest.ini` that
tests/pytest.ini requires (a path like tests/pytest.ini double-resolves to
tests/tests/pytest.ini and fails with FileNotFoundError).

Any extra arguments are forwarded to pytest:
    .\run_pytest.ps1 -q test_git_slash_branch_ref.py

.EXAMPLE
Double-click this file in Explorer to run the whole suite and keep the window
open afterwards.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $PytestArgs
)

$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-PythonCandidate {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        'C:\Python314\python.exe',
        'C:\Python313\python.exe'
    )) {
        if ($p) { $paths.Add($p) }
    }

    # Managed/embedded interpreters and anything else discoverable on disk.
    foreach ($root in @(
        (Join-Path $env:USERPROFILE '.workbuddy-ai\binaries\python\versions'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python')
    )) {
        if ($root -and (Test-Path -LiteralPath $root)) {
            Get-ChildItem -LiteralPath $root -Filter 'python.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                ForEach-Object { $paths.Add($_.FullName) }
        }
    }

    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $paths.Add($cmd.Source) }
    }

    foreach ($p in $paths) {
        if (-not $p) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (-not $seen.Add($p)) { continue }
        $p
    }
}

function Test-PytestAvailable {
    param([string] $Python)

    try {
        $out = & $Python -c 'import pytest, sys; sys.stdout.write(pytest.__version__)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return $out.Trim() }
    } catch { }
    return $null
}

$chosen = $null
$chosenVersion = $null
$tried = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in (Get-PythonCandidate)) {
    $tried.Add($candidate)
    $ver = Test-PytestAvailable -Python $candidate
    if ($ver) { $chosen = $candidate; $chosenVersion = $ver; break }
}

if (-not $chosen) {
    Write-Host ""
    Write-Host "No interpreter with pytest found. Probed $($tried.Count):" -ForegroundColor Red
    foreach ($t in $tried) { Write-Host "  - $t" }
    Write-Host ""
    Write-Host "Install pytest into one of them, e.g.  <python> -m pip install pytest" -ForegroundColor Yellow
    exit 2
}

Write-Host "pytest $chosenVersion via $chosen" -ForegroundColor DarkGray
Push-Location -LiteralPath $testsDir
try {
    & $chosen -m pytest -c pytest.ini @PytestArgs
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

# Double-click support: keep the window open when Explorer launched us, so the
# operator can read the result. A console invocation just exits with the code.
$parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
$parentName = if ($parent) { (Get-Process -Id $parent -ErrorAction SilentlyContinue).ProcessName } else { $null }
if ($parentName -eq 'explorer') {
    Write-Host ""
    [void](Read-Host "Exit code $code - press Enter to close")
}

exit $code
