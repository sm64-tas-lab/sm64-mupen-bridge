# Recherche d'approche SBLJ depuis le slot 10 (Mario a l'arret au pied de l'escalier du hall).
# Phase 1 : m frames stick vers D1 (perpendiculaire vers la contremarche) ; phase 2 : n frames stick vers F ;
# puis Z, Z+A (LJ), puis stick arriere (F+32768+th) + Z jusqu'a l'atterrissage du LJ (0x479).
# Parallele a la marche n1 (x+z = -1950) : yaw -8174.
. "$PSScriptRoot\lib.ps1"
$script:PAR = -8174
function ApproachSB([double]$D1, [int]$m, [double]$F, [int]$n, [double]$th, [double]$cy) {
    $fr = @(); $a1 = St $D1 $cy; $a2 = St $F $cy
    for ($i = 0; $i -lt $m; $i++) { $fr += , @($a1[0], $a1[1], 0) }
    for ($i = 0; $i -lt $n; $i++) { $fr += , @($a2[0], $a2[1], 0) }
    $fr += , @($a2[0], $a2[1], 0x20); $fr += , @($a2[0], $a2[1], 0xA0)
    $b = St ($F + 32768 + $th) $cy
    for ($i = 0; $i -lt 40; $i++) { $fr += , @($b[0], $b[1], 0x20) }
    $r = RunFrom 10 $fr
    $k = $m + $n + 2
    $land = $r | ? { $_.f -gt $k -and [long]$_.s.action -eq 0x479 } | Select -First 1
    if (-not $land) { return $null }
    [pscustomobject]@{ m = $m; F = $F; n = $n; th = $th; fl = $land.f; v = [math]::Round($land.s.forward_vel, 1); yaw = $land.s.face_yaw
        dyaw = $land.s.face_yaw - $script:PAR; d = [math]::Round((PerpD $land.s), 2); y = $land.s.pos_y; frames = $fr[0..($land.f - 1)] }
}
# chaine SBLJ gloutonne depuis un prefixe (slot 10) : cycles (Z+A+cote, Z+cote), garde d proche de DC
function ChainSB($prefix, [double]$cy, [int]$maxCycles = 10, [double]$DC = 1.5, [double[]]$dirs = @(26000..34000 | ? { $_ % 500 -eq 0 })) {
    $cur = @($prefix); $vs = @()
    for ($c = 0; $c -lt $maxCycles; $c++) {
        $ok = @()
        foreach ($d in $dirs) {
            $a = St $d $cy; $tr = $cur + @(, @($a[0], $a[1], 0xA0)) + @(, @($a[0], $a[1], 0x20))
            $fs = RunFrom 10 $tr; $s1 = $fs[-2].s; $s2 = $fs[-1].s
            if ([long]$s1.action -eq 0x479 -and [long]$s2.action -eq 0x479 -and $s2.pos_y -lt 1) { $ok += [pscustomobject]@{ d = $d; tr = $tr; v = $s2.forward_vel; st = $s2 } }
        }
        if ($ok.Count -eq 0) { break }
        $best = $ok | Sort-Object @{e = { [math]::Abs((PerpD $_.st) - $DC) } } | Select -First 1
        $cur = $best.tr; $vs += [math]::Round($best.v, 1)
        Write-Host ("cycle {0}: dir={1} v={2:N1} d={3:N1} {4}" -f $c, $best.d, $best.v, (PerpD $best.st), (Fmt $best.st))
    }
    [pscustomobject]@{ frames = $cur; vs = $vs }
}
