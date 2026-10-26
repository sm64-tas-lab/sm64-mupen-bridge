# Watches a running batch: as soon as hit n (n = HitIndex) sends Mario toward the target (in front of him, offset < MaxPerp), shows it and exits.
param([string]$Tag, [int]$HitIndex = 2, [double]$TX = 4602, [double]$TZ = 4622, [double]$MaxPerp = 300, [int]$TimeoutSec = 900)
$sw = [Diagnostics.Stopwatch]::StartNew()
function Hits($t) {
    $hits = @(); $ph = 0x880
    foreach ($e in $t.ev) { if ($e[4] -lt $ph -and ($ph - $e[4]) -ge 0x40 -and ($hits.Count -eq 0 -or $e[0] - $hits[-1][0] -gt 20)) { $hits += , $e }; $ph = $e[4] }
    $hits
}
while ($true) {
    $done = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -match 'worker\.ps1' } | Measure).Count -eq 0
    $res = @(Get-ChildItem "$env:TEMP\sm64par_$Tag" -Filter 'out_*.jsonl' -ErrorAction SilentlyContinue | % { Get-Content $_.FullName } | % { $_ | ConvertFrom-Json })
    $best = foreach ($t in $res) {
        $h = @(Hits $t); if ($h.Count -lt $HitIndex) { continue }
        # position/yaw at the end of the back motion: last event before the next hit
        $e = $h[$HitIndex - 1]
        $a = $e[1] / 65536 * 2 * [math]::PI; $dx = [math]::Sin($a); $dz = [math]::Cos($a)
        $px = $TX - $e[2]; $pz = $TZ - $e[3]; $along = $px * $dx + $pz * $dz; $perp = [math]::Abs($px * $dz - $pz * $dx)
        [pscustomobject]@{ id = $t.id; f = $e[0]; yaw = $e[1]; x = $e[2]; z = $e[3]; hp = ('{0:X}' -f $e[4]); along = [int]$along; perp = [int]$perp; b = (@($t.b) -join ',') }
    }
    if ($res.Count -eq 0) { $done = $false }   # workers not started yet
    $ok = @($best | ? { $_.along -gt 0 -and $_.perp -lt $MaxPerp } | Sort-Object perp)
    if ($ok.Count -gt 0 -or $done -or $sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
        "read: $($res.Count)  found: $($ok.Count)  finished: $done"
        if ($ok.Count) { $ok | Select -First 10 | ft -AutoSize | Out-String -Width 250 }
        else { "best (along>0):"; $best | ? { $_.along -gt 0 } | Sort-Object perp | Select -First 8 | ft -AutoSize | Out-String -Width 250 }
        break
    }
    Start-Sleep 20
}
