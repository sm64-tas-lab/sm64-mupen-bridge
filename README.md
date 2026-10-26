# sm64-mupen-bridge

Control plane for **Mupen64-rr-lua** and **Super Mario 64**: Lua file-IPC bridge, PowerShell SDK (`SM64Ctl`), MCP stdio server and TAS toolbox.

It lets you drive Mupen64 programmatically (AI / scripts) without manual interaction with the graphical interface: input injection, deterministic frame-by-frame stepping, N64 RAM read/write, savestates, `.m64` movie export, and computation of STROOP variables.

---

## Architecture

```text
sm64-mupen-bridge/
├── tas/
│   ├── control/
│   │   ├── mupen/
│   │   │   └── bridge.lua           # IPC server running inside Mupen64
│   │   ├── mcp/
│   │   │   ├── sm64_mcp_server.ps1  # stdio JSON-RPC MCP server
│   │   │   └── mcp.json             # MCP registration configuration
│   │   ├── SM64Ctl.psm1             # PowerShell SDK module (high-level commands)
│   │   ├── m64_header_template.bin  # Header template for .m64 export
│   │   ├── USER_GUIDE.md            # Detailed user guide
│   │   ├── HOW_IT_WORKS.md          # Full architecture and protocol
│   │   └── README.md
│   └── tas_lib/                     # TAS scripts, input search, parallel workers
├── outils/
│   ├── geometrie/                   # SM64 geometry / collision tools
│   └── rag/                         # RAG query scripts
├── chat/                            # Local LLM chat interface to drive Mupen
└── README.md
```

---

## Quick start

### 0. Easiest way: INSTALL.bat

Double-click `INSTALL.bat`. It sets everything up: it finds or downloads Mupen64-rr-lua, asks for your own SM64 US ROM, registers the `sm64` MCP server for Claude Code / Gemini CLI (`mcp.json` for other clients), and can install `sm64-tas-cpu` (headless, no emulator) beside it.

### 1. Via the PowerShell SDK (`SM64Ctl.psm1`)

In PowerShell (Windows PowerShell 5.1 or PowerShell 7+):

```powershell
Import-Module .\tas\control\SM64Ctl.psm1 -Force

# Check the detected paths (Mupen, ROM, STROOP)
Get-SM64Paths

# Launch Mupen with the ROM and the bridge
$s = Start-Mupen

# Get Mario's state (pos, speed, action, angle...)
Get-MarioState $s

# Advance 30 frames with the stick up and the A button
Step-Frames $s -Frames 30 -Buttons @{ A = $true; Y = 127 }

# Save and restore a checkpoint in RAM
Save-MemState $s -Slot 1
Load-MemState $s -Slot 1

# Close the emulator cleanly
Stop-Mupen $s
```

### 2. Optional environment variables

If your files are not in the default locations:
- `MUPEN_EXE`: absolute path to `mupen64.exe` (e.g. `C:\path\to\mupen64.exe`)
- `SM64_ROM`: path to your Super Mario 64 ROM (e.g. `Super Mario 64 (USA).z64`)

### 3. MCP registration for Claude / AI agents

Automatic registration in one command:

```powershell
powershell -ExecutionPolicy Bypass -File .\tas\control\mcp\register_mcp.ps1
```

Or manually via the Claude CLI:

```bash
claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<repo_path>\tas\control\mcp\sm64_mcp_server.ps1"
```

Exposed tools: `start_mupen`, `stop_mupen`, `get_state`, `step_frames`, `read_mem`, `write_mem`, `save_memstate`, `load_memstate`, `stroop_vars`, `invoke_action`, `screenshot`.

---

## Detailed documentation

- [tas/control/USER_GUIDE.md](tas/control/USER_GUIDE.md): Step-by-step guide and code recipes.
- [tas/control/HOW_IT_WORKS.md](tas/control/HOW_IT_WORKS.md): Explanation of the JSONL protocol, Lua hooks and technical workarounds (inverted pause, NoVideo/NoAudio stubs).
