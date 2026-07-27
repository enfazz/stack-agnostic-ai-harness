#!/usr/bin/env python3
"""build-graph.py — index a repo's file + import dependency graph into SQLite.

Language-agnostic MVP: nodes are source files, edges are intra-repo import/require
dependencies. Python imports are parsed with `ast` (accurate, incl. relative
imports and src/ layouts via import-root suffix resolution); JS/TS with a
comment-stripped, boundary-anchored regex plus tsconfig/jsconfig path-alias +
baseUrl resolution. Bare (third-party) specifiers are ignored — only edges
resolvable to a file inside the repo are recorded.

Usage:  build-graph.py [repo-root] [db-path]   (defaults: .  and  <root>/.harness/graph.db)
Only dependency: python3 (sqlite3, ast, json, re are stdlib). No external services.
It never executes target code (ast.parse only) and never follows dir symlinks.
"""
import ast, json, os, re, sqlite3, sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
DB = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, ".harness", "graph.db")

# Pruned at ANY depth (never source): VCS, deps, caches, virtualenvs.
PRUNE_ALWAYS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".tox",
                ".next", ".cache", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".harness"}
# Pruned only at the REPO ROOT (a dir named build/dist/etc. deeper down may be a
# legitimate source package, so it is kept).
PRUNE_ROOT = {"build", "dist", "target", "vendor", ".build", ".idea", ".vscode", "out", "coverage"}
JS_EXT = (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs")
PY_EXT = (".py",)
TEST_RE = re.compile(r"(^|/)tests?/|(^|/)test_[^/]*\.py$|_test\.py$|\.(test|spec)\.[jt]sx?$", re.I)

def walk():
    for dp, dns, fns in os.walk(ROOT, followlinks=False):
        keep = []
        for d in dns:
            if d in PRUNE_ALWAYS:
                continue
            if d in PRUNE_ROOT and os.path.dirname(os.path.join(dp, d)) == ROOT:
                continue
            keep.append(d)
        dns[:] = keep
        for fn in fns:
            yield os.path.join(dp, fn)

files = sorted(f for f in walk() if f.endswith(JS_EXT + PY_EXT))
rel = lambda f: os.path.relpath(f, ROOT).replace(os.sep, "/")
relset = {rel(f) for f in files}

def is_test(r):
    return bool(TEST_RE.search(r))

def lang_of(r):
    return "python" if r.endswith(PY_EXT) else "js"

# ---- Python import-root suffix index (handles src/ and other roots) --------
def py_modpath(r):
    if r.endswith("/__init__.py"):
        return r[: -len("/__init__.py")]
    if r == "__init__.py":
        return ""
    return r[:-3]  # strip .py

SUFFIX_INDEX = {}
for r in relset:
    if not r.endswith(PY_EXT):
        continue
    mp = py_modpath(r)
    if not mp:
        continue
    parts = mp.split("/")
    for i in range(len(parts)):
        SUFFIX_INDEX.setdefault("/".join(parts[i:]), set()).add(r)

def resolve_py(importer_rel, module, level):
    if level and level > 0:  # relative import: path-based from the file's package
        pkg = os.path.dirname(importer_rel).split("/") if os.path.dirname(importer_rel) else []
        up = pkg[: len(pkg) - (level - 1)] if level - 1 <= len(pkg) else []
        base = "/".join(up)
        tail = module.replace(".", "/") if module else ""
        m = (base + "/" + tail).strip("/") if tail else base
        cands = [m + ".py", m + "/__init__.py"] if m else []
        return [c for c in cands if c in relset]
    # absolute import
    slash = module.replace(".", "/")
    exact = [c for c in (slash + ".py", slash + "/__init__.py") if c in relset]
    if exact:
        return exact
    if "/" in slash:  # >=2 segments: match against any import root via suffix
        return sorted(SUFFIX_INDEX.get(slash, ()))
    return []  # single-segment absolute -> assume stdlib/third-party

# ---- JS/TS resolution (relative + tsconfig aliases + baseUrl) --------------
def load_ts_config():
    baseurl, aliases = None, []
    for cfg in ("tsconfig.json", "jsconfig.json"):
        p = os.path.join(ROOT, cfg)
        if not os.path.isfile(p):
            continue
        try:
            txt = open(p, encoding="utf-8", errors="ignore").read()
            txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
            txt = re.sub(r"(?<!:)//[^\n]*", "", txt)
            txt = re.sub(r",(\s*[}\]])", r"\1", txt)  # trailing commas
            co = (json.loads(txt) or {}).get("compilerOptions", {}) or {}
        except Exception:
            continue
        if co.get("baseUrl"):
            baseurl = os.path.normpath(co["baseUrl"])
        for pat, targs in (co.get("paths", {}) or {}).items():
            aliases.append((pat, targs))
    return baseurl, aliases

TS_BASEURL, TS_ALIASES = load_ts_config()

def _js_file(base_rel):
    base = os.path.normpath(base_rel).replace(os.sep, "/")
    cands = [base] + [base + e for e in JS_EXT] + [base + "/index" + e for e in JS_EXT]
    if base.endswith(JS_EXT):
        stem = base.rsplit(".", 1)[0]
        cands += [stem + e for e in JS_EXT]
    for c in cands:
        if c in relset:
            return c
    return None

def resolve_js(importer_rel, spec):
    if spec.startswith("."):
        return _js_file(os.path.join(os.path.dirname(importer_rel), spec))
    for pat, targs in TS_ALIASES:  # tsconfig path aliases
        if "*" in pat:
            pre = pat.split("*", 1)[0]
            if spec.startswith(pre):
                rest = spec[len(pre):]
                for t in targs:
                    hit = _js_file(os.path.join(TS_BASEURL or ".", t.replace("*", rest)))
                    if hit:
                        return hit
        elif spec == pat:
            for t in targs:
                hit = _js_file(os.path.join(TS_BASEURL or ".", t))
                if hit:
                    return hit
    if TS_BASEURL is not None:  # non-relative resolved against baseUrl
        hit = _js_file(os.path.join(TS_BASEURL, spec))
        if hit:
            return hit
    return None

# ---- extract edges ---------------------------------------------------------
edges = set()
# statement imports/exports anchored at line start (so text in a mid-line string
# literal isn't matched); comments are stripped first.
JS_STMT = re.compile(r"(?m)^\s*(?:import\b[^'\"]*?from|export\b[^'\"]*?from|import)\s*['\"]([^'\"]+)['\"]")
# dynamic import()/require() anywhere, but require/import must be a real token.
JS_CALL = re.compile(r"(?<![\w$.])(?:import|require)\s*\(\s*['\"]([^'\"]+)['\"]")

def strip_js_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)     # block comments
    s = re.sub(r"(?<!:)//[^\n]*", "", s)            # line comments (keep http://)
    return s

