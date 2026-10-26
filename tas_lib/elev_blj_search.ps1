# Spaced BLJ on the elevator (unbuffered) from e1_sur_elevateur.st, then reverse at hyperspeed toward the grid.
# o Z frames before the 1st BLJ, n spaced BLJs of s frames (A+Z on the BLJ frame, Z otherwise, back stick 18209),
# 3 landing frames (Z), then reverse toward (1456,446) (stick opposite the target) for 70 frames.
# Criterion: Mario behind the grid (> 60) at the pen level (y >= 760). Stop at the first success.
. "$PSScriptRoot\freerun.ps1"
$d = if ($env:MOVIE_CHOMP_DIR) { $env:MOVIE_CHOMP_DIR } else { Join-Path $PSScriptRoot '..\MOVIE_CHOMP' }
$nx = -0.536; $nz = 0.844
function BehindXZ($x, $z) { - ((($x - 1456) * $nx) + (($z - 446) * $nz)) }
$trials = @(); $meta = @()
foreach ($s in 3, 2) { foreach ($n in 10, 11, 9, 12, 8) { foreach ($o in 0, 1, 2) {
    $c = @(); if ($o) { 1..$o | % { $c += , @(18209, 0x20) } }
    for ($b = 0; $b -lt $n; $b++) { $c += , @(18209, 0xA0); if ($b -lt $n - 1) { 1..($s - 1) | % { $c += , @(18209, 0x20) } } }
    1..3 | % { $c += , @(18209, 0x20) }
    1..70 | % { $c += , @($null, 0, 1456, 446, 1) }
    $trials += , $c; $meta += [pscustomobject]@{ s = $s; n = $n; o = $o } } } }
$tag = 'ebs_' + (Get-Date -Format 'HHmmss'); $pool = Start-Pool "$d\e1_sur_elevateur.st" 6 $tag 0
$hit = $null
try {
    for ($i = 0; $i -lt $trials.Count -and -not $hit; $i += 6) {
        $j = [math]::Min($i + 5, $trials.Count - 1)
        $res = Invoke-PoolCmds $pool $trials[$i..$j]
        for ($q = 0; $q -le ($j - $i); $q++) {
            $t = $res[$q].traj; $m = $meta[$i + $q]
            $best = ($t | % { BehindXZ $_[0] $_[2] } | measure -Maximum).Maximum
            $maxv = ($t | % { [math]::Abs($_[5]) } | measure -Maximum).Maximum
            $fin = $t[-1]
            Write-Host ("  s={0} n={1} o={2} : |v| max={3:N0} behind max={4:N0} fin=({5},{6},{7}) act={8:X}" -f $m.s, $m.n, $m.o, $maxv, $best, $fin[0], $fin[1], $fin[2], [long]$fin[3])
            for ($f = 0; $f -lt $t.Count; $f++) {
                if ((BehindXZ $t[$f][0] $t[$f][2]) -gt 60 -and $t[$f][1] -ge 760 -and $t[$f][1] -lt 1000 -and [math]::Abs($t[$f][0]) -lt 5000 -and [math]::Abs($t[$f][2]) -lt 5000) {
                    $hit = [pscustomobject]@{ s = $m.s; n = $m.n; o = $m.o; f = $f + 1; pos = $t[$f]; inputs = @($res[$q].inputs); traj = $t }; break }
            }
            if ($hit) { break }
        }
        Write-Host ("trials {0}..{1} done ; {2}" -f $i, $j, $(if ($hit) { "FOUND s=$($hit.s) n=$($hit.n) o=$($hit.o) frame $($hit.f) pos=($($hit.pos[0]),$($hit.pos[1]),$($hit.pos[2]))" } else { 'nothing' }))
    }
} finally { Stop-Pool $pool }
if ($hit) { $hit | ConvertTo-Json -Depth 6 -Compress | Set-Content "$env:TEMP\ebs_hit.json"; "SUCCES s=$($hit.s) n=$($hit.n) o=$($hit.o)" } else { "no pass through the grid" }
