# SM64 control layer — driving mupen, STROOP and the Rust sim at 100 %

This directory (`tas/control/`) is a **self-contained control plane** that lets an agent (Claude) or a
human drive all three SM64 tools in this workspace programmatically, with nothing hand-clicked:

| Tool | What it is | How we control it |
|------|-----------|-------------------|
| **mupen64-rr-lua** | the real, cycle-accurate N64 emulator (`mupen64-rr-lua/build/out/mupen64.exe`) | a Lua **bridge server** running inside it + a PowerShell SDK that launches it and talks over files |
| **STROOP** | the SM64 RAM inspector (`STROOP/.../STROOP.exe`), whose real value is its **curated variable/formula database** | we parse STROOP's `Config/*Data.xml` and **compute every variable from live RAM** (read through the mupen bridge) — STROOP, headless |
| **aitest2-improved** | a Rust SM64 physics sim (`sm64-sim-rs`) + GPU input bruteforcers (`sm64-gpu-handover`) | a PowerShell wrapper that builds/runs its examples and bruteforcers and parses their output |

Everything lives here and is **never committed or pushed**, and never edits the `mupen64-rr-lua/`,
`STROOP/` or `sm64/` source trees (the one exception is a stale sim example we repaired — see §4).

```
tas/control/
├─ SM64Ctl.psm1            # the SDK — import this, it drives all three tools
├─ mupen/
│  └─ bridge.lua           # file-IPC control server that runs INSIDE mupen
├─ stroop/                 # (variable engine lives in SM64Ctl.psm1; see §3)
├─ sim/                    # (sim wrappers live in SM64Ctl.psm1; see §4)
├─ mcp/
│  ├─ sm64_mcp_server.ps1  # MCP (stdio JSON-RPC) server exposing all three as native tools
│  └─ mcp.json             # registration snippet for a future Claude Code session
├─ session/                # per-run IPC scratch dirs (cmd.jsonl / resp.jsonl / bridge.log)
└─ HOW_IT_WORKS.md         # this file
```

## Toolchain on this machine (what's available, what's not)

- **Rust / cargo** ✅ (builds the sim). **PowerShell 5.1** ✅ (the SDK + MCP host).
- **.NET 8 runtime** ✅ (runs the prebuilt `STROOP.exe`) but **no .NET SDK** — cannot compile new C#.
- **No Python, no Node, no standalone Lua.** That's why the SDK and MCP are PowerShell, and the
  in-emulator half is Lua (mupen embeds it).

---

## 1. Quick start

```powershell
Import-Module '...\tas\control\SM64Ctl.psm1' -Force

$s = Start-Mupen                      # launches mupen headless, loads ROM + Task-3 savestate, waits for ready
Get-MarioState $s                     # full Mario state pack (pos, vel, action, coins, yaw, floor, rng, ...)
Step-Frames $s -Frames 20 -Buttons @{ A=$true; Y=127 }   # advance 20 frames holding A + stick up; returns state reached
Save-MemState $s -Slot 1              # fast in-memory checkpoint
Load-MemState $s -Slot 1              # restore it (exact)
Get-StroopVars $s -IncludeComputed    # every STROOP variable, computed live from RAM
Stop-Mupen $s
```

All of the above is **verified working** on this machine (see §6 for the exact evidence).

---

## 2. mupen — full emulator control

### 2.1 How the emulator is driven

mupen64-rr-lua advances **one frame per Lua callback**; you cannot step it synchronously in a loop.
Its Lua API (registered in `src/Views.Win32/lua/LuaRegistry.cpp`) gives you, among others:

- `memory.read*/write*` at full KSEG0 addresses (`0x80xxxxxx`) — read/write live RAM.
- `emu.atinput(fn)` — fires every frame; `joypad.set(port, input)` injects the controller.
- `emu.atinterval(fn)` — fires on a **timer even while the core is paused** (our out-of-frame channel).
- `savestate.do_file/do_slot/do_memory(…, callback, ignore_warnings)` — **asynchronous** savestates.
- `movie.play/stop/begin_seek/begin_warp_modify` — movie playback & in-place input optimisation.
- `action.invoke(name)` / `action.get_actions_matching_filter(f)` — invoke ANY menu action.
- `emu.pause(x)` — **INVERTED for legacy compat**: `emu.pause(true)` RESUMES, `emu.pause(false)` PAUSES.
- Standard Lua `io`/`os` are available (only `os.exit` is overridden) → a **file-based IPC** works.

