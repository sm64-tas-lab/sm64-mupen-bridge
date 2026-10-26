@echo off
chcp 65001 >nul
title CHAT SM64 - chat with the model
cd /d "%~dp0"
echo Check that llama-server (lancer-GLM.bat) is running...
echo.
python sm64_chat.py
echo.
pause
