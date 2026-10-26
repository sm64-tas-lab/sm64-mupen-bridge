import sys
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "files"))
import query
m, c, r = query.load_retriever()
res = c.get(where_document={"$contains": sys.argv[1]}, include=["documents","metadatas"])
for d, md in zip(res["documents"], res["metadatas"]):
    print("=====", md.get("title", md.get("source")))
    print(d[:3000])
