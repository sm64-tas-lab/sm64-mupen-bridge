import os
from sm64_geo_common import get_decomp_dir
DECOMP = get_decomp_dir()
import re,math
src=open(os.path.join(DECOMP, "levels/bob/areas/1/collision.inc.c")).read()
V=[tuple(map(int,m)) for m in re.findall(r"COL_VERTEX\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)",src)]
cur=None; out=[]
for line in src.splitlines():
    m=re.search(r"COL_TRI_INIT\((\w+)",line)
    if m: cur=m.group(1);continue
    m=re.search(r"COL_TRI(?:_SPECIAL)?\((\d+),\s*(\d+),\s*(\d+)",line)
    if not(m and cur): continue
    a,b,c=[V[int(i)] for i in m.groups()]
    xs=[p[0] for p in (a,b,c)];ys=[p[1] for p in (a,b,c)];zs=[p[2] for p in (a,b,c)]
    if max(xs)<700 or min(xs)>2400 or max(zs)<-500 or min(zs)>1300 or max(ys)<600 or min(ys)>1500: continue
    ux,uy,uz=[b[i]-a[i] for i in range(3)];vx,vy,vz=[c[i]-a[i] for i in range(3)]
    nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx; L=math.sqrt(nx*nx+ny*ny+nz*nz) or 1
    kind='SOL' if ny/L>0.1 else ('PLAF' if ny/L<-0.1 else 'MUR')
    out.append((kind,cur.replace('SURFACE_',''),(a,b,c),(round(nx/L,2),round(ny/L,2),round(nz/L,2))))
for o in sorted(out,key=lambda o:(o[0],min(p[1] for p in o[2]))): print(o)
