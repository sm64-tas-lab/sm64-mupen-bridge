# SBLJ approach from Mario standing still (slot 10 = MOVIE_FREERUN/depart_idle.st): stop at the 1st valid result.
# k frames toward D, t frames toward F (-8474 = 300 below parallel), Z, Z+A, then back stick + Z until the LJ landing.
. "$PSScriptRoot\freerun.ps1"
$F = -8474
function TryApp([double]$D, [int]$k, [int]$t, [double]$th = 0) {
    $cmds = @(); for ($i = 0; $i -lt $k; $i++) { $cmds += , @($D, 0) }
    for ($i = 0; $i -lt $t; $i++) { $cmds += , @($F, 0) }
    $cmds += , @($F, 0x20); $cmds += , @($F, 0xA0)
    for ($i = 0; $i -lt 34; $i++) { $cmds += , @(($F + 32768 + $th), 0x20) }
    $dr = Drive 10 @() $cmds 6
    $k2 = $k + $t + 2
    $land = $dr.states | ? { $_.f -gt $k2 -and [long]$_.s.action -eq 0x479 } | Select -First 1
    if (-not $land) { return [pscustomobject]@{ ok = $false; dir = $D; k = $k; t = $t; info = (Fmt $dr.states[-1].s) } }
    $m = $land.s
    [pscustomobject]@{ ok = $true; dir = $D; k = $k; t = $t; fl = $land.f; dist = [math]::Round((PerpD $m), 2); al = [math]::Round((AlongS $m)); v = [math]::Round($m.forward_vel, 1); yaw = $m.face_yaw; y = $m.pos_y; frames = $dr.frames[0..($land.f - 1)] }
}
function Good($r) { $r.ok -and $r.y -eq 0 -and $r.dist -gt 0.3 -and $r.dist -lt 6 -and $r.v -lt -8 -and [math]::Abs($r.yaw - $F) -lt 250 -and $r.al -lt -1900 }
