<#
  install.ps1 - set sm64-mupen-bridge up for an AI (INSTALL.bat runs this).

  1. Mupen64-rr-lua: found on this PC, or the official release downloaded into .\bin (1.5.0-8 or newer has every
     Lua call the bridge uses);
  2. your own Super Mario 64 (USA) ROM (only its path is kept, in config.json);
  3. STROOP (optional);
  4. the MCP server 'sm64' for your AI: Claude Code (and its skill), Gemini CLI when installed, mcp.json for others;
  5. optionally sm64-tas-cpu beside this folder: the same game headless (no emulator, ~40,000 frames/s), MCP 'sm64-headless'.

      powershell -ExecutionPolicy Bypass -File install.ps1 [-Rom ROM] [-Mupen EXE] [-Stroop EXE] [-Yes] [-NoHeadless]
#>
param([string]$Rom, [string]$Mupen, [string]$Stroop, [switch]$Yes, [switch]$NoHeadless, [switch]$NoRegister)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$CfgPath = Join-Path $Root 'config.json'
$Server = Join-Path $Root 'tas\control\mcp\sm64_mcp_server.ps1'
$MupenRepo = 'mupen64/mupen64-rr-lua'
$HeadlessGit = 'https://github.com/sm64-tas-lab/sm64-tas-cpu.git'
$RomMd5 = '20b854b239203baf6c961b850a4a51a2'

function Ask([string]$q, [string]$default) {
    if ($Yes) { return $default }
    $hint = if ($default) { " [$default]" } else { '' }
    $a = (Read-Host "$q$hint").Trim().Trim('"')
    if ($a) { return $a } else { return $default }
}

