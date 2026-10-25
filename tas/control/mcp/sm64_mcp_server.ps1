<#
  sm64_mcp_server.ps1 — Model Context Protocol (stdio, JSON-RPC 2.0) server exposing the three SM64
  tools to a future Claude Code session as native tools. It is a thin dispatcher over SM64Ctl.psm1,
  and it holds the live mupen session in a script variable across calls (so start_mupen once, then
  read/step many times).

  Register (in an interactive Claude Code session, or edit .mcp.json — see control/mcp/mcp.json):
      claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<abs path>\sm64_mcp_server.ps1"

  Protocol: newline-delimited JSON-RPC over stdio. ONLY JSON-RPC goes to stdout; logs go to stderr.
#>
$ErrorActionPreference = 'Stop'
# Emit/read JSON-RPC as UTF-8 (object names etc. can contain non-ASCII; the OS codepage would corrupt them).
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path (Split-Path -Parent $here) 'SM64Ctl.psm1') -Force -WarningAction SilentlyContinue

$script:SESS = $null
$script:RUN_INPUTS = New-Object System.Collections.ArrayList   # every frame's input since start_mupen -> one full-run movie
$script:MOVIE_SEQ = 0                                           # per-run counter so auto-named movies never collide/overwrite
function Add-RunInputs($inputs) { foreach ($f in @($inputs)) { [void]$script:RUN_INPUTS.Add($f) } }
function Log($m) { [Console]::Error.WriteLine("[sm64-mcp] $m") }
# PS 5.1 has no ?? operator — use this instead of value-coalescing.
function Def($v, $d) { if ($null -ne $v -and "$v" -ne '') { $v } else { $d } }

# Movies always land in tas\movies\ so a model's bare/relative filename never scatters to the cwd.
$script:MoviesDir = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'movies'
function Resolve-MoviePath($p, $default) {
    if (-not $p -or "$p" -eq '') { $p = $default }
    # A relative path (even "tas\movies\x.m64") -> keep only the filename and put it in tas\movies\
    # (avoids double-joining like tas\movies\tas\movies\x.m64).
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:MoviesDir ([System.IO.Path]::GetFileName($p)) }
    $p
}
# Write a replayable .m64 (+ .sticks.json + same-basename .st) from a recorded input list. $Out absolute.
function Export-GotoMovie($inputs, $out) {
    $stick = [System.IO.Path]::ChangeExtension($out, '.sticks.json')
    $j = '[' + ((@($inputs) | ForEach-Object { '[' + ($_ -join ',') + ']' }) -join ',') + ']'
    Set-Content -Path $stick -Value $j -Encoding Ascii
    $stBeside = [System.IO.Path]::ChangeExtension($out, '.st')
    if ($script:SESS.Savestate -and (Test-Path $script:SESS.Savestate)) { Copy-Item $script:SESS.Savestate $stBeside -Force }
    $e = Export-M64 -Sticks $stick -Out $out -Start savestate
    @{ movie=$e.Out; movie_frames=$e.Frames; movie_st=$stBeside }
}
# A per-leg movie of JUST that leg's inputs is only replayable from the leg's START state, but the .st we
# have is the run's START savestate -> a leg after the first replays from the wrong place (garbage movie).
# So every action exports the FULL run so far (RUN_INPUTS from the start savestate): ALWAYS valid, and the
# latest action is at the end. Sequence-numbered so movies never overwrite each other.
function Export-RunSoFar($hint, $save) {
    if (@($script:RUN_INPUTS).Count -eq 0) { return $null }
    $script:MOVIE_SEQ++
    $name = if ($save -and "$save" -ne '') { $save } else { ("run{0:D2}_{1}.m64" -f $script:MOVIE_SEQ, ($hint -replace '[^A-Za-z0-9]','_')) }
    Export-GotoMovie ($script:RUN_INPUTS.ToArray()) (Resolve-MoviePath $name '')
}

# ---- tool definitions (name -> {schema, handler}) ----------------------------------------------
function TextResult($obj) {
    $txt = if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Depth 8 -Compress }
    @{ content = @(@{ type = 'text'; text = "$txt" }) }
}

