import re
src=open(r"G:/tas-lab/repos/sm64-decomp/levels/castle_inside/areas/1/collision.inc.c").read()
V=[tuple(map(int,m)) for m in re.findall(r"COL_VERTEX\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)",src)]
cur=None
for line in src.splitlines():
    m=re.search(r"COL_TRI_INIT\((\w+)",line)
    if m: cur=m.group(1);continue
    m=re.search(r"COL_TRI(?:_SPECIAL)?\((\d+),\s*(\d+),\s*(\d+)",line)
    if not(m and cur): continue
    a,b,c=[V[int(i)] for i in m.groups()]
    ux,uy,uz=[b[i]-a[i] for i in range(3)];vx,vy,vz=[c[i]-a[i] for i in range(3)]
    nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
    L=(nx*nx+ny*ny+nz*nz)**.5
    if L==0 or abs(ny/L)>0.1: continue
    xs=[p[0] for p in (a,b,c)];ys=[p[1] for p in (a,b,c)];zs=[p[2] for p in (a,b,c)]
    if max(ys)>179 and min(ys)<260 and max(xs)>350 and min(xs)<1150 and max(zs)>-400 and min(zs)<450:
        print(cur[8:],(min(xs),max(xs)),(min(ys),max(ys)),(min(zs),max(zs)),"n=(%.2f,%.2f)"%(nx/L,nz/L))
