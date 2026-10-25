. "$PSScriptRoot\checker.ps1"
$MS = 0x8033B170
function CamYaw { $ar = U32 (Read-Mem -Session $s -Addr ($MS + 0x90) -Type u32); $cm = U32 (Read-Mem -Session $s -Addr ($ar + 0x24) -Type u32); [double](Read-Mem -Session $s -Addr ($cm + 0x2) -Type s16) }
# stick (x,y) pour aller dans la direction monde $Dir (yaw SM64) avec la camera $cy
function St([double]$Dir, [double]$cy, [double]$mag = 127) { $t = ($Dir - $cy) / 65536 * 2 * [math]::PI; @([int][math]::Round($mag * [math]::Sin($t)), [int][math]::Round(-$mag * [math]::Cos($t))) }
# distance perpendiculaire a la contremarche n1 (x+z=-1950), >0 = cote marche basse ; abscisse le long de la marche
function PerpD($st) { ($st.pos_x + $st.pos_z + 1950) / 1.41421356 }
function AlongS($st) { ($st.pos_x - $st.pos_z) / 1.41421356 }
function Fmt($st) { '({0:N1},{1:N1},{2:N1}) v={3:N1} yaw={4} act={5:X}' -f $st.pos_x, $st.pos_y, $st.pos_z, $st.forward_vel, $st.face_yaw, ([long]$st.action) }
# chaine SBLJ depuis l'etat courant : cycles (Z+A+cote, Z+cote). Renvoie liste des vitesses et etat final
function Chain([int]$maxCycles = 12, [double]$side = -24576) {
    $cy = CamYaw; $a = St $side $cy; $fr = @()
    for ($c = 0; $c -lt $maxCycles; $c++) { $fr += , @($a[0], $a[1], 0xA0); $fr += , @($a[0], $a[1], 0x20) }
    $r = Invoke-Replay -Session $s -Frames $fr -SampleAll
    $vs = @(); $last = $null
    foreach ($f in $r.frames) { if ($f.f % 2 -eq 0) { if ([long]$f.s.action -ne 0x479) { break }; $vs += [math]::Round($f.s.forward_vel, 1); $last = $f } }
    [pscustomobject]@{ vs = $vs; n = $vs.Count; last = $last; frames = $fr }
}
# essaie un cycle (2 frames) avec la direction $d ; renvoie l'etat apres le cycle
function TryCycle([double]$d, [double]$cy) { $a = St $d $cy; $fr = @(, @($a[0], $a[1], 0xA0)) + @(, @($a[0], $a[1], 0x20)); $r = Invoke-Replay -Session $s -Frames $fr -SampleAll; [pscustomobject]@{ d = $d; fr = $fr; s1 = $r.frames[0].s; s2 = $r.frames[1].s } }
function OkCycle($t) { ([long]$t.s2.action -eq 0x479) -and ($t.s2.pos_y -lt 1) -and ([long]$t.s1.action -eq 0x479) }
# chaine gloutonne avec anticipation d'un cycle. Slots memoire 20.. utilises. Renvoie inputs + vitesses
function ChainGreedy([int]$maxCycles = 12, [double[]]$dirs = @(26000..34000 | ? { $_ % 500 -eq 0 })) {
    $all = @(); $vs = @(); $cur = $null
    Save-MemState $s -Slot 20 | Out-Null
    for ($c = 0; $c -lt $maxCycles; $c++) {
        Load-MemState $s -Slot 20 | Out-Null; $cy = CamYaw
        $cands = @()
        foreach ($d in $dirs) {
            Load-MemState $s -Slot 20 | Out-Null; $t = TryCycle $d $cy
            if (OkCycle $t) {
                # anticipation : existe-t-il un cycle suivant valide ?
                Save-MemState $s -Slot 21 | Out-Null; $cy2 = CamYaw; $nxt = 0
                foreach ($d2 in $dirs) { Load-MemState $s -Slot 21 | Out-Null; if (OkCycle (TryCycle $d2 $cy2)) { $nxt++ } }
                $cands += [pscustomobject]@{ t = $t; nxt = $nxt; v = $t.s2.forward_vel }
            }
        }
        if ($cands.Count -eq 0) { break }
        $best = $cands | Sort-Object @{e = { $_.nxt -gt 0 }; Descending = $true }, @{e = { $_.v } } | Select -First 1
        Load-MemState $s -Slot 20 | Out-Null; $t = TryCycle $best.t.d $cy
        $all += $t.fr; $vs += [math]::Round($t.s2.forward_vel, 1); $cur = $t.s2
        Save-MemState $s -Slot 20 | Out-Null
        if ($best.nxt -eq 0) { break }
    }
    [pscustomobject]@{ frames = $all; vs = $vs; last = $cur }
}
# approche depuis le slot 10 : n frames de course vers F, Z, Z+A, puis stick arriere (F+32768+th) + Z jusqu'a l'atterrissage LJ
function Approach([double]$F, [int]$n, [double]$th, [int]$j = 0, [double]$cy = 10863) {
    $fr = @(); $a = St $F $cy
    for ($i = 0; $i -lt $n; $i++) { $fr += , @($a[0], $a[1], 0) }
    $fr += , @($a[0], $a[1], 0x20); $fr += , @($a[0], $a[1], 0xA0)
    for ($i = 0; $i -lt $j; $i++) { $fr += , @(0, 0, 0x20) }
    $b = St ($F + 32768 + $th) $cy
    for ($i = 0; $i -lt 45; $i++) { $fr += , @($b[0], $b[1], 0x20) }
    Load-MemState $s -Slot 10 | Out-Null
    $r = Invoke-Replay -Session $s -Frames $fr -SampleAll
    $lj = $r.frames | ? { [long]$_.s.action -eq 0x3000888 } | Select -First 1
    $land = $r.frames | ? { $_.f -gt ($n + 2) -and [long]$_.s.action -eq 0x479 } | Select -First 1
    if (-not $land) { return $null }
    [pscustomobject]@{ F = $F; n = $n; th = $th; j = $j; fl = $land.f; v = [math]::Round($land.s.forward_vel, 1); yaw = $land.s.face_yaw; d = [math]::Round((PerpD $land.s), 1); sAl = [math]::Round((AlongS $land.s)); y = $land.s.pos_y; ljv = $(if ($lj) { [math]::Round($lj.s.forward_vel, 1) } else { $null }); frames = $fr[0..($land.f - 1)] }
}
# version deterministe : chaque essai rejoue tout le prefixe depuis le slot 10
function RunFrom10($frames) { Load-MemState $s -Slot 10 | Out-Null; (Invoke-Replay -Session $s -Frames $frames -SampleAll).frames }
function ChainGreedyPrefix($prefix, [int]$maxCycles = 10, [double[]]$dirs = @(26000..34000 | ? { $_ % 500 -eq 0 })) {
    $cur = @($prefix); $vs = @()
    $cy = 10863
    for ($c = 0; $c -lt $maxCycles; $c++) {
        $ok = @()
        foreach ($d in $dirs) {
            $a = St $d $cy; $tr = $cur + @(, @($a[0], $a[1], 0xA0)) + @(, @($a[0], $a[1], 0x20))
            $fs = RunFrom10 $tr; $s1 = $fs[-2].s; $s2 = $fs[-1].s
            if ([long]$s1.action -eq 0x479 -and [long]$s2.action -eq 0x479 -and $s2.pos_y -lt 1) { $ok += [pscustomobject]@{ d = $d; tr = $tr; v = $s2.forward_vel; st = $s2 } }
        }
        if ($ok.Count -eq 0) { break }
        # anticipation sur les 4 plus rapides
        $best = $null; $bestN = -1
        $cand = $(if ($script:DCenter) { $ok | Sort-Object @{e = { [math]::Abs((PerpD $_.st) - $script:DCenter) } } | Select -First 3 } else { $ok | Sort-Object v | Select -First 4 })
        foreach ($o in $cand) {
            $n = 0; foreach ($d2 in $dirs) { $a = St $d2 $cy; $fs = RunFrom10 ($o.tr + @(, @($a[0], $a[1], 0xA0)) + @(, @($a[0], $a[1], 0x20))); if ([long]$fs[-2].s.action -eq 0x479 -and [long]$fs[-1].s.action -eq 0x479 -and $fs[-1].s.pos_y -lt 1) { $n++ } }
            if ($n -gt $bestN) { $bestN = $n; $best = $o }
        }
        $cur = $best.tr; $vs += [math]::Round($best.v, 1); Write-Host ("cycle {0}: dir={1} v={2:N1} suite={3} d={5:N1} {4}" -f $c, $best.d, $best.v, $bestN, (Fmt $best.st), (PerpD $best.st))
        if ($bestN -eq 0) { break }
    }
    [pscustomobject]@{ frames = $cur; vs = $vs }
}
function Base84 { $fr = @((Get-Content "$PSScriptRoot\chain2.json" -Raw | ConvertFrom-Json).frames | % { , @([int]$_[0], [int]$_[1], [int]$_[2]) }); $fr + @(1..36 | % { , @(0, 0, 0) }) }
# BLJ d'escalier start-bufferise : a chaque frame de jeu, si Mario est en atterrissage LJ -> A+Z+Start puis 3 frames figees
function BufferedStairs($fr, [int]$maxGame = 40, [int]$stopZ = -1160) {
    $log = @()
    for ($g = 0; $g -lt $maxGame; $g++) {
        $fs = RunFrom10 $fr; $m = $fs[-1].s
        if ($m.pos_z -lt $stopZ -or ([long]$m.action -band 0x1FF) -in 0x12F, 0x120, 0x121) { break }
        if ([long]$m.action -eq 0x479) { $fr += , @(0, 0, 0xB0); $fr += , @(0, 0, 0x20); $fr += , @(0, 0, 0x30); $fr += , @(0, 0, 0x20); $tag = 'BLJ' }
        else { $fr += , @(0, 0, 0x20); $tag = '-' }
        $log += ('{0} {1}' -f $tag, (Fmt $m))
    }
    $fs = RunFrom10 $fr
    [pscustomobject]@{ frames = $fr; log = $log; last = $fs[-1].s }
}

