# Search for the Bob-omb grab from c2a_passage.st: walk toward theta, B at frame f.
# Criterion: Mario grabbing (0x383); keep the earliest grab. Stop by batches at the first success.
. "$PSScriptRoot\freerun.ps1"
$d = if ($env:MOVIE_CHOMP_DIR) { $env:MOVIE_CHOMP_DIR } else { Join-Path $PSScriptRoot '..\MOVIE_CHOMP' }
Use-Milestone "$d/c2a_passage.st" 27; $cy = CamYaw
$base = -32270; $thetas = @(0, -700, 700, -1400, 1400) | % { Wrap ($base + $_) }
$trials = @(); $meta = @()
foreach ($f in 5..40) { foreach ($th in $thetas) {
    $st = StickRaw $th $cy; $fr = @(1..60 | % { , @($st[0], $st[1], 0) }); $fr[$f - 1] = @($st[0], $st[1], 0x40)
    $trials += , $fr; $meta += [pscustomobject]@{ f = $f; th = $th } } }
$tag = 'grab_' + (Get-Date -Format 'HHmmss'); $pool = Start-Pool "$d\c2a_passage.st" 6 $tag 0
$best = $null
try {
    for ($i = 0; $i -lt $trials.Count; $i += 30) {
        $j = [math]::Min($i + 29, $trials.Count - 1)
        $res = Invoke-PoolBatch $pool $trials[$i..$j] -All
        for ($k = 0; $k -le ($j - $i); $k++) {
            $t = $res[$k].traj; $hitF = $null
            for ($q = 0; $q -lt $t.Count; $q++) { if ([long]$t[$q][3] -eq 0x383) { $hitF = $q + 1; break } }
            if ($hitF -and (-not $best -or $hitF -lt $best.hit)) { $best = [pscustomobject]@{ hit = $hitF; f = $meta[$i + $k].f; th = $meta[$i + $k].th; frames = $trials[$i + $k] } }
        }
        Write-Host ("trials {0}..{1} done ; best: {2}" -f $i, $j, $(if ($best) { "grab frame $($best.hit) (B f=$($best.f), th=$($best.th))" } else { 'none' }))
        # the f values increase: if we already have a grab before the next f tested, no need to continue
        if ($best -and $meta[[math]::Min($j + 1, $meta.Count - 1)].f -ge $best.hit) { break }
    }
} finally { Stop-Pool $pool }
if ($best) { $best | ConvertTo-Json -Depth 4 -Compress | Set-Content "$env:TEMP\grab_best.json"; "BEST GRAB: frame $($best.hit), B at f=$($best.f), theta=$($best.th)" } else { "no grab" }
