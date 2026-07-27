#!/usr/bin/env python3
"""graph-query.py — query the SQLite dependency graph built by build-graph.py.

Subcommands (db defaults to .harness/graph.db):
  dependents <file...>   files that (transitively) import the given files  [impact]
  deps       <file...>   files the given files (transitively) import
  affected   <file...>   dependents + the files themselves (the change's blast radius)
  tests      <file...>   affected files that are test files (what to re-run)
  cycles                 files in an import cycle (SCC of size>1; self-imports are
                         dropped by the indexer, so they are not reported)
  orphans                files with NO inbound import edges, excluding tests.
                         NOTE: "no importers" != "dead code" — entrypoints and
                         package __init__.py legitimately appear here.
  stats                  counts
Usage:  graph-query.py [--db PATH] <subcommand> [args...]
Pure Python: no SQLite JSON1 extension required; O(V+E) traversals.
"""
import os, sqlite3, sys

argv = sys.argv[1:]
DB = os.path.join(".harness", "graph.db")
if argv and argv[0] == "--db":
    DB = argv[1]; argv = argv[2:]
if not argv:
    print(__doc__); sys.exit(2)
cmd, args = argv[0], argv[1:]

if not os.path.exists(DB):
    print(f"no graph at {DB} — run build-graph first", file=sys.stderr); sys.exit(1)
con = sqlite3.connect(DB)

# Load node maps once so result-set -> path resolution needs no IN(?,...) clause
# (avoids the SQLite "too many SQL variables" crash on large blast radii).
ID2PATH, ID2TEST, PATH2ID = {}, {}, {}
for nid, path, is_test in con.execute("SELECT id, path, is_test FROM nodes"):
    ID2PATH[nid] = path; ID2TEST[nid] = is_test; PATH2ID[path] = nid

def norm(p):
    return p.replace("\\", "/").replace(os.sep, "/")

def ids(paths):
    out = []
    for p in paths:
        nid = PATH2ID.get(norm(p))
        if nid is not None:
            out.append(nid)
        else:
            print(f"(not in graph: {p})", file=sys.stderr)
    return out

# Transitive closure via pure-Python BFS. dir='up' = dependents (who imports me:
# edges.dst->src), 'down' = deps (edges.src->dst). Returns seeds + reachable.
def closure(seed_ids, direction):
    if not seed_ids:
        return set()
    if direction == "up":
        pairs = con.execute("SELECT dst, src FROM edges").fetchall()
    else:
        pairs = con.execute("SELECT src, dst FROM edges").fetchall()
    adj = {}
    for k, v in pairs:
        adj.setdefault(k, []).append(v)
    seen = set(seed_ids); stack = list(seed_ids)
    while stack:
        n = stack.pop()
        for m in adj.get(n, ()):
            if m not in seen:
                seen.add(m); stack.append(m)
    return seen

def sorted_paths(id_set):
    return sorted(ID2PATH[i] for i in id_set if i in ID2PATH)

if cmd in ("dependents", "deps", "affected", "tests"):
    seeds = ids(args)
    reached = closure(seeds, "down" if cmd == "deps" else "up")
    if cmd in ("dependents", "deps"):
        reached -= set(seeds)
        for p in sorted_paths(reached): print(p)
    elif cmd == "affected":
        for p in sorted_paths(reached): print(p)   # includes seeds
    elif cmd == "tests":
        for p in sorted(ID2PATH[i] for i in reached if ID2TEST.get(i)): print(p)

elif cmd == "cycles":
    # Tarjan SCC (iterative), O(V+E). A node is in a cycle iff its SCC size > 1.
    adj = {}
    for s, d in con.execute("SELECT src, dst FROM edges"):
        adj.setdefault(s, []).append(d)
    index = {}; low = {}; onstack = {}; stack = []; idx = [0]; in_cycle = []
    for root in list(ID2PATH):
        if root in index:
            continue
        work = [(root, 0)]
        while work:
            v, pi = work[-1]
            if pi == 0:
                index[v] = low[v] = idx[0]; idx[0] += 1
                stack.append(v); onstack[v] = True
            recursed = False
            nbrs = adj.get(v, ())
            i = pi
            while i < len(nbrs):
                w = nbrs[i]
                if w not in index:
                    work[-1] = (v, i + 1)
                    work.append((w, 0))
                    recursed = True
                    break
                if onstack.get(w):
                    low[v] = min(low[v], index[w])
                i += 1
            if recursed:
                continue
            if low[v] == index[v]:
                comp = []
                while True:
                    w = stack.pop(); onstack[w] = False; comp.append(w)
                    if w == v:
                        break
                if len(comp) > 1:
                    in_cycle.extend(comp)
            work.pop()
            if work:
                p = work[-1][0]
                low[p] = min(low[p], low[v])
    for p in sorted(ID2PATH[i] for i in in_cycle): print(p)
    print(f"({len(in_cycle)} files participate in an import cycle)", file=sys.stderr)

elif cmd == "orphans":
    have_in = {d for (d,) in con.execute("SELECT DISTINCT dst FROM edges")}
    for i in sorted(ID2PATH):
        if not ID2TEST.get(i) and i not in have_in:
            print(ID2PATH[i])

elif cmd == "stats":
    for k, v in con.execute("SELECT key,value FROM meta"): print(f"{k}={v}")
    print(f"test_files={sum(1 for t in ID2TEST.values() if t)}")
else:
    print(__doc__); sys.exit(2)
