# SM64 TAS Toolkit & Mupen Bridge — local LLM / Agent driving Mupen via MCP

## Contenu

- `tas/control/mupen/bridge.lua` : pont file-IPC exécuté directement dans Mupen64-rr-lua.
- `tas/control/SM64Ctl.psm1` : module PowerShell (navigation, perception, frame stepping, savestates, export .m64).
- `tas/control/mcp/sm64_mcp_server.ps1` : serveur MCP JSON-RPC stdio exposant les outils à Claude ou tout agent IA.
- `tas/control/mcp/mcp.json` : exemple d'enregistrement MCP.
- `tas/control/m64_header_template.bin` : modèle d'en-tête de film `.m64`.
- `tas/control/README.md`, `HOW_IT_WORKS.md`, `USER_GUIDE.md` : documentation complète de référence.
- `tas_lib/` : bibliothèque TAS (gestion de jalons, recherche parallèle, scripts SBLJ/BLJ/rejeu).
- `chat/` : interface de dialogue interactive locale (GLM / LLM) pilotant Mupen.
- `outils/geometrie/` : inspection de la collision et cartographie.
- `outils/rag/` : interrogation de base RAG.

## Dépendances externes

- **Mupen64-rr-lua** : exécutable `mupen64.exe` (ex: `D:\mupen\mupen64-rr-lua\build\out\mupen64.exe` ou via variable `MUPEN_EXE`).
- **ROM Super Mario 64** : `Super Mario 64 (USA).z64` (détecté automatiquement ou via variable `SM64_ROM`).
- Optionnel : serveur local llama.cpp / GGUF si utilisation du mode chat autonome.

## Démarrage rapide

1. Dans PowerShell :
   ```powershell
   Import-Module .\tas\control\SM64Ctl.psm1 -Force
   Get-SM64Paths
   ```
2. Ou via MCP pour Claude :
   ```bash
   claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<chemin>\tas\control\mcp\sm64_mcp_server.ps1"
   ```