mupen also has a CLI: `mupen64.exe --rom <z64> --lua <script.lua;…> [--st <state>] [--movie <m64>]`.

### 2.2 The bridge (`mupen/bridge.lua`)

A control server that runs inside mupen and turns it into a request/response service over two
append-only JSON-Lines files in a **session directory** (from env `SM64CTL_SESSION`):

```
cmd.jsonl   client -> bridge   {"id":N,"op":"...","args":{...}}
resp.jsonl  bridge -> client   {"id":N,"ok":true,"result":...}   |   {"id":N,"ok":false,"err":"..."}
status.json heartbeat, bridge.log human log
```

A single `pump()` drains new command lines from both `emu.atinput` (frame-synchronised, for
`advance`) and `emu.atinterval` (for everything else, works while paused). Ops:

| op | meaning |
|----|---------|
| `ping` / `getframe` | liveness / frame & sample counters |
| `read` / `readmany` / `readrange` / `write` | RAM access (`u8 s8 u16 s16 u32 s32 f32 f64`) |
| `state` | the Mario **state pack** (see below) |
| `setinput` / `advance` | set sticky controller / run N frames applying it, return the state reached |
| `memstate` (save/load) | **in-memory** savestate slots — fast, disk-free, the search primitive |
| `savestate` (save/load, path or slot) | disk savestate (async; `ignore_warnings` defaults true) |
| `pause` / `speed` | pause/resume, speed mode (`normal`/`maximum`) |
| `movie` / `screenshot` / `action` / `actions` | movie play/stop, PNG, invoke/list menu actions |
| `eval` | run arbitrary Lua (escape hatch) |

**Determinism model:** the core idles **paused** between calls; `advance` unpauses, runs *exactly* N
frames (counted in `atinput`), then re-pauses and replies with the state reached. So every read is
frame-stable, and `Load-MemState` + `Step-Frames` replays **bit-identically** (verified).

The **Mario state pack** (`state` / `Get-MarioState`) — US `gMarioState` @ `0x8033B170`:
`action, prev_action, action_timer, intended_mag/yaw, face_yaw/pitch, slide_yaw, pos_{x,y,z},
vel_{x,y,z}, forward_vel, slide_vel_{x,z}, ceil/floor_height, ridden_obj, num_coins/stars, health,
hurt_counter, invinc_timer, red_coins, hud_coins, course, rng, global_timer, frame`.

### 2.3 The SDK verbs (`SM64Ctl.psm1`)

`Start-Mupen` / `Connect-Mupen` / `Stop-Mupen`, `Test-Mupen`, `Get-MupenFrame`, `Get-MarioState`,
`Read-Mem` / `Read-MemMany` / `Write-Mem` / `Read-Range`, `Set-Input`, `Step-Frames`,
`Save-MemState` / `Load-MemState`, `Save-State` / `Load-State`, `Set-Speed` / `Set-Pause`,
`Play-Movie` / `Stop-Movie`, `Invoke-MupenAction` / `Get-MupenActions`, `Save-Screenshot`,
`Invoke-MupenLua`, `Send-Cmd` (low-level).

### 2.4 Why headless / the four gotchas we hit (so you don't rediscover them)

1. **`emu.pause` is inverted** (legacy compat). The bridge wraps it in `set_paused()`. If frame
   stepping ever hangs, this is the first suspect.
2. **PS 5.1 `Start-Process -ArgumentList` does not quote array elements**, and every path here has a
   space (`crackhex update`). We build one quoted command-line string.
3. **Loading a savestate via `--st` at CLI startup can pop a warning dialog that blocks `start_lua`**
   → the bridge never loads. We launch ROM+Lua only, then load the savestate *through the bridge*
   with `ignore_warnings=true`.
