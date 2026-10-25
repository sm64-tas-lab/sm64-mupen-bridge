. "$PSScriptRoot\lib.ps1"
Invoke-MupenLua $s 'emu.set_speed_mode(2); return 1' | Out-Null
$bob_st = if ($env:MOVIE_BOB_ST) { $env:MOVIE_BOB_ST }
    elseif (Test-Path "$PSScriptRoot\..\MOVIE_BOB\sortie_porte.st") { "$PSScriptRoot\..\MOVIE_BOB\sortie_porte.st" }
    else { "$PSScriptRoot\sortie_porte.st" }
if (Test-Path $bob_st) { Use-Milestone $bob_st 11 }
function Route([string]$mode) {
  $m = (RunFrom 11 @(, @(0, 0, 0)))[-1].s; $fr = @(); $etape = 0; $log = @()
  for ($i = 0; $i -lt 90; $i++) {
    $mv = [math]::Atan2(-5400 - $m.pos_x, -460 - $m.pos_z) / (2 * [math]::PI) * 65536
    $a = St $mv 16801; $act = [long]$m.action; $low = $act -band 0x1FF; $air = ($act -band 0x800) -ne 0
    $btn = 0
    if ($i -lt 3) { } elseif ($i -eq 3) { $btn = 0x20 }
    elseif ($i -eq 4) { $btn = $(if ($mode -eq 'sk') { 0x40 } else { 0xA0 }); $etape = $(if ($mode -eq 'sk') { 1 } else { 3 }) }
    elseif ($etape -eq 1 -and $low -eq 0x05A) { $btn = 0x80; $etape = 2; $log += "i$i rollout" }          # glissade SK -> A une fois
    elseif ($etape -eq 2 -and -not $air -and $i -gt 6) { $btn = 0x20; $etape = 21; $log += "i$i Z" }  # atterrissage rollout -> Z
    elseif ($etape -eq 21) { $btn = 0xA0; $etape = 3; $log += "i$i LJ" }                              # puis A -> long jump
    elseif ($etape -eq 3 -and $act -eq 0x479) { $btn = 0xA0; $etape = 4; $log += "i$i LJ2" }          # atterrissage LJ -> Z+A une fois
    elseif ($etape -eq 4 -and $act -eq 0x479) { $btn = 0xA0; $etape = 5; $log += "i$i LJ3" }
    elseif ($etape -ge 3) { $btn = 0x20 }
    $fr += , @($a[0], $a[1], $btn)
    $fs = RunFrom 11 $fr; $m = $fs[-1].s
    if (($m.action -band 0xFFFF) -eq 0x1300) { return [pscustomobject]@{ n = $fr.Count; fr = $fr; m = $m; log = $log } }
  }
  [pscustomobject]@{ n = -1; fr = $fr; m = $m; log = $log }
}
foreach ($mode in 'lj', 'sk') {
  $r = Route $mode
  "$mode : dans le tableau apres $($r.n) frames | actions: $($r.log -join ', ') | " + (Fmt $r.m)
  @{ frames = $r.fr } | ConvertTo-Json -Depth 5 | Set-Content "$PSScriptRoot\route_$mode.json"
}
