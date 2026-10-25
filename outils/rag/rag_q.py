import sys
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "files"))
import query
m, c, r = query.load_retriever()
for q in sys.argv[1:]:
    print("=====", q)
    for d, meta, sc in query.retrieve(m, c, r, q, 4):
        print("-- [%.2f] %s" % (sc, meta.get("source", "")))
        print("   ", d[:600].replace(chr(10), " "))
