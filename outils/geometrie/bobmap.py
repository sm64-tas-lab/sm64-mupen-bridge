import tempfile
import os
from sm64_geo_common import get_decomp_dir
DECOMP = get_decomp_dir()
import re,math
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon
src=open(os.path.join(DECOMP, "levels/bob/areas/1/collision.inc.c")).read()
V=[tuple(map(int,m)) for m in re.findall(r"COL_VERTEX\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)",src)]
tris=[];cur=None
for line in src.splitlines():
    m=re.search(r"COL_TRI_INIT\((\w+)",line)
    if m: cur=m.group(1);continue
    m=re.search(r"COL_TRI(?:_SPECIAL)?\((\d+),\s*(\d+),\s*(\d+)",line)
    if m and cur: tris.append((cur,[V[int(i)] for i in m.groups()]))
fig,ax=plt.subplots(figsize=(14,14))
cm=plt.get_cmap("terrain")
X0,X1,Z0,Z1=-7500,7500,-7500,7500
for t,(a,b,c) in tris:
    ux,uy,uz=[b[i]-a[i] for i in range(3)];vx,vy,vz=[c[i]-a[i] for i in range(3)]
    nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx;L=math.sqrt(nx*nx+ny*ny+nz*nz) or 1
    if ny/L>0.1:
        y=(a[1]+b[1]+c[1])/3
        ax.add_patch(Polygon([(p[0],p[2]) for p in (a,b,c)],closed=True,fc=cm(min(max(y/4500,0),1)),ec='none',alpha=0.9))
    elif abs(ny/L)<=0.1 and max(a[1],b[1],c[1])>-100:
        ax.plot([p[0] for p in (a,b,c)],[p[2] for p in (a,b,c)],color='k',lw=0.3)
pts={'spawn':(-6525,6431),'grille':(1456,446),'etoile':(1550,300),'elevateur':(1612,4611),'chomp':(260,1920)}
for k,(x,z) in pts.items(): ax.plot(x,z,'r*',ms=14); ax.text(x+80,z+80,k,color='red',fontsize=12,weight='bold')
for (x,z) in [(-3080,-5200),(-1750,-2800),(-1400,-950),(-2650,1750),(-1900,3450),(2350,3700),(-3800,-460),(-3480,-2120)]:
    ax.plot(x,z,'ko',ms=8); ax.text(x+60,z-150,'bomb',fontsize=9)
ax.set_xlim(X0,X1); ax.set_ylim(Z1,Z0); ax.set_aspect('equal'); ax.grid(alpha=0.3)
ax.set_xlabel('x'); ax.set_ylabel('z (down = +z)')
sm=plt.cm.ScalarMappable(cmap=cm,norm=plt.Normalize(0,4500)); plt.colorbar(sm,ax=ax,shrink=0.6,label='height y')
plt.savefig(os.path.join(tempfile.gettempdir(), "bobmap.png"),dpi=70,bbox_inches='tight')
