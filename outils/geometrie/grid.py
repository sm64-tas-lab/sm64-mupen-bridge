import os, sys
args = sys.argv[1:]
sys.argv = [sys.argv[0]]
with open(os.path.join(os.path.dirname(__file__), "bobfloor.py"), encoding="utf-8") as _f:
    src = _f.read().split("pts=")[0]
exec(src)
x0, x1, z0, z1, st = (int(a) for a in (args if args else ["600", "2400", "3600", "6000", "150"]))
xs = range(x0, x1 + 1, st); zs = range(z0, z1 + 1, st)
print("z/x   " + " ".join("%5d" % x for x in xs))
for z in zs:
    row = []
    for x in xs:
        f = floor(x, z, 3000)
        row.append("%5d" % int(f[0]) if f else "  OOB")
    print("%5d " % z + " ".join(row))
