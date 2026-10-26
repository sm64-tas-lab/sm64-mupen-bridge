# Parallel search worker: launches ITS OWN mupen, loads a milestone, replays a list of trials.
# Trial = @{ id; n (frames); win = @(@(start, end), ...) } : auto-B (0x100) active on [start, end[ (1-based frames)
#         or @{ id; n; b = @(frames where B is pressed) }.
# Output (jsonl): id, frames where B was actually pressed, yaw changes (hits), HP, final state.
param([int]$Id, [string]$Milestone, [string]$TrialsFile, [string]$OutFile)
Import-Module "$PSScriptRoot\..\tas\control\SM64Ctl.psm1" -Force -WarningAction SilentlyContinue
[System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::InvariantCulture
$s = Start-Mupen -NoSavestate
try {
    Set-Pause $s -Value $true; Load-State -Session $s -Path $Milestone | Out-Null; Start-Sleep 2; Set-Pause $s -Value $true
    Save-MemState $s -Slot 1 | Out-Null
    Invoke-MupenLua $s 'REPLAY_SPEED_MODE = 2; return 1' | Out-Null   # replays at ultra fast-forward
    $trials = Get-Content $TrialsFile -Raw | ConvertFrom-Json
    foreach ($t in $trials) {
        $fr = New-Object 'object[]' ([int]$t.n)
        for ($i = 0; $i -lt $t.n; $i++) { $fr[$i] = @(0, 0, 0) }
        if ($t.win) { foreach ($w in $t.win) { for ($i = [int]$w[0]; $i -lt [int]$w[1] -and $i -le $t.n; $i++) { $fr[$i - 1] = @(0, 0, 0x100) } } }
        if ($t.b) { foreach ($p in $t.b) { $fr[[int]$p - 1] = @(0, 0, 0x40) } }
        Load-MemState $s -Slot 1 | Out-Null
        $r = Invoke-Replay -Session $s -Frames $fr -SampleAll
        $ev = @(); $py = $null; $ph = $null
        foreach ($f in $r.frames) {
            $st = $f.s
            if ($null -ne $py -and ($st.face_yaw -ne $py -or $st.health -ne $ph)) { $ev += , @($f.f, $st.face_yaw, [int]$st.pos_x, [int]$st.pos_z, $st.health, [long]$st.action) }
            $py = $st.face_yaw; $ph = $st.health
        }
        $last = $r.frames[-1].s
        $b = @(); foreach ($i in 0..($t.n - 1)) { if (([int]$fr[$i][2] -band 0x40) -ne 0) { $b += ($i + 1) } }
        $b += @($r.autob)
        $o = [ordered]@{ id = $t.id; b = @($b | Sort-Object -Unique); ev = $ev; x = $last.pos_x; y = $last.pos_y; z = $last.pos_z; yaw = $last.face_yaw; hp = $last.health; act = [long]$last.action }
        ($o | ConvertTo-Json -Compress -Depth 5) | Add-Content -LiteralPath $OutFile
    }
} finally { Stop-Mupen $s }
