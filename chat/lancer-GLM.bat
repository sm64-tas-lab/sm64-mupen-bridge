@echo off
title GLM-4.7-Flash - llama.cpp

if "%LLAMA_SERVER%"=="" (
  where llama-server.exe >nul 2>&1
  if not errorlevel 1 (
    set "LLAMA_SERVER=llama-server.exe"
  ) else if exist "C:\llama.cpp\llama-server.exe" (
    set "LLAMA_SERVER=C:\llama.cpp\llama-server.exe"
  ) else (
    set "LLAMA_SERVER=llama-server.exe"
  )
)

if "%MODEL_PATH%"=="" (
  if exist "%USERPROFILE%\Downloads\GLM-4.7-Flash-Q4_K_M.gguf" (
    set "MODEL_PATH=%USERPROFILE%\Downloads\GLM-4.7-Flash-Q4_K_M.gguf"
  ) else (
    set "MODEL_PATH=GLM-4.7-Flash-Q4_K_M.gguf"
  )
)

echo Lancement du modele : %MODEL_PATH% ... interface web : http://localhost:8080
echo (Laisse cette fenetre ouverte tant que tu utilises le modele)
echo.
"%LLAMA_SERVER%" ^
  -m "%MODEL_PATH%" ^
  -ngl 99 --cpu-moe -fa on --jinja ^
  --cache-type-k q4_0 --cache-type-v q4_0 ^
  -c 131072 ^
  --host 127.0.0.1 --port 8080
pause
