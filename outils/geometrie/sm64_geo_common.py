import os

def get_decomp_dir():
    """Dynamically locates the SM64 decompiled source root directory."""
    env_dir = os.environ.get("SM64_DECOMP")
    if env_dir and os.path.isdir(env_dir):
        return env_dir
    
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        # Relative siblings (e.g. if cloned alongside sm64-decomp or moteur)
        os.path.abspath(os.path.join(here, "..", "..", "..", "sm64-decomp")),
        os.path.abspath(os.path.join(here, "..", "..", "..", "moteur", "deps", "sm64-decomp")),
        os.path.abspath(os.path.join(here, "..", "..", "..", "tas-lab", "HackerSM64")),
        # Common machine paths
        r"D:\moteur\deps\sm64-decomp",
        r"D:\tas-lab\HackerSM64",
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "levels")):
            return c
    return candidates[0]
