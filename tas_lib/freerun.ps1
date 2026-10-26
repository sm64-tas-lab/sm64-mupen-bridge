# Freerun (SBLJ -> wall kick -> BLJ on the other staircase -> painting). Loads lib.ps1.
. "$PSScriptRoot\lib.ps1"
function Wrap([double]$a) { while ($a -gt 32767) { $a -= 65536 }; while ($a -lt -32768) { $a += 65536 }; $a }
# raw stick for world direction $Dir with camera $cy, compensating the SM64 dead zone (-6 per axis)
function StickRaw([double]$Dir, [double]$cy, [double]$mag = 1) {
    $t = ($Dir - $cy) / 65536 * 2 * [math]::PI
    $out = @(); foreach ($p in @((121 * $mag * [math]::Sin($t)), (-121 * $mag * [math]::Cos($t)))) {
        $q = [int][math]::Round($p); if ([math]::Abs($q) -lt 2) { $out += 0 } else { $out += [math]::Max(-127, [math]::Min(127, $q + 6 * [math]::Sign($q))) } }
    $out
}
# Drive: cmds = list of @(dir|$null, buttons). Corrects the camera frame by frame via intended_yaw (replays).
# Returns frames (inputs) + states. Always replays from the slot (deterministic).
function Drive([int]$Slot, $prefix, $cmds, [int]$iters = 4) {
    $n = $cmds.Count; $np = @($prefix).Count
    if ($np -gt 0) { RunFrom $Slot @($prefix) | Out-Null } else { Load-MemState $s -Slot $Slot | Out-Null }; $c0 = CamYaw
    $cam = New-Object 'double[]' $n; for ($i = 0; $i -lt $n; $i++) { $cam[$i] = $c0 }
    for ($it = 0; $it -lt $iters; $it++) {
        $fr = @(); for ($i = 0; $i -lt $n; $i++) { $c = $cmds[$i]
            if ($null -eq $c[0]) { $fr += , @(0, 0, [int]$c[1]) } else { $mg = $(if ($c.Count -gt 2) { $c[2] } else { 1 }); $st = StickRaw $c[0] $cam[$i] $mg; $fr += , @($st[0], $st[1], [int]$c[1]) } }
        $all = @($prefix) + $fr; $r = RunFrom $Slot $all
        $err = 0; $last = $c0
        for ($i = 0; $i -lt $n; $i++) { $c = $cmds[$i]; $ms = $r[$np + $i].s
            if ($null -ne $c[0]) { $e = Wrap ($c[0] - $ms.intended_yaw); $err = [math]::Max($err, [math]::Abs($e)); $cam[$i] = Wrap ($cam[$i] - $e); $last = $cam[$i] }
            elseif ($i + 1 -lt $n) { $cam[$i + 1] = $cam[$i] } }
        # propagate the estimate to the following frames not yet seen
        if ($err -lt 24) { break }
    }
    [pscustomobject]@{ frames = $all; own = $fr; states = $r; err = $err }
}
# greedy SBLJ chain from a prefix (slot): each cycle (Z+A+side, Z+side) keeps the direction that leaves Mario
# landing a LJ on the low step (y<1); picks the distance to the riser closest to DC.
function ChainSBLJ([int]$Slot, $prefix, [int]$maxCycles = 10, [double]$DC = 1.5, $dirs = @(-40000..-26000 | ? { $_ % 1000 -eq 0 })) {
    $cur = @($prefix); $vs = @()
    for ($c = 0; $c -lt $maxCycles; $c++) {
        RunFrom $Slot $cur | Out-Null; $cy = CamYaw; $ok = @()
        foreach ($d in $dirs) {
            $a = StickRaw $d $cy; $tr = $cur + @(, @($a[0], $a[1], 0xA0)) + @(, @($a[0], $a[1], 0x20))
            $fs = RunFrom $Slot $tr; $s1 = $fs[-2].s; $s2 = $fs[-1].s
            if ([long]$s1.action -eq 0x479 -and [long]$s2.action -eq 0x479 -and $s2.pos_y -lt 1) { $ok += [pscustomobject]@{ dd = $d; tr = $tr; v = $s2.forward_vel; st = $s2 } }
        }
        if ($ok.Count -eq 0) { break }
        $best = $ok | Sort-Object @{e = { [math]::Abs((PerpD $_.st) - $DC) } } | Select -First 1
        $cur = $best.tr; $vs += [math]::Round($best.v, 1)
        Write-Host ("cycle {0}: dir={1} ok={2} v={3:N1} d={4:N2} al={5:N0} {6}" -f $c, $best.dd, $ok.Count, $best.v, (PerpD $best.st), (AlongS $best.st), (Fmt $best.st))
    }
    [pscustomobject]@{ frames = $cur; vs = $vs }
}
function YawTo([double]$x, [double]$z, [double]$tx, [double]$tz) { [int]([math]::Atan2($tx - $x, $tz - $z) / (2 * [math]::PI) * 65536) }
# Closed-loop navigation by replays: waypoints [x,z,radius]; stick toward the current waypoint (position of the previous frame)
# ; after the last waypoint, neutral from the frame where the remaining distance < $stop. N frames in total.
function Nav([int]$Slot, $prefix, $wps, [int]$N, [double]$stop = 0, [int]$iters = 4) {
    $cmds = @(); for ($i = 0; $i -lt $N; $i++) { $cmds += , @((YawTo 0 0 $wps[0][0] $wps[0][1]), 0) }
    $dr = $null
    for ($it = 0; $it -lt $iters; $it++) {
        $dr = Drive $Slot $prefix $cmds 3; $np = @($prefix).Count
        $w = 0; $neutral = $false; $new = @()
        for ($i = 0; $i -lt $N; $i++) {
            $p = $(if ($i -eq 0) { $dr.states[[math]::Max(0, $np - 1)].s } else { $dr.states[$np + $i - 1].s })
            while ($w -lt $wps.Count - 1 -and [math]::Sqrt([math]::Pow($p.pos_x - $wps[$w][0], 2) + [math]::Pow($p.pos_z - $wps[$w][1], 2)) -lt $wps[$w][2]) { $w++ }
            $dist = [math]::Sqrt([math]::Pow($p.pos_x - $wps[$w][0], 2) + [math]::Pow($p.pos_z - $wps[$w][1], 2))
            if ($w -eq $wps.Count - 1 -and $dist -lt $stop) { $neutral = $true }
            if ($neutral) { $new += , @($null, 0) } else { $new += , @((YawTo $p.pos_x $p.pos_z $wps[$w][0] $wps[$w][1]), 0) }
        }
        $cmds = $new
    }
    Drive $Slot $prefix $cmds 4
}
# greedy steering: blocks of $chunk frames, direction toward the current waypoint from the real position; chosen blocks are frozen.
# stops (neutral) when the distance to the last waypoint < $stop; returns the raw frames (prefix included).
function NavGreedy([int]$Slot, $prefix, $wps, [int]$maxFrames = 200, [double]$stop = 0, [int]$chunk = 4) {
    $cur = @($prefix); $w = 0
    while (($cur.Count - @($prefix).Count) -lt $maxFrames) {
        $p = $(if ($cur.Count) { (RunFrom $Slot $cur)[-1].s } else { (RunFrom $Slot @(, @(0, 0, 0)))[-1].s })
        while ($w -lt $wps.Count - 1 -and [math]::Sqrt([math]::Pow($p.pos_x - $wps[$w][0], 2) + [math]::Pow($p.pos_z - $wps[$w][1], 2)) -lt $wps[$w][2]) { $w++ }
        $dist = [math]::Sqrt([math]::Pow($p.pos_x - $wps[$w][0], 2) + [math]::Pow($p.pos_z - $wps[$w][1], 2))
        if ($w -eq $wps.Count - 1 -and $dist -lt $stop) { break }
        $y = YawTo $p.pos_x $p.pos_z $wps[$w][0] $wps[$w][1]
        $cmds = @(); for ($i = 0; $i -lt $chunk; $i++) { $cmds += , @($y, 0) }
        $cur = (Drive $Slot $cur $cmds 3).frames
        Write-Host ("{0} w={1} dist={2:N0} {3}" -f ($cur.Count - @($prefix).Count), $w, $dist, (Fmt $p))
    }
    $cur
}
# Staircase BLJ as a state machine: each frame, if Mario is landing a LJ (0x479) -> Z+A+back stick, otherwise Z+back stick.
function BLJMachine([int]$Slot, $prefix, [double]$backDir, [int]$maxFrames = 40, [double]$stopY = 205, [int]$delay = 0) {
    $cur = @($prefix); $log = @(); $seen = 0
    for ($i = 0; $i -lt $maxFrames; $i++) {
        $m = (RunFrom $Slot $cur)[-1].s; $cy = CamYaw
        if ($m.pos_y -ge $stopY -and [long]$m.action -ne 0x3000888) { break }
        $a = StickRaw $backDir $cy
        $b = 0x20; $prevA = ($cur.Count -gt 0 -and ([int]$cur[-1][2] -band 0x80)); if ([long]$m.action -eq 0x479) { $seen++; if ($seen -gt $delay -and -not $prevA) { $b = 0xA0 } }
        $cur += , @($a[0], $a[1], $b); $log += ('{0} {1}' -f $(if ($b -eq 0xA0) { 'A' } else { '-' }), (Fmt $m))
    }
    [pscustomobject]@{ frames = $cur; log = $log }
}
# Hall straight-staircase BLJ: A only if the next riser (x - z = -97 + 72.5 k) is within $fac*|v| (and not A on the previous frame)
function RiserDist($m) { $u = $m.pos_x - $m.pos_z; $k = [math]::Floor(($u + 97) / 72.5) + 1; ((-97 + 72.5 * $k) - $u) / 1.41421356 }
function BLJRight([int]$Slot, $prefix, [double]$backDir = 24236, [int]$maxFrames = 45, [double]$fac = 1.1) {
    $cur = @($prefix); $log = @()
    for ($i = 0; $i -lt $maxFrames; $i++) {
        $m = (RunFrom $Slot $cur)[-1].s; $cy = CamYaw
        if ($m.pos_y -ge 205 -and [long]$m.action -ne 0x3000888) { break }
        $a = StickRaw $backDir $cy; $prevA = ($cur.Count -gt 0 -and ([int]$cur[-1][2] -band 0x80)); $rd = RiserDist $m
        $b = 0x20; if ([long]$m.action -eq 0x479 -and -not $prevA -and $rd -lt $fac * [math]::Abs($m.forward_vel)) { $b = 0xA0 }
        $cur += , @($a[0], $a[1], $b); $log += ('{0} rd={1:N1} {2}' -f $(if ($b -eq 0xA0) { 'A' } else { '-' }), $rd, (Fmt $m))
    }
    [pscustomobject]@{ frames = $cur; log = $log }
}
# steering in REVERSE (hyperspeed): Mario backs away opposite the stick -> stick = wanted direction + 0x8000.
# blocks of $chunk frames; stops (returns) when the distance to the last waypoint < $stop or the speed > -$minV.
function NavBack([int]$Slot, $prefix, $wps, [int]$maxFrames = 60, [double]$stop = 0, [int]$chunk = 2, [double]$minV = 5) {
    $cur = @($prefix); $w = 0
    while (($cur.Count - @($prefix).Count) -lt $maxFrames) {
        $p = (RunFrom $Slot $cur)[-1].s
        while ($w -lt $wps.Count - 1 -and [math]::Sqrt([math]::Pow($p.pos_x - $wps[$w][0], 2) + [math]::Pow($p.pos_z - $wps[$w][1], 2)) -lt $wps[$w][2]) { $w++ }
        $dist = [math]::Sqrt([math]::Pow($p.pos_x - $wps[$w][0], 2) + [math]::Pow($p.pos_z - $wps[$w][1], 2))
        Write-Host ("{0} w={1} dist={2:N0} {3}" -f ($cur.Count - @($prefix).Count), $w, $dist, (Fmt $p))
        if (($w -eq $wps.Count - 1 -and $dist -lt $stop) -or $p.forward_vel -gt -$minV) { break }
        $y = Wrap ((YawTo $p.pos_x $p.pos_z $wps[$w][0] $wps[$w][1]) + 32768)
        $cmds = @(); for ($i = 0; $i -lt $chunk; $i++) { $cmds += , @($y, 0) }
        $cur = (Drive $Slot $cur $cmds 3).frames
    }
    $cur
}
# Straight-staircase BLJ with buffered pause: A only if the next riser is in range (rd < fac*|v|).
# From the $bufFrom-th A on: block A+Z+Start, Z, Z+Start, Z (1 game frame, then pause) -> one LJ per game frame.
function BLJBuffered([int]$Slot, $prefix, [double]$backDir, [int]$maxGame = 40, [double]$fac = 1.1, [int]$bufFrom = 3) {
    $cur = @($prefix); $log = @(); $nA = 0
    for ($g = 0; $g -lt $maxGame; $g++) {
        $m = (RunFrom $Slot $cur)[-1].s; $cy = CamYaw
        if ($m.pos_y -ge 205 -and [long]$m.action -ne 0x3000888) { break }
        $a = StickRaw $backDir $cy; $rd = RiserDist $m
        $prevA = ($cur.Count -gt 0 -and ([int]$cur[-1][2] -band 0x80))
        $want = ([long]$m.action -eq 0x479 -and $rd -lt $fac * [math]::Abs($m.forward_vel))
        if ($want -and ($nA + 1) -ge $bufFrom) {
            $cur += , @($a[0], $a[1], 0xB0); $cur += , @($a[0], $a[1], 0x20); $cur += , @($a[0], $a[1], 0x30); $cur += , @($a[0], $a[1], 0x20); $nA++; $t = 'AP'
        } elseif ($want -and -not $prevA) { $cur += , @($a[0], $a[1], 0xA0); $nA++; $t = 'A ' }
        else { $cur += , @($a[0], $a[1], 0x20); $t = '- ' }
        $log += ('{0} rd={1:N1} {2}' -f $t, $rd, (Fmt $m))
    }
    [pscustomobject]@{ frames = $cur; log = $log }
}
# ---- RIGHT staircase (mirror of the left staircase, x' = -2047 - x): riser 1 = x - z = -97 ----
function PerpDR($st) { (-97 - ($st.pos_x - $st.pos_z)) / 1.41421356 }   # >0 = low-step side
function AlongR($st) { ($st.pos_x + $st.pos_z) / 1.41421356 }
function ChainSBLJR([int]$Slot, $prefix, [int]$maxCycles = 10, [double]$DC = 1.5, $dirs = @(26000..40000 | ? { $_ % 1000 -eq 0 }), [double]$target = 0) {
    $cur = @($prefix); $vs = @()
    for ($c = 0; $c -lt $maxCycles; $c++) {
        RunFrom $Slot $cur | Out-Null; $cy = CamYaw; $ok = @()
        foreach ($d in $dirs) {
            $a = StickRaw $d $cy; $tr = $cur + @(, @($a[0], $a[1], 0xA0)) + @(, @($a[0], $a[1], 0x20))
            $fs = RunFrom $Slot $tr; $s1 = $fs[-2].s; $s2 = $fs[-1].s
            if ([long]$s1.action -eq 0x479 -and [long]$s2.action -eq 0x479 -and $s2.pos_y -lt 1) { $ok += [pscustomobject]@{ dd = $d; tr = $tr; v = $s2.forward_vel; st = $s2 } }
        }
        if ($ok.Count -eq 0) { break }
        $best = $ok | Sort-Object @{e = { [math]::Abs((PerpDR $_.st) - $DC) } } | Select -First 1
        # guard: no gain -> stop (keep the previous prefix)
        if ($vs.Count -gt 0 -and $best.v -ge $vs[-1]) { Write-Host "stop: no gain"; break }
        $cur = $best.tr; $vs += [math]::Round($best.v, 1)
        Write-Host ("cycle {0}: dir={1} ok={2} v={3:N1} d={4:N2} al={5:N0} {6}" -f $c, $best.dd, $ok.Count, $best.v, (PerpDR $best.st), (AlongR $best.st), (Fmt $best.st))
        if ($target -gt 0 -and [math]::Abs($best.v) -ge $target) { Write-Host "stop: target reached"; break }
    }
    [pscustomobject]@{ frames = $cur; vs = $vs }
}
# ---- parallel: N persistent workers (worker_srv.ps1), each with its own mupen on the same milestone ----
function Start-Pool([string]$Milestone, [int]$N = 3, [string]$Tag = 'pool', [int]$Speed = 0) {
    $dir = Join-Path $env:TEMP "sm64pool_$Tag"; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $dir | Out-Null
    for ($k = 0; $k -lt $N; $k++) {
        Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\worker_srv.ps1`"", '-Id', $k, '-Milestone', "`"$Milestone`"", '-JobDir', "`"$dir`"", '-Speed', $Speed) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $dir "w${k}_out.txt") -RedirectStandardError (Join-Path $dir "w${k}_err.txt") | Out-Null
        Start-Sleep 2
    }
    $t0 = Get-Date; while (@(Get-ChildItem $dir -Filter 'ready_*').Count -lt $N) { if (((Get-Date) - $t0).TotalSeconds -gt 120) { throw "pool not ready" }; Start-Sleep 1 }
    [pscustomobject]@{ Dir = $dir; N = $N; Next = 0 }
}
function Stop-Pool($pool) { Set-Content (Join-Path $pool.Dir 'stop') '1' }
# trials as world commands: each trial = list of [yaw|$null, buttons, tx|$null, tz|$null]; the worker corrects the camera each frame
# and returns traj (x,y,z,action,stars,speed,yaw) + the inputs actually applied.
function Invoke-PoolCmds($pool, $trials) {
    $ids = @(); $k = 0
    foreach ($t in $trials) {
        $id = $pool.Next; $pool.Next++; $ids += $id
        $clean = @($t | % { , @($(if ($null -eq $_[0]) { $null } else { [int]$_[0] }), [int]$_[1], $(if ($_.Count -gt 2 -and $null -ne $_[2]) { [double]$_[2] } else { $null }), $(if ($_.Count -gt 3 -and $null -ne $_[3]) { [double]$_[3] } else { $null }), $(if ($_.Count -gt 4) { [int]$_[4] } else { 0 }), $(if ($_.Count -gt 5) { [int]$_[5] } else { 0 }), $(if ($_.Count -gt 6) { [int]$_[6] } else { 0 })) })
        $tmp = Join-Path $pool.Dir ("j{0}.tmp" -f $id)
        (@{ id = $id; cmds = $clean } | ConvertTo-Json -Compress -Depth 4) | Set-Content $tmp
        Move-Item $tmp (Join-Path $pool.Dir ("job_{0}_{1}.json" -f ($k % $pool.N), $id)); $k++
    }
    $out = @{}
    while ($out.Count -lt $ids.Count) {
        foreach ($id in $ids) { if (-not $out.ContainsKey($id)) { $p = Join-Path $pool.Dir "res_$id.json"; if (Test-Path $p) { try { $out[$id] = Get-Content $p -Raw -ErrorAction Stop | ConvertFrom-Json; Remove-Item $p -ErrorAction SilentlyContinue } catch {} } } }
        Start-Sleep -Milliseconds 100
    }
    $ids | % { $out[$_] }
}
# runs a list of trials (input lists) in parallel; returns the results in order
function Invoke-PoolBatch($pool, $trials, [switch]$All) {
    $ids = @(); $k = 0
    foreach ($t in $trials) {
        $id = $pool.Next; $pool.Next++; $ids += $id
        $tmp = Join-Path $pool.Dir ("j{0}.tmp" -f $id)
        $clean = @($t | % { , @([int]$_[0], [int]$_[1], [int]$_[2]) })   # pure integers (otherwise ConvertTo-Json writes {})
        (@{ id = $id; frames = $clean; all = [bool]$All } | ConvertTo-Json -Compress -Depth 4) | Set-Content $tmp
        Move-Item $tmp (Join-Path $pool.Dir ("job_{0}_{1}.json" -f ($k % $pool.N), $id)); $k++
    }
    $out = @{}
    while ($out.Count -lt $ids.Count) {
        foreach ($id in $ids) { if (-not $out.ContainsKey($id)) { $p = Join-Path $pool.Dir "res_$id.json"; if (Test-Path $p) { try { $out[$id] = Get-Content $p -Raw -ErrorAction Stop | ConvertFrom-Json; Remove-Item $p -ErrorAction SilentlyContinue } catch {} } } }
        Start-Sleep -Milliseconds 100
    }
    $ids | % { $out[$_] }
}
# right-staircase SBLJ chain, directions tested in parallel; guards: target / maxCycles / no gain / no valid direction left
function ChainSBLJRPar($pool, [int]$Slot, $prefix, $dirs, [int]$maxCycles = 12, [double]$DC = 1.5, [double]$target = 500) {
    $cur = @($prefix); $vs = @()
    for ($c = 0; $c -lt $maxCycles; $c++) {
        RunFrom $Slot $cur | Out-Null; $cy = CamYaw
        $trials = @(); foreach ($d in $dirs) { $a = StickRaw $d $cy; $trials += , ($cur + @(, @($a[0], $a[1], 0xA0)) + @(, @($a[0], $a[1], 0x20))) }
        $res = Invoke-PoolBatch $pool $trials
        $ok = @(); for ($i = 0; $i -lt $dirs.Count; $i++) { $s1 = $res[$i].states[0]; $s2 = $res[$i].states[1]
            if ([long]$s1.action -eq 0x479 -and [long]$s2.action -eq 0x479 -and $s2.pos_y -lt 1) { $ok += [pscustomobject]@{ dd = $dirs[$i]; tr = $trials[$i]; v = $s2.forward_vel; st = $s2 } } }
        if ($ok.Count -eq 0) { Write-Host "stop: no valid direction left"; break }
        $best = $ok | Sort-Object @{e = { [math]::Abs((PerpDR $_.st) - $DC) } } | Select -First 1
        if ($vs.Count -gt 0 -and $best.v -ge $vs[-1]) { Write-Host "stop: no gain"; break }
        $cur = $best.tr; $vs += [math]::Round($best.v, 1)
        Write-Host ("cycle {0}: dir={1} ok={2} v={3:N1} d={4:N2} x+z={5:N0} {6}" -f $c, $best.dd, $ok.Count, $best.v, (PerpDR $best.st), ($best.st.pos_x + $best.st.pos_z), (Fmt $best.st))
        if ([math]::Abs($best.v) -ge $target) { Write-Host "stop: target reached"; break }
    }
    [pscustomobject]@{ frames = $cur; vs = $vs }
}
# straight-line long-jump chain toward (tx,tz): start (idle or walking), Z held, A on each LJ landing (0x479).
# stops when the horizontal distance to the target < $stop, or after $maxFrames. Returns frames + log.
function LJChain([int]$Slot, $prefix, [double]$tx, [double]$tz, [int]$maxFrames = 300, [double]$stop = 100, [int]$runFrames = 3) {
    $cur = @($prefix); $log = @(); $started = $false; $n = 0
    while ($n -lt $maxFrames) {
        $m = $(if ($cur.Count) { (RunFrom $Slot $cur)[-1].s } else { (RunFrom $Slot @(, @(0, 0, 0)))[-1].s }); $cy = CamYaw
        $dist = [math]::Sqrt([math]::Pow($tx - $m.pos_x, 2) + [math]::Pow($tz - $m.pos_z, 2))
        if ($dist -lt $stop) { break }
        $dir = YawTo $m.pos_x $m.pos_z $tx $tz; $a = StickRaw $dir $cy
        $prevA = ($cur.Count -gt 0 -and ([int]$cur[-1][2] -band 0x80)); $act = [long]$m.action
        if (-not $started) {
            if ($n -lt $runFrames) { $b = 0 } elseif ($n -eq $runFrames) { $b = 0x20 } else { $b = 0xA0; $started = $true }
        } elseif ($act -eq 0x479 -and -not $prevA) { $b = 0xA0 } else { $b = 0x20 }
        $cur += , @($a[0], $a[1], $b); $n++
        $log += ('{0,3} b={1:X2} dist={2:N0} {3}' -f $n, $b, $dist, (Fmt $m))
    }
    [pscustomobject]@{ frames = $cur; log = $log }
}
function AngDiff([double]$a, [double]$b) { [math]::Abs((Wrap ($a - $b))) }
# route made of LJ chains through waypoints [x,z,radius]: A on the LJ landing if aligned (< $tol), otherwise walk to turn then Z, Z+A.
function LJRoute([int]$Slot, $prefix, $wps, [int]$maxFrames = 400, [double]$tol = 1200) {
    $cur = @($prefix); $log = @(); $w = 0; $state = 'run'; $n = 0; $runN = 0
    while ($n -lt $maxFrames) {
        $m = $(if ($cur.Count) { (RunFrom $Slot $cur)[-1].s } else { (RunFrom $Slot @(, @(0, 0, 0)))[-1].s }); $cy = CamYaw
        while ($w -lt $wps.Count -and [math]::Sqrt([math]::Pow($wps[$w][0] - $m.pos_x, 2) + [math]::Pow($wps[$w][1] - $m.pos_z, 2)) -lt $wps[$w][2]) { $w++ }
        if ($w -ge $wps.Count) { break }
        $dir = YawTo $m.pos_x $m.pos_z $wps[$w][0] $wps[$w][1]; $a = StickRaw $dir $cy
        $act = [long]$m.action; $prev = $(if ($cur.Count) { [int]$cur[-1][2] } else { 0 }); $aligned = (AngDiff $m.face_yaw $dir) -lt $tol
        $air = (($act -band 0x800) -ne 0)
        if ($act -eq 0x479) { $b = $(if ($aligned -and -not ($prev -band 0x80)) { 0xA0 } else { 0 }) }
        elseif ($air) { $b = $(if ($prev -band 0x20) { 0x20 } else { 0 }) }
        elseif ($act -eq 0x4808459) { $b = $(if ($prev -band 0x80) { 0x20 } else { 0xA0 }) }   # crouch slide -> A (LJ)
        else {
            # on the ground (walking, landing...): if aligned and speed > 10 -> Z (crouch slide), otherwise walk
            $b = $(if ($aligned -and $m.forward_vel -gt 10.5 -and -not ($prev -band 0x20)) { 0x20 } else { 0 })
        }
        $cur += , @($a[0], $a[1], $b); $n++
        $log += ('{0,3} w={1} b={2:X2} {3}' -f $n, $w, $b, (Fmt $m))
    }
    [pscustomobject]@{ frames = $cur; log = $log; w = $w }
}
# Runs world commands on the main Mupen (same logic as worker_srv): [yaw|$null, btn, tx|$null, tz|$null, rev]
# Stick recomputed each frame with the real camera; returns the raw inputs applied + the states.
function RunCmds([int]$Slot, $prefix, $cmds) {
    if (@($prefix).Count) { RunFrom $Slot $prefix | Out-Null } else { Load-MemState $s -Slot $Slot | Out-Null }
    Set-Pause $s -Value $true
    $applied = @(); $states = @(); $gt = [long](Read-Mem -Session $s -Addr 0x8032D5D4 -Type u32)
    foreach ($c in $cmds) {
        $cy = CamYaw; $dir = $null
        if ($c.Count -gt 3 -and $null -ne $c[2]) { $m = Get-MarioState -Session $s; $dir = YawTo $m.pos_x $m.pos_z $c[2] $c[3]; if ($c.Count -gt 4 -and $c[4] -eq 1) { $dir = Wrap ($dir + 32768) } }
        elseif ($null -ne $c[0]) { $dir = $c[0] }
        $st = $(if ($null -ne $dir) { StickRaw $dir $cy } else { @(0, 0) }); $b = [int]$c[1]
        $m = Step-Frames -Session $s -Frames 1 -Buttons @{ X = [int]$st[0]; Y = [int]$st[1]; A = (($b -band 0x80) -ne 0); B = (($b -band 0x40) -ne 0); Z = (($b -band 0x20) -ne 0); start = (($b -band 0x10) -ne 0) }
        $gt2 = [long]$m.global_timer; for ($x = $gt + 1; $x -lt $gt2; $x++) { $applied += , @(0, 0, 0); $states += $m }; $gt = $gt2
        $applied += , @([int]$st[0], [int]$st[1], $b); $states += $m
    }
    [pscustomobject]@{ frames = @($prefix) + $applied; own = $applied; states = $states }
}
