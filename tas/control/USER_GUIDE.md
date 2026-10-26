# User guide — driving mupen, STROOP and the sim

Copy-paste practical guide. The detailed technical doc is in `HOW_IT_WORKS.md`.
Everything lives in `tas/control/`.

## 0. Start (one line to remember)

Open **PowerShell** and load the SDK:

```powershell
Import-Module '<repo>\sm64-toolkit\tas\control\SM64Ctl.psm1' -Force
```

Check that the 3 tools are found:

```powershell
Get-SM64Paths        # MupenExists / StroopExists / SimExists must be True
```

## 1. mupen — the emulator

```powershell
$s = Start-Mupen                       # starts mupen (headless), loads the ROM + Task-3 savestate, waits for "ready"
Get-MarioState $s                      # Mario's full state (position, speed, action, coins, yaw, floor/ceiling, rng...)

# advance frames while holding a controller input:
Step-Frames $s -Frames 20 -Buttons @{ A=$true; Y=127 }   # 20 frames, A pressed + stick up
#   buttons: A B Z R L start Cup Cdown Cleft Cright up down left right  (= $true/$false)
#   stick  : X, Y  (integers -128..127)

# in-memory checkpoints (fast, to test several branches):
Save-MemState $s -Slot 1               # save the state
Load-MemState $s -Slot 1               # restore it (exact)

# read/write RAM directly (N64 addresses 0x80xxxxxx):
Read-Mem  $s -Addr 0x8033B170 -Type u32
Write-Mem $s -Addr 0x8033B1AE -Value 2176 -Type s16     # e.g. health

Stop-Mupen $s                          # close cleanly
```

**Example: testing two directions from the same point**
```powershell
Save-MemState $s -Slot 1
$a = Step-Frames $s -Frames 20 -Buttons @{ X=127 }      # right
Load-MemState $s -Slot 1
$b = Step-Frames $s -Frames 20 -Buttons @{ X=-127 }     # left
"$($a.pos_x) vs $($b.pos_x)"
```
Replay is **deterministic**: same inputs from the same checkpoint = bit-identical result.

## 2. STROOP — the variables, without the UI

```powershell
# every STROOP variable computed from live RAM:
$v = Get-StroopVars $s -IncludeComputed
$v['X']; $v['H Speed']; $v['De Facto Speed']; $v['Floor Normal Y']; $v['PU X']

# list the variable definitions of a STROOP file:
Get-StroopVarDefs -Files @('MarioData.xml') | Format-Table Name,Type,OffsetHex,Base

# ALSO launch the real STROOP.exe (UI) for visual control, attached to mupen:
Start-Stroop
```

## 3. aitest2 — the simulator

```powershell
Get-SimExamples                                  # list the CPU sim examples
Invoke-SimExample -Name selftest -Release        # the reference test (must print "PASS ... 5 coins")
Invoke-SimExample -Name ttm_probe -Release       # TTM probes, etc.

# GPU bruteforcers (⚠ see the limitation below):
Invoke-SimBruteforce -Bin guided_flying_bruteforce -EnvVars @{ GEN=300 }
```

## 4. The MCP (for a future Claude Code session)

To expose the 3 tools as native Claude tools (in a **new** session):

```powershell
claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\sm64-toolkit\tas\control\mcp\sm64_mcp_server.ps1"
```
(or copy the `sm64` entry of `mcp/mcp.json` into your `.mcp.json`). It cannot be added live: start a new session.

## 5. Troubleshooting

| Problem | Fix |
|---|---|
| `Start-Mupen` stuck / "not ready" | a stray mupen is running: `Get-Process mupen64 \| Stop-Process -Force` then retry |
| `Step-Frames` timeout | you are not on the up-to-date `bridge.lua` (inverted `emu.pause` trap, already fixed) |
| back to your normal mupen config | `Restore-MupenConfig` (the SDK switches to NoVideo/NoAudio for reliability; backup in `config-x64.json.sm64ctlbak`) |
| GPU bruteforce crashing | **known limitation**: the RTX 5070 gives an ACCESS_VIOLATION at the first dispatch (tool/driver bug, not this layer). Use the **CPU sim** (same physics). |

## 6. What is proven (tested on the original machine)

- mupen: live state in TTM on the shell, input injection, exact savestates, bit-identical replay.
- STROOP: X/Z exact vs the emulator; De Facto Speed = H Speed × Floor Normal Y.
- CPU sim: `selftest` PASSES (5/5 red coins, frame 371, no emulator).
- MCP: 16 tools, protocol validated.
- GPU: detected (RTX 5070 / Vulkan) but the aitest2 bruteforcer crashes (tool hardware limitation). This is unrelated
  to the CUDA engine in the sm64-tas-gpu repo, which works.
