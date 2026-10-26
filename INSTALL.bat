@echo off
rem sm64-mupen-bridge for AIs: Mupen64-rr-lua driven live through MCP (and, optionally, sm64-tas-cpu headless).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
