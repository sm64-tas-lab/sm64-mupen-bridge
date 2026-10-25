# Worker persistant : son propre mupen, charge un jalon une fois, puis rejoue les jobs deposes dans JobDir.
# Job   : JobDir\job_<Id>_<n>.json = { id, frames:[[x,y,btn],...] }
# Result: JobDir\res_<id>.json      = { id, states:[etat avant-derniere frame, etat derniere frame] }
# Arret : fichier JobDir\stop
param([int]$Id, [string]$Milestone, [string]$JobDir, [int]$Speed = 0)   # Speed 0 = temps reel, 2 = ultra fast-forward
Import-Module "$PSScriptRoot\..\tas\control\SM64Ctl.psm1" -Force -WarningAction SilentlyContinue
[System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::InvariantCulture
$s = Start-Mupen -NoSavestate -Rom 'G:\tas-lab\Super Mario 64 (USA).z64' -MupenExe 'G:\mupen\mupen64-rr-lua\build\out\mupen64.exe'
try {
    Set-Pause $s -Value $true; Load-State -Session $s -Path $Milestone | Out-Null; Start-Sleep 2; Set-Pause $s -Value $true
    Save-MemState $s -Slot 1 | Out-Null
    Invoke-MupenLua $s ("REPLAY_SPEED_MODE = $Speed; REPLAY_SPEED_PCT = $(if ($Speed -eq 0) { 100 } else { 5000 }); return 1") | Out-Null
    Set-Content (Join-Path $JobDir "ready_$Id") '1'
    while (-not (Test-Path (Join-Path $JobDir 'stop'))) {
        $jobs = @(Get-ChildItem $JobDir -Filter "job_${Id}_*.json" -ErrorAction SilentlyContinue)
        if ($jobs.Count -eq 0) { Start-Sleep -Milliseconds 50; continue }
        foreach ($jf in $jobs) {
            $j = Get-Content $jf.FullName -Raw | ConvertFrom-Json
            if ($j.cmds) {
                # Mode commandes monde : chaque commande = [yaw|null, boutons, tx|null, tz|null].
                # Avant chaque frame : camera reelle lue en memoire (celle que le jeu utilise pour ce stick)
                # et, si cible (tx,tz), direction recalculee depuis la position reelle de Mario.
                Load-MemState $s -Slot 1 | Out-Null; Set-Pause $s -Value $true
                $traj = @(); $applied = @(); $last = $null
                $gt = [long](Read-Mem -Session $s -Addr 0x8032D5D4 -Type u32)   # compteur global de frames
                foreach ($c in $j.cmds) {
                    $ar = [long](Read-Mem -Session $s -Addr (0x8033B170 + 0x90) -Type u32); if ($ar -lt 0) { $ar += 4294967296 }
                    $cm = [long](Read-Mem -Session $s -Addr ($ar + 0x24) -Type u32); if ($cm -lt 0) { $cm += 4294967296 }
                    $cy = [double](Read-Mem -Session $s -Addr ($cm + 0x2) -Type s16)
                    $dir = $null
                    if ($c.Count -gt 6 -and [int]$c[5] -eq 1) { }
                    elseif ($null -ne $c[2]) {
                        $px = [double](Read-Mem -Session $s -Addr (0x8033B170 + 0x3C) -Type f32); $pz = [double](Read-Mem -Session $s -Addr (0x8033B170 + 0x44) -Type f32)
                        $dir = [math]::Atan2([double]$c[2] - $px, [double]$c[3] - $pz) / (2 * [math]::PI) * 65536
                        if ($c.Count -gt 4 -and [int]$c[4] -eq 1) { $dir += 32768 }   # recul : Mario tourne le dos a la cible et recule vers elle
                    } elseif ($null -ne $c[0]) { $dir = [double]$c[0] }
                    $sx = 0; $sy = 0
                    if ($c.Count -gt 6 -and [int]$c[5] -eq 1) { $dir = $null; $sx = [int]$c[0]; $sy = [int]$c[6] }   # input brut [sx, btn, -, -, -, 1, sy]
                    if ($null -ne $dir) {
                        $t = ($dir - $cy) / 65536 * 2 * [math]::PI; $o2 = @()
                        foreach ($p in @((121 * [math]::Sin($t)), (-121 * [math]::Cos($t)))) { $q = [int][math]::Round($p); if ([math]::Abs($q) -lt 2) { $o2 += 0 } else { $o2 += [int][math]::Max(-127, [math]::Min(127, $q + 6 * [math]::Sign($q))) } }
                        $sx = [int]$o2[0]; $sy = [int]$o2[1]
                    }
                    $b = [int]$c[1]
                    $st = Step-Frames -Session $s -Frames 1 -Buttons @{ X = $sx; Y = $sy; A = (($b -band 0x80) -ne 0); B = (($b -band 0x40) -ne 0); Z = (($b -band 0x20) -ne 0); start = (($b -band 0x10) -ne 0) }
                    # frames en trop (emulateur qui a tourne sans input) : les consigner en neutre pour que le rejeu soit identique
                    $row = @([math]::Round($st.pos_x, 1), [math]::Round($st.pos_y, 1), [math]::Round($st.pos_z, 1), [long]$st.action, $st.num_stars, [math]::Round($st.forward_vel, 1), [int]$st.face_yaw)
                    $gt2 = [long]$st.global_timer; for ($x = $gt + 1; $x -lt $gt2; $x++) { $applied += , @(0, 0, 0); $traj += , $row }; $gt = $gt2
                    $applied += , @($sx, $sy, $b)
                    $traj += , $row
                    $last = $st
                }
                $o = [ordered]@{ id = $j.id; traj = $traj; inputs = $applied; states = @($last, $last) }
                $tmp = Join-Path $JobDir ("res_{0}.tmp" -f $j.id)
                ($o | ConvertTo-Json -Compress -Depth 5) | Set-Content $tmp
                Move-Item $tmp (Join-Path $JobDir ("res_{0}.json" -f $j.id)) -Force
                Remove-Item $jf.FullName -Force
                continue
            }
            $fr = @($j.frames | % { , @([int]$_[0], [int]$_[1], [int]$_[2]) })
            Load-MemState $s -Slot 1 | Out-Null
            $n = $fr.Count
            if ($j.all) {
                $r = Invoke-Replay -Session $s -Frames $fr -SampleAll
                $o = [ordered]@{ id = $j.id; traj = @($r.frames | % { , @([math]::Round($_.s.pos_x, 1), [math]::Round($_.s.pos_y, 1), [math]::Round($_.s.pos_z, 1), [long]$_.s.action, $_.s.num_stars) }); states = @($r.frames[-2].s, $r.frames[-1].s) }
            } else {
                $r = Invoke-Replay -Session $s -Frames $fr -Samples @(($n - 1), $n)
                $o = [ordered]@{ id = $j.id; states = @($r.frames | % { $_.s }) }
            }
            $tmp = Join-Path $JobDir ("res_{0}.tmp" -f $j.id)
            ($o | ConvertTo-Json -Compress -Depth 5) | Set-Content $tmp
            Move-Item $tmp (Join-Path $JobDir ("res_{0}.json" -f $j.id)) -Force
            Remove-Item $jf.FullName -Force
        }
    }
} finally { Stop-Mupen $s }
