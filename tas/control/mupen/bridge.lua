-- bridge.lua — headless file-IPC control server for mupen64-rr-lua.
--
-- Runs INSIDE mupen (drag-drop, or `mupen64.exe --lua bridge.lua`). It turns the emulator into a
-- programmable server: an external process (the PowerShell SM64Ctl SDK, the Rust MCP, or a human)
-- writes JSON commands to a file, the bridge executes them and appends JSON responses to another
-- file. This gives 100% programmatic control of the real, cycle-accurate emulator without touching
-- the GUI.
--
-- Transport: two append-only text files in a session directory (one JSON object per line):
--     cmd.jsonl   external -> bridge   {"id":N,"op":"...","args":{...}}
--     resp.jsonl  bridge -> external   {"id":N,"ok":true,"result":...}  | {"id":N,"ok":false,"err":"..."}
--   plus status.json (heartbeat) and bridge.log (human log).
--
-- The session directory comes from the SM64CTL_SESSION environment variable (set by the launcher),
-- falling back to a path next to this script's expected location.
--
-- Command loop runs from BOTH emu.atinterval (fires on a timer even while the core is paused, so
-- memory/savestate/action commands work any time) AND emu.atinput (frame-synchronised, so input
-- injection and frame-advance are exact). A single pump() drains the queue in either context.

------------------------------------------------------------------------ config / paths
local SESSION = os.getenv("SM64CTL_SESSION")
if not SESSION or SESSION == "" then
  -- fallback: a fixed session dir under the control tree (launcher normally overrides this)
  local tmp = os.getenv("TEMP") or os.getenv("TMP") or "."; SESSION = tmp:gsub("\\", "/") .. "/sm64ctl_session"
end
local function pjoin(a, b) return (a:gsub("[/\\]+$", "")) .. "/" .. b end
local CMD_PATH    = pjoin(SESSION, "cmd.jsonl")
local RESP_PATH   = pjoin(SESSION, "resp.jsonl")
local STATUS_PATH = pjoin(SESSION, "status.json")
local LOG_PATH    = pjoin(SESSION, "bridge.log")

------------------------------------------------------------------------ tiny logging
local function logline(s)
  local f = io.open(LOG_PATH, "a")
  if f then f:write(tostring(s) .. "\n"); f:close() end
end