$cfg = [ordered]@{}
if (Test-Path $CfgPath) {
    try { (Get-Content $CfgPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch { }
}

# ---- 1. Mupen ----------------------------------------------------------------------------------------------------
Write-Host '[1/5] Mupen64-rr-lua' -ForegroundColor Cyan
Import-Module (Join-Path $Root 'tas\control\SM64Ctl.psm1') -Force -WarningAction SilentlyContinue
$found = if ($Mupen) { $Mupen } elseif ($cfg.mupen) { $cfg.mupen } else { (Get-SM64Paths).MupenExe }
if (-not ($found -and (Test-Path $found))) {
    $a = Ask '  mupen64.exe path, or Enter to download the official release into .\bin' ''
    if ($a) { $found = $a }
    else {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$MupenRepo/releases/latest" -Headers @{ 'User-Agent' = 'sm64-mupen-bridge' }
        $asset = $rel.assets | Where-Object { $_.name -like '*windows-x64*.zip' } | Select-Object -First 1
        if (-not $asset) { throw 'no Windows x64 build in the latest Mupen64-rr-lua release' }
        $zip = Join-Path $env:TEMP $asset.name
        Write-Host "  downloading Mupen64-rr-lua $($rel.tag_name)..."
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
        $bin = Join-Path $Root 'bin'
        Expand-Archive $zip -DestinationPath $bin -Force
        Remove-Item $zip
        $found = (Get-ChildItem $bin -Recurse -Filter 'mupen64.exe' | Select-Object -First 1).FullName
    }
}
if (-not ($found -and (Test-Path $found))) { throw "Mupen64 not found ($found): run INSTALL.bat again" }
$cfg.mupen = (Resolve-Path $found).Path
Write-Host "  $($cfg.mupen)"

# ---- 2. the ROM --------------------------------------------------------------------------------------------------
Write-Host '[2/5] your Super Mario 64 (USA) ROM (never copied, only its path is kept)' -ForegroundColor Cyan
$guess = if ($Rom) { $Rom } elseif ($cfg.rom_us) { $cfg.rom_us } else { $p = (Get-SM64Paths).DefaultRom; if (Test-Path $p) { $p } else { '' } }
$r = if ($Rom) { $Rom } else { Ask '  ROM path (.z64)' $guess }
if (-not ($r -and (Test-Path $r))) { throw 'the US ROM is needed: run INSTALL.bat again with its path' }
$md5 = (Get-FileHash $r -Algorithm MD5).Hash.ToLower()
if ($md5 -ne $RomMd5) { Write-Host "  warning: this is not the original US .z64 (md5 $md5); Mupen may still run it" -ForegroundColor Yellow }
$cfg.rom_us = (Resolve-Path $r).Path

# ---- 3. STROOP ---------------------------------------------------------------------------------------------------
Write-Host '[3/5] STROOP (optional: its variables, read without its window)' -ForegroundColor Cyan
$s = if ($Stroop) { $Stroop } elseif ($cfg.stroop) { $cfg.stroop } else { Ask '  STROOP.exe path (Enter to skip)' '' }
if ($s -and (Test-Path $s)) { $cfg.stroop = (Resolve-Path $s).Path }
$cfg | ConvertTo-Json | Set-Content $CfgPath -Encoding UTF8

# ---- 4. the MCP server -------------------------------------------------------------------------------------------
function Register-Mcp([string]$name, [string]$command, [string[]]$arguments, [string]$skill) {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if ($claude) {
        & claude mcp remove --scope user $name *> $null
        & claude mcp add --scope user $name -- $command @arguments
        Write-Host "  Claude Code: $name added"
        if ($skill -and (Test-Path $skill)) {
            $dst = Join-Path $HOME ".claude\skills\$name"
            New-Item -ItemType Directory -Force $dst | Out-Null
            Copy-Item $skill (Join-Path $dst 'SKILL.md') -Force
            Write-Host "  Claude Code skill: $dst"
        }
    } else {
        Write-Host "  Claude Code not found: later run  claude mcp add $name -- $command $($arguments -join ' ')"
    }
    $gem = Join-Path $HOME '.gemini\settings.json'
    if ((Get-Command gemini -ErrorAction SilentlyContinue) -or (Test-Path $gem)) {
        $g = if (Test-Path $gem) { Get-Content $gem -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        if (-not $g.PSObject.Properties['mcpServers']) { $g | Add-Member mcpServers ([pscustomobject]@{}) }
        $g.mcpServers | Add-Member $name ([pscustomobject]@{ command = $command; args = $arguments }) -Force
        New-Item -ItemType Directory -Force (Split-Path $gem) | Out-Null
        $g | ConvertTo-Json -Depth 10 | Set-Content $gem -Encoding UTF8
        Write-Host "  Gemini CLI: $name added to $gem"
    }
}
Write-Host '[4/5] the MCP server sm64 (Mupen driven live) for your AI' -ForegroundColor Cyan
$psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Server)
[ordered]@{ mcpServers = [ordered]@{ sm64 = [ordered]@{ command = 'powershell'; args = $psArgs } } } |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Root 'mcp.json') -Encoding UTF8
Write-Host "  mcp.json written (for any MCP client)"
if (-not $NoRegister) { Register-Mcp 'sm64' 'powershell' $psArgs '' }

# ---- 5. sm64-tas-cpu (headless) ----------------------------------------------------------------------------------
Write-Host '[5/5] sm64-tas-cpu: the same game headless, no emulator (optional)' -ForegroundColor Cyan
if (-not $NoHeadless) {
    $hl = Join-Path (Split-Path -Parent $Root) 'sm64-tas-cpu'
    $go = if (Test-Path $hl) { 'y' } else { Ask '  install it beside this folder? (y/n)' 'y' }
    if ($go -like 'y*') {
        if (-not (Test-Path $hl)) {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is needed to fetch sm64-tas-cpu (https://git-scm.com)' }
            & git clone --depth 1 --branch public $HeadlessGit $hl
            if ($LASTEXITCODE) { & git clone --depth 1 $HeadlessGit $hl }
        }
        $py = $null
        foreach ($c in @(@('py', '-3'), @('python'))) {
            if (Get-Command $c[0] -ErrorAction SilentlyContinue) {
                & $c[0] @($c[1..9]) -c 'import sys; assert sys.version_info >= (3, 9) and sys.maxsize > 2**32' 2>$null
                if ($LASTEXITCODE -eq 0) { $py = $c; break }
            }
        }
        if (-not $py) { Write-Host '  Python 3.9+ 64-bit is needed for it: https://www.python.org/downloads/ then run its INSTALL.bat' -ForegroundColor Yellow }
        else {
            $extra = @('--rom-us', $cfg.rom_us, '--mupen', $cfg.mupen, '--yes')
            if ($NoRegister) { $extra += '--no-register' }
            & $py[0] @($py[1..9]) (Join-Path $hl 'install.py') @extra
        }
    }
}
Write-Host "`nDone. Ask your AI, e.g.: ""start Mupen with the sm64 tools from my savestate C:\...\my.st and read Mario's state""." -ForegroundColor Green
