@echo off
:: Double-click wrapper (###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.bat) for ###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1
:: Runs it via pwsh.exe (fallback powershell.exe) with -ExecutionPolicy Bypass
:: so it executes even if .ps1 has no Explorer association / Restricted policy
:: (a plain double-click of the .ps1 can silently close under Restricted policy).
setlocal
set "SCRIPT=%~dp0###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1"
where pwsh.exe >nul 2>nul && (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
) || (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
)
endlocal
