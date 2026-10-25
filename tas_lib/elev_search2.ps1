# Arrivee sur l'elevateur (montee de P127, t+146..186) depuis c2a_passage.st, en commandes monde (camera corrigee chaque frame).
# w neutres, k frames de marche vers (1680,4466), Z, Z+A (LJ), j frames Z seul, puis stick arriere + Z.
# Critere : 0x479 sur la plateforme (1500<x<1760, 300<y<600). Arret au premier succes (w croissant).
. "$PSScriptRoot\freerun.ps1"
$d = if ($env:MOVIE_CHOMP_DIR) { $env:MOVIE_CHOMP_DIR } else { Join-Path $PSScriptRoot '..\MOVIE_CHOMP' }
$aim = YawTo 2207 4373 1680 4466; $back = Wrap ($aim + 32768)
$trials = @(); $meta = @()
$back = 16384
foreach ($w in 76..120) { foreach ($k in 12, 14, 16) { foreach ($jj in 0, 3, 6, 9) {
    $c = @(); 1..$w | % { $c += , @($null, 0, $null, $null) }
    1..6 | % { $c += , @($null, 0, 2150, 4466) }          # se placer sur l'axe z=4466
    1..$k | % { $c += , @(-16384, 0, $null, $null) }       # plein ouest
    $c += , @(-16384, 0x20, $null, $null); $c += , @(-16384, 0xA0, $null, $null)
    if ($jj) { 1..$jj | % { $c += , @($null, 0x20, $null, $null) } }
    1..40 | % { $c += , @($back, 0x20, $null, $null) }
    $trials += , $c; $meta += [pscustomobject]@{ w = $w; k = $k; j = $jj } } } }
$tag = 'elev2_' + (Get-Date -Format 'HHmmss'); $pool = Start-Pool "$d\c2a_passage.st" 6 $tag 0
$hit = $null
try {
    for ($i = 0; $i -lt $trials.Count -and -not $hit; $i += 18) {
        $j = [math]::Min($i + 17, $trials.Count - 1)
        $res = Invoke-PoolCmds $pool $trials[$i..$j]
        for ($q = 0; $q -le ($j - $i); $q++) {
            $t = $res[$q].traj; $m = $meta[$i + $q]; $start = $m.w + $m.k + 8
            for ($f = $start; $f -lt $t.Count; $f++) {
                if ([long]$t[$f][3] -eq 0x479 -and [long]$t[$f - 1][3] -ne 0x479 -and $t[$f][0] -gt 1600 -and $t[$f][0] -lt 1760 -and $t[$f][2] -gt 4430 -and $t[$f][2] -lt 4500 -and $t[$f][1] -gt 440 -and $t[$f][1] -lt 500 -and [math]::Abs($t[$f][6] + 16384) -lt 400) {
                    $hit = [pscustomobject]@{ w = $m.w; k = $m.k; j = $m.j; f = $f + 1; pos = $t[$f]; inputs = @($res[$q].inputs)[0..$f] }; break }
            }
            if ($hit) { break }
        }
        Write-Host ("essais {0}..{1} (w={2}..{3}) faits ; {4}" -f $i, $j, $meta[$i].w, $meta[$j].w, $(if ($hit) { "TROUVE w=$($hit.w) k=$($hit.k) j=$($hit.j) atterrissage frame $($hit.f) pos=($($hit.pos[0]),$($hit.pos[1]),$($hit.pos[2])) v=$($hit.pos[5])" } else { 'rien' }))
    }
} finally { Stop-Pool $pool }
if ($hit) { $hit | ConvertTo-Json -Depth 5 -Compress | Set-Content "$env:TEMP\elev2_hit.json"; "SUCCES w=$($hit.w) k=$($hit.k) j=$($hit.j)" } else { "aucun atterrissage sur la plateforme" }
