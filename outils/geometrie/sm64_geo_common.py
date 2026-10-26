import os

def get_decomp_dir():
    """Dynamically locates the SM64 decompiled source root directory."""
    env_dir = os.environ.get("SM64_DECOMP")
    if env_dir and os.path.isdir(env_dir):
        return env_dir
    
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    try:
        import json
        cfg = json.load(open(os.path.join(root, "config.json"), encoding="utf-8")).get("decomp")
    except (OSError, ValueError):
        cfg = None
    candidates = [c for c in [cfg] if c] + [
        # Relative siblings (e.g. cloned beside sm64-tas-cpu, whose INSTALL.bat fetches the decomp)
        os.path.abspath(os.path.join(root, "..", "sm64-tas-cpu", "deps", "sm64-decomp")),
        os.path.abspath(os.path.join(root, "..", "sm64-decomp")),
        os.path.abspath(os.path.join(root, "..", "moteur", "deps", "sm64-decomp")),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "levels")):
            return c
    return candidates[0]
