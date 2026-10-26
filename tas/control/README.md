# SM64 control layer — READ THIS FIRST (for a Claude Code session)

You (Claude) can drive **all three SM64 tools in this workspace programmatically** through the code in
this folder. Nothing here is committed/pushed and it never edits the `mupen64-rr-lua/`, `STROOP/` or
`sm64/` source trees. There are **two ways** to use it — pick based on how you were started:

## Option A — MCP native tools (preferred if registered)
If a session was started with the `sm64` MCP server registered, you have these tools directly:
`start_mupen, stop_mupen, get_state, step_frames, read_mem, write_mem, save_memstate,
load_memstate, stroop_vars, invoke_action, list_actions, screenshot, sim_example, sim_examples,
sim_bruteforce, paths`. Call `start_mupen` once, then `step_frames`, `get_state`, etc.

To register it (must be done by the user in a NEW session — MCP can't hot-load):
```
claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<this folder>\mcp\sm64_mcp_server.ps1"
```
The MCP server is a thin wrapper over the SDK below and keeps the live mupen session across calls.

## Option B — the PowerShell SDK, via the Bash/PowerShell tool (works right now, no registration)
```powershell
Import-Module '<this folder>\SM64Ctl.psm1' -Force
$s = Start-Mupen                                  # headless mupen + ROM + Task-3 savestate, waits for ready
Get-MarioState $s                                 # full Mario state pack
Step-Frames $s -Frames 20 -Buttons @{ A=$true; Y=127 }   # deterministic frame stepping
Save-MemState $s -Slot 1 ; Load-MemState $s -Slot 1      # in-memory checkpoints (search primitive)
Get-StroopVars $s -IncludeComputed                # every STROOP variable, computed from live RAM
Invoke-SimExample -Name selftest -Release         # the Rust CPU sim (PASS = 5 coins, frame 371)
Stop-Mupen $s
```
Run this from the PowerShell tool (Windows PowerShell 5.1). The absolute path on this machine is
`<repo>/sm64-toolkit/tas/control`.

## What each tool gives you
- **mupen** = the real, cycle-accurate emulator. Full control: read/write RAM at N64 addresses
  (`0x80xxxxxx`), inject controller input per frame, step frames **deterministically** (core is paused
  between calls; replays are bit-identical), in-memory savestates, movies, any menu action.
- **STROOP** = its variable database, headless: `Get-StroopVars` reads the same RAM and computes
  every variable (Mario base `0x8033B170`, Camera `0x8033C520`). `Start-Stroop` also launches the GUI.
- **aitest2 sim** = Rust SM64 physics. `Invoke-SimExample` (CPU, validated) / `Invoke-SimBruteforce`
  (GPU bruteforcers — see the known limitation below).

## Gotchas already solved — don't rediscover them (all handled in the code)
1. `emu.pause()` in mupen Lua is **inverted** (`pause(true)` resumes). The bridge wraps it.
2. Force-killing mupen with TASVideo/TASAudio locks the GPU/sound device and hangs the next launch →
   `Start-Mupen -Headless` (default) swaps to NoVideo/NoAudio stubs. `Restore-MupenConfig` reverts.
3. Loading a savestate via `--st` at startup can pop a blocking dialog → the SDK loads it through the
   bridge with `ignore_warnings=true` instead.
4. If `Start-Mupen` won't become ready or `Step-Frames` times out: kill stray emulators first —
   `Get-Process mupen64 | Stop-Process -Force` — then retry.

## Known limitation
The **GPU bruteforcers crash** (STATUS_ACCESS_VIOLATION at the first dispatch) on this machine's
RTX 5070 — a tool/driver issue on new hardware, not this control layer. The **CPU sim uses the same
physics** and works; use it as the search path. Everything else is verified working.

## More docs
- `USER_GUIDE.md` — human quick-start with copy-paste recipes.
- `HOW_IT_WORKS.md` — full architecture, bridge protocol, command reference, evidence.