$TOOLS = [ordered]@{
  'start_mupen' = @{
    desc = 'Launch mupen with the bridge, load the ROM and a savestate. Call ONCE at the very start, then use the other tools. IDEMPOTENT: if mupen is already running it does NOT relaunch — it tells you so, so do NOT call it again (pass restart=true only to force a fresh instance).'
    schema = @{ type='object'; properties=@{
        rom=@{type='string';description='ROM path (optional; defaults to Super-Mario-64.z64)'}
        savestate=@{type='string';description='savestate path (optional; defaults to the Task-3 .st)'}
        no_savestate=@{type='boolean'}
        restart=@{type='boolean';description='force stop+relaunch even if mupen is already running'} } }
    handler = {
        param($a)
        $alive = ($script:SESS -and $script:SESS.Proc -and -not $script:SESS.Proc.HasExited)
        if ($alive -and -not $a.restart) {
            TextResult @{ ok=$true; already_running=$true; pid=$script:SESS.Pid;
                message="mupen est DEJA demarre (pid $($script:SESS.Pid)). NE rappelle PAS start_mupen. Passe directement a l'etape suivante: scan, goto ou open_chest." }
        } else {
            if ($alive) { try { Stop-Mupen $script:SESS } catch {} ; $script:SESS = $null }
            $p=@{}; if($a.rom){$p.Rom=$a.rom}; if($a.savestate){$p.Savestate=$a.savestate}; if($a.no_savestate){$p.NoSavestate=$true}
            $script:SESS = Start-Mupen @p -ReadyTimeoutSec 60
            $script:RUN_INPUTS = New-Object System.Collections.ArrayList   # fresh run recording
            $script:MOVIE_SEQ = 0
            TextResult @{ ok=$true; pid=$script:SESS.Pid; session=$script:SESS.SessionDir }
        }
    } }
  'stop_mupen' = @{
    desc='Stop the running mupen instance.'
    schema=@{type='object';properties=@{}}
    handler={ param($a) if($script:SESS){ Stop-Mupen $script:SESS; $script:SESS=$null }; TextResult @{ok=$true} } }
  'get_state' = @{
    desc='Read the full Mario state pack (position, velocity, action, coins, yaw, floor/ceil, timers, rng...).'
    schema=@{type='object';properties=@{}}
    handler={ param($a) TextResult (Get-MarioState $script:SESS) } }
  'step_frames' = @{
    desc='Advance N frames applying a controller input, then return the state reached. Deterministic; core is paused between calls. buttons: {A,B,Z,R,L,start,Cup,Cdown,Cleft,Cright,up,down,left,right (bool), X,Y (int8 stick)}.'
    schema=@{type='object';properties=@{ frames=@{type='integer'}; buttons=@{type='object'} }; required=@('frames') }
    handler={ param($a) $b=@{}; if($a.buttons){ $a.buttons.PSObject.Properties|ForEach-Object{ $b[$_.Name]=$_.Value } }
              TextResult (Step-Frames $script:SESS -Frames ([int]$a.frames) -Buttons $b) } }
  'read_mem' = @{
    desc='Read a value from N64 RAM at a KSEG0 address (0x80xxxxxx). type in u8,s8,u16,s16,u32,s32,f32,f64.'
    schema=@{type='object';properties=@{ addr=@{type='integer'}; type=@{type='string'} }; required=@('addr') }
    handler={ param($a) TextResult @{ value=(Read-Mem $script:SESS -Addr ([long]$a.addr) -Type (Def $a.type 'u32')) } } }
  'write_mem' = @{
    desc='Write a value to N64 RAM at a KSEG0 address. type as in read_mem.'
    schema=@{type='object';properties=@{ addr=@{type='integer'}; value=@{}; type=@{type='string'} }; required=@('addr','value') }
    handler={ param($a) Write-Mem $script:SESS -Addr ([long]$a.addr) -Value $a.value -Type (Def $a.type 'u32'); TextResult @{ok=$true} } }
  'save_memstate' = @{
    desc='Save an in-memory savestate checkpoint into a slot (fast, disk-free) for branching/search.'
    schema=@{type='object';properties=@{ slot=@{type='integer'} }}
    handler={ param($a) TextResult (Save-MemState $script:SESS -Slot ([int](Def $a.slot 1))) } }
  'load_memstate' = @{
    desc='Restore an in-memory savestate checkpoint from a slot.'
    schema=@{type='object';properties=@{ slot=@{type='integer'} }}
    handler={ param($a) TextResult (Load-MemState $script:SESS -Slot ([int](Def $a.slot 1))) } }
  'stroop_vars' = @{
    desc='Compute STROOP variables live from RAM (declarative + common computed). files defaults to MarioData+CameraData.'
    schema=@{type='object';properties=@{ files=@{type='array';items=@{type='string'}}; computed=@{type='boolean'} }}
    handler={ param($a) $f= if($a.files){ @($a.files) } else { @('MarioData.xml','CameraData.xml') }
              TextResult (Get-StroopVars $script:SESS -Files $f -IncludeComputed:([bool]$a.computed)) } }
  'invoke_action' = @{
    desc='Invoke any mupen menu action by identifier (e.g. reset). List with list_actions.'
    schema=@{type='object';properties=@{ name=@{type='string'} }; required=@('name') }
    handler={ param($a) TextResult (Invoke-MupenAction $script:SESS -Name $a.name) } }
  'list_actions' = @{
    desc='List mupen menu actions matching a filter substring.'
    schema=@{type='object';properties=@{ filter=@{type='string'} }}
    handler={ param($a) TextResult @{ actions=(Get-MupenActions $script:SESS -Filter (Def $a.filter '')) } } }
  'screenshot' = @{
    desc='Save a PNG screenshot of the emulator to a path.'
    schema=@{type='object';properties=@{ path=@{type='string'} }; required=@('path') }
    handler={ param($a) TextResult (Save-Screenshot $script:SESS -Path $a.path) } }
  'sim_example' = @{
    desc='Build+run an sm64-sim-rs CPU-simulator example by name (e.g. selftest, blj_probe, ttm_probe). Returns output.'
    schema=@{type='object';properties=@{ name=@{type='string'}; release=@{type='boolean'} }; required=@('name') }
    handler={ param($a) $o=Invoke-SimExample -Name $a.name -Release:([bool](Def $a.release $true)); TextResult (($o|Select-Object -Last 40) -join "`n") } }
  'sim_examples' = @{
    desc='List available sm64-sim-rs examples.'
    schema=@{type='object';properties=@{}}
    handler={ param($a) TextResult @{ examples=(Get-SimExamples) } } }
  'sim_bruteforce' = @{
    desc='Build+run a GPU bruteforcer binary (guided_flying_bruteforce etc.). env: {GEN,BATCHES,OUT,TX,TY,TZ}. First build is slow.'
    schema=@{type='object';properties=@{ bin=@{type='string'}; env=@{type='object'} }}
    handler={ param($a) $e=@{}; if($a.env){ $a.env.PSObject.Properties|ForEach-Object{ $e[$_.Name]=$_.Value } }
              $o=Invoke-SimBruteforce -Bin (Def $a.bin 'guided_flying_bruteforce') -EnvVars $e; TextResult (($o|Select-Object -Last 40) -join "`n") } }
  'paths' = @{
    desc='Show resolved tool paths and existence checks.'
    schema=@{type='object';properties=@{}}
    handler={ param($a) TextResult (Get-SM64Paths) } }
  'confirm_movie' = @{
    desc='THE verify gate: replay a COMPLETE movie (a [[x,y,btn]] json, from the .st incl. pre-mount prefix) on a fresh mupen and report {Ok,Mounted,MountFrame,ShellKept,Coins,CoinSlots,VoidFrame,Dur,Frames}. Counts red coins BY POSITION. Never call a built run good until this passes. Starts/stops its own mupen.'
    schema=@{type='object';properties=@{ sticks=@{type='string';description='path to the full-movie [[x,y,btn]] json'}; margin=@{type='number'}; require_coins=@{type='number'} }; required=@('sticks') }
    handler={ param($a) $p=@{ Sticks=$a.sticks }; if($null -ne $a.margin){$p.Margin=[double]$a.margin}; if($null -ne $a.require_coins){$p.RequireCoins=[double]$a.require_coins}
              TextResult (Confirm-Movie @p) } }
  'export_m64' = @{
    desc='Build a VALID .m64 from a stick-list json (handles the ROM-name/plugin/frame-count/byte-order traps). start: savestate (default; needs a same-basename .st beside the .m64) or poweron.'
    schema=@{type='object';properties=@{ sticks=@{type='string'}; out=@{type='string'}; start=@{type='string'}; template=@{type='string'} }; required=@('sticks','out') }
    handler={ param($a) $p=@{ Sticks=$a.sticks; Out=$a.out }; if($a.start){$p.Start=$a.start}; if($a.template){$p.Template=$a.template}
              TextResult (Export-M64 @p) } }
  'octagon_clamp' = @{
    desc='Humanize a stick-list json by clamping to the N64 octagonal gate (T=160 => diagonal notch ~80). Writes the clamped [[x,y,btn]] to out_json. Re-verify with confirm_movie afterwards (rounding can shift a razor-precise ending).'
    schema=@{type='object';properties=@{ sticks=@{type='string'}; out_json=@{type='string'}; t=@{type='number'}; cardinal=@{type='number'} }; required=@('sticks','out_json') }
    handler={ param($a) $p=@{ Sticks=$a.sticks }; if($null -ne $a.t){$p.T=[double]$a.t}; if($null -ne $a.cardinal){$p.Cardinal=[double]$a.cardinal}
              $c=ConvertTo-OctagonSticks @p
              $json='['+((@($c)|ForEach-Object{'['+($_ -join ',')+']'}) -join ',')+']'
              Set-Content -Path $a.out_json -Value $json -Encoding Ascii
              TextResult @{ ok=$true; out=$a.out_json; frames=@($c).Count } } }
  'list_chests' = @{
    desc='List the task-4 chest/star world targets by name (chest1..chest4) with their (x,z). Use these coords with goto. No need to reverse-engineer the object pool.'
    schema=@{type='object';properties=@{}}
    handler={ param($a) $t=Get-Task4Targets; $o=@{}; foreach($k in $t.Keys){ $o[$k]=@{ x=$t[$k][0]; z=$t[$k][1] } }; TextResult $o } }
  'goto' = @{
    desc='HIGH-LEVEL navigation: move Mario to a world position (x,z) autonomously (closed-loop beeline; handles walls by persistence). ALWAYS writes a replayable .m64 movie (auto-named in tas\movies\ unless save_m64 is given) and returns its path in `movie` plus a ready-to-report `summary`. Returns {reached,dist,steps,x,z,frames,movie,summary}. reached=true means within stop_dist (default 200). This is the tool to reach a point / TAS a route: goto each target in turn (coords via list_chests). style="longjump" makes Mario cover open ground with long jumps. Run from the task-4 savestate (calibration is camera-relative).'
    schema=@{type='object';properties=@{
        x=@{type='number';description='target world X'}; z=@{type='number';description='target world Z'}
        y=@{type='number';description='optional target HEIGHT (world Y). If set, goto aims in 3D and CLIMBS toward it (long-jumps up when blocked under an elevated target, e.g. a star on a rock). Get x,y,z + dy from scan.'}
        max_steps=@{type='integer';description='step cap (default 300)'}
        frames=@{type='integer';description='frames advanced per step (default 6)'}
        stop_dist=@{type='number';description='success distance (default 200)'}
        style=@{type='string';enum=@('walk','longjump');description="locomotion: 'walk' (default) or 'longjump' (cover open ground with long jumps)"}
        save_m64=@{type='string';description='optional output .m64 path; if set, exports a replayable movie of this navigation (copies the loaded savestate to a same-basename .st beside it).'} }; required=@('x','z') }
    handler={ param($a) $p=@{ TargetX=[double]$a.x; TargetZ=[double]$a.z }
              if($null -ne $a.y){$p.TargetY=[double]$a.y}
              if($null -ne $a.max_steps){$p.MaxSteps=[int]$a.max_steps}
              if($null -ne $a.frames){$p.Frames=[int]$a.frames}
              if($null -ne $a.stop_dist){$p.StopDist=[double]$a.stop_dist}
              if($a.style){$p.Style=$a.style}
              $r=Invoke-Goto $script:SESS @p
              Add-RunInputs $r.Inputs
              $out=[ordered]@{ ok=$r.Ok; reached=$r.Reached; steps=$r.Steps; dist=$r.Dist; x=$r.X; z=$r.Z; frames=$r.Frames }
              $mv=Export-RunSoFar ("goto_{0}_{1}" -f [int]$a.x,[int]$a.z) $a.save_m64
              if($mv){ $out.movie=$mv.movie; $out.movie_frames=$mv.movie_frames; $out.movie_st=$mv.movie_st
                       $out.summary=("Run vers ({0},{1}): reached={2}, dist={3}. Movie de la run complete: {4}." -f [int]$a.x,[int]$a.z,$r.Reached,$r.Dist,$mv.movie) }
              else { $out.summary=("Run vers ({0},{1}): reached={2}, dist={3}." -f [int]$a.x,[int]$a.z,$r.Reached,$r.Dist) }
              TextResult $out } }
  'open_chest' = @{
    desc='Open task-4 chest N (1-4). A chest opens ONLY when Mario contacts it FROM ITS FRONT FACE and chests must be opened IN ORDER 1->2->3->4 (this tool handles the front approach automatically; you must still call them in order). Verifies the open for REAL via the chest-progress counter: opened=true ONLY if it actually incremented (opened=false if wrong order or bad contact). ALWAYS writes a replayable .m64 movie (auto-named in tas\movies\ unless save_m64) plus a ready-to-report `summary`. For all 4 chests: open_chest 1,2,3,4 in order, then export_run for one combined movie. Returns {opened, chest_progress_before, chest_progress_after, reached, x, z, movie, summary}.'
    schema=@{type='object';properties=@{
        chest=@{type='integer';description='chest number 1-4 (see list_chests)'}
        stop_dist=@{type='number';description='approach distance (default 170 = contact)'}
        style=@{type='string';enum=@('walk','longjump');description="locomotion: 'walk' (default) or 'longjump' (cover open ground with long jumps, then walk to touch)"}
        save_m64=@{type='string';description='optional output .m64 path to record this run'} }; required=@('chest') }
    handler={ param($a) $p=@{ Chest=[int]$a.chest }; if($null -ne $a.stop_dist){$p.StopDist=[double]$a.stop_dist}
              if($a.style){$p.Style=$a.style}
              $r=Invoke-OpenChest $script:SESS @p
              Add-RunInputs $r.Inputs
              $out=[ordered]@{ ok=$true; chest=$r.Chest; opened=$r.Opened; reason=$r.Reason; chest_progress_before=$r.ProgressBefore; chest_progress_after=$r.ProgressAfter; dist=$r.Dist; reached=$r.Reached; x=$r.X; z=$r.Z; frames=$r.Frames }
              $mv=Export-RunSoFar ("chest{0}" -f [int]$a.chest) $a.save_m64
              if($mv){ $out.movie=$mv.movie; $out.movie_frames=$mv.movie_frames; $out.movie_st=$mv.movie_st }
              $out.summary=("Coffre {0}: opened={1} [{2}] (chest_progress {3}->{4}). Movie: {5}." -f $r.Chest,$r.Opened,$r.Reason,$r.ProgressBefore,$r.ProgressAfter,(Def $mv.movie '(rien enregistre)'))
              TextResult $out } }
  'scan' = @{
    desc='PERCEPTION: see what is AROUND Mario instead of navigating blind. Returns Mario context (pos x/y/z, floor/ceil height, facing, num_stars), named OBJECTS (name, x, z, dist, dx, dz, dy=height above Mario) AND collision WALLS (x, z, dist, dx, dz, normal nx/nz, y_lo/y_hi). To FIND a specific target ANYWHERE (not just nearby), pass filter (substring/regex on the name, e.g. "red coin", "coin", "star", "switch") -> returns every match sorted by distance across a large radius. Objects give x,z and dy; for a 3D goto you need the target Y = mario.y + dy. Set walls:false to skip walls (faster).'
    schema=@{type='object';properties=@{
        filter=@{type='string';description='find objects whose NAME matches this (substring/regex, case-insensitive), e.g. "red coin". Searches far (default radius 30000) so distant targets are found.'}
        radius=@{type='number';description='objects within this XZ distance (default 3000, or 30000 when filter is set)'}
        max=@{type='integer';description='max objects, nearest first (default 15, or 40 when filter is set)'}
        walls=@{type='boolean';description='include collision walls (default true, off when filter is set)'}
        wall_radius=@{type='number';description='walls within this XZ distance (default 1200)'}
        floors=@{type='boolean';description='include standable FLOORS/PLATFORMS grouped by height level (default true, off when filter is set) — each: height, dh (vs mario.y), dist, x, z. Use it to see WHERE you can stand and plan a vertical route to an elevated/lower target.'}
        floor_radius=@{type='number';description='floors within this XZ distance (default 2500)'} }}
    handler={ param($a) $m=Get-MarioState $script:SESS
              $q=@{}; if($a.filter){ $q.Filter=[string]$a.filter; $q.Radius=30000.0; $q.Max=40 }
              if($null -ne $a.radius){$q.Radius=[double]$a.radius}; if($null -ne $a.max){$q.Max=[int]$a.max}
              $objs=Get-NearbyObjects $script:SESS @q
              $doWalls = if($a.filter){ $a.walls -eq $true } else { $a.walls -ne $false }
              $walls=@(); if($doWalls){ $wq=@{}; if($null -ne $a.wall_radius){$wq.Radius=[double]$a.wall_radius}; $walls=Get-NearbyWalls $script:SESS @wq }
              $doFloors = if($a.filter){ $a.floors -eq $true } else { $a.floors -ne $false }
              $floors=@(); if($doFloors){ $fq=@{}; if($null -ne $a.floor_radius){$fq.Radius=[double]$a.floor_radius}; $floors=Get-NearbyFloors $script:SESS @fq }
              TextResult ([ordered]@{
                  mario=[ordered]@{ x=[int][math]::Round($m.pos_x); y=[int][math]::Round($m.pos_y); z=[int][math]::Round($m.pos_z); floor=[int]$m.floor_height; ceil=[int]$m.ceil_height; face_yaw=$m.face_yaw; num_stars=$m.num_stars; num_coins=$m.num_coins; red_coins=$m.red_coins }
                  objects=@($objs); walls=@($walls); floors=@($floors) }) } }
  'move' = @{
    desc='Perform a named SM64 MOVE in a world direction (dir_x,dir_z; default toward -Z). Repertoire: jump, long_jump, double_jump, triple_jump, backflip, ground_pound, dive, punch. Returns {ok,move,action,x,y,z,frames}; ok=true means the move actually came out (verified by action id). long_jump/dive cover ground fast; backflip/ground_pound gain height. Use between goto legs to clear ledges, gaps or gain reach.'
    schema=@{type='object';properties=@{
        move=@{type='string';enum=@('jump','long_jump','double_jump','triple_jump','backflip','ground_pound','dive','punch');description='which move'}
        dir_x=@{type='number';description='world X direction (default 0)'}
        dir_z=@{type='number';description='world Z direction (default -1)'} }; required=@('move') }
    handler={ param($a) $p=@{ Move=$a.move }
              if($null -ne $a.dir_x){$p.DirX=[double]$a.dir_x}
              if($null -ne $a.dir_z){$p.DirZ=[double]$a.dir_z}
              $r=Invoke-Move $script:SESS @p
              Add-RunInputs $r.Inputs
              TextResult ([ordered]@{ ok=$r.Ok; move=$r.Move; action=($r.Actions -join ','); expected=$r.ExpectedAction; x=$r.X; y=$r.Y; z=$r.Z; frames=$r.Frames }) } }
  'collect' = @{
    desc='Find the nearest object matching `name` and COLLECT it: go to it in 3D (climbs if elevated) and VERIFY it was actually picked up. collected=true ONLY if it really was (the object went inactive OR a counter rose: red_coins/coins/stars) — NOT just "got close" (getting near is not grabbing). POLYVALENT: any task, any collectible (name="red coin", "coin", "1-up", "star", ...). ALWAYS writes a replayable .m64. Returns {found, collected, name, reason, red_coins_before/after, dist, movie, summary}.'
    schema=@{type='object';properties=@{
        name=@{type='string';description='object name to find & collect (substring/regex, case-insensitive), e.g. "red coin"'}
        near_x=@{type='number';description='optional: target the matching object nearest to THIS x,z (to pick a SPECIFIC one, e.g. a chosen red coin). Give both near_x and near_z.'}
        near_z=@{type='number';description='optional: paired with near_x'}
        style=@{type='string';enum=@('walk','longjump');description="'walk' (default) or 'longjump'"}
        save_m64=@{type='string';description='optional output .m64 path'} }; required=@('name') }
    handler={ param($a) $p=@{ Name=[string]$a.name }; if($a.style){$p.Style=$a.style}
              if($null -ne $a.near_x){$p.NearX=[double]$a.near_x}; if($null -ne $a.near_z){$p.NearZ=[double]$a.near_z}
              $r=Invoke-Collect $script:SESS @p
              Add-RunInputs $r.Inputs
              $out=[ordered]@{ ok=$true; found=$r.Found; collected=$r.Collected; name=$r.Name; reason=$r.Reason; red_coins_before=$r.RedCoinsBefore; red_coins_after=$r.RedCoinsAfter; coins_before=$r.CoinsBefore; coins_after=$r.CoinsAfter; dist=$r.Dist; x=$r.X; z=$r.Z; frames=$r.Frames }
              $mv = if($r.Collected){ Export-RunSoFar ("collect_{0}" -f ([string]$r.Name -replace '[^A-Za-z0-9]','_')) $a.save_m64 } else { $null }
              if($mv){
                  $out.movie=$mv.movie; $out.movie_frames=$mv.movie_frames; $out.movie_st=$mv.movie_st
                  $out.summary=("Collect '{0}': collected={1} [{2}] (red_coins {3}->{4}). Movie de la run complete: {5}." -f $r.Name,$r.Collected,$r.Reason,$r.RedCoinsBefore,$r.RedCoinsAfter,$mv.movie)
              } else { $out.summary=$r.Reason }
              TextResult $out } }
  'grab_star' = @{
    desc='Collect a HIGH star that floats above a platform and is OUT of normal jump range from the floor (e.g. the Jolly Roger Bay cave chest star). The tool climbs ONTO the highest platform under the star, faces away from it, and BACKFLIPS up into it (a backflip clears the last gap; the star hitbox is generous). Verifies with num_stars and only reports grabbed=true if it really rose (119->120). Use this when plain collect("star") fails because the star is too high. Returns {found, grabbed, name, stars_before/after, platform_y, peak, reason, movie}.'
    schema=@{type='object';properties=@{
        name=@{type='string';description='star name to find (default "Power Star")'}
        save_m64=@{type='string';description='optional output .m64 path'} }}
    handler={ param($a) $p=@{}; if($a.name){$p.Filter=[string]$a.name}
              $r=Invoke-GrabPlatformStar $script:SESS @p
              Add-RunInputs $r.Inputs
              $out=[ordered]@{ ok=$true; found=$r.Found; grabbed=$r.Grabbed; name=$r.Name; reason=$r.Reason; stars_before=$r.StarsBefore; stars_after=$r.StarsAfter; platform_y=$r.PlatformY; peak=$r.Peak; frames=$r.Frames }
              $mv = if($r.Grabbed){ Export-RunSoFar 'grab_star' $a.save_m64 } else { $null }
              if($mv){
                  $out.movie=$mv.movie; $out.movie_frames=$mv.movie_frames; $out.movie_st=$mv.movie_st
                  $out.summary=("grab_star: grabbed={0} (num_stars {1}->{2}, backflip depuis plateforme y={3}). Movie de la run complete: {4}." -f $r.Grabbed,$r.StarsBefore,$r.StarsAfter,$r.PlatformY,$mv.movie)
              } else { $out.summary=$r.Reason }
              TextResult $out } }
  'export_run' = @{
    desc='Export ONE replayable .m64 movie of EVERYTHING done since start_mupen (all goto/move/open_chest legs combined, in order), from the loaded savestate. Use this AFTER a multi-step run (e.g. chest 1 then chest 2) to get a single continuous movie instead of one file per leg. Auto-named in tas\movies\ unless out is given.'
    schema=@{type='object';properties=@{ out=@{type='string';description='output .m64 path (optional)'} }}
    handler={ param($a)
              if(@($script:RUN_INPUTS).Count -eq 0){ TextResult @{ ok=$false; message="Rien a exporter: aucun deplacement enregistre depuis start_mupen. Fais d'abord des goto/move/open_chest." } }
              else {
                  $mv=Export-GotoMovie $script:RUN_INPUTS.ToArray() (Resolve-MoviePath $a.out 'run_full.m64')
                  TextResult ([ordered]@{ ok=$true; movie=$mv.movie; movie_frames=$mv.movie_frames; movie_st=$mv.movie_st
                      summary=("Movie COMPLET de la run ({0} frames) pret a verifier: {1}. Tache terminee." -f $mv.movie_frames,$mv.movie) }) } } }
  'reset_run' = @{
    desc='Clear the full-run recording (start a fresh combined movie from the current point). The per-leg goto/open_chest movies are unaffected.'
    schema=@{type='object';properties=@{}}
    handler={ param($a) $script:RUN_INPUTS = New-Object System.Collections.ArrayList; $script:MOVIE_SEQ = 0; TextResult @{ ok=$true; message="Enregistrement de run remis a zero." } } }
}

