# Search for the arrival on the elevator from c2a_passage.st: wait w, walk k frames west,
# Z, Z+A (LJ to the west), back stick (east) + Z until landing. Criterion: 0x479 on the platform
# (x > 1680, y > 300, speed < 0). Stop at the first success (in batches, w increasing).
. "$PSScriptRoot\freerun.ps1"
$d = if ($env:MOVIE_CHOMP_DIR) { $env:MOVIE_CHOMP_DIR } else { Join-Path $PSScriptRoot '..\MOVIE_CHOMP' }
Use-Milestone "$d/c2a_passage.st" 27; $cy = CamYaw
# aims at the center of platform P127 (1680,4466) from the stop after landing (~2207,4373)
$aim = YawTo 2207 4373 1680 4466; $W = StickRaw $aim $cy; $E = StickRaw (Wrap ($aim + 32768)) $cy
$trials = @(); $meta = @()
foreach ($w in 80..110) { foreach ($k in 18, 20) { foreach ($jj in 4, 6, 8, 10, 12, 14) {
    $fr = @(); if ($w) { 1..$w | % { $fr += , @(0, 0, 0) } }
    1..$k | % { $fr += , @($W[0], $W[1], 0) }; $fr += , @($W[0], $W[1], 0x20); $fr += , @($W[0], $W[1], 0xA0)
    1..$jj | % { $fr += , @(0, 0, 0x20) }
    1..45 | % { $fr += , @($E[0], $E[1], 0x20) }
    $trials += , $fr; $meta += [pscustomobject]@{ w = $w; k = $k; j = $jj } } } }
$tag = 'elev_' + (Get-Date -Format 'HHmmss'); $pool = Start-Pool "$d\c2a_passage.st" 6 $tag 0
$hit = $null
try {
    for ($i = 0; $i -lt $trials.Count -and -not $hit; $i += 24) {
        $j = [math]::Min($i + 23, $trials.Count - 1)
        $res = Invoke-PoolBatch $pool $trials[$i..$j] -All
        for ($q = 0; $q -le ($j - $i); $q++) {
            $t = $res[$q].traj; $m = $meta[$i + $q]; $start = $m.w + $m.k + 2
            for ($f = $start; $f -lt $t.Count; $f++) {
                if ([long]$t[$f][3] -eq 0x479 -and $t[$f][0] -gt 1500 -and $t[$f][0] -lt 1760 -and $t[$f][1] -gt 300 -and $t[$f][1] -lt 600) { $hit = [pscustomobject]@{ w = $m.w; k = $m.k; j = $m.j; f = $f + 1; pos = $t[$f]; frames = $trials[$i + $q][0..$f] }; break }
            }
            if ($hit) { break }
        }
        Write-Host ("trials {0}..{1} done ; {2}" -f $i, $j, $(if ($hit) { "FOUND w=$($hit.w) k=$($hit.k) landing frame $($hit.f) pos=($($hit.pos[0]),$($hit.pos[1]),$($hit.pos[2]))" } else { 'nothing' }))
    }
} finally { Stop-Pool $pool }
if ($hit) { $hit | ConvertTo-Json -Depth 5 -Compress | Set-Content "$env:TEMP\elev_hit.json"; "SUCCES w=$($hit.w) k=$($hit.k)" } else { "aucun atterrissage sur la plateforme" }
