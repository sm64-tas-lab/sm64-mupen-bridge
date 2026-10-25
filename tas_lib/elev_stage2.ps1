# Etape 2 : depuis l'atterrissage sur l'elevateur (e2_sur_elevateur.st), BLJ espaces puis recul vers la grille.
# n BLJ espaces de 3 frames (les d derniers espaces de 2), e frames d'atterrissage, puis recul vers (tx,tz).
# Critere : Mario DANS l'enclos (profondeur 60..340 derriere la grille, |abscisse| < 480, y 760..1000).
. "$PSScriptRoot\freerun.ps1"
$d = 'G:\tas-lab\MOVIE_CHOMP'
$nx = -0.536; $nz = 0.844
function Depth($x, $z) { - ((($x - 1456) * $nx) + (($z - 446) * $nz)) }
function Along($x, $z) { (($x - 1456) * 0.844) + (($z - 446) * 0.536) }
# jalon e2 depuis c2a + inputs de l'atterrissage trouve
$hit = Get-Content "$env:TEMP\elev2_hit.json" -Raw | ConvertFrom-Json
$pre = @($hit.inputs | % { , @([int]$_[0], [int]$_[1], [int]$_[2]) })
Use-Milestone "$d/c2a_passage.st" 27
Write-Host "atterrissage (rejeu du prefixe) : $(Fmt (RunFrom 27 $pre)[-1].s)"
# prefixe en inputs bruts (pas de jalon sauve : la frame neutre ajoutee par la sauvegarde casse le premier BLJ)
$rawPre = @($pre | % { , @($_[0], $_[2], $null, $null, 0, 1, $_[1]) })
$trials = @(); $meta = @()
# p BLJ bufferises (A+Z+Start, Z, Z+Start, Z = 1 frame de jeu chacun) puis q BLJ normaux espaces de sp frames,
# e frames d'atterrissage, puis recul vers la grille. Duree de la montee = p + sp*(q-1) + 1 frames, vitesse ~ 14*1.45^(p+q).
foreach ($sp in 3, 2) { foreach ($q in 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4) { foreach ($p in 0, 2, 4, 6) { foreach ($e in 3, 1) {
    $tgt = @(1456, 446); $c = @()
    if ($p) { 1..$p | % { $c += , @(16384, 0xB0); $c += , @(16384, 0x20); $c += , @(16384, 0x30); $c += , @(16384, 0x20) } }
    for ($b = 0; $b -lt $q; $b++) { $c += , @(16384, 0xA0); if ($b -lt $q - 1) { 1..($sp - 1) | % { $c += , @(16384, 0x20) } } }
    1..$e | % { $c += , @(16384, 0x20) }
    1..60 | % { $c += , @($null, 0, $tgt[0], $tgt[1], 1) }
    $trials += , $c; $meta += [pscustomobject]@{ n = "$p buf + $q nor (sp=$sp)"; d = 0; e = $e; tx = $tgt[0]; tz = $tgt[1] } } } } }
$tag = 'es2_' + (Get-Date -Format 'HHmmss'); $pool = Start-Pool "$d\e2_sur_elevateur.st" 6 $tag 0
$hit2 = $null
try {
    for ($i = 0; $i -lt $trials.Count -and -not $hit2; $i += 6) {
        $j = [math]::Min($i + 5, $trials.Count - 1)
        $res = Invoke-PoolCmds $pool $trials[$i..$j]
        for ($q = 0; $q -le ($j - $i); $q++) {
            $t = $res[$q].traj; $m = $meta[$i + $q]
            $maxv = ($t | % { [math]::Abs($_[5]) } | measure -Maximum).Maximum
            $fin = $t[-1]
            Write-Host ("  n={0} d={1} e={2} cible=({3},{4}) : |v| max={5:N0} fin=({6},{7},{8}) act={9:X}" -f $m.n, $m.d, $m.e, $m.tx, $m.tz, $maxv, $fin[0], $fin[1], $fin[2], [long]$fin[3])
            for ($f = 0; $f -lt $t.Count; $f++) {
                $dp = Depth $t[$f][0] $t[$f][2]; $al = Along $t[$f][0] $t[$f][2]
                if ($dp -gt 60 -and $dp -lt 340 -and [math]::Abs($al) -lt 480 -and $t[$f][1] -ge 760 -and $t[$f][1] -lt 1000) {
                    $hit2 = [pscustomobject]@{ n = $m.n; d = $m.d; e = $m.e; tx = $m.tx; tz = $m.tz; f = $f + 1; pos = $t[$f]; inputs = @($res[$q].inputs); traj = $t }; break }
            }
            if ($hit2) { break }
        }
        Write-Host ("essais {0}..{1} faits ; {2}" -f $i, $j, $(if ($hit2) { "DANS L'ENCLOS n=$($hit2.n) d=$($hit2.d) e=$($hit2.e) frame $($hit2.f) pos=($($hit2.pos[0]),$($hit2.pos[1]),$($hit2.pos[2]))" } else { 'rien' }))
    }
} finally { Stop-Pool $pool }
if ($hit2) { $hit2 | ConvertTo-Json -Depth 6 -Compress | Set-Content "$env:TEMP\es2_hit.json"; "SUCCES2 n=$($hit2.n) d=$($hit2.d) e=$($hit2.e)" } else { "aucun passage dans l'enclos" }
