@echo off
title GLM-4.7-Flash - llama.cpp
if "%MODEL_PATH%"=="" set "MODEL_PATH=C:\Users\hugo2\Downloads\GLM-4.7-Flash-Q4_K_M.gguf"
echo Lancement de GLM-4.7-Flash (MoE deepseek2)... interface web : http://localhost:8080
echo (Laisse cette fenetre ouverte tant que tu utilises le modele)
echo.
"C:\llama.cpp\llama-server.exe" ^
  -m %MODEL_PATH% ^
  -ngl 99 --cpu-moe -fa on --jinja ^
  --cache-type-k q4_0 --cache-type-v q4_0 ^
  -c 131072 ^
  --host 127.0.0.1 --port 8080
pause
