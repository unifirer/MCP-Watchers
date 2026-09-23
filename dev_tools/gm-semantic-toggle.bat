@echo off
REM Thin shim for dev_tools\gm-semantic-toggle.ps1 so the switch can be flipped
REM from a plain cmd prompt or by double-clicking. Bead mcpw-b81.3.
REM Usage: gm-semantic-toggle.bat -Mode on|off|toggle|status [-Force]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gm-semantic-toggle.ps1" %*
exit /b %ERRORLEVEL%
