<#
  register_mcp.ps1 — Automatically registers the SM64 MCP server in Claude Code.
  Usage:
      powershell -ExecutionPolicy Bypass -File .\register_mcp.ps1
#>
$here = Split-Path -Parent $PSCommandPath
$serverPs1 = (Resolve-Path (Join-Path $here 'sm64_mcp_server.ps1')).Path

Write-Host "SM64 MCP server found: $serverPs1" -ForegroundColor Cyan

# Check whether the claude CLI is installed
$claudeCmd = Get-Command 'claude' -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Host "Registering via 'claude mcp add sm64'..." -ForegroundColor Yellow
    & claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "$serverPs1"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "MCP server 'sm64' registered successfully in Claude!" -ForegroundColor Green
    }
} else {
    Write-Host "'claude' CLI not found in PATH." -ForegroundColor Yellow
}

# Generate the JSON snippet
$jsonSnippet = [ordered]@{
    mcpServers = [ordered]@{
        sm64 = [ordered]@{
            command = "powershell"
            args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $serverPs1)
        }
    }
} | ConvertTo-Json -Depth 5

Write-Host "`nConfiguration to copy into your .mcp.json if needed:" -ForegroundColor Cyan
Write-Host $jsonSnippet
