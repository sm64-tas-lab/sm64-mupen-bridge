import re
src=open(r"G:/tas-lab/repos/sm64-decomp/levels/castle_inside/areas/1/collision.inc.c").read()
V=[tuple(map(int,m)) for m in re.findall(r"COL_VERTEX\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)",src)]
tris=[];cur=None
for line in src.splitlines():
    m=re.search(r"COL_TRI_INIT\((\w+)",line)
    if m: cur=m.group(1);continue
    m=re.search(r"COL_TRI(?:_SPECIAL)?\((\d+),\s*(\d+),\s*(\d+)",line)
    if m and cur: tris.append((cur,[V[int(i)] for i in m.groups()]))
import collections
floors=collections.defaultdict(list)
for t,(a,b,c) in tris:
    ux,uy,uz=[b[i]-a[i] for i in range(3)];vx,vy,vz=[c[i]-a[i] for i in range(3)]
    nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
    L=(nx*nx+ny*ny+nz*nz)**.5
    if L==0: continue
    if ny/L>0.99 and all(1000<p[0]<5000 and -2500<p[2]<2500 for p in (a,b,c)):
        y=a[1]
        floors[y].append((t,(a,b,c)))
for y in sorted(floors):
    xs=[p[0] for _,tr in floors[y] for p in tr]; zs=[p[2] for _,tr in floors[y] for p in tr]
    print(y,len(floors[y]),"x",min(xs),max(xs),"z",min(zs),max(zs),set(t for t,_ in floors[y]))
print("----")
for y in (26,51,77,102,179,205):
    for t,tr in floors[y]:
        print(y,tr)
