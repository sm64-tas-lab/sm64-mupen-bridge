# Configuration Portable - sm64-mupen-bridge

Ce document explique comment configurer le projet pour différents PC sans modifier le code.

## Variables d'environnement

Toutes les variables d'environnement sont optionnelles. Si non définies, le projet utilise des valeurs par défaut.

### Variables pour Python (chat/sm64_chat.py)

| Variable | Description | Exemple |
|----------|-------------|---------|
| `SM64_LLM_URL` | URL du serveur LLM local | `http://127.0.0.1:8080/v1/chat/completions` |
| `SM64_MCP_SERVER` | Chemin vers sm64_mcp_server.ps1 | `C:\sm64-mupen-bridge\tas\control\mcp\sm64_mcp_server.ps1` |
| `SM64_SAVESTATE` | Chemin vers le savestate par défaut | `C:\sm64-mupen-bridge\30th Anniversary Task 4.st` |

### Variables pour PowerShell (SM64Ctl.psm1)

| Variable | Description | Exemple |
|----------|-------------|---------|
| `MUPEN_EXE` | Chemin absolu vers mupen64.exe | `D:\mupen\build\out\mupen64.exe` |
| `MUPEN_EXE_DIR` | Dossier contenant mupen64.exe | `D:\mupen\build\out` |
| `MUPEN_EXE_SEARCH_PATHS` | Dossiers de recherche (sémécolones) | `D:\mupen;E:\emulators\mupen` |
| `SM64_ROM` | Chemin absolu vers la ROM | `D:\roms\Super Mario 64 (USA).z64` |
| `SM64_ROM_DIR` | Dossier contenant la ROM | `D:\roms` |
| `SM64_ROM_PATHS` | Chemins de ROM (sémécolones) | `D:\roms;E:\games\sm64` |
| `SM64_DEFAULT_SAVESTATE` | Savestate par défaut | `C:\sm64-mupen-bridge\task3.st` |
| `STROOP_EXE` | Chemin absolu vers STROOP.exe | `D:\STROOP\STROOP.exe` |
| `STROOP_DIR` | Dossier STROOP (contenant STROOP.exe) | `D:\STROOP` |
| `STROOP_EXE_SEARCH_PATHS` | Dossiers de recherche STROOP | `D:\STROOP;C:\Program Files\STROOP` |
| `SM64_SIM_ROOT` | Racine du projet aitest2-improved | `D:\aitest2-improved` |
| `AITEST2_ROOT` | Alternative pour aitest2-improved | `E:\dev\aitest2-improved` |
| `SM64_DECOMP` | Racine du décompilé SM64 (outils géométrie) | `D:\sm64-decomp` |

## Configuration MCP (mcp.json)

Le fichier `tas/control/mcp/mcp.json` contient un placeholder `<CHEMIN_VERS_LE_DEPOT>` qui doit être remplacé par le chemin absolu de votre dépôt.

### Méthodes de configuration :

1. **Automatique** : Exécutez le script `register_mcp.ps1` (si disponible)
2. **Manuel** : Remplacez le placeholder dans mcp.json
3. **Variable d'environnement** : Utilisez la variable `SM64_MCP_SERVER_PATH`

## Exemple de configuration Windows

```powershell
# Dans votre profil PowerShell ($PROFILE) ou dans un script de setup :

$env:MUPEN_EXE = "D:\Emulator\mupen64-rr-lua\build\out\mupen64.exe"
$env:SM64_ROM = "D:\ROMs\Super Mario 64 (USA).z64"
$env:STROOP_EXE = "D:\STROOP\STROOP.exe"
$env:SM64_SIM_ROOT = "D:\Dev\aitest2-improved"
$env:SM64_DECOMP = "D:\SM64\sm64-decomp"
$env:SM64_DEFAULT_SAVESTATE = "D:\SM64\savestates\Task3.st"
```

## Exemple de configuration Linux/macOS

```bash
# Dans votre ~/.bashrc, ~/.zshrc ou équivalent :

export MUPEN_EXE="$HOME/emulators/mupen64/build/mupen64"
export SM64_ROM="$HOME/roms/sm64-us.z64"
export SM64_DECOMP="$HOME/dev/sm64-decomp"
export SM64_SIM_ROOT="$HOME/dev/aitest2-improved"
```

## Vérification de la configuration

Utilisez les commandes suivantes pour vérifier que tout est détecté correctement :

### PowerShell
```powershell
Import-Module .\tas\control\SM64Ctl.psm1 -Force
Get-SM64Paths
```

### Python
```bash
python chat/sm64_chat.py
```

## Migration depuis une configuration existante

Si vous aviez auparavant modifié des fichiers directement, vous pouvez maintenant :

1. Identifier les chemins personnalisés que vous utilisiez
2. Définir les variables d'environnement correspondantes
3. Restaurer les fichiers originaux (si modifiés)

Les variables d'environnement remplacent les chemins codés en dur sans nécessiter de modification du code.
