# SM64 TAS Toolkit & Mupen Bridge: local LLM / agent driving Mupen via MCP

## Contents

- `tas/control/mupen/bridge.lua`: file-IPC bridge running directly inside Mupen64-rr-lua.
- `tas/control/SM64Ctl.psm1`: PowerShell module (navigation, perception, frame stepping, savestates, .m64 export).
- `tas/control/mcp/sm64_mcp_server.ps1`: stdio JSON-RPC MCP server exposing the tools to Claude or any AI agent.
- `tas/control/mcp/mcp.json`: example MCP registration.
- `tas/control/m64_header_template.bin`: `.m64` movie header template.
- `tas/control/README.md`, `HOW_IT_WORKS.md`, `USER_GUIDE.md`: full reference documentation.
- `tas_lib/`: TAS library (milestone management, parallel search, SBLJ/BLJ/replay scripts).
- `chat/`: local interactive chat interface (GLM / LLM) driving Mupen.
- `outils/geometrie/`: collision inspection and mapping.
- `outils/rag/`: RAG database queries.

## External dependencies

- **Mupen64-rr-lua**: the `mupen64.exe` executable (e.g. `C:\path\to\mupen64-rr-lua\build\out\mupen64.exe`, or set the `MUPEN_EXE` variable).
- **Super Mario 64 ROM**: `Super Mario 64 (USA).z64` (detected automatically, or set the `SM64_ROM` variable).
- Optional: local llama.cpp / GGUF server if you use the standalone chat mode.

## Quick start

0. Easiest: double-click `INSTALL.bat`. It finds or downloads Mupen64-rr-lua, asks for your own SM64 US ROM, registers the `sm64` MCP server for Claude Code / Gemini CLI (`mcp.json` for other clients), and can install `sm64-tas-cpu` (headless, no emulator) beside it.
1. In PowerShell:
   ```powershell
   Import-Module .\tas\control\SM64Ctl.psm1 -Force
   Get-SM64Paths
   ```
2. Or via MCP for Claude:
   ```bash
   claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<path>\tas\control\mcp\sm64_mcp_server.ps1"
   ```