4. **TASVideo/TASAudio plugins hold GPU/sound devices that lock on force-kill and hang the next ROM
   start.** `Start-Mupen -Headless` (default) rewrites the config to the **NoVideo + NoAudio** stub
   plugins (`Set-MupenHeadlessConfig`, backed up to `config-x64.json.sm64ctlbak`,
   `Restore-MupenConfig` to undo). Input stays on TASInput; `joypad.set` works regardless.
   Also: cmd.jsonl is read in **binary** with exact byte accounting so CRLF/text-mode never drifts
   the cursor; and `respond()` is defined **before** the handlers so their async callbacks capture
   the real upvalue (a subtle Lua ordering bug that silently swallowed savestate responses).

---

## 3. STROOP — the variable engine, headless

STROOP attaches to the emulator process and reads the same RDRAM the bridge exposes (its config
lists `mupen64 ramStart=0x01000000`). Its real asset is the **variable/formula database** in
`STROOP/.../Config/*Data.xml`. Each `<Data … base="Mario" offset="0x3C" type="float">X</Data>` is a
declarative `base + offset : type` read; base addresses (verified against STROOP source):

- Mario `0x8033B170` (`MarioConfig.StructAddressUS`), Camera `0x8033C520` (`CameraConfig.StructAddressUS`).

`Get-StroopVars $s` reads **every declarative variable in one batched `readmany`** and returns an
ordered `Name -> value` map — i.e. **STROOP without the GUI**. `Get-StroopVarDefs` exposes the raw
definitions; with `-IncludeComputed` it also adds the `specialType` (computed) variables ported from
the decomp: **De Facto Speed** (`forward_vel × floor.normal.y`, reading the floor-triangle pointer at
`gMarioState+0x68` and its normal at `Triangle+0x1C/0x20/0x24`), Floor Normal X/Y/Z, **PU X/Z**
(parallel-universe indices), H-speed vector, Total Speed, DYaw (intended−face), height above
floor/below ceiling, and angle u16 conversions. Verified live: STROOP `X`/`Z` match the emulator's
`pos_x`/`pos_z` **exactly**, and De Facto Speed = H Speed × Floor Normal Y as STROOP computes it.
(Niche `specialType` vars — trajectory, HOLP, etc. — aren't all ported yet; add them to
`Get-StroopComputed` as needed.)

`Start-Stroop` launches the real `STROOP.exe` GUI so a human can *also* attach it to the running
mupen for a visual cross-check (config already targets `mupen64`, `ramStart=0x01000000`).

To add more variables, point `Get-StroopVars -Files @('MarioData.xml','ObjectData.xml',…)`; any
`specialType` you need that isn't ported yet can be added to `Get-StroopComputed`.

---

## 4. aitest2-improved — Rust CPU sim + GPU bruteforcers

Two faces, both wrapped in the SDK:

**A. CPU simulator library** (`sm64-sim-rs`, crates `sm64-sim-core` + `sm64-sim-io`, ~16 examples).
`Get-SimExamples` lists them; `Invoke-SimExample -Name <ex> -Release` builds+runs one and returns
its output. Highlights: `selftest` (reproduces the verified Task-3 run end-to-end with **no
emulator** — 371 frames, 5 red coins), `blj_probe`, `camera_diff`, `ttm_probe`, `route_planner`,
`leg_solver`, `mount_search`, `tas_standalone`. *(We repaired `selftest.rs`: `find_floor` now
returns `(Option<Surface>, f32)` instead of an out-param — the only source edit outside `control/`.)*

**B. GPU bruteforcers** (`sm64-gpu-handover/spirv_run`, needs a **Vulkan** GPU).
`Invoke-SimBruteforce -Bin <bin> -EnvVars @{ GEN=300 }` builds the `.spv` (first build compiles the
rust-gpu backend, ~3 min) then runs a bruteforcer. Bins: `guided_flying_bruteforce`,
`guided_flying_collision_bruteforce` (the real tool — guided + full collision),
`guided_flight_refine` (improves a real `.flight`), `flight_replay`, and the random-search variants.
Env passthrough: `GEN` (generations), `BATCHES`, `OUT`, `TX/TY/TZ` (target), `FULL_VERIFY`.
See `aitest2-improved/USAGE.md` for the search theory.

