# Reads the results (partial or complete) of a batch and lists the hits that send Mario toward a target.
# Hit = HP drop; extend the straight line (punches) from the position after the hit.
param([string]$Tag = 'flyguy2', [int]$MinHp = 0x480)
$tg = @(@{n = 'pokey'; x = 4602; z = 4622; r = 250 }, @{n = 'g1'; x = 6068; z = 2800; r = 700 }, @{n = 'g2'; x = 5535; z = 3377; r = 700 }, @{n = 'g3'; x = 5980; z = 3911; r = 700 })
$res = Get-ChildItem "$env:TEMP\sm64par_$Tag" -Filter 'out_*.jsonl' | % { Get-Content $_.FullName } | % { $_ | ConvertFrom-Json }
$rows = foreach ($t in $res) {
    # last event of each back-motion sequence = position/yaw after the hit
    $prevHp = $null
    foreach ($e in $t.ev) {
        $f = $e[0]; $yaw = $e[1]; $x = $e[2]; $z = $e[3]; $hp = $e[4]
        if ($null -ne $prevHp -and $hp -lt $prevHp -and $hp -ge $MinHp) {
            $a = $yaw / 65536 * 2 * [math]::PI; $dx = [math]::Sin($a); $dz = [math]::Cos($a)
            foreach ($g in $tg) {
                $px = $g.x - $x; $pz = $g.z - $z; $along = $px * $dx + $pz * $dz; $perp = [math]::Abs($px * $dz - $pz * $dx)
                if ($along -gt 0 -and $perp -lt $g.r) { [pscustomobject]@{ id = $t.id; f = $f; yaw = $yaw; x = $x; z = $z; hp = ('{0:X}' -f $hp); cible = $g.n; dist = [int]$along; perp = [int]$perp; b = (@($t.b) -join ',') } }
            }
        }
        $prevHp = $hp
    }
}
"trials read: $(@($res).Count)  candidates: $(@($rows).Count)"
$rows | Sort-Object id, f -Unique | Sort-Object @{e = { [int]('0x' + $_.hp) }; Descending = $true }, perp | Select -First 20 | ft -AutoSize | Out-String -Width 250
