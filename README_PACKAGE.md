# SM64 TAS Toolkit — local LLM driving Mupen via MCP

CONTENTS (the CODE + instructions; NOT the ROM/emulator/savestates):

  tas/control/SM64Ctl.psm1            <- THE PowerShell module (all logic: goto navigation, collect,
                                         grab_star, open_chest, perception scan/walls/floors, chase,
                                         reliability: global_timer guard, anti-desync reads/retry...)
  tas/control/m64_header_template.bin <- .m64 header (movie export)
  tas/control/mcp/sm64_mcp_server.ps1 <- MCP SERVER (JSON-RPC stdio) exposing the tools to the model
  tas/control/mcp/mcp.json            <- example MCP server registration (adapt the path!)
  tas/control/mupen/bridge.lua        <- emulator-side bridge (load it in mupen64-rr-lua)
  tas/control/README.md, HOW_IT_WORKS.md, USER_GUIDE.md  <- project docs
  chat/sm64_chat.py                   <- interactive CHAT: the local model (GLM) drives Mupen through MCP
  chat/OUTILS_SM64.md                 <- INSTRUCTIONS read by the model (tool guide, golden rules)
  chat/CHAT-sm64.bat, chat/lancer-GLM.bat  <- launchers (if present)

EXTERNAL DEPENDENCIES (NOT included, too heavy / machine-specific):
  - mupen64-rr-lua (emulator build, mupen64.exe)
  - the Super-Mario-64.z64 ROM (+ the "30th Anniversary" romhack)
  - the tasks' .st savestates (Task 3/4/5, goomba, etc.)
  - llama.cpp + the GGUF model (GLM-4.7-Flash) for the local server on 127.0.0.1:8080

PATHS TO ADAPT when moving the folder:
  - mcp/mcp.json         : -File points to your sm64_mcp_server.ps1
  - chat/sm64_chat.py    : PROJECT constant (mupen-for-claude root) and SAVEST (default savestate)
  - the module finds mupen64.exe / the ROM through paths relative to ...\mupen-for-claude (see the top of the .psm1)

QUICK START:
  1) start llama-server (lancer-GLM.bat), wait for "model loaded"
  2) python chat/sm64_chat.py   (the chat starts the MCP server itself and talks to the model)
  3) ask the model: "start task 4, open the 4 chests, then grab the star"
