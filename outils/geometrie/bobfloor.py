import re,math,sys
src=open(r"G:/tas-lab/repos/sm64-decomp/levels/bob/areas/1/collision.inc.c").read()
V=[tuple(map(int,m)) for m in re.findall(r"COL_VERTEX\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)",src)]
F=[];cur=None
for line in src.splitlines():
    m=re.search(r"COL_TRI_INIT\((\w+)",line)
    if m: cur=m.group(1);continue
    m=re.search(r"COL_TRI(?:_SPECIAL)?\((\d+),\s*(\d+),\s*(\d+)",line)
    if m and cur:
        a,b,c=[V[int(i)] for i in m.groups()]
        ux,uy,uz=[b[i]-a[i] for i in range(3)];vx,vy,vz=[c[i]-a[i] for i in range(3)]
        nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx;L=math.sqrt(nx*nx+ny*ny+nz*nz) or 1
        if ny/L>0.01: F.append((a,b,c,nx/L,ny/L,nz/L,cur))
def floor(x,z,ymax=1e9):
    best=None
    for a,b,c,nx,ny,nz,t in F:
        # point in triangle (xz)
        def s(p,q): return (q[0]-p[0])*(z-p[2])-(q[2]-p[2])*(x-p[0])
        d1,d2,d3=s(a,b),s(b,c),s(c,a)
        if (d1<0 or d2<0 or d3<0) and (d1>0 or d2>0 or d3>0): continue
        y=a[1]-(nx*(x-a[0])+nz*(z-a[2]))/ny
        if y<=ymax and (best is None or y>best[0]): best=(y,ny,t.replace('SURFACE_',''))
    return best
pts=[tuple(map(float,p.split(','))) for p in sys.argv[1:]]
for (x0,z0),(x1,z1) in zip(pts,pts[1:]):
    n=int(math.hypot(x1-x0,z1-z0)/200)+1
    print(f"--- ({x0:.0f},{z0:.0f}) -> ({x1:.0f},{z1:.0f})")
    for i in range(n+1):
        x=x0+(x1-x0)*i/n; z=z0+(z1-z0)*i/n; f=floor(x,z,3000)
        print(f"  ({x:6.0f},{z:6.0f}) sol={f[0]:7.1f} ny={f[1]:.2f} {f[2]}" if f else f"  ({x:6.0f},{z:6.0f}) HORS LIMITES")
