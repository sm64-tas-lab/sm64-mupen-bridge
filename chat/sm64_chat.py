#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
INTERACTIVE CLI to chat with the local model (Qwen3-Coder via llama-server) that drives mupen (SM64)
through the MCP server. You type tasks in natural language, the model replies and uses the tools.
Reliable: it exposes the right tools directly (no ToolSearch / loop detector like Qwen Code).

Prerequisite: llama-server running ('lancer-GLM.bat').
Run:          python sm64_chat.py     (or double-click CHAT-sm64.bat)
Commands:     /reset (clear the conversation)   /quit (quit)
"""
import json, os, subprocess, urllib.request, sys
try:
    sys.stdout.reconfigure(encoding="utf-8")   # so accented characters display correctly in the terminal
    sys.stdin.reconfigure(encoding="utf-8")
except Exception:
    pass

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
LLM_URL = "http://127.0.0.1:8080/v1/chat/completions"
PS1     = PROJECT + r"\tas\control\mcp\sm64_mcp_server.ps1"
SAVEST  = os.environ.get("SM64_SAVESTATE", os.path.join(PROJECT, "30th Anniversary Task 4.st"))
# HIGH-LEVEL tool set exposed to the model (lean = the model does not get lost)
KEEP = {"start_mupen", "scan", "list_chests", "goto", "open_chest", "collect", "grab_star", "move", "get_state", "export_run", "reset_run", "stop_mupen"}
MAX_TOOL_STEPS = 20   # anti-loop guard per turn

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
# The tool guide is read from OUTILS_SM64.md (next to this script): edit that .md to change
# the model's instructions, without touching the code.
_GUIDE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "OUTILS_SM64.md")
try:
    with open(_GUIDE, encoding="utf-8") as _f:
        SYSTEM = _f.read().rstrip() + f"\n\n(Default Task 4 savestate: {SAVEST})"
    print(f"[guide] loaded from {_GUIDE}")
except Exception as _e:
    SYSTEM = ("You drive Mario (SM64) through the 'sm64' tools. Call start_mupen first (absolute savestate), "
              "then scan(filter='...') to find a target, collect(name='...') to pick it up (check "
              "collected=true), goto(x,z) to move. Reply in French, one tool at a time.")
    print(f"[guide] OUTILS_SM64.md not found ({_e}) — default prompt")

def main():
    if not llama_up():
        print("!! llama-server is not running (127.0.0.1:8080). Start 'lancer-GLM.bat', wait for 'model loaded', then run again.")
        sys.exit(1)
    mcp=MCP(); mcp.init(); tools=oai(mcp.tools())
    print("="*64)
    print("  CHAT SM64  —  chat with the model, it drives mupen via the MCP")
    print("  Outils:", ", ".join(sorted(t['function']['name'] for t in tools)))
    print("  Commands: /reset  /quit")
    print("  Examples: 'start task 4 and go to chest 1' | 'scan around mario' | 'open chest 2 with long jumps'")
    print("="*64)
    msgs=[{"role":"system","content":SYSTEM}]
    try:
        while True:
            try: user=input("\nYou> ").strip()
            except EOFError: break
            if not user: continue
            if user in ("/quit","/exit","quit","exit"): break
            if user=="/reset": msgs=[{"role":"system","content":SYSTEM}]; print("(conversation reset)"); continue
            msgs.append({"role":"user","content":user})
            seen_calls={}   # anti-loop: counts identical calls (tool+args) in THIS turn
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
                    print(f"   [tool] {name}({json.dumps(args, ensure_ascii=False)[:100]})")
                    sig=name+"|"+json.dumps(args,sort_keys=True,ensure_ascii=False)
                    seen_calls[sig]=seen_calls.get(sig,0)+1
                    # anti-loop: a READ-ONLY tool called again with the SAME args returns an IDENTICAL result
                    # (Mario did not move). We short-circuit on the 2nd (read-only) / 3rd (any tool) identical call
                    # and PUSH the model to change approach or reply, instead of going round in circles.
                    ro = name in ("scan","get_state","list_chests")
                    if (ro and seen_calls[sig]>=2) or seen_calls[sig]>=3:
                        res=json.dumps({"stop_repeat":True,"message":(
                            f"You ALREADY called {name} with these same arguments ({seen_calls[sig]}x) and the result is "
                            "IDENTICAL (nothing changed). STOP repeating the same tool. Only two options: "
                            "(1) CHANGE approach (precise near_x/near_z, goto, grab_star, move), or "
                            "(2) REPLY to the user (say what you found, or honestly that the target is "
                            "unreachable/blocked). Do NOT call the same tool with the same arguments again.")},ensure_ascii=False)
                        print(f"           -> [anti-loop guard: identical call #{seen_calls[sig]} short-circuited]")
                    else:
                        res=mcp.call(name,args)
                        print(f"           -> {res[:220]}")
                    msgs.append({"role":"tool","tool_call_id":tc.get("id",name),"content":res})
            else:
                print("(guard: too many tool calls in this turn, handing control back)")
    finally:
        try: mcp.call("stop_mupen")
        except: pass
        mcp.close()
        print("\nSee you soon.")

if __name__ == "__main__":
    main()
