# sm64-mupen-bridge: Super Mario 64 in Mupen64-rr-lua, driven by an AI

An MCP server (`sm64`) that drives the real emulator, Mupen64-rr-lua, through a Lua bridge: start Mupen on a
savestate, read Mario's state and the objects from RAM, step frames with any input, navigate (goto / move / collect /
grab_star), in-memory savestates to branch, STROOP variables, screenshots, export the run as a `.m64` and replay it
on a fresh Mupen to prove it. The core is paused between calls, so everything is deterministic.

For thousands of tries per second without the emulator, use its companion **sm64-tas-cpu** (the same game headless,
bit-exact with Mupen, MCP server `sm64-headless`).

## Install

The simplest way: give your AI the skill of sm64-tas-cpu (`skill/sm64/SKILL.md`): it sets both repos up.

By hand (Windows 10/11 x64):

```
git clone https://github.com/sm64-tas-lab/sm64-mupen-bridge
sm64-mupen-bridge\INSTALL.bat
```

`INSTALL.bat` finds Mupen64-rr-lua or downloads the official release into `bin\`, asks for **your own** Super Mario
64 (USA) ROM (only its path is kept, in `config.json`), STROOP optionally, registers the `sm64` MCP server for
Claude Code and Gemini CLI (`mcp.json` for other clients), and can install sm64-tas-cpu beside it. Restart your AI
client afterwards so it loads the server.

## The tools

| Tool | What it does |
|---|---|
| `start_mupen`, `stop_mupen`, `paths` | launch Mupen on a `.st` (once), stop it, show what was found |
| `get_state`, `scan`, `read_mem`, `write_mem`, `stroop_vars`, `screenshot` | read the game |
| `step_frames` | N frames with a controller input |
| `goto`, `move`, `collect`, `grab_star` | high-level navigation |
| `save_memstate`, `load_memstate` | in-memory checkpoints (the run recording follows them) |
| `export_run`, `reset_run`, `export_m64`, `octagon_clamp` | the run as a `.m64` (+ `.st`), a real-controller stick clamp |
| `replay_movie` | replay an exported movie on a fresh Mupen and return the final state |
| `invoke_action`, `list_actions` | any Mupen menu action |

The same functions are available from PowerShell: `Import-Module .\tas\control\SM64Ctl.psm1`, then
`$s = Start-Mupen -Savestate my.st; Step-Frames $s -Frames 30 -Buttons @{Y=127}; Get-MarioState $s; Stop-Mupen $s`.
How it works inside: [tas/control/HOW_IT_WORKS.md](tas/control/HOW_IT_WORKS.md).

## Files

| Path | Role |
|---|---|
| `tas/control/mcp/sm64_mcp_server.ps1` | the MCP server |
| `tas/control/SM64Ctl.psm1` | the PowerShell SDK (Mupen control, state, navigation, STROOP variables, .m64 export) |
| `tas/control/mupen/bridge.lua` | the Lua server running inside Mupen |
| `tas/control/m64_header_template.bin` | the .m64 header template |
| `install.ps1`, `INSTALL.bat` | the installer |
