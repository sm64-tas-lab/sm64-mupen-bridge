# Lance N workers en parallele sur une liste d'essais ; renvoie les resultats (objets) quand tout est fini.
function Invoke-Parallel([string]$Milestone, $Trials, [int]$N = 6, [string]$Tag = 'run') {
    $dir = Join-Path $env:TEMP "sm64par_$Tag"; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $dir | Out-Null
    $procs = @()
    for ($k = 0; $k -lt $N; $k++) {
        $part = @(for ($i = $k; $i -lt $Trials.Count; $i += $N) { $Trials[$i] })
        if ($part.Count -eq 0) { continue }
        $tf = Join-Path $dir "trials_$k.json"; ConvertTo-Json -InputObject $part -Depth 5 -Compress | Set-Content $tf
        $of = Join-Path $dir "out_$k.jsonl"
        $procs += Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\worker.ps1`"", '-Id', $k, '-Milestone', "`"$Milestone`"", '-TrialsFile', "`"$tf`"", '-OutFile', "`"$of`"") -WindowStyle Hidden -PassThru
        Start-Sleep 3
    }
    $procs | Wait-Process
    Get-ChildItem $dir -Filter 'out_*.jsonl' | % { Get-Content $_.FullName } | % { $_ | ConvertFrom-Json }
}
