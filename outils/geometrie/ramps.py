import os
from sm64_geo_common import get_decomp_dir
DECOMP = get_decomp_dir()
import re,math
src=open(os.path.join(DECOMP, "levels/bob/areas/1/collision.inc.c")).read()
V=[tuple(map(int,m)) for m in re.findall(r"COL_VERTEX\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)",src)]
cur=None
for line in src.splitlines():
    m=re.search(r"COL_TRI_INIT\((\w+)",line)
    if m: cur=m.group(1);continue
    m=re.search(r"COL_TRI(?:_SPECIAL)?\((\d+),\s*(\d+),\s*(\d+)",line)
    if not(m and cur): continue
    a,b,c=[V[int(i)] for i in m.groups()]
    ux,uy,uz=[b[i]-a[i] for i in range(3)];vx,vy,vz=[c[i]-a[i] for i in range(3)]
    nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx;L=math.sqrt(nx*nx+ny*ny+nz*nz) or 1
    ys=[a[1],b[1],c[1]]
    if ny/L>0.35 and min(ys)<=300 and max(ys)>=500 and max(ys)<=1000 and max(p[2] for p in (a,b,c))>-2000:
        print(cur.replace('SURFACE_',''),(a,b,c),'ny=%.2f'%(ny/L))
