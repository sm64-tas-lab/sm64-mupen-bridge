import re,glob
for f in sorted(glob.glob(r"G:/tas-lab/repos/sm64-decomp/levels/castle_inside/areas/*/collision.inc.c")):
    src=open(f).read()
    V=[tuple(map(int,m)) for m in re.findall(r"COL_VERTEX\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)",src)]
    cur=None
    for line in src.splitlines():
        m=re.search(r"COL_TRI_INIT\((\w+)",line)
        if m: cur=m.group(1);continue
        m=re.search(r"COL_TRI(?:_SPECIAL)?\((\d+),\s*(\d+),\s*(\d+)",line)
        if m and cur and "WARP_D" in cur:
            p=[V[int(i)] for i in m.groups()]
            print(f.split("areas")[1][:3],cur,p)
