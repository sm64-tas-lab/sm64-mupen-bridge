import os
from sm64_geo_common import get_decomp_dir
DECOMP = get_decomp_dir()
import re,math,sys
cx,cz,R,ylo,yhi=[float(a) for a in sys.argv[1:6]]
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
    if abs(ny/L)>0.1: continue
    if max(p[1] for p in (a,b,c))<ylo or min(p[1] for p in (a,b,c))>yhi: continue
    def dseg(p,q):
        px,pz,qx,qz=p[0],p[2],q[0],q[2]; dx,dz=qx-px,qz-pz; t=max(0,min(1,((cx-px)*dx+(cz-pz)*dz)/((dx*dx+dz*dz) or 1)))
        return math.hypot(cx-(px+t*dx),cz-(pz+t*dz))
    d=min(dseg(a,b),dseg(b,c),dseg(c,a))
    if d<R: print(cur.replace('SURFACE_',''),(a,b,c),'n=(%.2f,%.2f)'%(nx/L,nz/L),'d=%.0f'%d)
