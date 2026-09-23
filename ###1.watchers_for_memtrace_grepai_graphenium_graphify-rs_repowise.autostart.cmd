@echo off
:: ---------------------------------------------------------------------------
:: Logon / autostart entry point for the ###1 watchers launcher.
:: Bead mcpw-anb: "after a reboot, :8787 is LISTENING with no manual step".
::
:: SINGLE OWNER (option A). The ###1 launcher is the ONE supervised starter for
:: the headroom :8787 proxy. It registers, in its own source:
::     Start-BackendSupervisor -Name 'headroom-proxy' -Port 8787
::                             -Health 'http://127.0.0.1:8787/livez'
:: NOTHING ELSE may start :8787. A standalone proxy autostart entry would put
:: two starters on one singleton -- the memtrace flap / mcpw-ymo shape
:: (9,657 mail relaunches, 4,624 duplicate reaps). So the logon trigger is
:: given to the LAUNCHER, not to the proxy. The same rule already holds on this
:: box for every other launcher-owned port: the \MCPAgentMail8765,
:: \ClaudeMCPServer8080 and \GraphitiProxy8004 logon tasks are all Disabled.
::
:: Registered on this machine as:
::     HKCU\Software\Microsoft\Windows\CurrentVersion\Run
::     MCP-Watchers-Launcher = "<repo>\###1...autostart.cmd"
::
:: The "cd /d" is REQUIRED, not cosmetic: the launcher watches the CURRENT
:: WORKING DIRECTORY (README, "Workspace root"), and a Run entry inherits an
:: unpredictable cwd, which would make the launcher open its pane grid and run
:: its watchers against the WRONG repository.
::
:: Re-entrancy is safe: the launcher is single-instance (named mutex plus a lock
:: file, keyed per workspace), so a logon start followed by a manual
:: double-click exits silently instead of starting a second stack.
:: ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"
call "%~dp0###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.bat"
endlocal
