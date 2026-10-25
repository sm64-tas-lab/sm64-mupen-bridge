import re,math
src=open(r"G:/tas-lab/repos/sm64-decomp/levels/bob/areas/1/collision.inc.c").read()
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
    # distance du coin aux aretes
    def dseg(p,q,x=1200,z=-136):
        px,pz,qx,qz=p[0],p[2],q[0],q[2]; dx,dz=qx-px,qz-pz; t=max(0,min(1,((x-px)*dx+(z-pz)*dz)/((dx*dx+dz*dz) or 1)))
        return math.hypot(x-(px+t*dx),z-(pz+t*dz))
    dm=min(dseg(a,b),dseg(b,c),dseg(c,a))
    if dm<250 and max(a[1],b[1],c[1])>700 and min(a[1],b[1],c[1])<1100:
        k='SOL' if ny/L>0.1 else ('PLAF' if ny/L<-0.1 else 'MUR')
        print(k,cur.replace('SURFACE_',''),(a,b,c),'n=(%.2f,%.2f,%.2f)'%(nx/L,ny/L,nz/L),'d=%.0f'%dm)
