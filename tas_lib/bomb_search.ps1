# Recherche du bomb clip (grille du Chomp) : sonde fuse -> B saisie (frame g) -> B relance (frame t) ou rien.
# Critere : Mario a plus de 60 derriere le plan de la grille, sur le sol (y >= 760). Arret au premier succes.
. "$PSScriptRoot\freerun.ps1"
$nx = -0.536; $nz = 0.844
function BehindXZ($x, $z) { - ((($x - 1456) * $nx) + (($z - 446) * $nz)) }
$d = if ($env:MOVIE_CHOMP_DIR) { $env:MOVIE_CHOMP_DIR } else { Join-Path $PSScriptRoot '..\MOVIE_CHOMP' }
$hit = $null
foreach ($fuse in 150, 147, 144) {
    $tag = "bomb_${fuse}_" + (Get-Date -Format 'HHmmss')
    $pool = Start-Pool "$d\sonde_bomb_f$fuse.st" 6 $tag 0
    try {
        $trials = @(); $meta = @()
        foreach ($g in 1..8) { foreach ($t in @(0) + @(($g + 11)..($g + 26))) {
            $fr = @(1..45 | % { , @(0, 0, 0) }); $fr[$g - 1] = @(0, 0, 0x40); if ($t -gt 0) { $fr[$t - 1] = @(0, 0, 0x40) }
            $trials += , $fr; $meta += [pscustomobject]@{ fuse = $fuse; g = $g; t = $t } } }
        # par lots de 24 pour pouvoir s'arreter tot
        for ($i = 0; $i -lt $trials.Count -and -not $hit; $i += 24) {
            $j = [math]::Min($i + 23, $trials.Count - 1)
            $res = Invoke-PoolBatch $pool $trials[$i..$j] -All
            for ($k = 0; $k -le ($j - $i); $k++) {
                $best = ($res[$k].traj | % { BehindXZ $_[0] $_[2] } | measure -Maximum).Maximum
                $m = $meta[$i + $k]
                $inside = @($res[$k].traj | ? { (BehindXZ $_[0] $_[2]) -gt 60 -and $_[1] -ge 760 })
                if ($inside.Count -gt 0) { $hit = [pscustomobject]@{ fuse = $fuse; g = $m.g; t = $m.t; frames = $trials[$i + $k]; traj = $res[$k].traj }; break }
                if ($best -gt -30) { Write-Host ("  fuse={0} g={1} t={2} derriere max={3:N0}" -f $fuse, $m.g, $m.t, $best) }
            }
            Write-Host ("fuse={0} essais {1}..{2} faits" -f $fuse, $i, $j)
        }
    } finally { Stop-Pool $pool }
    if ($hit) { break }
}
if ($hit) {
    "SUCCES fuse=$($hit.fuse) g=$($hit.g) t=$($hit.t)"
    $hit.traj | % { $i = 0 } { $i++; "{0,2} ({1},{2},{3}) act={4:X} derriere={5:N0}" -f $i, $_[0], $_[1], $_[2], [long]$_[3], (BehindXZ $_[0] $_[2]) }
    $hit | ConvertTo-Json -Depth 5 -Compress | Set-Content "$env:TEMP\bomb_hit.json"
} else { "aucun clip trouve" }