# ---- JSON-RPC plumbing -------------------------------------------------------------------------
function Send-Msg($obj) {
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}
function Reply($id, $result) { Send-Msg @{ jsonrpc='2.0'; id=$id; result=$result } }
function ReplyErr($id, $code, $msg) { Send-Msg @{ jsonrpc='2.0'; id=$id; error=@{ code=$code; message=$msg } } }

Log "server starting; $($TOOLS.Count) tools"
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }           # stdin closed
    $line = $line.Trim(); if ($line.Length -eq 0) { continue }
    try { $req = $line | ConvertFrom-Json } catch { Log "bad json: $line"; continue }
    $method = $req.method; $id = $req.id
    try {
        switch ($method) {
            'initialize' {
                Reply $id @{ protocolVersion='2024-11-05'; capabilities=@{ tools=@{} };
                             serverInfo=@{ name='sm64ctl'; version='1.0.0' } } }
            'notifications/initialized' { }   # notification, no reply
            'ping' { Reply $id @{} }
            'resources/list' { Reply $id @{ resources=@() } }   # tools-only server: empty, not an error (some clients probe this)
            'resources/templates/list' { Reply $id @{ resourceTemplates=@() } }
            'prompts/list' { Reply $id @{ prompts=@() } }
            'tools/list' {
                $list = foreach ($k in $TOOLS.Keys) { @{ name=$k; description=$TOOLS[$k].desc; inputSchema=$TOOLS[$k].schema } }
                Reply $id @{ tools=@($list) } }
            'tools/call' {
                $name = $req.params.name; $args = $req.params.arguments
                if (-not $TOOLS.Contains($name)) { ReplyErr $id -32601 "unknown tool: $name"; break }
                # Clear, actionable error when a mupen-dependent tool is called before start_mupen
                # (otherwise it fails deep in PowerShell with a cryptic "Session is null" bind error).
                $script:NoSessionTools = @('start_mupen','list_chests','sim_example','sim_examples','sim_bruteforce','paths','export_m64','octagon_clamp','confirm_movie')
                if ($null -eq $script:SESS -and -not ($script:NoSessionTools -contains $name)) {
                    Reply $id @{ content=@(@{ type='text'; text="ERREUR: mupen n'est pas demarre. Appelle D'ABORD l'outil 'start_mupen' (et NON 'invoke_action') avec le savestate absolu de la task, puis reessaie '$name'." }); isError=$true }
                    break
                }
                try {
                    $res = & $TOOLS[$name].handler $args
                    Reply $id $res
                } catch {
                    Reply $id @{ content=@(@{ type='text'; text="ERROR: $($_.Exception.Message)" }); isError=$true }
                } }
            default {
                if ($null -ne $id) { ReplyErr $id -32601 "method not found: $method" }
            }
        }
    } catch { if ($null -ne $id) { ReplyErr $id -32603 $_.Exception.Message } ; Log "dispatch error: $($_.Exception.Message)" }
}
Log "server stopped"
