. "$PSScriptRoot\lib.ps1"
Invoke-MupenLua $s 'emu.set_speed_mode(2); return 1' | Out-Null
$pre = @((Get-Content 'G:/tas-lab/MOVIE_BOB/apres_porte_inputs.json' -Raw | ConvertFrom-Json).frames | % { , @([int]$_[0], [int]$_[1], [int]$_[2]) })
$st = 'G:/tas-lab/MOVIE_BOB/sortie_porte.st'
Use-Milestone 'G:/tas-lab/MOVIE_BLJ/escalier_depart.st' 10
Save-Milestone 10 $pre $st
Use-Milestone $st 11
$m0 = (RunFrom 11 @(, @(0, 0, 0)))[-1].s; "jalon: " + (Fmt $m0) + " cam=$(CamYaw)"
$mv = [math]::Atan2(-5400 - $m0.pos_x, -460 - $m0.pos_z) / (2 * [math]::PI) * 65536
Load-MemState $s -Slot 11 | Out-Null; $a = St $mv (CamYaw)
function Seq($n, $last) { @(1..$n | % { , @($a[0], $a[1], 0) }) + @(, @($a[0], $a[1], 0x20)) + @(, @($a[0], $a[1], $last)) + @(1..10 | % { , @($a[0], $a[1], 0) }) }
foreach ($c in @(@(2, 0x40, 'slide kick'), @(3, 0x40, 'slide kick'), @(3, 0xA0, 'long jump'))) {
  $fs = RunFrom 11 (Seq $c[0] $c[1])
  "$($c[2]) apres $($c[0]) frames : " + (($fs | % { '{0:N1}/{1:X}' -f $_.s.forward_vel, ([long]$_.s.action -band 0xFFF) }) -join ' ')
}
