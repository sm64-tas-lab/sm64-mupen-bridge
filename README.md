# sm64-mupen-bridge

Control plane pour **Mupen64-rr-lua** et **Super Mario 64** : bridge Lua file-IPC, SDK PowerShell (`SM64Ctl`), serveur MCP stdio et boîte à outils TAS.

Permet de piloter Mupen64 programmatiquement (IA / scripts) sans intervention manuelle sur l'interface graphique : injection d'inputs, pas-à-pas déterministe, lecture/écriture RAM N64, savestates, export de films `.m64`, calcul des variables STROOP.

---

## Architecture

```text
sm64-mupen-bridge/
├── tas/
│   ├── control/
│   │   ├── mupen/
│   │   │   └── bridge.lua           # Serveur IPC s'exécutant dans Mupen64
│   │   ├── mcp/
│   │   │   ├── sm64_mcp_server.ps1  # Serveur MCP stdio JSON-RPC
│   │   │   └── mcp.json             # Configuration d'enregistrement MCP
│   │   ├── SM64Ctl.psm1             # Module PowerShell SDK (commandes haut niveau)
│   │   ├── m64_header_template.bin  # Template d'en-tête pour export .m64
│   │   ├── USER_GUIDE.md            # Guide d'utilisation détaillé
│   │   ├── HOW_IT_WORKS.md          # Architecture complète et protocole
│   │   └── README.md
│   └── tas_lib/                     # Scripts TAS, recherche d'inputs, workers parallèles
├── outils/
│   ├── geometrie/                   # Outils géométrie / collision SM64
│   └── rag/                         # Scripts de requêtes RAG
├── chat/                            # Interface de chat LLM local pour piloter Mupen
└── README.md
```

---

## Démarrage rapide

### 1. Via le SDK PowerShell (`SM64Ctl.psm1`)

Dans PowerShell (Windows PowerShell 5.1 ou PowerShell 7+) :

```powershell
Import-Module .\tas\control\SM64Ctl.psm1 -Force

# Vérifier les chemins détectés (Mupen, ROM, STROOP)
Get-SM64Paths

# Lancer Mupen avec la ROM et le bridge
$s = Start-Mupen

# Récupérer l'état de Mario (pos, vitesse, action, angle...)
Get-MarioState $s

# Avancer de 30 frames avec le stick vers le haut et le bouton A
Step-Frames $s -Frames 30 -Buttons @{ A = $true; Y = 127 }

# Sauvegarder et restaurer un checkpoint en mémoire vive
Save-MemState $s -Slot 1
Load-MemState $s -Slot 1

# Fermer proprement l'émulateur
Stop-Mupen $s
```

### 2. Variables d'environnement optionnelles

Si tes fichiers ne sont pas aux emplacements par défaut :
- `MUPEN_EXE` : chemin absolu vers `mupen64.exe` (ex: `D:\mupen\mupen64-rr-lua\build\out\mupen64.exe`)
- `SM64_ROM` : chemin vers la ROM Super Mario 64 (ex: `Super Mario 64 (USA).z64`)

### 3. Enregistrement MCP pour Claude / Agents IA

Enregistrement automatique en une commande :

```powershell
powershell -ExecutionPolicy Bypass -File .\tas\control\mcp\register_mcp.ps1
```

Ou manuellement via Claude CLI :

```bash
claude mcp add sm64 -- powershell -NoProfile -ExecutionPolicy Bypass -File "<chemin_du_depot>\tas\control\mcp\sm64_mcp_server.ps1"
```

Outils exposés : `start_mupen`, `stop_mupen`, `get_state`, `step_frames`, `read_mem`, `write_mem`, `save_memstate`, `load_memstate`, `stroop_vars`, `invoke_action`, `screenshot`.

---

## Documentation détaillée

- [tas/control/USER_GUIDE.md](tas/control/USER_GUIDE.md) : Guide pas-à-pas et recettes de code.
- [tas/control/HOW_IT_WORKS.md](tas/control/HOW_IT_WORKS.md) : Explication du protocole JSONL, hooks Lua et contournements techniques (pause inversée, NoVideo/NoAudio stubs).