# ---- jalons : savestate FICHIER -> slot memoire, puis rejouer seulement le segment depuis ce jalon ----
# Utiliser un jalon (.st pris juste avant le passage a travailler) au lieu de tout rejouer depuis le debut.
function Use-Milestone([string]$Path, [int]$Slot = 11) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "jalon introuvable: $Path (un chargement de fichier inexistant bloque le bridge)" }
    # pause AVANT le chargement : sinon, si l'emulateur tourne (juste apres Start-Mupen), des frames sans input
    # passent pendant l'attente et le slot ne correspond plus au fichier .st
    Set-Pause $s -Value $true; Load-State -Session $s -Path $Path | Out-Null; Start-Sleep 2; Set-Pause $s -Value $true
    Save-MemState $s -Slot $Slot | Out-Null; $script:MSlot = $Slot
}
function RunFrom([int]$Slot, $frames) { Load-MemState $s -Slot $Slot | Out-Null; (Invoke-Replay -Session $s -Frames $frames -SampleAll).frames }
# sauver un jalon fichier apres un prefixe d'inputs rejoue depuis un slot
function Save-Milestone([int]$FromSlot, $frames, [string]$Path) { RunFrom $FromSlot $frames | Out-Null; Save-State -Session $s -Path $Path }
function Level { Read-Mem -Session $s -Addr 0x8032DDF8 -Type s16 }