for f in files:
    r = rel(f)
    try:
        src = open(f, encoding="utf-8", errors="ignore").read()
    except Exception:
        continue
    if r.endswith(PY_EXT):
        try:
            tree = ast.parse(src)          # parse only — never executes the file
        except Exception:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for n in node.names:
                    for d in resolve_py(r, n.name, 0):
                        edges.add((r, d))
            elif isinstance(node, ast.ImportFrom):
                mod, lvl = node.module or "", node.level or 0
                targets = [mod] if mod else []
                for n in node.names:
                    targets.append((mod + "." + n.name) if mod else n.name)
                for t in targets:
                    for d in resolve_py(r, t, lvl):
                        edges.add((r, d))
    else:
        clean = strip_js_comments(src)
        for spec in JS_STMT.findall(clean) + JS_CALL.findall(clean):
            d = resolve_js(r, spec)
            if d:
                edges.add((r, d))

edges = {(s, d) for (s, d) in edges if s != d}

# ---- write SQLite ----------------------------------------------------------
if os.path.exists(DB) and not os.path.isfile(DB):
    sys.exit(f"refusing to overwrite non-file path: {DB}")
os.makedirs(os.path.dirname(DB) or ".", exist_ok=True)
if os.path.isfile(DB):
    os.remove(DB)
con = sqlite3.connect(DB)
con.executescript("""
CREATE TABLE nodes(id INTEGER PRIMARY KEY, path TEXT UNIQUE, lang TEXT, is_test INTEGER);
CREATE TABLE edges(src INTEGER, dst INTEGER, kind TEXT, PRIMARY KEY(src,dst,kind));
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX idx_edges_dst ON edges(dst);
CREATE INDEX idx_edges_src ON edges(src);
""")
idof = {}
for r in sorted(relset):
    cur = con.execute("INSERT INTO nodes(path,lang,is_test) VALUES(?,?,?)",
                      (r, lang_of(r), 1 if is_test(r) else 0))
    idof[r] = cur.lastrowid
for (s, d) in sorted(edges):
    con.execute("INSERT OR IGNORE INTO edges(src,dst,kind) VALUES(?,?,'import')", (idof[s], idof[d]))
con.execute("INSERT INTO meta VALUES('root',?)", (ROOT,))
con.execute("INSERT INTO meta VALUES('files',?)", (str(len(relset)),))
con.execute("INSERT INTO meta VALUES('edges',?)", (str(len(edges)),))
con.commit()
con.close()
print(f"graph: {len(relset)} files, {len(edges)} import edges -> {DB}")
