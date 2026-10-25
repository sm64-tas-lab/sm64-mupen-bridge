@echo off
chcp 65001 >nul
title CHAT SM64 - discute avec le modele
cd /d "%~dp0"
echo Verifie que llama-server (lancer-Coder.bat) est allume...
echo.
python sm64_chat.py
echo.
pause
