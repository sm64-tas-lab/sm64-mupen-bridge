<#
  register_mcp.ps1 — Enregistre automatiquement le serveur MCP SM64 dans Claude Code.
  Usage:
      powershell -ExecutionPolicy Bypass -File .\register_mcp.ps1
#>
$here = Split-Path -Parent $PSCommandPath
$serverPs1 = (Resolve-Path (Join-Path $here 'sm64_mcp_server.ps1')).Path

Write-Host "Serveur MCP détecté : $serverPs1" -ForegroundColor Cyan

# Vérifier si la CLI claude est installée
$claudeCmd = Get-Command 'claude' -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Host "Enregistrement via 'claude mcp add sm64'..." -ForegroundColor Yellow
    & claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "$serverPs1"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Serveur MCP 'sm64' enregistré avec succès dans Claude !" -ForegroundColor Green
    }
} else {
    Write-Host "CLI 'claude' non trouvée dans le PATH." -ForegroundColor Yellow
}

# Générer le snippet JSON
$jsonSnippet = [ordered]@{
    mcpServers = [ordered]@{
        sm64 = [ordered]@{
            command = "powershell"
            args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $serverPs1)
        }
    }
} | ConvertTo-Json -Depth 5

Write-Host "`nConfiguration à copier dans votre .mcp.json si nécessaire :" -ForegroundColor Cyan
Write-Host $jsonSnippet
