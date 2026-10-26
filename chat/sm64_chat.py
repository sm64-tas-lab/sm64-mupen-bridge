#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CLI INTERACTIF pour discuter avec le modele local (Qwen3-Coder via llama-server) qui pilote mupen (SM64)
via le serveur MCP. Tu tapes des taches en langage naturel, le modele repond et utilise les outils.
Fiable : expose directement les bons outils (pas de ToolSearch / detecteur de boucle comme Qwen Code).

Pre-requis : llama-server allume ('lancer-Coder.bat').
Lancer     : python sm64_chat.py     (ou double-clic sur CHAT-sm64.bat)
Commandes  : /reset (efface la conversation)   /quit (quitter)
"""
import json, os, subprocess, urllib.request, sys
try:
    sys.stdout.reconfigure(encoding="utf-8")   # accents francais lisibles dans le terminal
    sys.stdin.reconfigure(encoding="utf-8")
except Exception:
    pass

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
LLM_URL = os.environ.get("SM64_LLM_URL", "http://127.0.0.1:8080/v1/chat/completions")
PS1 = os.environ.get("SM64_MCP_SERVER", PROJECT + r"\tas\control\mcp\sm64_mcp_server.ps1")
SAVEST  = os.environ.get("SM64_SAVESTATE", os.path.join(PROJECT, "30th Anniversary Task 4.st"))
# Jeu d'outils HAUT NIVEAU expose au modele (lean = le modele ne se perd pas)
KEEP = {"start_mupen", "scan", "list_chests", "goto", "open_chest", "collect", "grab_star", "move", "get_state", "export_run", "reset_run", "stop_mupen"}
MAX_TOOL_STEPS = 20   # garde-fou anti-boucle par tour

def llama_up():
    try: urllib.request.urlopen(LLM_URL.replace("/chat/completions","/models"), timeout=4); return True
    except Exception: return False

class MCP:
    def __init__(s):
        s.p=subprocess.Popen(["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File",PS1],
                             stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                             cwd=PROJECT,text=True,bufsize=1,encoding="utf-8"); s.id=0
    def rpc(s,m,pa=None):
        s.id+=1; j=s.id
        s.p.stdin.write(json.dumps({"jsonrpc":"2.0","id":j,"method":m,"params":pa or {}})+"\n"); s.p.stdin.flush()
        while True:
            l=s.p.stdout.readline()
            if not l: return None
            l=l.strip()
            if not l: continue
            try: o=json.loads(l)
            except: continue
            if o.get("id")==j: return o
    def init(s):
        s.rpc("initialize",{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"chat","version":"1"}})
        s.p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); s.p.stdin.flush()
    def tools(s): return s.rpc("tools/list")["result"]["tools"]
    def call(s,n,a=None):
        r=s.rpc("tools/call",{"name":n,"arguments":a or {}}); res=r.get("result",{}) if r else {}
        return "".join(x.get("text","") for x in res.get("content",[]) if x.get("type")=="text")
    def close(s):
        try: s.p.terminate()
        except: pass

def oai(mt):
    return [{"type":"function","function":{"name":t["name"],"description":t.get("description",""),
             "parameters":t.get("inputSchema",{"type":"object","properties":{}})}} for t in mt if t["name"] in KEEP]
def chat(msgs, tools):
    body=json.dumps({"model":"local","messages":msgs,"tools":tools,"tool_choice":"auto",
                     "temperature":0.3,"max_tokens":1500}).encode()
    req=urllib.request.Request(LLM_URL, data=body, headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=600) as r: d=json.loads(r.read())
    return d["choices"][0]["message"]

import os
# Le guide des outils est lu depuis OUTILS_SM64.md (a cote de ce script) : edite ce .md pour changer
# les instructions du modele, sans toucher au code.
_GUIDE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "OUTILS_SM64.md")
try:
    with open(_GUIDE, encoding="utf-8") as _f:
        SYSTEM = _f.read().rstrip() + f"\n\n(Savestate Task 4 par defaut : {SAVEST})"
    print(f"[guide] chargé depuis {_GUIDE}")
except Exception as _e:
    SYSTEM = ("Tu pilotes Mario (SM64) via les outils 'sm64'. Appelle start_mupen d'abord (savestate absolu), "
              "puis scan(filter='...') pour trouver une cible, collect(name='...') pour la ramasser (verifie "
              "collected=true), goto(x,z) pour te deplacer. Reponds en francais, un outil a la fois.")
    print(f"[guide] OUTILS_SM64.md introuvable ({_e}) — prompt par defaut")

def main():
    if not llama_up():
        print("!! llama-server eteint (127.0.0.1:8080). Lance 'lancer-Coder.bat', attends 'model loaded', puis relance.")
        sys.exit(1)
    mcp=MCP(); mcp.init(); tools=oai(mcp.tools())
    print("="*64)
    print("  CHAT SM64  —  discute avec le modele, il pilote mupen via le MCP")
    print("  Outils:", ", ".join(sorted(t['function']['name'] for t in tools)))
    print("  Commandes: /reset  /quit")
    print("  Exemples: 'demarre la task 4 et va au coffre 1' | 'scan autour de mario' | 'ouvre le coffre 2 en long jumps'")
    print("="*64)
    msgs=[{"role":"system","content":SYSTEM}]
    try:
        while True:
            try: user=input("\nToi> ").strip()
            except EOFError: break
            if not user: continue
            if user in ("/quit","/exit","quit","exit"): break
            if user=="/reset": msgs=[{"role":"system","content":SYSTEM}]; print("(conversation reinitialisee)"); continue
            msgs.append({"role":"user","content":user})
            seen_calls={}   # anti-boucle: compte les appels (outil+args) identiques dans CE tour
            for _ in range(MAX_TOOL_STEPS):
                msg=chat(msgs,tools); content=msg.get("content") or ""; tcs=msg.get("tool_calls") or []
                if content.strip(): print("\nModele>", content.strip())
                if not tcs:
                    msgs.append({"role":"assistant","content":content}); break
                msgs.append({"role":"assistant","content":content,"tool_calls":tcs})
                for tc in tcs:
                    fn=tc["function"]; name=fn["name"]
                    try: args=json.loads(fn["arguments"]) if isinstance(fn["arguments"],str) else fn["arguments"]
                    except: args=fn["arguments"] or {}
                    print(f"   [outil] {name}({json.dumps(args, ensure_ascii=False)[:100]})")
                    sig=name+"|\"+json.dumps(args,sort_keys=True,ensure_ascii=False)
                    seen_calls[sig]=seen_calls.get(sig,0)+1
                    # anti-boucle: un outil READ-ONLY rappele avec les MEMES args donne un resultat IDENTIQUE
                    # (Mario n'a pas bouge). On court-circuite au 2e (read-only) / 3e (tout outil) appel identique
                    # et on POUSSE le modele a changer d'approche ou a repondre, au lieu de tourner en rond.
                    ro = name in ("scan","get_state","list_chests")
                    if (ro and seen_calls[sig]>=2) or seen_calls[sig]>=3:
                        res=json.dumps({"stop_repeat":True,"message":(
                            f"Tu as DEJA appele {name} avec ces memes arguments ({seen_calls[sig]}x) et le resultat est "
                            "IDENTIQUE (rien n'a change). ARRETE de repeter le meme outil. Deux options seulement: "
                            "(1) CHANGE d'approche (near_x/near_z precis, goto, grab_star, move), ou "
                            "(2) REPONDS a l'utilisateur (dis ce que tu as trouve, ou honnetement que la cible est "
                            "inatteignable/bloquee). Ne rappelle PAS le meme outil avec les memes arguments.")},ensure_ascii=False)
                        print(f"           -> [garde-fou anti-boucle: appel identique #{seen_calls[sig]} court-circuite]")
                    else:
                        res=mcp.call(name,args)
                        print(f"           -> {res[:220]}")
                    msgs.append({"role":"tool","tool_call_id":tc.get("id",name),"content":res})
            else:
                print("(garde-fou: trop d'appels d'outils dans ce tour, je rends la main)")
    finally:
        try: mcp.call("stop_mupen")
        except: pass
        mcp.close()
        print("\nA bientot.")

if __name__ == "__main__":
    main()
