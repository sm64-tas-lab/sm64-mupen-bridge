# Enchaine : attend la fin de la recherche d'atterrissage, puis lance l'etape 2 si un atterrissage a ete trouve.
$o = "$env:TEMP\elev_search.out"
while (-not ((Test-Path $o) -and ((Get-Content $o -Raw) -match 'SUCCES|aucun atterrissage'))) { Start-Sleep 5 }
if ((Get-Content $o -Raw) -match 'SUCCES') {
    Start-Sleep 8   # laisser le pool se fermer
    Get-Process mupen64 -ErrorAction SilentlyContinue | ? { $_.Id -ne 33204 } | Stop-Process -Force -ErrorAction SilentlyContinue
    & "$PSScriptRoot\elev_stage2.ps1" *> "$env:TEMP\es2.out"
}
