# tests/run_launcher_tests.ps1
# Convenience runner for the launcher test suite.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_launcher_tests.ps1
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'launcher_tests.ps1')
exit $LASTEXITCODE