> **Known limitation (this machine):** the wrapper builds and launches the GPU bruteforcers
> correctly and the GPU is detected (`GPU: NVIDIA GeForce RTX 5070`, Vulkan), but the **first
> compute dispatch crashes with STATUS_ACCESS_VIOLATION** on the RTX 5070 (Blackwell). Precise
> diagnosis for whoever fixes it: `spirv_run` uses **wgpu 30 + `Features::PASSTHROUGH_SHADERS`** and
> feeds the prebuilt **`probe_shaders.spv`** raw to the driver via `create_shader_module_passthrough`
> (see `guided_flying_bruteforce.rs:104-125`). Raw rust-gpu SPIR-V handed straight to a brand-new
> Blackwell driver is the likely culprit — try in order: **(1) update the NVIDIA driver**, (2) bump
> `wgpu`/`cargo-gpu` and **regenerate `probe_shaders.spv`**, (3) as a test, drop `PASSTHROUGH_SHADERS`
> and let naga validate/translate the SPIR-V. This is independent of the control layer (the
> throughput figures in older notes predate this GPU). The **CPU simulator uses the same
> physics/collision** and is fully validated (`selftest` passes) — use it as the search path meanwhile.

---

## 5. The MCP server (for future interactive sessions)

`mcp/sm64_mcp_server.ps1` is a **stdio JSON-RPC MCP server** that exposes 16 tools
(`start_mupen, stop_mupen, get_state, step_frames, read_mem, write_mem, save_memstate,
load_memstate, stroop_vars, invoke_action, list_actions, screenshot, sim_example, sim_examples,
sim_bruteforce, paths`) — a thin dispatcher over the SDK that keeps the live mupen session across
calls. Protocol validated (initialize / tools/list / tools/call).

**MCP servers cannot be hot-added to a running session.** Register it, then start a new session:

```
claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<abs>\tas\control\mcp\sm64_mcp_server.ps1"
```

or copy the `sm64` entry from `mcp/mcp.json` into your project/user `.mcp.json`.

Until then, the **SM64Ctl SDK is the way to drive everything right now** (from any PowerShell, or
from Claude via the PowerShell/Bash tools).

---

## 6. Verified evidence (all run on this machine)

- mupen: bridge handshake OK; live `Get-MarioState` shows Mario **riding a shell in TTM (course 12)**
  at `(1534.94, 2309.53, 548.34)`; `global_timer` advances exactly with `Step-Frames`.
- input injection: stick +127 vs −127 for 20 frames from one checkpoint diverge by `dz≈441` units.
- savestates: `Save-MemState`/`Load-MemState` restore **EXACT**; determinism when paused is **STABLE**;
  a 15-frame input replay is **BIT-IDENTICAL** across two runs.
- STROOP: 99 variables computed live; `X`/`Z` **EXACT** match the emulator's position.
- sim: `blj_probe`, `camera_diff` run; `selftest` **PASSES** (5/5 coins, frame 371, no emulator).
- MCP: `initialize` → `sm64ctl`; `tools/list` → 16 tools; `tools/call paths` → `MupenExists=True`.

## 7. Troubleshooting

- *bridge never becomes ready* → a stray mupen is running, or a startup dialog blocked it. Kill
  `mupen64` (`Get-Process mupen64 | Stop-Process -Force`) and retry; `Start-Mupen` already uses the
  headless (NoVideo/NoAudio) config which makes this rare.
- *`Step-Frames` times out* → the pause inversion (§2.4.1); ensure you're on the current `bridge.lua`.
- *cargo "errors" that are only warnings* → PS 5.1 wraps native stderr as errors; the SDK routes
  cargo through `Invoke-Cargo` which tolerates that and checks the real exit code.
- *restore mupen to your normal plugins* → `Restore-MupenConfig`.
