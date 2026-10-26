. "$PSScriptRoot\sblj_approach.ps1"
$hit = $null
:outer foreach ($t in 4, 3) { foreach ($k in 8, 7) { foreach ($D in -14250, -14000, -14500, -13750) {
    $r = TryApp $D $k $t
    "{0} D={1} k={2} t={3} fl={4} dist={5} al={6} v={7} yaw={8} y={9} {10}" -f $r.ok, $D, $k, $t, $r.fl, $r.dist, $r.al, $r.v, $r.yaw, $r.y, $r.info
    if (Good $r) { $hit = $r; break outer } } } }
if ($hit) { ConvertTo-Json -InputObject $hit.frames -Compress | Set-Content "$env:TEMP\sblj_app_hit.json"; "HIT saved" } else { "no hit" }
