<#
  SM64Ctl.psm1 — PowerShell SDK to drive the three SM64 tools at 100%:

    * mupen64-rr-lua  — the real emulator, via the bridge.lua file-IPC server (this module launches
                        it, sends JSON commands, reads game state, injects input, steps frames,
                        does savestates, plays movies, invokes any menu action).
    * STROOP          — its full variable database (Config/*Data.xml) parsed here, so every STROOP
                        variable can be COMPUTED from a live RAM read (Get-StroopVars) without the GUI.
    * aitest2-improved — the Rust CPU sim (sm64-sim-rs) and the GPU bruteforcers
                        (sm64-gpu-handover/spirv_run), built/run through Invoke-Sim*.

  Nothing here is committed or pushed. Import with:
      Import-Module '...\tas\control\SM64Ctl.psm1' -Force
  Then:  $s = Start-Mupen ; Get-MarioState $s ; Step-Frames $s -Frames 4 -Input @{A=$true}
#>

$ErrorActionPreference = 'Stop'

# ---- resolve important paths relative to this module -------------------------------------------
$script:ControlDir = Split-Path -Parent $PSCommandPath                       # ...\tas\control
$script:Root       = Split-Path -Parent (Split-Path -Parent $script:ControlDir) # root of sm64-mupen-bridge
$script:BridgeLua  = Join-Path $script:ControlDir 'mupen\bridge.lua'
$script:MupenExe = if ($env:MUPEN_EXE -and (Test-Path $env:MUPEN_EXE)) { $env:MUPEN_EXE }
    elseif (Test-Path 'D:\mupen\mupen64-rr-lua\build\out\mupen64.exe') { 'D:\mupen\mupen64-rr-lua\build\out\mupen64.exe' }
    elseif (Test-Path 'G:\mupen\mupen64-rr-lua\build\out\mupen64.exe') { 'G:\mupen\mupen64-rr-lua\build\out\mupen64.exe' }
    else { 'D:\mupen\mupen64-rr-lua\build\out\mupen64.exe' }   # build reel (l'ancien chemin sous sm64-toolkit n'existe plus)
$script:DefaultRom = if ($env:SM64_ROM -and (Test-Path $env:SM64_ROM)) { $env:SM64_ROM }
    elseif (Test-Path 'D:\mupen\mupen64-rr-lua\build\out\roms\Super Mario 64 (USA).z64') { 'D:\mupen\mupen64-rr-lua\build\out\roms\Super Mario 64 (USA).z64' }
    elseif (Test-Path 'G:\testttttttt super mario\Super Mario 64 (USA).z64') { 'G:\testttttttt super mario\Super Mario 64 (USA).z64' }
    else { 'D:\mupen\mupen64-rr-lua\build\out\roms\Super Mario 64 (USA).z64' }
$script:DefaultSt  = Join-Path $script:Root '30th Anniversary Task 3.st'
$script:StroopCfg  = Join-Path $script:Root 'STROOP\STROOP\bin\Debug\net8.0-windows\Config'
$script:StroopExe  = if (Test-Path 'D:\mupen\STROOP\STROOP.exe') { 'D:\mupen\STROOP\STROOP.exe' }
    else { Join-Path $script:Root 'STROOP\STROOP\bin\Debug\net8.0-windows\STROOP.exe' }
$script:SimRoot    = Join-Path (Split-Path -Parent (Split-Path -Parent $script:Root)) 'aitest2-improved'

function Get-SM64Paths {
    [pscustomobject]@{
        ControlDir = $script:ControlDir
        MupenExe   = $script:MupenExe
        BridgeLua  = $script:BridgeLua
        DefaultRom = $script:DefaultRom
        DefaultSt  = $script:DefaultSt
        StroopCfg  = $script:StroopCfg
        StroopExe  = $script:StroopExe
        SimRoot    = $script:SimRoot
        MupenExists  = Test-Path $script:MupenExe
        StroopExists = Test-Path $script:StroopExe
        SimExists    = Test-Path $script:SimRoot
    }
}

# ================================================================================================
#  MUPEN CONTROL
# ================================================================================================

function Get-MupenConfigPath { Join-Path $env:LOCALAPPDATA 'mupen64-rr-lua\config-x64.json' }

function Set-MupenHeadlessConfig {
    <#
      Point mupen at the NoVideo + NoAudio stub plugins (self-contained, in build\out\plugin) and
      enable silent_mode / disable update checks. This is what makes headless automation reliable:
      TASVideo/TASAudio hold GPU/sound devices that lock up when the process is force-killed, hanging
      the next ROM start. NoVideo/NoAudio have no device to lock. Backs up the config once so the
      user's original plugin choice can be restored (Restore-MupenConfig). Input stays on TASInput
      (Lua joypad.set works regardless, and it holds no device).
    #>
    param([switch]$KeepAudioVideo)
    $cfg = Get-MupenConfigPath
    if (-not (Test-Path $cfg)) { Write-Verbose "no config yet at $cfg (mupen will create it)"; return }
    $bak = "$cfg.sm64ctlbak"
    if (-not (Test-Path $bak)) { Copy-Item $cfg $bak -Force }
    # Les builds recents de mupen64-rr-lua integrent les plugins dans l'exe : NoVideo/NoAudio se
    # selectionnent par "<builtin>/NoVideo" et "<builtin>/NoAudio", et un chemin vide = plugin TAS integre.
    # (L'ancien chemin build\out\plugin\*.dll n'existe plus : mupen retombait sur TASVideo OpenGL + audio
    # reel, ce qui limitait l'emulation a ~60 frames/s.)
    $text = Get-Content -Raw -Path $cfg
    if (-not $KeepAudioVideo) {
        $text = [regex]::Replace($text, '"selected_video_plugin"\s*:\s*"[^"]*"', '"selected_video_plugin": "<builtin>/NoVideo"')
        $text = [regex]::Replace($text, '"selected_audio_plugin"\s*:\s*"[^"]*"', '"selected_audio_plugin": "<builtin>/NoAudio"')
    }
    $text = [regex]::Replace($text, '"selected_input_plugin"\s*:\s*"[^"]*"', '"selected_input_plugin": ""')
    $text = [regex]::Replace($text, '"selected_rsp_plugin"\s*:\s*"[^"]*"',   '"selected_rsp_plugin": ""')
    $text = [regex]::Replace($text, '"silent_mode"\s*:\s*\d+', '"silent_mode": 1')
    $text = [regex]::Replace($text, '"automatic_update_checking"\s*:\s*\d+', '"automatic_update_checking": 0')
    [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Restore-MupenConfig {
    $cfg = Get-MupenConfigPath; $bak = "$cfg.sm64ctlbak"
    if (Test-Path $bak) { Copy-Item $bak $cfg -Force; Write-Output "restored $cfg" }
    else { Write-Output "no backup to restore" }
}

function Start-Mupen {
    <#
      Launch a fresh mupen instance running bridge.lua, load the ROM (+ optional savestate),
      wait for the bridge's ready handshake, and return a session object used by all other verbs.
    #>
    [CmdletBinding()]
    param(
        [string]$Rom = $script:DefaultRom,
        [string]$Savestate = $script:DefaultSt,
        [string]$MupenExe = $script:MupenExe,
        [switch]$NoSavestate,
        [bool]$Headless = $true,
        [int]$ReadyTimeoutSec = 40
    )
    if (-not (Test-Path $MupenExe)) { throw "mupen64.exe not found: $MupenExe" }
    if (-not (Test-Path $Rom))      { throw "ROM not found: $Rom" }
    if ($Headless) { Set-MupenHeadlessConfig }   # NoVideo/NoAudio => reliable, force-kill-safe

    Clear-MupenSessions -KeepLast 10 | Out-Null   # auto-prune stale IPC scratch so session\ never balloons
    $sess = Join-Path $script:ControlDir ('session\run_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    New-Item -ItemType Directory -Force -Path $sess | Out-Null
    $cmd  = Join-Path $sess 'cmd.jsonl'
    $resp = Join-Path $sess 'resp.jsonl'
    Set-Content -Path $cmd  -Value '' -NoNewline -Encoding Ascii
    Set-Content -Path $resp -Value '' -NoNewline -Encoding Ascii

    $env:SM64CTL_SESSION = ($sess -replace '\\','/')

    # PS 5.1 Start-Process does NOT quote array elements, and every path here can contain spaces
    # ("crackhex update"). Build one command-line string with each path explicitly double-quoted.
    # NOTE: we deliberately DO NOT pass --st here. Loading a savestate at CLI startup can pop a
    # warning dialog that blocks start_lua (the bridge never loads). Instead we launch ROM+Lua only
    # and load the savestate THROUGH the bridge after ready, with ignore_warnings=true.
    $q = { param($p) '"' + $p + '"' }
    $argStr = ('--rom {0} --lua {1}' -f (& $q $Rom), (& $q $script:BridgeLua))
    $proc = Start-Process -FilePath $MupenExe -ArgumentList $argStr -PassThru

    $session = [pscustomobject]@{
        Proc       = $proc
        Pid        = $proc.Id
        SessionDir = $sess
        CmdPath    = $cmd
        RespPath   = $resp
        StatusPath = Join-Path $sess 'status.json'
        NextId     = 1
        RespCursor = [long]0
        Responses  = @{}
        Rom        = $Rom
        Savestate  = $Savestate
    }

    # wait for ready (id 0)
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { throw "mupen exited during startup (code $($proc.ExitCode)). session=$sess" }
        _Drain-Responses $session
        if ($session.Responses.ContainsKey(0)) {
            Write-Verbose "bridge ready: $($session.Responses[0] | ConvertTo-Json -Compress)"
            $session.Responses.Remove(0)
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 150
    }
    if (-not $ready) { throw "bridge did not become ready within $ReadyTimeoutSec s (session=$sess). Is mupen running the ROM?" }

    # Resolve a RELATIVE savestate path against the project root. A relative path (e.g.
    # "tas/movies/task4.st") silently failed Test-Path depending on the caller's CWD -> the
    # savestate was skipped -> mupen sat at the title screen -> get_state returned all zeros.
    if (-not $NoSavestate -and $Savestate -and -not [System.IO.Path]::IsPathRooted($Savestate)) {
        $Savestate = Join-Path $script:Root $Savestate
    }
    $session.Savestate = $Savestate   # store the RESOLVED absolute path (movie export needs it)
    # load the savestate through the bridge (ignore_warnings=true so no dialog can block)
    if (-not $NoSavestate -and $Savestate -and (Test-Path $Savestate)) {
        Send-Cmd $session 'savestate' @{ job='load'; path=$Savestate; ignore=$true } -TimeoutSec 20 | Out-Null
        # let the loaded frame settle
        Send-Cmd $session 'advance' @{ frames=1 } -TimeoutSec 20 | Out-Null
    } elseif (-not $NoSavestate -and $Savestate) {
        Write-Warning "savestate not found -> Mario will be at the title screen (get_state = zeros): $Savestate"
    }
    return $session
}

function Connect-Mupen {
    <# Re-attach to an existing session directory (e.g. a mupen you launched by hand with the bridge). #>
    param([Parameter(Mandatory)][string]$SessionDir)
    $session = [pscustomobject]@{
        Proc = $null; Pid = $null
        SessionDir = $SessionDir
        CmdPath = Join-Path $SessionDir 'cmd.jsonl'
        RespPath = Join-Path $SessionDir 'resp.jsonl'
        StatusPath = Join-Path $SessionDir 'status.json'
        NextId = 1; RespCursor = [long]0; Responses = @{}
        Rom = $null; Savestate = $null
    }
    $session
}

function _Drain-Responses {
    param($Session)
    if (-not (Test-Path $Session.RespPath)) { return }
    $fs = [System.IO.File]::Open($Session.RespPath, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($Session.RespCursor, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
        $Session.RespCursor = $fs.Position
    } finally { $fs.Close() }
    if (-not $text) { return }
    # The bridge appends responses line-by-line, but a read can land MID-WRITE and capture a partial
    # trailing line. Advancing past that fragment (as the old code did) dropped/split the response and
    # desynced id-matching -> phantom zero states, null readmany, mismatched result payloads. Fix: only
    # parse COMPLETE lines (through the last '\n'); carry any partial remainder to the next drain.
    if ($null -eq $Session.PSObject.Properties['RespBuf']) {
        $Session | Add-Member -NotePropertyName RespBuf -NotePropertyValue '' -Force
    }
    $text = [string]$Session.RespBuf + $text
    $lastNl = $text.LastIndexOf("`n")
    if ($lastNl -lt 0) { $Session.RespBuf = $text; return }   # no complete line yet
    $complete = $text.Substring(0, $lastNl)
    $Session.RespBuf = $text.Substring($lastNl + 1)           # keep the partial tail for next time
    foreach ($line in ($complete -split "`n")) {
        $l = $line.Trim()
        if ($l.Length -eq 0) { continue }
        try {
            $obj = $l | ConvertFrom-Json
            $Session.Responses[[int]$obj.id] = $obj
        } catch { Write-Verbose "unparseable resp: $l" }
    }
}

function Send-Cmd {
    <# Low-level: send one command, wait for its response, return the .result (or throw on error). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Op,
        [hashtable]$Args = @{},
        [int]$TimeoutSec = 30,
        [switch]$Raw   # return the whole response object, not just .result
    )
    $id = [int]$Session.NextId
    $Session.NextId = $id + 1
    $msg = @{ id = $id; op = $Op; args = $Args } | ConvertTo-Json -Compress -Depth 8
    # append LF-terminated (bridge expects '\n'); ASCII, no BOM
    [System.IO.File]::AppendAllText($Session.CmdPath, $msg + "`n", (New-Object System.Text.ASCIIEncoding))

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        _Drain-Responses $Session
        if ($Session.Responses.ContainsKey($id)) {
            $r = $Session.Responses[$id]
            $Session.Responses.Remove($id)
            if ($Raw) { return $r }
            if (-not $r.ok) { throw "mupen op '$Op' failed: $($r.err)" }
            return $r.result
        }
        Start-Sleep -Milliseconds 20
    }
    throw "timeout waiting for '$Op' (id=$id) after $TimeoutSec s"
}

# ---- high-level verbs ---------------------------------------------------------------------------
function Test-Mupen      { param($Session) Send-Cmd $Session 'ping' }
function Get-MupenFrame  { param($Session) Send-Cmd $Session 'getframe' }

# The bridge occasionally returns an all-zero 'state' (a load/lag-frame transient, seen clustering right
# after a fresh savestate/memstate load). Mario is never at world-origin (0,0,0) during normal gameplay,
# so treat that as a bad read and re-issue 'state' (idempotent: the frame is already settled). This one
# guard hardens EVERY high-level verb (nav, jumps, collect, scan) that reads Mario's state.
function Test-StateValid {
    param($M)
    if ($null -eq $M) { return $false }
    # all three coordinates exactly 0 => garbage read (a real position is never precisely 0/0/0)
    if (([double]$M.pos_x -eq 0.0) -and ([double]$M.pos_y -eq 0.0) -and ([double]$M.pos_z -eq 0.0)) { return $false }
    return $true
}
function Get-MarioState  {
    param($Session, [int]$Retries = 6)
    $m = Send-Cmd $Session 'state'
    for ($i = 0; $i -lt $Retries -and -not (Test-StateValid $m); $i++) {
        Start-Sleep -Milliseconds 12
        $m = Send-Cmd $Session 'state'
    }
    $m
}

function Read-Mem {
    param($Session, [Parameter(Mandatory)][long]$Addr, [ValidateSet('u8','s8','u16','s16','u32','s32','f32','f64')][string]$Type='u32')
    $r = (Send-Cmd $Session 'read' @{ addr = $Addr; type = $Type }).value
    for ($i = 0; $i -lt 4 -and ($null -eq $r); $i++) { Start-Sleep -Milliseconds 12; $r = (Send-Cmd $Session 'read' @{ addr = $Addr; type = $Type }).value }
    $r
}
function Read-MemMany {
    param($Session, [Parameter(Mandatory)][array]$List)  # each: @{addr=..;type=..}
    # The bridge occasionally returns a null/short 'values' array (same load/lag transient as 'state').
    # Perception (object pool, walls, floors) indexes this array directly, so a null read throws
    # "cannot index into null array". Re-issue until we get the full-length result.
    $need = @($List).Count
    $v = (Send-Cmd $Session 'readmany' @{ list = $List }).values
    for ($i = 0; $i -lt 8 -and (($null -eq $v) -or (@($v).Count -ne $need)); $i++) {
        Start-Sleep -Milliseconds 15
        $v = (Send-Cmd $Session 'readmany' @{ list = $List }).values
    }
    # Never hand back a null/short array: callers index it positionally ($acts[$i]) and would crash with
    # "cannot index into null array". Degrade to a full-length null-filled array so perception cleanly
    # reports "no objects" on a persistent bad read instead of throwing.
    if (($null -eq $v) -or (@($v).Count -ne $need)) { return ,(New-Object object[] $need) }
    $v
}
function Write-Mem {
    param($Session, [Parameter(Mandatory)][long]$Addr, [Parameter(Mandatory)]$Value,
          [ValidateSet('u8','s8','u16','s16','u32','s32','f32','f64')][string]$Type='u32')
    Send-Cmd $Session 'write' @{ addr = $Addr; value = $Value; type = $Type } | Out-Null
}
function Read-ObjActs {
    # Read all 240 object active flags (the SM64 object pool). Retry if the whole array comes back
    # empty/all-zero: in normal gameplay that is a BAD READ (Mario is always an active object), not a
    # truly empty pool — and it is exactly what made `scan` intermittently return nothing (model loops).
    param($Session)
    $GOBJ=0x8033D488; $SZ=0x260; $O_ACT=0x74
    $al = New-Object System.Collections.ArrayList
    for ($i=0; $i -lt 240; $i++) { [void]$al.Add(@{ addr = $GOBJ + $i*$SZ + $O_ACT; type='s16' }) }
    $arr = $al.ToArray()
    for ($try=0; $try -lt 4; $try++) {
        $acts = Read-MemMany -Session $Session -List $arr
        foreach ($a in $acts) { if ($a) { return $acts } }   # any active flag => good read
        Start-Sleep -Milliseconds 15
    }
    $acts   # give up (genuinely empty, or persistent bad read — caller degrades to "no objects")
}
function Read-Range {
    param($Session, [Parameter(Mandatory)][long]$Addr, [Parameter(Mandatory)][int]$Count)
    (Send-Cmd $Session 'readrange' @{ addr = $Addr; count = $Count }).bytes
}

function Set-Input {
    # NOTE: parameter is -Buttons (not -Input: $input is a reserved automatic variable in PowerShell)
    param($Session, [hashtable]$Buttons = @{})
    Send-Cmd $Session 'setinput' @{ input = $Buttons } | Out-Null
}
function Step-Frames {
    <# Advance N frames applying -Buttons (sticky if omitted); returns the SETTLED Mario state.
       The advance reply is read at input-poll time (start of the last frame); we follow it with a
       fresh 'state' read so the returned state matches what every subsequent read/STROOP sees. #>
    param($Session, [int]$Frames = 1, [hashtable]$Buttons, [int]$TimeoutSec = 60)
    $a = @{ frames = $Frames }
    if ($PSBoundParameters.ContainsKey('Buttons')) { $a.input = $Buttons }
    Send-Cmd $Session 'advance' $a -TimeoutSec $TimeoutSec | Out-Null
    # settled state (core is paused after the advance); reject the occasional all-zero garbage read and
    # re-issue 'state' (safe/idempotent — the frame already advanced). Keeps nav/jump loops from veering
    # off on a phantom (0,0,0) position.
    $m = Send-Cmd $Session 'state' @{}
    for ($i = 0; $i -lt 6 -and -not (Test-StateValid $m); $i++) { Start-Sleep -Milliseconds 12; $m = Send-Cmd $Session 'state' @{} }
    # RELIABILITY GUARD (the big one): the core is supposed to idle PAUSED between advances, but it
    # occasionally free-wheels (esp. right after a memstate load). Left unchecked this compounds over a
    # long run into nondeterminism + garbage reads (the "runs start fine then flake/loop" degradation).
    # global_timer must advance by exactly $Frames per advance; if it didn't, the core ran loose -> force
    # a pause and re-read so the next advance starts from a frozen, deterministic state.
    $gt = [int64]$m.global_timer
    $exp = [int64]$Session.SM64_ExpGt
    if ($Session.SM64_GtInit -and ($gt -ne ($exp + $Frames))) {
        Send-Cmd $Session 'pause' @{ value = $true } | Out-Null
        $m = Send-Cmd $Session 'state' @{}
        for ($i = 0; $i -lt 6 -and -not (Test-StateValid $m); $i++) { Start-Sleep -Milliseconds 12; $m = Send-Cmd $Session 'state' @{} }
        $gt = [int64]$m.global_timer
    }
    $Session | Add-Member -NotePropertyName SM64_ExpGt -NotePropertyValue $gt -Force
    $Session | Add-Member -NotePropertyName SM64_GtInit -NotePropertyValue $true -Force
    $m
}

function Invoke-Replay {
    <# Batched max-speed replay: apply a whole per-frame input list in ONE bridge call (no per-frame
       IPC round-trip, no id-drift risk). Returns sampled Mario states.
       -Frames   array of [x,y,btn]; btn is a bitmask 0x80=A 0x40=B 0x20=Z 0x10=Start 0x08=R 0x04=L
                 (the same convention as the .m64/CSV body, so a task CSV feeds straight in).
       -Samples  1-based frame indices to capture (default: only the final frame).
       -StopStars stop the first frame num_stars >= this and return that frame (great for "when is
                 the star grabbed"). -SampleAll captures every frame (large payload; use sparingly).
       Load a memstate first to replay a segment from a checkpoint. Returns .frames = list of {f, s}. #>
    param($Session, [Parameter(Mandatory)][array]$Frames, [int[]]$Samples, [int]$StopStars,
          [switch]$SampleAll, [int]$TimeoutSec = 180)
    $a = @{ frames = $Frames }
    if ($Samples)   { $a.samples   = $Samples }
    if ($StopStars) { $a.stopstars = $StopStars }
    if ($SampleAll) { $a.sampleall = $true }
    $r = Send-Cmd $Session 'replaylist' $a -TimeoutSec $TimeoutSec
    # replaylist jumps global_timer by the whole list; drop the Step-Frames gt baseline so the next
    # single-step advance re-initialises instead of firing a spurious pause on a stale timer.
    if ($Session.PSObject.Properties['SM64_GtInit']) { $Session.SM64_GtInit = $false }
    $r
}

# NOTE: mupen slots are 1-based (do_slot subtracts 1). Savestate ops are async; Send-Cmd only
# returns once the bridge's completion callback fired, so the state is safe to use immediately after.
function Save-State { param($Session, [int]$Slot = 1, [string]$Path)
    if ($Path) { Send-Cmd $Session 'savestate' @{ job='save'; path=$Path } | Out-Null }
    else       { Send-Cmd $Session 'savestate' @{ job='save'; slot=$Slot } | Out-Null } }
function Load-State { param($Session, [int]$Slot = 1, [string]$Path)
    if ($Path) { Send-Cmd $Session 'savestate' @{ job='load'; path=$Path } | Out-Null }
    else       { Send-Cmd $Session 'savestate' @{ job='load'; slot=$Slot } | Out-Null } }

# In-memory savestates (fast, disk-free) — the primitive for search/branching.
function Save-MemState { param($Session, [int]$Slot = 1) Send-Cmd $Session 'memstate' @{ job='save'; slot=$Slot } }
function Load-MemState {
    param($Session, [int]$Slot = 1)
    $r = Send-Cmd $Session 'memstate' @{ job='load'; slot=$Slot }
    # A memstate load resets global_timer and can leave the core free-wheeling for a frame: force a pause
    # and drop the Step-Frames gt-tracking baseline so the next advance re-initialises instead of
    # comparing against a stale (pre-load) timer. This is what keeps a search loop (load/step/repeat)
    # deterministic run after run.
    Send-Cmd $Session 'pause' @{ value = $true } | Out-Null
    if ($Session.PSObject.Properties['SM64_GtInit']) { $Session.SM64_GtInit = $false }
    $r
}

function Search-Rollouts {
    <# Evaluate many candidate input-sequences from ONE checkpoint — the core primitive for TAS search.
       For each candidate it: loads memstate -Slot, replays the candidate at 5000x (Invoke-Replay),
       then scores the reached state. Returns one row per candidate {index, score, state, frames},
       sorted best-first (highest score). The emulator is left on the BEST candidate's end state.

       -Candidates  array of frame-lists; each frame-list is an array of [x,y,btn] (CSV/m64 convention).
       -Slot        memstate slot holding the segment start (Save-MemState it first).
       -Score       scriptblock given a hashtable {final=<state>, frames=<sampled>, index=<i>}; returns a
                    number (higher = better). Return [double]::NegativeInfinity to REJECT a candidate
                    (e.g. constraint violated: fell off, took damage, wrong facing). Default score = 0.
       -Samples/-SampleAll  forwarded to Invoke-Replay so -Score can inspect the whole trajectory
                    (e.g. min health, never-left-floor). Default captures only the final frame.
       -Keep        how many top rows to return (default: all). #>
    param($Session, [Parameter(Mandatory)][array]$Candidates, [int]$Slot = 1,
          [scriptblock]$Score, [int[]]$Samples, [switch]$SampleAll, [int]$Keep = 0,
          [int]$TimeoutSec = 180)
    $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Load-MemState $Session -Slot $Slot | Out-Null
        $rep = @{ Session = $Session; Frames = $Candidates[$i]; TimeoutSec = $TimeoutSec }
        if ($Samples)   { $rep.Samples = $Samples }
        if ($SampleAll) { $rep.SampleAll = $true }
        $r = Invoke-Replay @rep
        $final = $r.frames[-1].s
        $sc = 0.0
        if ($Score) { $sc = [double](& $Score @{ final = $final; frames = $r.frames; index = $i }) }
        [void]$rows.Add([pscustomobject]@{ index = $i; score = $sc; state = $final; frames = $Candidates[$i] })
    }
    $sorted = $rows | Sort-Object -Property score -Descending
    if ($Keep -gt 0) { $sorted = $sorted | Select-Object -First $Keep }
    # leave the emulator on the best candidate's end-state (convenience for chaining)
    $best = $sorted | Select-Object -First 1
    if ($best -and $best.score -gt [double]::NegativeInfinity) {
        Load-MemState $Session -Slot $Slot | Out-Null
        Invoke-Replay -Session $Session -Frames $best.frames -TimeoutSec $TimeoutSec | Out-Null
    }
    return $sorted
}

function Optimize-Rollout {
    <# Hill-climb an input-sequence from a checkpoint. Starts from -Base, and each round makes -Batch
       mutated candidates via -Mutate, scores them with Search-Rollouts, and keeps the best if it beats
       the incumbent. Returns {frames=<best input-seq>, score, state, history=<score per round>}.

       -Base    starting frame-list ([x,y,btn] rows). Pass @() to build from scratch in -Mutate.
       -Mutate  scriptblock given the current best frame-list; returns ONE new candidate frame-list.
                Called -Batch times per round (use $args randomness for diversity).
       -Score   as in Search-Rollouts (hashtable -> number; -Inf rejects).
       -Rounds  hill-climb rounds (default 8). -Batch candidates per round (default 12). #>
    param($Session, [Parameter(Mandatory)][scriptblock]$Mutate, [Parameter(Mandatory)][scriptblock]$Score,
          [array]$Base = @(), [int]$Slot = 1, [int]$Rounds = 8, [int]$Batch = 12,
          [int[]]$Samples, [switch]$SampleAll, [int]$TimeoutSec = 180)
    # score the incumbent
    $bestFrames = $Base; $bestScore = [double]::NegativeInfinity; $bestState = $null
    $hist = New-Object System.Collections.ArrayList
    if ($Base -and $Base.Count -gt 0) {
        $seed = Search-Rollouts -Session $Session -Candidates @(,$Base) -Slot $Slot -Score $Score -Samples $Samples -SampleAll:$SampleAll -TimeoutSec $TimeoutSec
        $bestScore = $seed[0].score; $bestState = $seed[0].state
    }
    for ($r = 0; $r -lt $Rounds; $r++) {
        $cands = New-Object System.Collections.ArrayList
        for ($b = 0; $b -lt $Batch; $b++) { [void]$cands.Add((& $Mutate $bestFrames)) }
        $res = Search-Rollouts -Session $Session -Candidates $cands.ToArray() -Slot $Slot -Score $Score -Samples $Samples -SampleAll:$SampleAll -TimeoutSec $TimeoutSec
        if ($res[0].score -gt $bestScore) { $bestScore = $res[0].score; $bestFrames = $res[0].frames; $bestState = $res[0].state }
        [void]$hist.Add([math]::Round($bestScore, 3))
    }
    return [pscustomobject]@{ frames = $bestFrames; score = $bestScore; state = $bestState; history = $hist.ToArray() }
}

function Set-Speed  { param($Session, [ValidateSet('normal','maximum')][string]$Mode, [int]$Value)
    $a=@{}; if($Mode){$a.mode=$Mode}; if($Value){$a.value=$Value}; Send-Cmd $Session 'speed' $a | Out-Null }
function Set-Pause  { param($Session, [bool]$Value=$true) Send-Cmd $Session 'pause' @{ value=$Value } | Out-Null }

function Play-Movie { param($Session, [Parameter(Mandatory)][string]$Path, [bool]$ReadOnly=$true)
    Send-Cmd $Session 'movie' @{ job='play'; path=$Path; readonly=$ReadOnly } | Out-Null }
function Stop-Movie { param($Session) Send-Cmd $Session 'movie' @{ job='stop' } | Out-Null }

function Invoke-MupenAction { param($Session, [Parameter(Mandatory)][string]$Name) Send-Cmd $Session 'action' @{ name=$Name } }
function Get-MupenActions   { param($Session, [string]$Filter='') (Send-Cmd $Session 'actions' @{ filter=$Filter }).actions }
function Save-Screenshot    { param($Session, [Parameter(Mandatory)][string]$Path) Send-Cmd $Session 'screenshot' @{ path=$Path } }
function Invoke-MupenLua    { param($Session, [Parameter(Mandatory)][string]$Code) Send-Cmd $Session 'eval' @{ code=$Code } }

function Stop-Mupen {
    param($Session)
    try { Send-Cmd $Session 'quit' @{} -TimeoutSec 3 | Out-Null } catch {}
    if ($Session.Proc -and -not $Session.Proc.HasExited) {
        try { $Session.Proc.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 400 } catch {}
        if (-not $Session.Proc.HasExited) { try { $Session.Proc.Kill() } catch {} }
    }
}

# ================================================================================================
#  STROOP — variable database (parse Config/*Data.xml) + compute from RAM
# ================================================================================================

# Base pointers/addresses used by STROOP <Data base="..."> entries (US). Object entries need an
# object address supplied at read time; the "static" bases below cover Mario/Camera/globals.
$script:StroopBases = @{
    Mario  = 0x8033B170
    Object = 0            # per-object; caller supplies -ObjectAddr
    Camera = 0x8033C520
    None   = 0            # specialType (computed) — handled case-by-case
}

function Get-StroopVarDefs {
    <#
      Parse one or more STROOP *Data.xml files into a flat list of variable definitions:
      { Name, Group, Type, OffsetHex, Offset, Base, JsonName, SpecialType, File }.
      Default: MarioData + MiscData + CameraData (the live-state ones).
    #>
    param([string[]]$Files = @('MarioData.xml','MiscData.xml','HudData.xml','CameraData.xml'))
    $out = New-Object System.Collections.ArrayList
    foreach ($f in $Files) {
        $p = Join-Path $script:StroopCfg $f
        if (-not (Test-Path $p)) { continue }
        [xml]$doc = Get-Content -Raw -Path $p
        foreach ($d in $doc.VarData.Data) {
            $offHex = $d.offset
            $off = $null
            if ($offHex) { $off = [Convert]::ToInt64(($offHex -replace '^0x',''),16) }
            [void]$out.Add([pscustomobject]@{
                Name        = $d.'#text'
                Group       = $d.groupList
                Type        = $d.type
                OffsetHex   = $offHex
                Offset      = $off
                Base        = $d.base
                JsonName    = $d.jsonName
                SpecialType = $d.specialType
                File        = $f
            })
        }
    }
    $out
}

function Get-StroopVars {
    <#
      Compute STROOP variables live from a running session. Reads every DECLARATIVE variable
      (base+offset+type) directly from RAM in one batch, then adds the most-used COMPUTED
      (specialType) variables ported from the decomp. Returns an ordered hashtable Name -> value.
    #>
    param($Session, [string[]]$Files = @('MarioData.xml','CameraData.xml'), [switch]$IncludeComputed)
    $defs = Get-StroopVarDefs -Files $Files
    $typeMap = @{ 'float'='f32'; 'double'='f64'; 'uint'='u32'; 'int'='s32';
                  'ushort'='u16'; 'short'='s16'; 'byte'='u8'; 'sbyte'='s8' }
    # build batch of declarative reads
    $batch = New-Object System.Collections.ArrayList
    $meta  = New-Object System.Collections.ArrayList
    foreach ($d in $defs) {
        if ($null -eq $d.Offset) { continue }
        if (-not $script:StroopBases.ContainsKey($d.Base)) { continue }
        $baseAddr = $script:StroopBases[$d.Base]
        if ($baseAddr -eq 0) { continue }
        $t = $typeMap[$d.Type]; if (-not $t) { continue }
        [void]$batch.Add(@{ addr = $baseAddr + $d.Offset; type = $t })
        [void]$meta.Add($d)
    }
    $result = [ordered]@{}
    if ($batch.Count -gt 0) {
        $vals = Read-MemMany $Session -List $batch.ToArray()
        for ($i=0; $i -lt $meta.Count; $i++) {
            $result[$meta[$i].Name] = $vals[$i]
        }
    }
    if ($IncludeComputed) {
        $m = Get-MarioState $Session
        foreach ($kv in (Get-StroopComputed $m).GetEnumerator()) { $result[$kv.Key] = $kv.Value }
        # De Facto Speed = forward_vel * floor.normal.y  (STROOP's real formula). Read the floor
        # triangle pointer (gMarioState+0x68) and its normal (Triangle+0x1C/0x20/0x24).
        $floorPtr = [int64](Read-Mem $Session -Addr (0x8033B170 + 0x68) -Type u32)
        if ($floorPtr -ne 0 -and $floorPtr -ge 0x80000000) {
            $nx = Read-Mem $Session -Addr ($floorPtr + 0x1C) -Type f32
            $ny = Read-Mem $Session -Addr ($floorPtr + 0x20) -Type f32
            $nz = Read-Mem $Session -Addr ($floorPtr + 0x24) -Type f32
            $result['Floor Normal X'] = $nx; $result['Floor Normal Y'] = $ny; $result['Floor Normal Z'] = $nz
            $result['De Facto Speed'] = [double]$m.forward_vel * [double]$ny
        } else {
            $result['De Facto Speed'] = [double]$m.forward_vel
        }
        # Parallel-universe indices: home PU (|coord|<32768) maps to 0.
        $result['PU X'] = [math]::Floor(([double]$m.pos_x + 32768) / 65536)
        $result['PU Z'] = [math]::Floor(([double]$m.pos_z + 32768) / 65536)
        $result['QStep DeFacto/4'] = ($result['De Facto Speed'] / 4.0)
    }
    $result
}

function Get-StroopComputed {
    <# The common STROOP specialType variables, ported from the SM64 decomp, from a Mario state pack. #>
    param([Parameter(Mandatory)]$M)
    $c = [ordered]@{}
    # H Speed (already gForwardVel); De Facto Speed = forwardVel * (floor slope factor) — approximated
    # as forwardVel when grounded normal ~1; exact needs the floor normal. Provide the raw vector mag:
    $c['H Speed (vector)'] = [math]::Sqrt([double]$M.vel_x*$M.vel_x + [double]$M.vel_z*$M.vel_z)
    $c['Total Speed']      = [math]::Sqrt([double]$M.vel_x*$M.vel_x + [double]$M.vel_y*$M.vel_y + [double]$M.vel_z*$M.vel_z)
    # angles: STROOP shows unsigned 0..65535; decomp stores s16
    $c['Face Yaw (u16)']   = ([int]$M.face_yaw -band 0xFFFF)
    $c['Intended Yaw (u16)']= ([int]$M.intended_yaw -band 0xFFFF)
    $c['DYaw (intended-face)'] = ((([int]$M.intended_yaw - [int]$M.face_yaw + 32768) % 65536) - 32768)
    $c['Height Above Floor'] = [double]$M.pos_y - [double]$M.floor_height
    $c['Height Below Ceiling'] = [double]$M.ceil_height - [double]$M.pos_y
    $c
}

function Start-Stroop {
    <# Launch the real STROOP.exe GUI so a human can attach it to the running mupen for a visual cross-check. #>
    if (-not (Test-Path $script:StroopExe)) { throw "STROOP.exe not found: $script:StroopExe" }
    Start-Process -FilePath $script:StroopExe -PassThru
}

# ================================================================================================
#  aitest2-improved — Rust CPU sim + GPU bruteforcers
# ================================================================================================

function Invoke-Cargo {
    <# Run cargo without letting stderr warnings trip PS 5.1's NativeCommandError; returns
       @{ Output=<lines>; ExitCode=<n> }. #>
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string[]]$CargoArgs)
    Push-Location $WorkDir
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & cargo @CargoArgs 2>&1 | ForEach-Object { "$_" }
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    } finally { $ErrorActionPreference = $old; Pop-Location }
}

function Invoke-SimExample {
    <#
      Build+run an sm64-sim-rs example (the CPU simulator side). Returns captured output lines.
      e.g. Invoke-SimExample -Name selftest -Release
    #>
    param([Parameter(Mandatory)][string]$Name, [string[]]$ExtraArgs=@(), [switch]$Release)
    $io = Join-Path $script:SimRoot 'sm64-sim-rs'
    $a = @('run')
    if ($Release) { $a += '--release' }
    $a += @('-p','sm64-sim-io','--example', $Name)
    if ($ExtraArgs.Count) { $a += @('--') + $ExtraArgs }
    $r = Invoke-Cargo -WorkDir $io -CargoArgs $a
    if ($r.ExitCode -ne 0) { Write-Warning "cargo exited $($r.ExitCode)" }
    $r.Output
}

function Get-SimExamples {
    param()
    $dir = Join-Path $script:SimRoot 'sm64-sim-rs\crates\sm64-sim-io\examples'
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Filter *.rs | ForEach-Object { $_.BaseName }
}

function Invoke-SimBruteforce {
    <#
      Build+run a GPU bruteforcer binary from sm64-gpu-handover/spirv_run.
      Env passthrough: GEN, BATCHES, OUT, TX/TY/TZ, FULL_VERIFY (set via -EnvVars @{GEN=300}).
      NOTE: the first build compiles the rust-gpu backend and is slow.
    #>
    param(
        [ValidateSet('flying_bruteforce','guided_flying_bruteforce','flying_collision_bruteforce',
                     'guided_flying_collision_bruteforce','guided_flight_refine','flight_replay')]
        [string]$Bin = 'guided_flying_bruteforce',
        [hashtable]$EnvVars = @{},
        [string[]]$BinArgs = @(),
        [switch]$BuildOnly
    )
    $probe = Join-Path $script:SimRoot 'sm64-gpu-handover\spirv_probe'
    $run   = Join-Path $script:SimRoot 'sm64-gpu-handover\spirv_run'
    if (-not (Test-Path $run)) { throw "spirv_run not found under $script:SimRoot" }
    # build the .spv first (first build compiles the rust-gpu backend and is slow)
    $b = Invoke-Cargo -WorkDir $probe -CargoArgs @('build','--release')
    $b.Output | Write-Output
    if ($BuildOnly) { return }
    foreach ($k in $EnvVars.Keys) { Set-Item -Path "Env:$k" -Value ([string]$EnvVars[$k]) }
    $a = @('run','--release','--bin',$Bin)
    if ($BinArgs.Count) { $a += @('--') + $BinArgs }
    (Invoke-Cargo -WorkDir $run -CargoArgs $a).Output
}

function Clear-MupenSessions {
    <#
      .SYNOPSIS  Delete ephemeral session\run_* IPC scratch dirs (cmd/resp.jsonl, logs) to reclaim disk.
                 These hold no results, savestates or seeds — pure per-run bridge scratch.
      .PARAMETER KeepLast  Keep the N most-recently-modified sessions (default 0 = remove all).
      .EXAMPLE  Clear-MupenSessions            # wipe all scratch
      .EXAMPLE  Clear-MupenSessions -KeepLast 5  # keep the 5 newest (recent debug logs)
    #>
    param([int]$KeepLast = 0)
    $dir = Join-Path $script:ControlDir 'session'
    if (-not (Test-Path $dir)) { return [pscustomobject]@{ Removed = 0; Kept = 0 } }
    $all  = @(Get-ChildItem $dir -Directory -Filter 'run_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $keep = if ($KeepLast -gt 0) { @($all | Select-Object -First $KeepLast) } else { @() }
    $keepPaths = $keep | ForEach-Object { $_.FullName }
    # ne jamais supprimer une session vivante (heartbeat status.json recent) : plusieurs mupen en parallele
    $live = { param($d) $st = Join-Path $d.FullName 'status.json'; (Test-Path $st) -and ((Get-Date) - (Get-Item $st).LastWriteTime).TotalSeconds -lt 120 }
    $kill = @($all | Where-Object { $keepPaths -notcontains $_.FullName -and -not (& $live $_) })
    foreach ($d in $kill) { Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ Removed = $kill.Count; Kept = ($all.Count - $kill.Count) }
}

function Confirm-Movie {
    <#
      .SYNOPSIS  THE verify gate: replay a COMPLETE movie on mupen and report the whole result.
                 Never call a built run "good" until this passes. Counts red coins by POSITION
                 (red_coins RAM reads 0 on the JP rom), tracks mount/shell-kept/void/DUR.
      .PARAMETER Sticks   Path to a full-movie [[x,y,btn],...] json (from the .st, incl. pre-mount prefix). btn bit 0x0080 = A.
      .PARAMETER Savestate  Starting .st (default = Task 3 on-foot start).
      .PARAMETER Margin   Coin-distance margin (matches the sim's coin_margin; default 0).
      .OUTPUTS  PSCustomObject: Mounted, MountFrame, ShellKept, Coins (count), CoinSlots, VoidFrame, Dur, Frames, Ok
    #>
    param(
        [Parameter(Mandatory)][string]$Sticks,
        [string]$Savestate = $script:DefaultSt,
        [double]$Margin = 0.0,
        [double]$RequireCoins = 5
    )
    if (-not (Test-Path $Sticks)) { throw "Sticks file not found: $Sticks" }
    $objPath = Join-Path $script:SimRoot 'sm64-sim-rs\crates\sm64-sim-io\tests\data\objective.json'
    if (-not (Test-Path $objPath)) { throw "objective.json not found: $objPath" }
    $obj = Get-Content $objPath -Raw | ConvertFrom-Json
    $coins = $obj.coins; $mr = $obj.mario_hitbox_radius; $mh = $obj.mario_hitbox_height; $voidY = $obj.void_out_y
    $seq = Get-Content $Sticks -Raw | ConvertFrom-Json
    $RIDE = 0x10000
    $collected = @{}; foreach ($c in $coins) { $collected[[int]$c.slot] = $false }
    $s = Start-Mupen -Savestate $Savestate
    try {
        $mountFrame = -1; $voidFrame = -1; $shellKept = $true; $everMounted = $false
        for ($i = 0; $i -lt $seq.Count; $i++) {
            $st = $seq[$i]
            $btn = @{ X = [int]$st[0]; Y = [int]$st[1] }
            if ((([int]$st[2]) -band 0x0080) -ne 0) { $btn.A = $true }
            Step-Frames -Session $s -Count 1 -Buttons $btn | Out-Null
            $m = Get-MarioState -Session $s
            $riding = ($m.action -band $RIDE) -ne 0
            if ($riding -and -not $everMounted) { $everMounted = $true; $mountFrame = $i + 1 }
            if ($everMounted -and $voidFrame -lt 0 -and -not $riding) { $shellKept = $false }
            # count red coins by position (coin_distance <= 0), only while riding
            if ($riding) {
                foreach ($c in $coins) {
                    if ($collected[[int]$c.slot]) { continue }
                    $dx = $m.pos_x - $c.x; $dz = $m.pos_z - $c.z
                    $r = [math]::Max($mr + $c.hitbox_radius - $Margin, 1.0)
                    $dxz = [math]::Sqrt($dx*$dx + $dz*$dz) - $r
                    $dy = [math]::Max($c.y - ($m.pos_y + $mh), $m.pos_y - ($c.y + $c.hitbox_height))
                    if ([math]::Max($dxz,0) + [math]::Max($dy,0) -le 0) { $collected[[int]$c.slot] = $true }
                }
            }
            if ($everMounted -and $m.pos_y -lt $voidY) { $voidFrame = $i + 1; break }
        }
        $slots = @($collected.Keys | Where-Object { $collected[$_] } | Sort-Object)
        $ncoins = $slots.Count
        $dur = if ($mountFrame -ge 0 -and $voidFrame -ge 0) { $voidFrame - $mountFrame } else { -1 }
        $ok = ($everMounted -and $shellKept -and $ncoins -ge $RequireCoins -and $voidFrame -ge 0)
        [pscustomobject]@{
            Ok = $ok; Mounted = $everMounted; MountFrame = $mountFrame; ShellKept = $shellKept
            Coins = $ncoins; CoinSlots = ($slots -join ','); VoidFrame = $voidFrame; Dur = $dur; Frames = $seq.Count
        }
    } finally { Stop-Mupen -Session $s }
}

function Invoke-Drive {
    <#
      .SYNOPSIS  Closed-loop console driver: steer Mario toward a world (x,z) target with full tilt,
                 using live intended_yaw feedback to track the camera (no camera-relative guessing).
                 Records and RETURNS every [x,y,btn] applied, so a native console movie can be assembled.
      .PARAMETER Session   Live mupen session (required; caller owns start/stop).
      .PARAMETER TargetX/TargetZ  World-space destination.
      .PARAMETER MaxFrames  Frame cap for this leg (default 120).
      .PARAMETER StopDist   Stop when within this XZ distance of the target (default 0 = only stop on mount/cap).
      .PARAMETER StopOnMount  Stop as soon as Mario mounts the shell (default $true).
      .OUTPUTS  PSCustomObject: Inputs (array of [x,y,btn]), Mounted, Fwd, X, Z, Frames
      .NOTE  Camera estimate persists in $script:SM64_Ccur across calls (a route = several Invoke-Drive legs).
             Set $script:SM64_Ccur before the first leg (e.g. -20028 at the Task-3 start) or pass -InitCam.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][double]$TargetX,
        [Parameter(Mandatory)][double]$TargetZ,
        [int]$MaxFrames = 120,
        [double]$StopDist = 0.0,
        [bool]$StopOnMount = $true,
        [double]$InitCam = [double]::NaN
    )
    $TAU = [math]::PI * 2
    if (-not [double]::IsNaN($InitCam)) { $script:SM64_Ccur = $InitCam }
    if ($null -eq $script:SM64_Ccur) { $script:SM64_Ccur = -20028 }
    $inputs = @(); $RIDE = 0x10000; $mounted = $false
    for ($f = 0; $f -lt $MaxFrames; $f++) {
        $m = Get-MarioState -Session $Session
        if ($StopOnMount -and (($m.action -band $RIDE) -ne 0)) { $mounted = $true; break }
        $d = [math]::Sqrt(($TargetX-$m.pos_x)*($TargetX-$m.pos_x) + ($TargetZ-$m.pos_z)*($TargetZ-$m.pos_z))
        if ($StopDist -gt 0 -and $d -lt $StopDist) { break }
        $B = [int][math]::Round(([math]::Atan2($TargetX-$m.pos_x, $TargetZ-$m.pos_z)/$TAU)*65536)
        $phi = $script:SM64_Ccur - $B
        while ($phi -gt 32768) { $phi -= 65536 }; while ($phi -lt -32768) { $phi += 65536 }
        $r = $phi/65536.0*$TAU
        $x = [int][math]::Round(120*[math]::Sin($r)); $y = [int][math]::Round(120*[math]::Cos($r))
        Step-Frames -Session $Session -Count 1 -Buttons @{ X=$x; Y=$y } | Out-Null
        $m = Get-MarioState -Session $Session
        $script:SM64_Ccur = $m.intended_yaw + $phi
        while ($script:SM64_Ccur -gt 32768) { $script:SM64_Ccur -= 65536 }; while ($script:SM64_Ccur -lt -32768) { $script:SM64_Ccur += 65536 }
        $inputs += ,@($x, $y, 0)
        if (($m.action -band $RIDE) -ne 0) { $mounted = $true }
    }
    $mf = Get-MarioState -Session $Session
    [pscustomobject]@{ Inputs = $inputs; Mounted = $mounted; Fwd = $mf.forward_vel; X = $mf.pos_x; Z = $mf.pos_z; Frames = $inputs.Count }
}

function Invoke-DriveYaws {
    <#
      .SYNOPSIS  Replay a camera-INDEPENDENT world-yaw sequence (from the sim's DUMPYAWS) on the live
                 console, converting each [worldYaw, mag, btn] to a stick via the live camera. This is
                 the bridge that lets an SA-optimised tour play natively on mupen regardless of the
                 console's camera history (the sim->console camera mismatch that blocked fast-mount builds).
      .PARAMETER Session  Live mupen session (Mario already mounted at the matching state).
      .PARAMETER Yaws     Array of [worldYaw(int), mag(0..32), btn]; btn bit 0x8000 = A.
      .PARAMETER InitCam  Camera-yaw estimate to seed $script:SM64_Ccur (default: keep current).
      .OUTPUTS  PSCustomObject: Inputs ([x,y,btn] applied), Frames, plus final Mario fields.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Yaws,
        [double]$InitCam = [double]::NaN,
        [switch]$Precise,
        [int]$Slot = 2
    )
    $TAU = [math]::PI * 2
    if (-not [double]::IsNaN($InitCam)) { $script:SM64_Ccur = $InitCam }
    if ($null -eq $script:SM64_Ccur) { $script:SM64_Ccur = -20028 }
    function _wrap($a){ while($a -gt 32768){$a-=65536}; while($a -lt -32768){$a+=65536}; $a }
    function _stick($phi,$R){ $r=$phi/65536.0*$TAU; ,@([int][math]::Round($R*[math]::Sin($r)), [int][math]::Round($R*[math]::Cos($r))) }
    $inputs = @()
    foreach ($row in $Yaws) {
        $B = [int]$row[0]; $mag = [double]$row[1]; $btn = [int]$row[2]
        $a = ($btn -band 0x8000) -ne 0
        if ($mag -lt 1.0) {
            $bt = @{ X = 0; Y = 0 }; if ($a) { $bt.A = $true }
            Step-Frames -Session $Session -Count 1 -Buttons $bt | Out-Null
            $inputs += ,@(0, 0, [int]($(if ($a) { 0x0080 } else { 0 }))); continue
        }
        $R = if ($mag -ge 31.0) { 120.0 } else { [math]::Max([math]::Min([math]::Sqrt(128.0*$mag)+6.0, 120.0), 8.0) }
        $phi0 = _wrap ($script:SM64_Ccur - $B)
        if (-not $Precise) {
            $st = _stick $phi0 $R
            $bt = @{ X = $st[0]; Y = $st[1] }; if ($a) { $bt.A = $true }
            Step-Frames -Session $Session -Count 1 -Buttons $bt | Out-Null
            $m = Get-MarioState -Session $Session
            $script:SM64_Ccur = _wrap ($m.intended_yaw + $phi0)
            $inputs += ,@($st[0], $st[1], [int]($(if ($a) { 0x0080 } else { 0 }))); continue
        }
        # PRECISE: probe the LIVE camera via memstate (intended_yaw = camera - phi), then apply the exact
        # phi. Two probes absorb the small deadzone non-linearity. Far faster + more accurate than a grid.
        Save-MemState -Session $Session -Slot $Slot | Out-Null
        $phi = $phi0
        foreach($probe in 0,1){
            $st=_stick $phi $R
            Load-MemState -Session $Session -Slot $Slot | Out-Null
            $bt=@{X=$st[0];Y=$st[1]}; if($a){$bt.A=$true}
            Step-Frames -Session $Session -Count 1 -Buttons $bt | Out-Null
            $mm=Get-MarioState -Session $Session
            $C = _wrap ($mm.intended_yaw + $phi)   # live camera this frame
            $phi = _wrap ($C - $B)
        }
        $st=_stick $phi $R
        Load-MemState -Session $Session -Slot $Slot | Out-Null
        $bt=@{X=$st[0];Y=$st[1]}; if($a){$bt.A=$true}
        Step-Frames -Session $Session -Count 1 -Buttons $bt | Out-Null
        $mm=Get-MarioState -Session $Session
        $script:SM64_Ccur = _wrap ($mm.intended_yaw + $phi)
        $inputs += ,@($st[0], $st[1], [int]($(if ($a) { 0x0080 } else { 0 })))
    }
    $mf = Get-MarioState -Session $Session
    [pscustomobject]@{ Inputs = $inputs; Frames = $inputs.Count; Fwd = $mf.forward_vel; X = $mf.pos_x; Y = $mf.pos_y; Z = $mf.pos_z; Action = $mf.action }
}

function Invoke-FollowPath {
    <#
      .SYNOPSIS  Closed-loop path follower: steer Mario along a fixed world-space trajectory with
                 look-ahead pure-pursuit, self-correcting each frame (camera- and stick-reconstruction
                 independent). Traverses an SA-optimised path robustly; a faster start covers it in
                 fewer frames. Records/returns every [x,y,btn] applied.
      .PARAMETER Path       Array of [x,z] world points (the trajectory to follow).
      .PARAMETER Lookahead  Aim this many path points ahead of the nearest point (default 6).
      .PARAMETER MaxFrames  Hard cap (default 520).
      .PARAMETER VoidY      Stop when pos_y drops below this (default -6143).
      .PARAMETER EndDist    Stop when within this of the final path point (default 60).
      .PARAMETER InitCam    Seed for $script:SM64_Ccur.
      .OUTPUTS  Inputs, Frames, Progress (path index reached), plus final Mario fields.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Path,
        [int]$Lookahead = 6,
        [int]$MaxFrames = 520,
        [double]$VoidY = -6143.0,
        [double]$EndDist = 60.0,
        [double]$InitCam = [double]::NaN
    )
    $TAU = [math]::PI * 2
    if (-not [double]::IsNaN($InitCam)) { $script:SM64_Ccur = $InitCam }
    if ($null -eq $script:SM64_Ccur) { $script:SM64_Ccur = -20028 }
    $RIDE = 0x10000; $n = $Path.Count; $prog = 0; $inputs = @()
    for ($f = 0; $f -lt $MaxFrames; $f++) {
        $m = Get-MarioState -Session $Session
        if (($m.action -band $RIDE) -eq 0) { break }        # lost the shell
        if ($m.pos_y -lt $VoidY) { break }                  # voided
        # advance progress to the nearest path point ahead (small forward window)
        $bd = [double]::PositiveInfinity; $best = $prog
        $hi = [math]::Min($prog + 20, $n - 1)
        for ($j = $prog; $j -le $hi; $j++) {
            $d = ($Path[$j][0]-$m.pos_x)*($Path[$j][0]-$m.pos_x) + ($Path[$j][1]-$m.pos_z)*($Path[$j][1]-$m.pos_z)
            if ($d -lt $bd) { $bd = $d; $best = $j }
        }
        $prog = $best
        $ti = [math]::Min($prog + $Lookahead, $n - 1)
        $tx = $Path[$ti][0]; $tz = $Path[$ti][1]
        # Past the end of the path, keep aiming at the final point so Mario carries on into the void
        # (the run ends on VoidY, not here). EndDist is retained only as a legacy no-op guard.
        $B = [int][math]::Round(([math]::Atan2($tx-$m.pos_x, $tz-$m.pos_z)/$TAU)*65536)
        $phi = $script:SM64_Ccur - $B
        while ($phi -gt 32768) { $phi -= 65536 }; while ($phi -lt -32768) { $phi += 65536 }
        $r = $phi/65536.0*$TAU
        $x = [int][math]::Round(120*[math]::Sin($r)); $y = [int][math]::Round(120*[math]::Cos($r))
        Step-Frames -Session $Session -Count 1 -Buttons @{ X=$x; Y=$y } | Out-Null
        $m2 = Get-MarioState -Session $Session
        $script:SM64_Ccur = $m2.intended_yaw + $phi
        while ($script:SM64_Ccur -gt 32768) { $script:SM64_Ccur -= 65536 }; while ($script:SM64_Ccur -lt -32768) { $script:SM64_Ccur += 65536 }
        $inputs += ,@($x, $y, 0)
    }
    $mf = Get-MarioState -Session $Session
    [pscustomobject]@{ Inputs = $inputs; Frames = $inputs.Count; Progress = $prog; Fwd = $mf.forward_vel; X = $mf.pos_x; Y = $mf.pos_y; Z = $mf.pos_z; Action = $mf.action }
}

# Known task-4 chest / star world positions (identified via STROOP behavior scan; see find_chests).
# High-level targets so a model can say "go to chest 1" instead of reverse-engineering the object pool.
$script:SM64_Task4Targets = [ordered]@{
    chest1 = @(-495.0, -5912.0); chest2 = @(2675.0, -6809.0)
    chest3 = @(5079.0, -5472.0); chest4 = @(-407.0, -3056.0)
}
function Get-Task4Targets { $script:SM64_Task4Targets }

# ---- Perception: name & list the objects around Mario (so a model isn't navigating blind) ----------
$script:SM64_ObjNames = $null
function Get-ObjNameMap {
    # behaviorScriptAddress (segmented 0x13xxxxxx, int) -> human object name, from STROOP's ObjectAssociations.xml
    if ($null -ne $script:SM64_ObjNames) { return $script:SM64_ObjNames }
    $map = @{}
    $path = Join-Path $script:Root 'STROOP\STROOP\Config\ObjectAssociations.xml'
    if (Test-Path $path) {
        try {
            [xml]$xml = Get-Content -Raw -Path $path
            foreach ($n in $xml.SelectNodes('//*[@behaviorScriptAddress]')) {
                $addr = "$($n.behaviorScriptAddress)"
                if ($addr -match '^0x[0-9A-Fa-f]+$') {
                    $key = [Convert]::ToInt64($addr, 16)
                    $nm = "$($n.name)"; if ([string]::IsNullOrEmpty($nm)) { $nm = $n.LocalName }
                    if (-not $map.ContainsKey($key)) { $map[$key] = $nm }
                }
            }
        } catch {}
    }
    $script:SM64_ObjNames = $map
    $map
}
function Get-NearbyObjects {
    <# List active objects near Mario with their name, position, distance and height delta. Uses ONE
       batched RAM read for the active flags and one for the payload (fast).
       -Filter (substring/regex, case-insensitive): only objects whose name matches — use it to FIND a
       target anywhere (e.g. "red coin", "coin", "star"), not just the nearest few. #>
    param($Session, [double]$Radius = 3000.0, [int]$Max = 15, [string]$Filter = '')
    $GOBJ=0x8033D488; $SZ=0x260; $O_ACT=0x74; $O_X=0xA0; $O_Y=0xA4; $O_Z=0xA8; $O_BHV=0x20C; $SEGTAB=0x8033B400
    $m = Get-MarioState -Session $Session
    # segment table stores the physical address (no KSEG0 base) -> add 0x80000000 (decimal, to dodge
    # PowerShell's signed-hex-literal trap) to get the RAM base of segment 0x13.
    $rawseg = [long](Read-Mem -Session $Session -Addr ($SEGTAB + 0x13*4) -Type 'u32')
    if ($rawseg -lt 0) { $rawseg += 4294967296 }
    $seg13 = 2147483648 + ($rawseg -band 16777215)   # 0x80000000 + (raw & 0x00FFFFFF)
    $names = Get-ObjNameMap
    $al = New-Object System.Collections.ArrayList
    for ($i=0; $i -lt 240; $i++) { [void]$al.Add(@{ addr = $GOBJ + $i*$SZ + $O_ACT; type='s16' }) }
    $acts = Read-ObjActs -Session $Session
    $activeIdx = @(); for ($i=0; $i -lt 240; $i++) { if ($acts[$i]) { $activeIdx += $i } }
    if ($activeIdx.Count -eq 0) { return @() }
    $dl = New-Object System.Collections.ArrayList
    foreach ($i in $activeIdx) {
        $base = $GOBJ + $i*$SZ
        [void]$dl.Add(@{addr=$base+$O_BHV;type='u32'}); [void]$dl.Add(@{addr=$base+$O_X;type='f32'})
        [void]$dl.Add(@{addr=$base+$O_Y;type='f32'}); [void]$dl.Add(@{addr=$base+$O_Z;type='f32'})
    }
    $vals = Read-MemMany -Session $Session -List $dl.ToArray()
    $out = New-Object System.Collections.ArrayList
    for ($k=0; $k -lt $activeIdx.Count; $k++) {
        $bhv=[long]$vals[$k*4]; if ($bhv -lt 0) { $bhv += 4294967296 }   # u32 as unsigned long
        $x=[double]$vals[$k*4+1]; $y=[double]$vals[$k*4+2]; $z=[double]$vals[$k*4+3]
        $dx=$x-$m.pos_x; $dz=$z-$m.pos_z; $dist=[math]::Sqrt($dx*$dx+$dz*$dz)
        if ($dist -gt $Radius) { continue }
        $seg = 318767104 + (($bhv - $seg13) -band 16777215)   # 0x13000000 + ((bhv-seg13) & 0x00FFFFFF)
        $nm = $names[[long]$seg]; if ([string]::IsNullOrEmpty($nm)) { $nm = ('bhv 0x{0:X8}' -f $bhv) }
        if ($nm -eq 'Mario') { continue }
        if ($Filter -and ($nm -notmatch $Filter)) { continue }
        [void]$out.Add([pscustomobject]@{ name=$nm; x=[int][math]::Round($x); z=[int][math]::Round($z);
            dist=[int][math]::Round($dist); dx=[int][math]::Round($dx); dz=[int][math]::Round($dz); dy=[int][math]::Round($y-$m.pos_y) })
    }
    @($out | Sort-Object dist | Select-Object -First $Max)
}

function Get-NearestObject {
    # Nearest ACTIVE object whose name matches $Filter, with its base address + absolute x/y/z + dist.
    param($Session, [Parameter(Mandatory)][string]$Filter)
    $GOBJ=0x8033D488; $SZ=0x260; $O_ACT=0x74; $O_X=0xA0; $O_Y=0xA4; $O_Z=0xA8; $O_BHV=0x20C; $SEGTAB=0x8033B400
    $m = Get-MarioState -Session $Session
    $rawseg=[long](Read-Mem -Session $Session -Addr ($SEGTAB+0x13*4) -Type 'u32'); if($rawseg -lt 0){$rawseg+=4294967296}
    $seg13=2147483648+($rawseg -band 16777215); $names=Get-ObjNameMap
    $al=New-Object System.Collections.ArrayList; for($i=0;$i -lt 240;$i++){[void]$al.Add(@{addr=$GOBJ+$i*$SZ+$O_ACT;type='s16'})}
    $acts=Read-ObjActs -Session $Session
    $idx=@(); for($i=0;$i -lt 240;$i++){ if($acts[$i]){ $idx+=$i } }
    if($idx.Count -eq 0){ return $null }
    $dl=New-Object System.Collections.ArrayList
    foreach($i in $idx){ $b=$GOBJ+$i*$SZ; [void]$dl.Add(@{addr=$b+$O_BHV;type='u32'});[void]$dl.Add(@{addr=$b+$O_X;type='f32'});[void]$dl.Add(@{addr=$b+$O_Y;type='f32'});[void]$dl.Add(@{addr=$b+$O_Z;type='f32'}) }
    $vv=Read-MemMany -Session $Session -List $dl.ToArray()
    $best=$null; $bestD=[double]::PositiveInfinity
    for($k=0;$k -lt $idx.Count;$k++){
        $bhv=[long]$vv[$k*4]; if($bhv -lt 0){$bhv+=4294967296}
        $nm=$names[[long](318767104+(($bhv-$seg13) -band 16777215))]; if([string]::IsNullOrEmpty($nm)){continue}
        if($nm -eq 'Mario' -or ($nm -notmatch $Filter)){ continue }
        $x=[double]$vv[$k*4+1]; $y=[double]$vv[$k*4+2]; $z=[double]$vv[$k*4+3]
        $d=[math]::Sqrt(($x-$m.pos_x)*($x-$m.pos_x)+($z-$m.pos_z)*($z-$m.pos_z))
        if($d -lt $bestD){ $bestD=$d; $best=@{ name=$nm; x=$x; y=$y; z=$z; base=($GOBJ+$idx[$k]*$SZ); dist=$d } }
    }
    $best
}

function Get-MatchingObjects {
    # All ACTIVE objects whose name matches $Filter, each with base + absolute x/y/z. Sorted by XZ distance
    # to Mario, or to (NearX,NearZ) if given (to target a specific one).
    param($Session, [Parameter(Mandatory)][string]$Filter, [int]$Max = 8, $NearX = $null, $NearZ = $null)
    $GOBJ=0x8033D488; $SZ=0x260; $O_ACT=0x74; $O_X=0xA0; $O_Y=0xA4; $O_Z=0xA8; $O_BHV=0x20C; $SEGTAB=0x8033B400
    $m = Get-MarioState -Session $Session
    $rawseg=[long](Read-Mem -Session $Session -Addr ($SEGTAB+0x13*4) -Type 'u32'); if($rawseg -lt 0){$rawseg+=4294967296}
    $seg13=2147483648+($rawseg -band 16777215); $names=Get-ObjNameMap
    $al=New-Object System.Collections.ArrayList; for($i=0;$i -lt 240;$i++){[void]$al.Add(@{addr=$GOBJ+$i*$SZ+$O_ACT;type='s16'})}
    $acts=Read-ObjActs -Session $Session
    $idx=@(); for($i=0;$i -lt 240;$i++){ if($acts[$i]){ $idx+=$i } }
    if($idx.Count -eq 0){ return @() }
    $dl=New-Object System.Collections.ArrayList
    foreach($i in $idx){ $b=$GOBJ+$i*$SZ; [void]$dl.Add(@{addr=$b+$O_BHV;type='u32'});[void]$dl.Add(@{addr=$b+$O_X;type='f32'});[void]$dl.Add(@{addr=$b+$O_Y;type='f32'});[void]$dl.Add(@{addr=$b+$O_Z;type='f32'}) }
    $vv=Read-MemMany -Session $Session -List $dl.ToArray()
    $out=New-Object System.Collections.ArrayList
    for($k=0;$k -lt $idx.Count;$k++){
        $bhv=[long]$vv[$k*4]; if($bhv -lt 0){$bhv+=4294967296}
        $nm=$names[[long](318767104+(($bhv-$seg13) -band 16777215))]; if([string]::IsNullOrEmpty($nm)){continue}
        if($nm -eq 'Mario' -or ($nm -notmatch $Filter)){ continue }
        $x=[double]$vv[$k*4+1]; $y=[double]$vv[$k*4+2]; $z=[double]$vv[$k*4+3]
        $d=[math]::Sqrt(($x-$m.pos_x)*($x-$m.pos_x)+($z-$m.pos_z)*($z-$m.pos_z))
        [void]$out.Add(@{ name=$nm; x=$x; y=$y; z=$z; base=($GOBJ+$idx[$k]*$SZ); dist=$d })
    }
    if ($null -ne $NearX -and $null -ne $NearZ) {
        @($out | Sort-Object { [math]::Sqrt(($_.x-$NearX)*($_.x-$NearX)+($_.z-$NearZ)*($_.z-$NearZ)) } | Select-Object -First $Max)
    } else {
        @($out | Sort-Object { $_.dist } | Select-Object -First $Max)
    }
}

function Invoke-Chase {
    <#
      .SYNOPSIS  Navigate toward a MOVING object identified by its object-pool BASE ADDRESS, re-reading the
                 target's LIVE position every chunk so a walking target (goomba, bob-omb, a coin that rolls/
                 falls) is never lost — "scan en continu pour ne pas perdre le fil". Steers with the same
                 camera-robust feedback as Invoke-Goto; climbs toward an elevated target when stalled.
                 Stops when within StopDist (XZ) of the target, or when the target goes INACTIVE
                 (defeated/collected -> .Gone), or at MaxSteps. Records every input for movie export.
      .OUTPUTS   { Reached, Gone, Steps, Dist, X, Z, Inputs }
    #>
    param($Session, [Parameter(Mandatory)][int64]$Base, [double]$StopDist = 90.0,
          [int]$MaxSteps = 250, [int]$Frames = 4, [switch]$Climb)
    $inputs = New-Object System.Collections.ArrayList
    $mb = Step-Frames -Session $Session -Frames 1 -Buttons @{ X=0; Y=100 }; [void]$inputs.Add(@(0,100,0)); $cam=[double]$mb.intended_yaw
    $reached=$false; $gone=$false; $best=[double]::PositiveInfinity; $prevXZ=[double]::PositiveInfinity; $stall=0; $m=$mb
    for ($step=1; $step -le $MaxSteps; $step++) {
        if ([int](Read-Mem -Session $Session -Addr ($Base+0x74) -Type 's16') -eq 0) { $gone=$true; break }  # target gone
        $tx=[double](Read-Mem -Session $Session -Addr ($Base+0xA0) -Type 'f32')
        $ty=[double](Read-Mem -Session $Session -Addr ($Base+0xA4) -Type 'f32')
        $tz=[double](Read-Mem -Session $Session -Addr ($Base+0xA8) -Type 'f32')
        $m = Get-MarioState -Session $Session
        $dx=$tx-$m.pos_x; $dz=$tz-$m.pos_z; $dist=[math]::Sqrt($dx*$dx+$dz*$dz)
        if ($dist -lt $best) { $best=$dist }
        if ($dist -lt $StopDist) { $reached=$true; break }
        if ($Climb -and (($ty-$m.pos_y) -gt 150) -and (-not (Test-Airborne $m))) {
            if (($prevXZ-$dist) -lt 8) { $stall++ } else { $stall=0 }
            $prevXZ=$dist
            if ($stall -ge 10) {
                $sh=Get-StickPure -Cam $cam -dx $dx -dz $dz
                $mv=Invoke-Move -Session $Session -Move 'long_jump' -StickX $sh.X -StickY $sh.Y
                foreach($f in $mv.Inputs){ [void]$inputs.Add($f) }
                $mb=Step-Frames -Session $Session -Frames 1 -Buttons @{X=0;Y=100}; [void]$inputs.Add(@(0,100,0)); $cam=[double]$mb.intended_yaw; $stall=0
                continue
            }
        }
        $sh=Get-StickPure -Cam $cam -dx $dx -dz $dz
        $m2=Step-Frames -Session $Session -Frames $Frames -Buttons @{X=$sh.X;Y=$sh.Y}
        for($fi=0;$fi -lt $Frames;$fi++){ [void]$inputs.Add(@([int]$sh.X,[int]$sh.Y,0)) }
        $cam=Update-Cam -IntendedYaw ([double]$m2.intended_yaw) -Phi $sh.Phi
    }
    [pscustomobject]@{ Reached=$reached; Gone=$gone; Steps=$step; Dist=[math]::Round($best,1); X=$m.pos_x; Z=$m.pos_z; Inputs=$inputs.ToArray() }
}

function Invoke-Collect {
    <#
      .SYNOPSIS  Find objects matching a name and COLLECT one, VERIFYING it was actually picked up (object
                 goes inactive OR a counter rises: red_coins/coins/stars) — not just "got close". Tries the
                 nearest matches in turn (reloading a checkpoint between tries so a failed attempt doesn't strand
                 Mario). For an in-air collectible it centers XZ exactly then does a plain vertical jump (grab
                 radius ~100-130, so no need to climb the full height; a run-up would de-center). Polyvalent.
      .OUTPUTS   { Collected, Found, Name, X, Z, Dist, Reason, RedCoinsBefore/After, ..., Frames, Inputs }
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaxSteps = 260,
        [ValidateSet('walk','longjump')][string]$Style = 'walk',
        [int]$MaxCandidates = 4,
        $NearX = $null, $NearZ = $null   # target the object nearest THIS point (else nearest to Mario)
    )
    $cands = @(Get-MatchingObjects -Session $Session -Filter $Name -NearX $NearX -NearZ $NearZ)
    if ($cands.Count -eq 0) { return [pscustomobject]@{ Collected=$false; Found=$false; Reason="aucun objet correspondant a '$Name' n'a ete trouve dans le niveau"; Frames=0; Inputs=@() } }
    # If the caller targets a SPECIFIC object (near_x/near_z), try only that one (fast, matches intent).
    if ($null -ne $NearX -and $null -ne $NearZ) { $MaxCandidates = 1 }
    $m0 = Get-MarioState -Session $Session
    $rc0=[int]$m0.red_coins; $c0=[int]$m0.num_coins; $s0=[int]$m0.num_stars
    Save-MemState -Session $Session -Slot 15 | Out-Null   # checkpoint to retry candidates without stranding Mario
    $n = [math]::Min($MaxCandidates, $cands.Count)
    $bestInputs=@(); $bestName=$cands[0].name; $bestDist=1e18
    for ($ci=0; $ci -lt $n; $ci++) {
        $obj = $cands[$ci]
        if ($ci -gt 0) { Load-MemState -Session $Session -Slot 15 | Out-Null }
        $inputs = New-Object System.Collections.ArrayList
        $isColl = {
            $mm = Get-MarioState -Session $Session
            $dch = [math]::Sqrt(($obj.x-$mm.pos_x)*($obj.x-$mm.pos_x)+($obj.z-$mm.pos_z)*($obj.z-$mm.pos_z))
            # Verify by the target's OWN signal, not any loose counter (a coin grabbed en route != star/target).
            # Red coins -> red_coins ; star -> num_stars ; anything -> the TARGET object going inactive while
            # Mario is right at it (near-gated so a far slot-reuse is not a false positive).
            $act = [int](Read-Mem -Session $Session -Addr ($obj.base+0x74) -Type 's16')
            ([int]$mm.red_coins -gt $rc0) -or ([int]$mm.num_stars -gt $s0) -or (($act -eq 0) -and ($dch -lt 220))
        }
        # 1) approach in 3D (climbs if elevated)
        $r = Invoke-Goto -Session $Session -TargetX $obj.x -TargetY $obj.y -TargetZ $obj.z -StopDist 150 -MaxSteps $MaxSteps -Style $Style
        foreach ($f in $r.Inputs) { [void]$inputs.Add($f) }
        $collected = & $isColl
        # 1.5) PUNCH finish for ENEMIES (goomba, bob-omb, ...). An enemy is DEFEATED by an attack, not a
        #      touch-grab, and a jump/dive makes Mario fall off a small platform -> a punch keeps him planted.
        #      The enemy WALKS, so re-scan its CURRENT position (via Invoke-Chase, which re-reads the live
        #      position each frame) before swinging, so the punch doesn't hit a stale spot.
        $isEnemy = [string]$obj.name -match '(?i)goomba|bob-?omb|koopa|bully|chuckya|piranha|scuttlebug|fly ?guy|snufit|spindrift|skeeter|mr\. ?i|amp|whomp|thwomp|monty|pokey'
        if (-not $collected -and $isEnemy) {
            $mc = Get-MarioState -Session $Session
            $xz = [math]::Sqrt(($obj.x-$mc.pos_x)*($obj.x-$mc.pos_x)+($obj.z-$mc.pos_z)*($obj.z-$mc.pos_z))
            if ($xz -lt 300) {
                # the enemy WALKS -> re-scan its CURRENT position so the punch doesn't swing at a stale spot
                $ecur = Get-MatchingObjects -Session $Session -Filter ([regex]::Escape([string]$obj.name)) -NearX $obj.x -NearZ $obj.z | Select-Object -First 1
                $ex = if ($ecur) { [double]$ecur.x } else { $obj.x }
                $ez = if ($ecur) { [double]$ecur.z } else { $obj.z }
                $rc = Invoke-Goto -Session $Session -TargetX $ex -TargetZ $ez -StopDist 45 -MaxSteps 50
                foreach ($f in $rc.Inputs) { [void]$inputs.Add($f) }
                $mb = Step-Frames -Session $Session -Frames 1 -Buttons @{X=0;Y=100}; [void]$inputs.Add(@(0,100,0))
                $sh = Get-StickPure -Cam ([double]$mb.intended_yaw) -dx ($ex-$mb.pos_x) -dz ($ez-$mb.pos_z)
                $mv = Invoke-Move -Session $Session -Move 'punch' -StickX $sh.X -StickY $sh.Y
                foreach ($f in $mv.Inputs) { [void]$inputs.Add($f) }
                for ($cf=0; $cf -lt 8 -and -not $collected; $cf++) { $mj = Step-Frames -Session $Session -Frames 1 -Buttons @{}; [void]$inputs.Add(@(0,0,0)); $collected = & $isColl }
            }
        }
        # 2) AIR-GRAB finish: exact XZ centering + plain vertical jump
        if (-not $collected) {
            $mc = Get-MarioState -Session $Session
            $xz = [math]::Sqrt(($obj.x-$mc.pos_x)*($obj.x-$mc.pos_x)+($obj.z-$mc.pos_z)*($obj.z-$mc.pos_z))
            if ($xz -lt 700) {
                for ($att=1; $att -le 4 -and -not $collected; $att++) {
                    $rc = Invoke-Goto -Session $Session -TargetX $obj.x -TargetZ $obj.z -StopDist 15 -MaxSteps 40
                    foreach ($f in $rc.Inputs) { [void]$inputs.Add($f) }
                    if (& $isColl) { $collected = $true; break }
                    $mj = Step-Frames -Session $Session -Frames 1 -Buttons @{ A=$true }; [void]$inputs.Add(@(0,0,0x80))
                    if ([int]$mj.red_coins -gt $rc0 -or [int]$mj.num_stars -gt $s0) { $collected = $true; break }
                    for ($cf=0; $cf -lt 16 -and -not $collected; $cf++) {
                        $mj = Step-Frames -Session $Session -Frames 1 -Buttons @{}; [void]$inputs.Add(@(0,0,0))
                        if ([int]$mj.red_coins -gt $rc0 -or [int]$mj.num_stars -gt $s0) { $collected = $true; break }
                    }
                    if (-not $collected) { $collected = & $isColl }
                }
            }
        }
        # 3) DROPPED COIN (enemies): a beaten enemy drops a coin. It WALKS-spawns and can FALL, so grab the
        #    coin NEAREST TO MARIO now (not the enemy's stale spot), gently (walk onto its XZ + a small hop;
        #    a big jump would knock Mario off a ledge). Skipped if no coin actually dropped (coinless enemy).
        if ($collected -and $isEnemy) {
            for ($k=0; $k -lt 6; $k++) { $mj = Step-Frames -Session $Session -Frames 1 -Buttons @{}; [void]$inputs.Add(@(0,0,0)) }
            $cBefore = [int]$mj.num_coins
            $coin = Get-NearbyObjects -Session $Session -Radius 450 | Where-Object { $_.name -match '(?i)coin' } | Sort-Object dist | Select-Object -First 1
            if ($coin) {
                $got = $false
                for ($att=1; $att -le 2 -and -not $got; $att++) {
                    $rc2 = Invoke-Goto -Session $Session -TargetX $coin.x -TargetZ $coin.z -StopDist 20 -MaxSteps 45
                    foreach ($f in $rc2.Inputs) { [void]$inputs.Add($f) }
                    $got = ([int](Get-MarioState -Session $Session).num_coins -gt $cBefore)
                    if (-not $got) {
                        $mj = Step-Frames -Session $Session -Frames 1 -Buttons @{A=$true}; [void]$inputs.Add(@(0,0,0x80))
                        for ($cf=0; $cf -lt 20 -and -not $got; $cf++) { $mj = Step-Frames -Session $Session -Frames 1 -Buttons @{}; [void]$inputs.Add(@(0,0,0)); $got = ([int]$mj.num_coins -gt $cBefore) }
                    }
                }
            }
        }
        $m1 = Get-MarioState -Session $Session
        $dObj = [math]::Sqrt(($m1.pos_x-$obj.x)*($m1.pos_x-$obj.x)+($m1.pos_y-$obj.y)*($m1.pos_y-$obj.y)+($m1.pos_z-$obj.z)*($m1.pos_z-$obj.z))
        if ($collected) {
            return [pscustomobject]@{
                Collected=$true; Found=$true; Name=$obj.name; X=$m1.pos_x; Z=$m1.pos_z; Dist=[math]::Round($dObj,1); Reason='ramasse'
                RedCoinsBefore=$rc0; RedCoinsAfter=[int]$m1.red_coins; CoinsBefore=$c0; CoinsAfter=[int]$m1.num_coins; StarsBefore=$s0; StarsAfter=[int]$m1.num_stars
                Frames=$inputs.Count; Inputs=$inputs.ToArray()
            }
        }
        if ($dObj -lt $bestDist) { $bestDist=$dObj; $bestName=$obj.name; $bestInputs=$inputs.ToArray() }
    }
    # TOTAL FAILURE -> restore the pre-collect state: un-strand Mario, keep prior progress (red_coins),
    # keep the level's objects loaded. A failed collect must be NON-destructive so the next command works.
    Load-MemState -Session $Session -Slot 15 | Out-Null
    $m1 = Get-MarioState -Session $Session
    [pscustomobject]@{
        Collected=$false; Found=$true; Name=$bestName; X=$m1.pos_x; Z=$m1.pos_z; Dist=[math]::Round($bestDist,1)
        Reason=("PAS ramasse apres {0} candidat(s) - meilleur approche dist3D={1:N0} (plateforme/route requise). Etat restaure, rien perdu." -f $n,$bestDist)
        RedCoinsBefore=$rc0; RedCoinsAfter=[int]$m1.red_coins; CoinsBefore=$c0; CoinsAfter=[int]$m1.num_coins; StarsBefore=$s0; StarsAfter=[int]$m1.num_stars
        Frames=0; Inputs=@()   # state was restored on failure -> no net movement recorded
    }
}

function Invoke-GrabPlatformStar {
    <#
      .SYNOPSIS  Collect a HIGH star that floats above a platform but is out of jump range from the floor
                 (e.g. the Jolly Roger Bay cave chest star). Route discovered from the task's TAS: climb
                 ONTO the highest platform under the star, face AWAY from the star, then BACKFLIP up into
                 it (a backflip gains ~430 units and the star's hitbox is generous, ~xz<100 / ygap<130).
                 No frame-precise chaining needed. Uses only goto + backflip; records every input for movie.
      .OUTPUTS   { Grabbed, Found, Name, StarsBefore, StarsAfter, PlatformY, Peak, Inputs, Frames, Reason }
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [string]$Filter = 'Power Star',
        [double]$PlatformRadius = 300.0,   # search floors within this XZ of the star for the launch platform
        [int[]]$SettleTries = @(26,22,30,18,34)  # backflip works over a window; try a few if the first misses
    )
    $star = Get-MatchingObjects -Session $Session -Filter $Filter | Select-Object -First 1
    if (-not $star) { return [pscustomobject]@{ Grabbed=$false; Found=$false; Reason="aucune etoile '$Filter' trouvee (scan)"; Inputs=@(); Frames=0 } }
    $SX=[double]$star.x; $SY=[double]$star.y; $SZ=[double]$star.z; $sbase=[int64]$star.base
    $s0 = [int](Get-MarioState -Session $Session).num_stars
    Save-MemState -Session $Session -Slot 15 | Out-Null   # non-destructive restore point on failure

    # 1) climb toward the star to get within floor-scan range of the platform
    $g1 = Invoke-Goto -Session $Session -TargetX $SX -TargetZ $SZ -TargetY $SY -MaxSteps 150 -StopDist 80
    # 2) find the launch platform = highest floor within PlatformRadius of the star's XZ
    $floors = Get-NearbyFloors -Session $Session
    $plat = $floors | Where-Object {
        [math]::Sqrt(($_.x-$SX)*($_.x-$SX)+($_.z-$SZ)*($_.z-$SZ)) -le $PlatformRadius
    } | Sort-Object { -[double]$_.height } | Select-Object -First 1
    if (-not $plat) { Load-MemState -Session $Session -Slot 15 | Out-Null
        return [pscustomobject]@{ Grabbed=$false; Found=$true; Name=$star.name; Reason='aucune plateforme de lancement trouvee sous l etoile'; Inputs=@(); Frames=0; StarsBefore=$s0; StarsAfter=$s0 } }
    $PX=[double]$plat.x; $PZ=[double]$plat.z; $PY=[double]$plat.height

    $stepFn = { param($inputs,$btn) $mm=Step-Frames -Session $Session -Frames 1 -Buttons $btn; [void]$inputs.Add(@([int]$btn.X,[int]$btn.Y,(ConvertTo-BtnMask $btn))); $mm }

    # --- Nav ONCE onto the platform (a SINGLE 3D climb straight to the platform XZ reaches it; climbing
    #     toward the star first breaks the approach). Record the nav inputs, checkpoint it (slot 14). ---
    Load-MemState -Session $Session -Slot 15 | Out-Null
    $navInputs = New-Object System.Collections.ArrayList
    $gp = Invoke-Goto -Session $Session -TargetX $PX -TargetZ $PZ -TargetY ($PY + 8) -MaxSteps 200 -StopDist 45
    foreach ($f in $gp.Inputs) { [void]$navInputs.Add($f) }
    $m = Get-MarioState -Session $Session
    if ([math]::Abs([double]$m.floor_height - $PY) -gt 60) {
        Load-MemState -Session $Session -Slot 15 | Out-Null
        return [pscustomobject]@{ Grabbed=$false; Found=$true; Name=$star.name; StarsBefore=$s0; StarsAfter=$s0; PlatformY=[math]::Round($PY)
            Reason=("nav n a pas atteint la plateforme (floor={0:N0}, cible={1:N0}). Etat restaure." -f $m.floor_height,$PY); Inputs=@(); Frames=0 }
    }
    Save-MemState -Session $Session -Slot 14 | Out-Null   # Mario standing on the launch platform

    # --- From the platform checkpoint, try the backflip grab (fast: no re-nav), sweeping the settle count ---
    foreach ($settle in $SettleTries) {
        Load-MemState -Session $Session -Slot 14 | Out-Null
        $att = New-Object System.Collections.ArrayList
        $m = Get-MarioState -Session $Session
        # orient to face AWAY from the star (a backflip travels backward -> carries Mario toward the star)
        $mb = & $stepFn $att @{ X=0; Y=100 }; $cam=[double]$mb.intended_yaw
        $dx = -($SX-$m.pos_x); $dz = -($SZ-$m.pos_z); $sh = Get-StickPure -Cam $cam -dx $dx -dz $dz
        for ($k=0; $k -lt 4; $k++) { $null = & $stepFn $att @{ X=$sh.X; Y=$sh.Y } }
        # settle to a stable idle, then BACKFLIP (crouch, then A while crouched)
        for ($k=0; $k -lt $settle; $k++) { $null = & $stepFn $att @{} }
        $null = & $stepFn $att @{ Z=$true }
        $null = & $stepFn $att @{ Z=$true; A=$true }
        $grab=$false; $peak=-99999.0
        for ($f=0; $f -lt 55; $f++) {
            $m = & $stepFn $att @{}
            if ([double]$m.pos_y -gt $peak) { $peak=[double]$m.pos_y }
            if ([int]$m.num_stars -gt $s0) { $grab=$true; break }
            if (((([int64]$m.action) -band 0x1C0) -ne 0x80) -and $f -gt 4) { break }  # landed, no grab
        }
        if ($grab) {
            $all = New-Object System.Collections.ArrayList
            foreach ($f in $navInputs) { [void]$all.Add($f) }; foreach ($f in $att) { [void]$all.Add($f) }
            return [pscustomobject]@{
                Grabbed=$true; Found=$true; Name=$star.name; StarsBefore=$s0; StarsAfter=[int]$m.num_stars
                PlatformY=[math]::Round($PY); Peak=[math]::Round($peak); Reason=("etoile attrapee (backflip depuis plateforme y={0:N0}, settle={1})" -f $PY,$settle)
                Inputs=$all.ToArray(); Frames=$all.Count
            }
        }
    }
    Load-MemState -Session $Session -Slot 15 | Out-Null   # non-destructive on failure
    [pscustomobject]@{
        Grabbed=$false; Found=$true; Name=$star.name; StarsBefore=$s0; StarsAfter=$s0
        PlatformY=[math]::Round($PY); Reason='backflip depuis la plateforme n a pas attrape (positionnement a affiner). Etat restaure.'
        Inputs=@(); Frames=0
    }
}

function Get-NearbyWalls {
    <# List the COLLISION WALL triangles near Mario (surfaces with a near-horizontal normal), so a model
       can see what it will bump into. Filters to walls within Radius (XZ, to the triangle centroid) and
       spanning Mario's height (+/- YTol). Returns nearest-first: {dist, x, z, dx, dz, nx, nz, y_lo, y_hi, type}.
       nx/nz = the wall's outward normal (the way it faces / pushes Mario back). #>
    param($Session, [double]$Radius = 1500.0, [int]$Max = 12, [double]$YTol = 200.0)
    $PTR_ADDR=0x8038EE9C; $CNT_ADDR=0x80361170; $SZ=0x30
    $m = Get-MarioState -Session $Session
    $ptr = [long](Read-Mem -Session $Session -Addr $PTR_ADDR -Type 'u32'); if ($ptr -lt 0) { $ptr += 4294967296 }
    $cnt = [int](Read-Mem -Session $Session -Addr $CNT_ADDR -Type 's32')
    if ($cnt -le 0 -or $ptr -le 0) { return @() }
    if ($cnt -gt 3000) { $cnt = 3000 }
    # pass 1: read every surface's normal.y (chunked) -> wall = |normY| <= 0.01
    $ny = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $cnt) {
        $n = [math]::Min(256, $cnt - $i)
        $chunk = New-Object System.Collections.ArrayList
        for ($j=0; $j -lt $n; $j++) { [void]$chunk.Add(@{ addr = $ptr + ($i+$j)*$SZ + 0x20; type='f32' }) }
        foreach ($v in (Read-MemMany -Session $Session -List $chunk.ToArray())) { [void]$ny.Add([double]$v) }
        $i += $n
    }
    $wallIdx = @(); for ($k=0; $k -lt $cnt; $k++) { if ([math]::Abs($ny[$k]) -le 0.01) { $wallIdx += $k } }
    if ($wallIdx.Count -eq 0) { return @() }
    # pass 2: verts + normal(x,z) + type for wall surfaces only
    $dl = New-Object System.Collections.ArrayList
    foreach ($k in $wallIdx) {
        $b = $ptr + $k*$SZ
        foreach ($o in 0x0A,0x0C,0x0E,0x10,0x12,0x14,0x16,0x18,0x1A) { [void]$dl.Add(@{addr=$b+$o;type='s16'}) }
        [void]$dl.Add(@{addr=$b+0x1C;type='f32'}); [void]$dl.Add(@{addr=$b+0x24;type='f32'}); [void]$dl.Add(@{addr=$b+0x00;type='s16'})
    }
    $vv = Read-MemMany -Session $Session -List $dl.ToArray()
    $out = New-Object System.Collections.ArrayList
    for ($w=0; $w -lt $wallIdx.Count; $w++) {
        $o = $w*12
        $x1=$vv[$o];$y1=$vv[$o+1];$z1=$vv[$o+2];$x2=$vv[$o+3];$y2=$vv[$o+4];$z2=$vv[$o+5];$x3=$vv[$o+6];$y3=$vv[$o+7];$z3=$vv[$o+8]
        $nx=[double]$vv[$o+9];$nz=[double]$vv[$o+10];$type=[int]$vv[$o+11]
        $cx=($x1+$x2+$x3)/3.0; $cz=($z1+$z2+$z3)/3.0
        $ylo=[math]::Min($y1,[math]::Min($y2,$y3)); $yhi=[math]::Max($y1,[math]::Max($y2,$y3))
        $dx=$cx-$m.pos_x; $dz=$cz-$m.pos_z; $dist=[math]::Sqrt($dx*$dx+$dz*$dz)
        if ($dist -gt $Radius) { continue }
        if ($m.pos_y -lt ($ylo - $YTol) -or $m.pos_y -gt ($yhi + $YTol)) { continue }   # wall not at Mario's height
        [void]$out.Add([pscustomobject]@{ dist=[int][math]::Round($dist); x=[int][math]::Round($cx); z=[int][math]::Round($cz)
            dx=[int][math]::Round($dx); dz=[int][math]::Round($dz); nx=[math]::Round($nx,2); nz=[math]::Round($nz,2)
            y_lo=[int]$ylo; y_hi=[int]$yhi; type=('0x{0:X}' -f $type) })
    }
    @($out | Sort-Object dist | Select-Object -First $Max)
}

function Get-NearbyFloors {
    <# List nearby FLOOR/PLATFORM surfaces (normal.y > 0.5 = standable), grouped by height level so a model
       can see WHERE it can stand and at what height (to plan a vertical route). Returns, per distinct
       height level, the nearest point: { height, dh (height-mario.y), dist, x, z, dx, dz }. #>
    param($Session, [double]$Radius = 2500.0, [int]$Max = 12)
    $PTR_ADDR=0x8038EE9C; $CNT_ADDR=0x80361170; $SZ=0x30
    $m = Get-MarioState -Session $Session
    $ptr = [long](Read-Mem -Session $Session -Addr $PTR_ADDR -Type 'u32'); if ($ptr -lt 0) { $ptr += 4294967296 }
    $cnt = [int](Read-Mem -Session $Session -Addr $CNT_ADDR -Type 's32')
    if ($cnt -le 0 -or $ptr -le 0) { return @() }
    if ($cnt -gt 3000) { $cnt = 3000 }
    $ny = New-Object System.Collections.ArrayList; $i = 0
    while ($i -lt $cnt) {
        $n = [math]::Min(256, $cnt - $i); $chunk = New-Object System.Collections.ArrayList
        for ($j=0; $j -lt $n; $j++) { [void]$chunk.Add(@{ addr = $ptr + ($i+$j)*$SZ + 0x20; type='f32' }) }
        foreach ($v in (Read-MemMany -Session $Session -List $chunk.ToArray())) { [void]$ny.Add([double]$v) }
        $i += $n
    }
    $floorIdx = @(); for ($k=0; $k -lt $cnt; $k++) { if ($ny[$k] -gt 0.5) { $floorIdx += $k } }
    if ($floorIdx.Count -eq 0) { return @() }
    $dl = New-Object System.Collections.ArrayList
    foreach ($k in $floorIdx) { $b = $ptr + $k*$SZ; foreach ($o in 0x0A,0x0C,0x0E,0x10,0x12,0x14,0x16,0x18,0x1A) { [void]$dl.Add(@{addr=$b+$o;type='s16'}) } }
    $vv = Read-MemMany -Session $Session -List $dl.ToArray()
    $levels = @{}   # rounded-height -> nearest {dist,x,z,height}
    for ($w=0; $w -lt $floorIdx.Count; $w++) {
        $o=$w*9; $x1=$vv[$o];$y1=$vv[$o+1];$z1=$vv[$o+2];$x2=$vv[$o+3];$y2=$vv[$o+4];$z2=$vv[$o+5];$x3=$vv[$o+6];$y3=$vv[$o+7];$z3=$vv[$o+8]
        $cx=($x1+$x2+$x3)/3.0; $cz=($z1+$z2+$z3)/3.0; $hy=($y1+$y2+$y3)/3.0
        $dx=$cx-$m.pos_x; $dz=$cz-$m.pos_z; $dist=[math]::Sqrt($dx*$dx+$dz*$dz)
        if ($dist -gt $Radius) { continue }
        $lvl = [int][math]::Round($hy/120.0)*120   # bucket heights ~120 apart
        if (-not $levels.ContainsKey($lvl) -or $dist -lt $levels[$lvl].dist) {
            $levels[$lvl] = @{ dist=$dist; x=$cx; z=$cz; height=$hy; dx=$dx; dz=$dz }
        }
    }
    $out = foreach ($lvl in $levels.Keys) { $e=$levels[$lvl]
        [pscustomobject]@{ height=[int][math]::Round($e.height); dh=[int][math]::Round($e.height-$m.pos_y)
            dist=[int][math]::Round($e.dist); x=[int][math]::Round($e.x); z=[int][math]::Round($e.z)
            dx=[int][math]::Round($e.dx); dz=[int][math]::Round($e.dz) } }
    @($out | Sort-Object dist | Select-Object -First $Max)
}

function Convert-DirToStick {
    # Calibrated (task-4 camera) stick for a desired unit world direction (wx,wz). Full tilt (mag 100).
    param([double]$Wx, [double]$Wz)
    $sx = 0.1936*$Wx + 0.2497*$Wz
    $sy = 0.2827*$Wx - 0.1355*$Wz
    $mag = [math]::Sqrt($sx*$sx + $sy*$sy); if ($mag -eq 0) { $mag = 1 }
    $X = [int][math]::Round($sx*100/$mag); $Y = [int][math]::Round($sy*100/$mag)
    @([math]::Max(-127,[math]::Min(127,$X)), [math]::Max(-127,[math]::Min(127,$Y)))
}

# CAMERA-ROBUST steering. Instead of a fixed calibration matrix (which breaks the moment the camera
# rotates), aim by the game's own intended_yaw feedback: keep a running camera-yaw estimate, compute the
# full-tilt stick for the desired world direction, then correct the estimate from the intended_yaw the
# game reports. Works from ANY position/orientation (verified after arbitrary jumps/dives moved Mario).
function Get-StickPure {
    param([double]$Cam, [double]$dx, [double]$dz)
    $TAU = 2*[math]::PI
    $B = ([math]::Atan2($dx,$dz)/$TAU)*65536       # desired world angle (SM64 units)
    $phi = $Cam - $B
    while ($phi -gt 32768) { $phi -= 65536 }; while ($phi -lt -32768) { $phi += 65536 }
    $r = $phi/65536.0*$TAU
    @{ X=[int][math]::Round(100*[math]::Sin($r)); Y=[int][math]::Round(100*[math]::Cos($r)); Phi=$phi }
}
function Update-Cam {
    param([double]$IntendedYaw, [double]$Phi)
    $c = $IntendedYaw + $Phi
    while ($c -gt 32768) { $c -= 65536 }; while ($c -lt -32768) { $c += 65536 }
    $c
}

function Invoke-Goto {
    <#
      .SYNOPSIS  High-level closed-loop navigation: move Mario to a world (x,z) by beeline, steering via
                 the game's intended_yaw feedback so it is ROBUST to camera rotation (works from any
                 position/orientation, e.g. after the model did jumps/dives). Deliberately NO wall-follow:
                 persistence threads gaps that intervention breaks (verified reaching task-4 chest 1 behind
                 its wall). Records every frame's input for movie export.
      .OUTPUTS   PSCustomObject { Ok, Reached, Steps, Dist, Best, X, Z, Target, Inputs, Frames }
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][double]$TargetX,
        [Parameter(Mandatory)][double]$TargetZ,
        [double]$TargetY = [double]::NaN,  # optional height: if set, stop on 3D distance AND climb toward it when blocked
        [int]$MaxSteps = 300,        # enough to cross the map (a full traverse is ~5000+ units)
        [int]$Frames = 6,
        [double]$StopDist = 200.0,   # "reached" should mean close; open terrain gets within ~50, a wall floors ~150
        [int]$StopCoinsAbove = -1,     # if >=0, stop when num_coins exceeds this (e.g. a chest opened)...
        [double]$CoinStopWithin = 1e9, # ...but only once within this distance of the target (ignore loose path coins)
        [ValidateSet('walk','longjump')][string]$Style = 'walk',  # 'longjump' = cover open ground with long jumps
        [double]$JumpUntil = 1300.0  # in longjump style, long-jump while dist>this, then walk for precision
    )
    $has3D = -not [double]::IsNaN($TargetY)
    $best = [double]::PositiveInfinity; $reached = $false; $m = $null
    $inputs = New-Object System.Collections.ArrayList   # [x,y,btn] per frame, for movie export
    # bootstrap the camera estimate (recorded frame): stick 'up' => intended_yaw ~= camera yaw
    $mb = Step-Frames -Session $Session -Frames 1 -Buttons @{ X=0; Y=100 }
    [void]$inputs.Add(@(0,100,0)); $cam = [double]$mb.intended_yaw
    $prevXZ = [double]::PositiveInfinity; $stall = 0
    for ($step = 1; $step -le $MaxSteps; $step++) {
        $m = Get-MarioState -Session $Session
        $dx = $TargetX - $m.pos_x; $dz = $TargetZ - $m.pos_z
        $distXZ = [math]::Sqrt($dx*$dx + $dz*$dz)
        $metric = if ($has3D) { $dyt=$TargetY-$m.pos_y; [math]::Sqrt($dx*$dx + $dyt*$dyt + $dz*$dz) } else { $distXZ }
        if ($metric -lt $best) { $best = $metric }
        if ($StopCoinsAbove -ge 0 -and $distXZ -lt $CoinStopWithin -and [int]$m.num_coins -gt $StopCoinsAbove) { $reached = $true; break }
        if ($metric -lt $StopDist) { $reached = $true; break }
        # CLIMB: target is well above and Mario is stuck in XZ (bumping a rock/ledge) -> build speed + long jump up
        if ($has3D -and (($TargetY - $m.pos_y) -gt 150) -and (-not (Test-Airborne $m))) {
            if (($prevXZ - $distXZ) -lt 8) { $stall++ } else { $stall = 0 }
            $prevXZ = $distXZ
            if ($stall -ge 10) {
                $sh = Get-StickPure -Cam $cam -dx $dx -dz $dz
                $mv = Invoke-Move -Session $Session -Move 'long_jump' -StickX $sh.X -StickY $sh.Y
                foreach ($f in $mv.Inputs) { [void]$inputs.Add($f) }
                $mb = Step-Frames -Session $Session -Frames 1 -Buttons @{ X=0; Y=100 }
                [void]$inputs.Add(@(0,100,0)); $cam = [double]$mb.intended_yaw; $stall = 0
                continue
            }
        }
        if ($Style -eq 'longjump' -and $distXZ -gt $JumpUntil) {
            # long jump toward the target (camera-aware stick, records its own inputs)
            $sh = Get-StickPure -Cam $cam -dx $dx -dz $dz
            $mv = Invoke-Move -Session $Session -Move 'long_jump' -StickX $sh.X -StickY $sh.Y
            foreach ($f in $mv.Inputs) { [void]$inputs.Add($f) }
            $mb = Step-Frames -Session $Session -Frames 1 -Buttons @{ X=0; Y=100 }
            [void]$inputs.Add(@(0,100,0)); $cam = [double]$mb.intended_yaw
            continue
        }
        $sh = Get-StickPure -Cam $cam -dx $dx -dz $dz
        $m2 = Step-Frames -Session $Session -Frames $Frames -Buttons @{ X=$sh.X; Y=$sh.Y }
        for ($fi = 0; $fi -lt $Frames; $fi++) { [void]$inputs.Add(@([int]$sh.X, [int]$sh.Y, 0)) }
        $cam = Update-Cam -IntendedYaw ([double]$m2.intended_yaw) -Phi $sh.Phi
    }
    $mf = Get-MarioState -Session $Session
    [pscustomobject]@{
        Ok=$true; Reached=$reached; Steps=$step; Dist=[math]::Round($best,1)
        Best=[math]::Round($best,1); X=$mf.pos_x; Z=$mf.pos_z; Target=@($TargetX,$TargetZ)
        Inputs=$inputs.ToArray(); Frames=$inputs.Count
    }
}

function Get-ChestProgress {
    # The chest star spawner counts how many chests have been opened (offset 0xF4). This is the REAL
    # "a chest just opened" signal (it increments on a genuine open), unlike coins (loose path pickups).
    param($Session)
    $GOBJ=0x8033D488; $SZ=0x260; $O_ACT=0x74; $O_BHV=0x20C; $SEGTAB=0x8033B400
    $raw=[long](Read-Mem -Session $Session -Addr ($SEGTAB+0x13*4) -Type 'u32'); if($raw -lt 0){$raw+=4294967296}
    $seg13=2147483648+($raw -band 16777215); $names=Get-ObjNameMap
    $al=New-Object System.Collections.ArrayList; for($i=0;$i -lt 240;$i++){[void]$al.Add(@{addr=$GOBJ+$i*$SZ+$O_ACT;type='s16'})}
    $acts=Read-ObjActs -Session $Session
    $idx=@(); for($i=0;$i -lt 240;$i++){ if($acts[$i]){ $idx+=$i } }
    if($idx.Count -eq 0){ return $null }
    $bl=New-Object System.Collections.ArrayList; foreach($i in $idx){[void]$bl.Add(@{addr=$GOBJ+$i*$SZ+$O_BHV;type='u32'})}
    $bhvs=Read-MemMany -Session $Session -List $bl.ToArray()
    for($k=0;$k -lt $idx.Count;$k++){
        $bhv=[long]$bhvs[$k]; if($bhv -lt 0){$bhv+=4294967296}
        $nm=$names[[long](318767104+(($bhv-$seg13) -band 16777215))]
        if($nm -like 'Chest Star Spawner*'){ return [int](Read-Mem -Session $Session -Addr ($GOBJ+$idx[$k]*$SZ+0xF4) -Type 's32') }
    }
    return $null
}

function Get-ChestObject {
    # Live position + "Yaw Facing" (0xD4) of the Chest Bottom whose order (oBehParams 0x144) == $Order.
    param($Session, [int]$Order)
    $GOBJ=0x8033D488; $SZ=0x260; $O_ACT=0x74; $O_BHV=0x20C; $SEGTAB=0x8033B400
    $raw=[long](Read-Mem -Session $Session -Addr ($SEGTAB+0x13*4) -Type 'u32'); if($raw -lt 0){$raw+=4294967296}
    $seg13=2147483648+($raw -band 16777215); $names=Get-ObjNameMap
    $al=New-Object System.Collections.ArrayList; for($i=0;$i -lt 240;$i++){[void]$al.Add(@{addr=$GOBJ+$i*$SZ+$O_ACT;type='s16'})}
    $acts=Read-ObjActs -Session $Session
    $idx=@(); for($i=0;$i -lt 240;$i++){ if($acts[$i]){ $idx+=$i } }
    if($idx.Count -eq 0){ return $null }
    $bl=New-Object System.Collections.ArrayList; foreach($i in $idx){[void]$bl.Add(@{addr=$GOBJ+$i*$SZ+$O_BHV;type='u32'})}
    $bhvs=Read-MemMany -Session $Session -List $bl.ToArray()
    foreach($k in 0..($idx.Count-1)){
        $bhv=[long]$bhvs[$k]; if($bhv -lt 0){$bhv+=4294967296}
        if($names[[long](318767104+(($bhv-$seg13) -band 16777215))] -eq 'Chest Bottom'){
            $b=$GOBJ+$idx[$k]*$SZ
            if([int](Read-Mem -Session $Session -Addr ($b+0x144) -Type 'u32') -eq $Order){
                return @{ x=[double](Read-Mem -Session $Session -Addr ($b+0xA0) -Type 'f32')
                          z=[double](Read-Mem -Session $Session -Addr ($b+0xA8) -Type 'f32')
                          yaw=([long](Read-Mem -Session $Session -Addr ($b+0xD4) -Type 'u32') -band 0xFFFF) }
            }
        }
    }
    return $null
}

function Invoke-OpenChest {
    <#
      .SYNOPSIS  Open task-4 chest N (1-4). A chest opens only when Mario contacts it FROM ITS FRONT FACE
                 (its "Yaw Facing"), AND chests must be opened IN ORDER (1,2,3,4). So this routes Mario to a
                 point in front of the chest, then into it, and verifies via the chest-progress counter
                 (opened=true only if it actually incremented). Records inputs (front leg + contact leg) for movie.
      .OUTPUTS   { Chest, Opened, ProgressBefore, ProgressAfter, X, Z, Dist, Reached, Frames, Inputs }
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$Chest,
        [int]$MaxSteps = 400,           # generous: chest 3 -> chest 4 crosses the whole map
        [ValidateSet('walk','longjump')][string]$Style = 'walk',
        [double]$ApproachDist = 350.0   # how far in front of the chest to line up before going in
    )
    $prog0 = Get-ChestProgress -Session $Session
    $co = Get-ChestObject -Session $Session -Order $Chest
    $inputs = New-Object System.Collections.ArrayList
    if ($co) {
        $fr = ($co.yaw/65536.0)*(2*[math]::PI)
        $fx = $co.x + $ApproachDist*[math]::Sin($fr); $fz = $co.z + $ApproachDist*[math]::Cos($fr)  # point in front of the chest
        $r1 = Invoke-Goto -Session $Session -TargetX $fx -TargetZ $fz -StopDist 120 -MaxSteps $MaxSteps -Style $Style
        foreach ($f in $r1.Inputs) { [void]$inputs.Add($f) }
        $r2 = Invoke-Goto -Session $Session -TargetX $co.x -TargetZ $co.z -StopDist 60 -MaxSteps 45   # into the chest, front-on
        foreach ($f in $r2.Inputs) { [void]$inputs.Add($f) }
        $last = $r2
    } else {
        $t = $script:SM64_Task4Targets["chest$Chest"]
        if (-not $t) { throw "unknown chest $Chest (expected 1-4)" }
        $r = Invoke-Goto -Session $Session -TargetX $t[0] -TargetZ $t[1] -StopDist 120 -MaxSteps $MaxSteps -Style $Style
        foreach ($f in $r.Inputs) { [void]$inputs.Add($f) }
        $last = $r
    }
    $prog1 = Get-ChestProgress -Session $Session
    if ($null -ne $prog0 -and $null -ne $prog1) { $opened = ($prog1 -gt $prog0) } else { $opened = $last.Reached }
    # honest reason so a model doesn't guess (e.g. mistake a blocked path for a "wrong order")
    $dChest = if ($co) { [math]::Sqrt(($last.X-$co.x)*($last.X-$co.x)+($last.Z-$co.z)*($last.Z-$co.z)) } else { $last.Dist }
    $reason = if ($opened) { 'ouvert' }
              elseif ($dChest -gt 400) { 'PAS atteint (obstacle/mur sur le chemin ou trop loin) — reessaie open_chest, ou contourne' }
              else { 'atteint mais pas ouvert (mauvais ordre, ou deja ouvert) — ouvre les coffres dans l ordre 1,2,3,4' }
    [pscustomobject]@{
        Chest=$Chest; Opened=$opened; ProgressBefore=$prog0; ProgressAfter=$prog1; Reason=$reason
        X=$last.X; Z=$last.Z; Dist=[math]::Round($dChest,1); Reached=$last.Reached
        Frames=$inputs.Count; Inputs=$inputs.ToArray()
    }
}

function ConvertTo-BtnMask {
    param([hashtable]$B)
    $m = 0
    if ($B.A) { $m = $m -bor 0x80 }; if ($B.B) { $m = $m -bor 0x40 }; if ($B.Z) { $m = $m -bor 0x20 }
    if ($B.start) { $m = $m -bor 0x10 }; if ($B.R) { $m = $m -bor 0x08 }; if ($B.L) { $m = $m -bor 0x04 }
    $m
}
function Test-Airborne { param($M) ([int]([int64]$M.action -band 0x1C0)) -eq 0x80 }  # SM64 action group AIRBORNE=0x80

# expected action id per move (verified in-engine) -> used to confirm the move actually came out
$script:SM64_MoveAction = @{
    jump=0x03000880; long_jump=0x03000888; double_jump=0x03000881; triple_jump=0x01000882
    backflip=0x01000883; ground_pound=0x008008A9; dive=0x0188088A; punch=0x00800457
}

function Invoke-Move {
    <#
      .SYNOPSIS  Perform a named SM64 move in a world direction (DirX,DirZ), recording every frame's
                 input (for movie export) and VERIFYING the move by the action id it produces.
                 Repertoire (calibrated on task 4): jump, long_jump, double_jump, triple_jump, backflip,
                 ground_pound, dive, punch. long_jump/dive cover far ground; backflip/ground_pound gain height.
      .OUTPUTS   { Move, Ok, ExpectedAction, Actions, X, Y, Z, Frames, Inputs }
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][ValidateSet('jump','long_jump','double_jump','triple_jump','backflip','ground_pound','dive','punch')][string]$Move,
        [double]$DirX = 0.0, [double]$DirZ = -1.0,
        [int]$SpeedFrames = -1, [int]$MaxAir = 60,
        $StickX = $null, $StickY = $null   # explicit stick (camera already resolved by caller); bypasses DirX/DirZ
    )
    $inputs = New-Object System.Collections.ArrayList
    $seen   = New-Object System.Collections.Generic.HashSet[int]
    $stepFn = {
        param($btn,$n)
        $mm = $null
        for ($i=0; $i -lt $n; $i++) {
            $mm = Step-Frames -Session $Session -Frames 1 -Buttons $btn
            [void]$inputs.Add(@([int]$btn.X, [int]$btn.Y, (ConvertTo-BtnMask $btn)))
            [void]$seen.Add([int]([int64]$mm.action -band 0xFFFFFFFF))
        }
        $mm
    }
    # forward stick: explicit (caller already resolved the camera) or camera-aware from DirX/DirZ
    if ($null -ne $StickX -and $null -ne $StickY) {
        $fwd = @{ X=[int]$StickX; Y=[int]$StickY }
    } else {
        $mb = & $stepFn @{ X=0; Y=100 } 1                          # recorded bootstrap: intended_yaw ~= camera
        $sh = Get-StickPure -Cam ([double]$mb.intended_yaw) -dx $DirX -dz $DirZ
        $fwd = @{ X=$sh.X; Y=$sh.Y }
    }
    # run-up to build speed (defaults per move)
    $sf = $SpeedFrames
    if ($sf -lt 0) { $sf = @{ ground_pound=14; backflip=0; punch=0 }[$Move]; if ($null -eq $sf) { $sf = 18 } }
    if ($sf -gt 0) { $null = & $stepFn $fwd $sf }
    $A=@{X=$fwd.X;Y=$fwd.Y;A=$true}; $ZA=@{X=$fwd.X;Y=$fwd.Y;Z=$true;A=$true}; $Zc=@{X=$fwd.X;Y=$fwd.Y;Z=$true}; $Bc=@{X=$fwd.X;Y=$fwd.Y;B=$true}
    switch ($Move) {
        'jump'        { $null = & $stepFn $A 1 }
        'long_jump'   { $null = & $stepFn $Zc 1; $null = & $stepFn $ZA 1 }
        'backflip'    { $null = & $stepFn @{} 4; $null = & $stepFn @{Z=$true} 1; $null = & $stepFn @{Z=$true;A=$true} 1 }  # brake first (works even from a run)
        'ground_pound'{ $null = & $stepFn $A 1; $null = & $stepFn $fwd 4; $null = & $stepFn @{X=$fwd.X;Y=$fwd.Y;Z=$true} 1 }
        'dive'        {
            # dive needs high ground speed (forward_vel > ~26); B while slow = punch, B in air = jump-kick.
            # Keep running until fast enough, then B on the ground.
            $mm = Get-MarioState -Session $Session; $k=0
            while ($k -lt 40 -and $mm.forward_vel -lt 27) { $mm = & $stepFn $fwd 1; $k++ }
            $null = & $stepFn $Bc 1
        }
        'punch'       { $null = & $stepFn $Bc 1 }
        'double_jump' {
            $null = & $stepFn $A 1
            $k=0; while ($k -lt $MaxAir) { $mm = & $stepFn $fwd 1; if (-not (Test-Airborne $mm)) { break }; $k++ }
            $null = & $stepFn $A 1
        }
        'triple_jump' {
            $null = & $stepFn $A 1
            $k=0; while ($k -lt $MaxAir) { $mm = & $stepFn $fwd 1; if (-not (Test-Airborne $mm)) { break }; $k++ }
            $null = & $stepFn $A 1
            $k=0; while ($k -lt $MaxAir) { $mm = & $stepFn $fwd 1; if (-not (Test-Airborne $mm)) { break }; $k++ }
            $null = & $stepFn $A 1
        }
    }
    # coast until Mario is back on the ground (so the move fully resolves)
    $k=0; while ($k -lt $MaxAir) { $mm = & $stepFn $fwd 1; if (-not (Test-Airborne $mm)) { break }; $k++ }
    $mf = Get-MarioState -Session $Session
    $exp = [int]$script:SM64_MoveAction[$Move]
    [pscustomobject]@{
        Move=$Move; Ok=$seen.Contains($exp); ExpectedAction=('0x{0:X8}' -f $exp)
        Actions=@($seen | ForEach-Object { '0x{0:X8}' -f $_ })
        X=$mf.pos_x; Y=$mf.pos_y; Z=$mf.pos_z; Frames=$inputs.Count; Inputs=$inputs.ToArray()
    }
}

function Export-M64 {
    <#
      .SYNOPSIS  Build a VALID .m64 from a stick list. Fixes every header trap hit before: the ROM name
                 is NULL-padded (space padding made mupen reject the header), plugin names are the modern
                 TAS 1.4.0-5 set, the frame count is written to BOTH 0x0C and 0x18, and the button word is
                 low-byte-first (0x0080=A -> byte 0x80,0x00; writing it big-endian dropped every A press).
      .PARAMETER Sticks   Array of [x,y,btn] (btn optional, sim convention 0x0080=A) OR a path to such a json.
      .PARAMETER Out      Output .m64 path.
      .PARAMETER Start    'savestate' (default; needs a same-basename .st next to the .m64) or 'poweron'.
      .PARAMETER Template 1024-byte header template (default: the bundled m64_header_template.bin).
      .OUTPUTS  Out, Frames, Bytes, Start.
    #>
    param(
        [Parameter(Mandatory)]$Sticks,
        [Parameter(Mandatory)][string]$Out,
        [ValidateSet('savestate','poweron')][string]$Start='savestate',
        [string]$Template
    )
    if ($Sticks -is [string]) { $Sticks = Get-Content $Sticks -Raw | ConvertFrom-Json }
    if (-not $Template) { $Template = Join-Path $script:ControlDir 'm64_header_template.bin' }
    if (-not (Test-Path $Template)) { throw "m64 header template not found: $Template" }
    $hdr = [System.IO.File]::ReadAllBytes($Template)
    if ($hdr.Length -lt 1024) { throw "template shorter than 1024 bytes" }
    if ($hdr.Length -gt 1024) { $hdr = $hdr[0..1023] }
    $N = @($Sticks).Count
    foreach ($off in 0x0C, 0x18) { $hdr[$off]=$N -band 255; $hdr[$off+1]=($N -shr 8) -band 255; $hdr[$off+2]=($N -shr 16) -band 255; $hdr[$off+3]=($N -shr 24) -band 255 }
    $hdr[0x1C] = if ($Start -eq 'savestate') { 1 } else { 2 }; $hdr[0x1D]=0
    $body = New-Object System.Collections.Generic.List[byte]
    foreach ($f in $Sticks) {
        $x=[int]$f[0]; $y=[int]$f[1]; $b= if (@($f).Count -ge 3) { [int]$f[2] } else { 0 }
        if ($x -lt 0) { $x+=256 }; if ($y -lt 0) { $y+=256 }
        $body.Add([byte]($b -band 255)); $body.Add([byte](($b -shr 8) -band 255)); $body.Add([byte]$x); $body.Add([byte]$y)
    }
    $all = New-Object System.Collections.Generic.List[byte]
    $all.AddRange([byte[]]$hdr); $all.AddRange($body.ToArray())
    [System.IO.File]::WriteAllBytes($Out, $all.ToArray())
    [pscustomobject]@{ Out=$Out; Frames=$N; Bytes=$all.Count; Start=$Start }
}

function ConvertTo-OctagonSticks {
    <#
      .SYNOPSIS  "Humanize" a stick list by clamping each [x,y] into the N64 octagonal gate so a real
                 controller could produce it. The gate = { |x|<=Cardinal, |y|<=Cardinal, |x+y|<=T, |x-y|<=T }
                 (T=160 => diagonal notch ~80). Values are scaled RADIALLY (direction preserved); the game
                 clamps stick magnitude to 64 so maxed sticks are behaviourally unchanged, but tiny rounding
                 on off-axis frames can still shift a razor-precise ending by a frame or two -- always re-verify
                 with Confirm-Movie after exporting.
      .PARAMETER Sticks  Array of [x,y,btn] OR a path to such a json.
      .PARAMETER T       Diagonal bound (default 160 => notch 80). Larger = looser gate, fewer frames changed.
      .PARAMETER Cardinal  Axis bound (default 127).
      .OUTPUTS  New array of [x,y,btn].
    #>
    param([Parameter(Mandatory)]$Sticks, [double]$T=160.0, [double]$Cardinal=127.0)
    if ($Sticks -is [string]) { $Sticks = Get-Content $Sticks -Raw | ConvertFrom-Json }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Sticks) {
        $x=[double]$f[0]; $y=[double]$f[1]; $b= if (@($f).Count -ge 3) { [int]$f[2] } else { 0 }
        $s=1.0
        if ($x -ne 0) { $s=[math]::Min($s, $Cardinal/[math]::Abs($x)) }
        if ($y -ne 0) { $s=[math]::Min($s, $Cardinal/[math]::Abs($y)) }
        if (($x+$y) -ne 0) { $s=[math]::Min($s, $T/[math]::Abs($x+$y)) }
        if (($x-$y) -ne 0) { $s=[math]::Min($s, $T/[math]::Abs($x-$y)) }
        $out.Add(@([int][math]::Round($s*$x), [int][math]::Round($s*$y), $b))
    }
    ,$out.ToArray()
}

Export-ModuleMember -Function *-* , Get-SM64Paths, Send-Cmd