------------------------------------------------------------------------ minimal JSON (encode/decode)
-- Supports: nil/true/false, numbers, strings (with \" \\ \n \t \uXXXX), arrays, string-keyed maps.
-- Sufficient for the flat command/response messages used here.
local json = {}
do
  local function enc(v, out)
    local t = type(v)
    if v == nil then out[#out+1] = "null"
    elseif t == "boolean" then out[#out+1] = v and "true" or "false"
    elseif t == "number" then
      if v ~= v then out[#out+1] = "null"                 -- NaN
      elseif v == math.huge then out[#out+1] = "1e999"
      elseif v == -math.huge then out[#out+1] = "-1e999"
      elseif math.type and math.type(v) == "integer" then out[#out+1] = string.format("%d", v)
      else
        -- keep full precision for floats
        local s = string.format("%.17g", v)
        out[#out+1] = s
      end
    elseif t == "string" then
      local s = v:gsub('[%z\1-\31\\"]', function(c)
        local m = {['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t', ['\b']='\\b', ['\f']='\\f'}
        return m[c] or string.format("\\u%04x", string.byte(c))
      end)
      out[#out+1] = '"' .. s .. '"'
    elseif t == "table" then
      -- decide array vs object
      local n = 0; local isarr = true
      for k in pairs(v) do
        n = n + 1
        if type(k) ~= "number" then isarr = false end
      end
      if isarr and n == #v then
        out[#out+1] = "["
        for i = 1, #v do if i > 1 then out[#out+1] = "," end; enc(v[i], out) end
        out[#out+1] = "]"
      else
        out[#out+1] = "{"
        local first = true
        for k, val in pairs(v) do
          if not first then out[#out+1] = "," end
          first = false
          enc(tostring(k), out); out[#out+1] = ":"; enc(val, out)
        end
        out[#out+1] = "}"
      end
    else
      out[#out+1] = "null"
    end
  end
  function json.encode(v)
    local out = {}; enc(v, out); return table.concat(out)
  end

  local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return (j or i-1) + 1
  end
  local decode_value
  local function decode_string(s, i)
    -- assumes s:sub(i,i) == '"'
    local buf = {}; i = i + 1
    while i <= #s do
      local c = s:sub(i, i)
      if c == '"' then return table.concat(buf), i + 1
      elseif c == "\\" then
        local e = s:sub(i+1, i+1)
        if e == "n" then buf[#buf+1] = "\n"
        elseif e == "t" then buf[#buf+1] = "\t"
        elseif e == "r" then buf[#buf+1] = "\r"
        elseif e == "b" then buf[#buf+1] = "\b"
        elseif e == "f" then buf[#buf+1] = "\f"
        elseif e == "/" then buf[#buf+1] = "/"
        elseif e == '"' then buf[#buf+1] = '"'
        elseif e == "\\" then buf[#buf+1] = "\\"
        elseif e == "u" then
          local hex = s:sub(i+2, i+5); local cp = tonumber(hex, 16) or 63
          if cp < 128 then buf[#buf+1] = string.char(cp)
          else buf[#buf+1] = "?" end   -- non-ASCII rare in our messages
          i = i + 4
        else buf[#buf+1] = e end
        i = i + 2
      else buf[#buf+1] = c; i = i + 1 end
    end
    error("unterminated string")
  end
  local function decode_number(s, i)
    local j = i
    while j <= #s and s:sub(j, j):match("[%-%+%.eE0-9]") do j = j + 1 end
    return tonumber(s:sub(i, j-1)), j
  end
  decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decode_string(s, i)
    elseif c == "{" then
      local obj = {}; i = skip_ws(s, i + 1)
      if s:sub(i, i) == "}" then return obj, i + 1 end
      while true do
        local key; key, i = decode_string(s, skip_ws(s, i))
        i = skip_ws(s, i); assert(s:sub(i, i) == ":", "expected :"); i = i + 1
        local val; val, i = decode_value(s, i); obj[key] = val
        i = skip_ws(s, i); local d = s:sub(i, i)
        if d == "," then i = skip_ws(s, i + 1)
        elseif d == "}" then return obj, i + 1
        else error("bad object") end
      end
    elseif c == "[" then
      local arr = {}; i = skip_ws(s, i + 1)
      if s:sub(i, i) == "]" then return arr, i + 1 end
      while true do
        local val; val, i = decode_value(s, i); arr[#arr+1] = val
        i = skip_ws(s, i); local d = s:sub(i, i)
        if d == "," then i = i + 1
        elseif d == "]" then return arr, i + 1
        else error("bad array") end
      end
    elseif c == "t" then return true, i + 4
    elseif c == "f" then return false, i + 5
    elseif c == "n" then return nil, i + 4
    else return decode_number(s, i) end
  end
  function json.decode(s)
    local v = decode_value(s, 1); return v
  end
end

------------------------------------------------------------------------ SM64 state pack (reused addrs)
-- Kept inline so the bridge is self-contained. US gMarioState = 0x8033B170 (see tas/lua/lib/sm64_addr.lua).
local MARIO = 0x8033B170
local G = {
  red_coin_count = 0x803613FE, hud_coin_count = 0x803316D2,
  course_index = 0x8033BAC6, current_area = 0x8032DDCC,
  rng_value = 0x8038EEE0, global_timer = 0x8032D5D4,
}
local function mario_pack()
  local rf, rw, rd = memory.readfloat, memory.readwordsigned, memory.readdword
  local ru = memory.readdword
  return {
    action     = ru(MARIO + 0x0C),
    prev_action= ru(MARIO + 0x10),
    action_state = memory.readword(MARIO + 0x18),
    action_timer = memory.readword(MARIO + 0x1A),
    intended_mag = rf(MARIO + 0x20),
    intended_yaw = rw(MARIO + 0x24),
    face_yaw   = rw(MARIO + 0x2E),
    face_pitch = rw(MARIO + 0x2C),
    yaw_vel    = rw(MARIO + 0x34),
    water_level = rw(MARIO + 0x76),
    slide_yaw  = rw(MARIO + 0x38),
    pos_x = rf(MARIO + 0x3C), pos_y = rf(MARIO + 0x40), pos_z = rf(MARIO + 0x44),
    vel_x = rf(MARIO + 0x48), vel_y = rf(MARIO + 0x4C), vel_z = rf(MARIO + 0x50),
    forward_vel = rf(MARIO + 0x54),
    slide_vel_x = rf(MARIO + 0x58), slide_vel_z = rf(MARIO + 0x5C),
    ceil_height = rf(MARIO + 0x6C), floor_height = rf(MARIO + 0x70),
    ridden_obj = ru(MARIO + 0x84),
    num_coins = memory.readwordsigned(MARIO + 0xA8),
    num_stars = memory.readwordsigned(MARIO + 0xAA),
    health = memory.readwordsigned(MARIO + 0xAE),
    hurt_counter = memory.readbyte(MARIO + 0xB2),
    invinc_timer = memory.readword(MARIO + 0xB6),
    red_coins = memory.readbytesigned(G.red_coin_count),
    hud_coins = memory.readword(G.hud_coin_count),
    course = memory.readwordsigned(G.course_index),
    rng = memory.readword(G.rng_value),
    global_timer = memory.readdword(G.global_timer),
    frame = emu.framecount(),
    samples = emu.samplecount(),
  }
end

------------------------------------------------------------------------ memory read/write dispatch
local READERS = {
  u8 = memory.readbyte, s8 = memory.readbytesigned,
  u16 = memory.readword, s16 = memory.readwordsigned,
  u32 = memory.readdword, s32 = memory.readdwordsigned,
  f32 = memory.readfloat, f64 = memory.readdouble,
}
local WRITERS = {
  u8 = memory.writebyte, s8 = memory.writebyte,
  u16 = memory.writeword, s16 = memory.writeword,
  u32 = memory.writedword, s32 = memory.writedword,
  f32 = memory.writefloat, f64 = memory.writedouble,
}
local function do_read(addr, typ)
  local r = READERS[typ or "u32"]; assert(r, "bad type " .. tostring(typ))
  return r(addr)
end

------------------------------------------------------------------------ input model
-- Sticky input applied every atinput frame; frame-advance decrements a countdown.
local sticky_input = {}         -- current controller table
local advance = nil             -- {remaining=N, id=cmdid, input=table} or nil
local replay = nil              -- {frames,i,n,samp,sampleAll,out,id,stopstars} batched max-speed replay
local port = 1

local function norm_input(t)
  t = t or {}
  -- pass through mupen JoypadInputs field names; default missing buttons to false, axes to 0
  local out = {
    right = t.right or false, left = t.left or false, down = t.down or false, up = t.up or false,
    start = t.start or false, Z = t.Z or false, B = t.B or false, A = t.A or false,
    Cright = t.Cright or false, Cleft = t.Cleft or false, Cdown = t.Cdown or false, Cup = t.Cup or false,
    R = t.R or false, L = t.L or false,
    X = t.X or 0, Y = t.Y or 0,
  }
  return out
end

------------------------------------------------------------------------ pause helper
-- IMPORTANT: mupen's emu.pause() is INVERTED for legacy compat (emu.pause(true) RESUMES,
-- emu.pause(false) PAUSES). Wrap it so the rest of the code reads normally.
local function set_paused(p) emu.pause(not p) end

------------------------------------------------------------------------ response writer
-- Defined BEFORE the handlers so their deferred callbacks (savestate/memstate) capture the real
-- local `respond` as an upvalue, not a nil global.
local function respond(id, ok, payload)
  local msg = { id = id, ok = ok }
  if ok then msg.result = payload else msg.err = tostring(payload) end
  local f = io.open(RESP_PATH, "a")
  if f then f:write(json.encode(msg) .. "\n"); f:close() end
end

------------------------------------------------------------------------ command handlers
local handlers = {}

handlers.ping = function() return { pong = true, version = emu.getversion and emu.getversion() or "?", frame = emu.framecount() } end
handlers.getframe = function() return { frame = emu.framecount(), samples = emu.samplecount(), inputs = emu.inputcount() } end

handlers.read = function(a) return { value = do_read(a.addr, a.type) } end
handlers.readmany = function(a)
  local res = {}
  for i, spec in ipairs(a.list or {}) do
    res[i] = do_read(spec.addr, spec.type)
  end
  return { values = res }
end
handlers.write = function(a)
  local w = WRITERS[a.type or "u32"]; assert(w, "bad type")
  w(a.addr, a.value); return { ok = true }
end
handlers.readrange = function(a)
  -- read `count` bytes from addr as an array of u8 (for RAM snapshots)
  local out = {}
  for i = 0, (a.count or 0) - 1 do out[i+1] = memory.readbyte(a.addr + i) end
  return { bytes = out }
end

handlers.state = function() return mario_pack() end

handlers.setinput = function(a) sticky_input = norm_input(a.input); return { ok = true } end
handlers.setport  = function(a) port = a.port or 1; return { port = port } end

-- advance N frames applying `input` (or current sticky). Unpauses the core, runs exactly N frames
-- (counted in atinput), then re-pauses and responds with the state reached. The core idles PAUSED
-- between advances so that reads are frame-stable and the run is deterministic.
handlers.advance = function(a, id)
  local n = a.frames or 1
  if a.input ~= nil then sticky_input = norm_input(a.input) end
  advance = { remaining = n, id = id, input = sticky_input }
  set_paused(false)   -- start running; atinput will re-pause at frame N
  return nil          -- deferred; completed in atinput
end

-- replaylist: apply a per-frame input list [ [x,y,btn], ... ] at MAXIMUM speed in one call.
-- btn is the .m64 button word: 0x80 A, 0x40 B, 0x20 Z, 0x10 Start, 0x08/0x04/0x02/0x01 D-pad up/down/left/right,
-- 0x0800/0x0400/0x0200/0x0100 C up/down/left/right, 0x1000 R, 0x2000 L; 0x10000 = "auto B" (see atinput).
-- Returns sampled Mario states: a.samples (list of 1-based frame indices) if given, else only the final
-- frame. Optional a.stopstars: stop early the first frame num_stars >= that value (returns the stop frame).
-- Mirrors `advance` timing: the state for frame i is read at the following atinput (after frame i ran),
-- so replaylist == calling advance(1) once per frame, but with no per-frame IPC round-trip.
handlers.replaylist = function(a, id)
  local fr = a.frames or {}
  local samp = {}
  if type(a.samples) == "table" then for _, i in ipairs(a.samples) do samp[tonumber(i)] = true end end
  replay = { frames = fr, i = 0, n = #fr, samp = samp, sampleAll = (a.sampleall == true),
             out = {}, id = id, stopstars = tonumber(a.stopstars), autob = {} }
  -- REPLAY_SPEED_MODE / REPLAY_SPEED_PCT (globals, settable via Invoke-MupenLua): 0 + 100 = real time, visible
  emu.set_speed_mode(REPLAY_SPEED_MODE or 1); pcall(function() emu.speed(REPLAY_SPEED_PCT or 5000) end)
  set_paused(false)
  return nil          -- deferred; completed in atinput
end

local mem_states = {}   -- in-memory savestate buffers keyed by slot number

handlers.savestate = function(a, id)
  -- job: "save" | "load". slot is 1-based (do_slot subtracts 1 internally); or pass a file path.
  -- Savestate ops are ASYNC (ThreadPool + dispatcher callback); defer the response until the
  -- completion callback fires so the client can safely act on the loaded state right after.
  local jobstr = a.job or "load"
  local ignore = a.ignore ~= false   -- default TRUE: never let a warning dialog block automation
  if a.clean and jobstr == "save" then
    pcall(function() movie.stop() end)
  end
  local cb = function(result, data)
    logline("savestate cb fired: job=" .. jobstr .. " result=" .. tostring(result))
    respond(id, true, { ok = true, result_code = result })
  end
  if a.path then
    savestate.do_file(a.path, jobstr, cb, ignore)
  else
    savestate.do_slot(a.slot or 1, jobstr, cb, ignore)
  end
  return nil   -- deferred; response comes from cb
end

-- In-memory savestate: fast, disk-free checkpoints for search. slot = integer key.
handlers.memstate = function(a, id)
  local slot = a.slot or 1
  if a.job == "save" then
    savestate.do_memory("", "save", function(result, buf)
      mem_states[slot] = buf
      logline("memstate SAVE slot=" .. slot .. " len=" .. tostring(buf and #buf or 0) .. " result=" .. tostring(result))
      respond(id, true, { ok = true, slot = slot, bytes = buf and #buf or 0 })
    end)
  else -- load
    local buf = mem_states[slot]
    if not buf then respond(id, false, "no in-memory state in slot " .. slot); return nil end
    savestate.do_memory(buf, "load", function(result, _)
      logline("memstate LOAD slot=" .. slot .. " result=" .. tostring(result))
      respond(id, true, { ok = true, slot = slot })
    end)
  end
  return nil
end

handlers.pause = function(a) local p = a.value ~= false; set_paused(p); return { paused = p } end
local SPEED_MODE = { normal = 0, fastforward = 1, maximum = 1, ultra = 2, ultrafastforward = 2 }
handlers.speed = function(a)
  if a.mode ~= nil then
    local m = a.mode
    if type(m) == "string" then m = SPEED_MODE[m:lower()] or 0 end
    emu.set_speed_mode(m)   -- CoreSpeedMode int enum (0=Normal,1=FastForward,2=UltraFastForward)
  end
  if a.value then emu.speed(a.value) end
  return { ok = true }
end

handlers.movie = function(a)
  if a.job == "play" then movie.play(a.path, a.readonly ~= false, a.pause == true)
  elseif a.job == "stop" then movie.stop() end
  return { ok = true }
end

handlers.screenshot = function(a) emu.screenshot(a.path); return { path = a.path } end

handlers.action = function(a)
  -- invoke any mupen menu action by identifier; list with op "actions"
  if a.filter then
    -- fall through to list
  end
  action.invoke(a.name)
  return { invoked = a.name }
end
handlers.actions = function(a)
  local list = action.get_actions_matching_filter(a.filter or "")
  return { actions = list }
end

handlers.eval = function(a)
  -- escape hatch: run arbitrary Lua and return a value (string). USE CAREFULLY.
  local fn, err = load("return " .. (a.code or "nil"))
  if not fn then fn, err = load(a.code or "") end
  assert(fn, err)
  local ok, res = pcall(fn)
  return { ok = ok, result = tostring(res) }
end

handlers.quit = function() emu.pause(false); return { bye = true } end

------------------------------------------------------------------------ command pump
local cmd_cursor = 0            -- bytes consumed from cmd.jsonl
local pending = {}             -- queued decoded commands not yet run

local function read_new_commands()
  -- binary mode + exact byte accounting: only consume COMPLETE lines (up to the last '\n'),
  -- leaving any partial trailing line for the next pump. Immune to CRLF/text-mode drift.
  local f = io.open(CMD_PATH, "rb")
  if not f then return end
  f:seek("set", cmd_cursor)
  local data = f:read("*a") or ""
  f:close()
  if #data == 0 then return end
  local start, consumed = 1, 0
  while true do
    local nl = data:find("\n", start, true)
    if not nl then break end
    local line = data:sub(start, nl - 1):gsub("\r$", "")
    consumed = nl
    start = nl + 1
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if #line > 0 then
      local ok, obj = pcall(json.decode, line)
      if ok and type(obj) == "table" then pending[#pending+1] = obj
      else logline("bad cmd line: " .. line) end
    end
  end
  cmd_cursor = cmd_cursor + consumed
end

local function run_command(c, in_atinput)
  local h = handlers[c.op]
  if not h then respond(c.id, false, "unknown op: " .. tostring(c.op)); return end
  local ok, res = pcall(h, c.args or {}, c.id)
  if not ok then respond(c.id, false, res)
  elseif res ~= nil then respond(c.id, true, res)
  end
  -- res == nil with ok means "deferred" (advance) — response comes later
end

local function pump(in_atinput)
  read_new_commands()
  local queue = pending; pending = {}
  for _, c in ipairs(queue) do run_command(c, in_atinput) end
end

------------------------------------------------------------------------ heartbeat
local hb = 0
local function heartbeat()
  hb = hb + 1
  local f = io.open(STATUS_PATH, "w")
  if f then
    f:write(json.encode({ alive = true, hb = hb, frame = emu.framecount(), inputs = emu.inputcount() }))
    f:close()
  end
end

------------------------------------------------------------------------ callbacks
emu.atinput(function()
  -- During an active replaylist we skip pump(): no new command can arrive (the client is blocked
  -- awaiting this replay's response), and pump()'s per-frame cmd-file read (io.open+seek+read)
  -- otherwise caps max-speed replay to disk-I/O rate (~34 VI/s) instead of full dynarec speed.
  if not replay then
    -- 1) run any queued frame-critical commands (advance)
    pump(true)
  end
  -- 1b) batched replaylist: apply one list frame per atinput at max speed, sample requested frames
  if replay then
    -- state for the frame just run (replay.i) is available now (before this frame's input applies)
    if replay.i >= 1 then
      local stars = memory.readwordsigned(MARIO + 0xAA)
      if replay.sampleAll or replay.samp[replay.i] then
        replay.out[#replay.out+1] = { f = replay.i, s = mario_pack() }
      end
      if replay.stopstars and stars >= replay.stopstars then
        replay.out[#replay.out+1] = { f = replay.i, s = mario_pack(), stop = true }
        local id = replay.id; local out = replay.out; local ab = replay.autob; replay = nil
        emu.set_speed_mode(0); pcall(function() emu.speed(100) end); set_paused(true); respond(id, true, { frames = out, autob = ab }); return
      end
    end
    if replay.i >= replay.n then
      if not (replay.samp[replay.n] or replay.sampleAll) then
        replay.out[#replay.out+1] = { f = replay.n, s = mario_pack(), final = true }
      end
      local id = replay.id; local out = replay.out; local ab = replay.autob; replay = nil
      emu.set_speed_mode(0); pcall(function() emu.speed(100) end); set_paused(true); respond(id, true, { frames = out, autob = ab }); return
    end
    replay.i = replay.i + 1
    local fr = replay.frames[replay.i]
    local bt = fr[3] or 0
    -- bit 0x10000 = "auto B": B only if Mario is stationary (idle, end of a landing...), outside
    -- punch, and if B was not pressed on the previous frame -> optimal punch rate (1 punch / 16 f)
    if (math.floor(bt/65536) % 2) == 1 then
      bt = bt % 65536
      local act = memory.readdword(MARIO + 0x0C)
      if act < 0 then act = act + 4294967296 end
      local stationary = (math.floor(act / 0x200) % 2) == 1
      if stationary and act ~= 0x00800380 and not replay.lastB then bt = bt - (bt % 128) + 64 + (bt % 64); replay.autob[#replay.autob+1] = replay.i end
    end
    replay.lastB = (math.floor(bt/64) % 2) == 1
    local function bit(v) return (math.floor(bt / v) % 2) == 1 end
    local rinp = norm_input({ X = fr[1] or 0, Y = fr[2] or 0,
      right = bit(1), left = bit(2), down = bit(4), up = bit(8), start = bit(16), Z = bit(32), B = bit(64), A = bit(128),
      Cright = bit(256), Cleft = bit(512), Cdown = bit(1024), Cup = bit(2048), R = bit(4096), L = bit(8192) })
    joypad.set(port, rinp)
    return
  end
  -- 2) apply sticky/advance input for THIS frame
  local inp = sticky_input
  if advance then inp = advance.input end
  joypad.set(port, inp)
  -- 3) if advancing, decrement and complete when done
  if advance then
    advance.remaining = advance.remaining - 1
    if advance.remaining <= 0 then
      local id = advance.id
      advance = nil
      set_paused(true)                   -- idle paused between advances (deterministic, frame-stable)
      respond(id, true, mario_pack())    -- return the state reached
    end
  end
end)

emu.atinterval(function()
  pump(false)
  heartbeat()
end)

emu.atstop(function()
  logline("bridge: emu stopped")
end)

-- announce ready
do
  -- truncate resp file at startup so stale responses don't confuse a fresh client
  local rf = io.open(RESP_PATH, "w"); if rf then rf:close() end
  -- skip any commands already present in cmd.jsonl (only process ones appended after start)
  local cf = io.open(CMD_PATH, "rb")
  if cf then cmd_cursor = cf:seek("end"); cf:close() else
    local nf = io.open(CMD_PATH, "w"); if nf then nf:close() end; cmd_cursor = 0
  end
  logline("bridge: started, session=" .. SESSION)
  respond(0, true, { ready = true, session = SESSION, version = emu.getversion and emu.getversion() or "?" })
  print("[sm64ctl bridge] ready; session=" .. SESSION)
end
