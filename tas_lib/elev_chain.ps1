# Chains: waits for the end of the landing search, then runs step 2 if a landing was found.
$o = "$env:TEMP\elev_search.out"
while (-not ((Test-Path $o) -and ((Get-Content $o -Raw) -match 'SUCCES|aucun atterrissage'))) { Start-Sleep 5 }
if ((Get-Content $o -Raw) -match 'SUCCES') {
    Start-Sleep 8   # let the pool close
    & "$PSScriptRoot\elev_stage2.ps1" *> "$env:TEMP\es2.out"
}
