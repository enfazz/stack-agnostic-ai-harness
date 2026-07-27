#!/usr/bin/env python3
"""build-graph.py — index a repo's file + import dependency graph into SQLite.

Language-agnostic MVP: nodes are source files, edges are intra-repo import/require
dependencies. Python imports are parsed with `ast` (accurate, incl. relative
imports and src/ layouts via import-root suffix resolution); JS/TS with a
comment-stripped, boundary-anchored regex plus tsconfig/jsconfig path-alias +
baseUrl resolution. Bare (third-party) specifiers are ignored — only edges
resolvable to a file inside the repo are recorded.

INCREMENTAL: when a compatible graph already exists at the DB path, a file whose
CONTENT HASH is unchanged reuses its cached import specifiers instead of being
re-parsed; only changed/added files are re-parsed. Every file is still read (to
hash it), and resolution is always redone in full against the current file set —
so the result is byte-for-byte identical to a full build, including the case
where ADDING a file newly resolves an UNCHANGED file's import. The win is
skipping the expensive parse (ast/regex), not the read. Pass --full to force a
from-scratch rebuild. The DB is written atomically (temp + os.replace), so a
crash never destroys the previous good graph.

Usage:  build-graph.py [--full] [repo-root] [db-path]   (defaults: .  and  <root>/.harness/graph.db)
Only dependency: python3 (sqlite3, ast, json, re, hashlib are stdlib).
It never executes target code (ast.parse only) and never follows dir symlinks.
"""
import ast, hashlib, json, os, re, sqlite3, sys

SCHEMA_VERSION = "3"   # bump on any nodes/specs schema change (invalidates the cache)
PARSER_VERSION = "1"   # bump when extract_specs() logic changes (invalidates the parse cache)

pos = [a for a in sys.argv[1:] if a != "--full"]
FULL = "--full" in sys.argv[1:]
ROOT = os.path.abspath(pos[0] if len(pos) > 0 else ".")
DB = pos[1] if len(pos) > 1 else os.path.join(ROOT, ".harness", "graph.db")

PRUNE_ALWAYS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".tox",
                ".next", ".cache", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".harness"}
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

def relof(f):
    return os.path.relpath(f, ROOT).replace(os.sep, "/")

cur = {}   # rel -> (abspath, mtime_ns, size)
for f in walk():
    if f.endswith(JS_EXT + PY_EXT):
        try:
            st = os.stat(f)
        except OSError:
            continue
        cur[relof(f)] = (f, st.st_mtime_ns, st.st_size)
relset = set(cur)

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
    return r[:-3]

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
    if level and level > 0:
        pkg = os.path.dirname(importer_rel).split("/") if os.path.dirname(importer_rel) else []
        up = pkg[: len(pkg) - (level - 1)] if level - 1 <= len(pkg) else []
        base = "/".join(up)
        tail = module.replace(".", "/") if module else ""
        m = (base + "/" + tail).strip("/") if tail else base
        cands = [m + ".py", m + "/__init__.py"] if m else []
        return [c for c in cands if c in relset]
    slash = module.replace(".", "/")
    exact = [c for c in (slash + ".py", slash + "/__init__.py") if c in relset]
    if exact:
        return exact
    if "/" in slash:
        return sorted(SUFFIX_INDEX.get(slash, ()))
    return []

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
            txt = re.sub(r",(\s*[}\]])", r"\1", txt)
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
    for pat, targs in TS_ALIASES:
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
    if TS_BASEURL is not None:
        hit = _js_file(os.path.join(TS_BASEURL, spec))
        if hit:
            return hit
    return None

# ---- spec extraction (the expensive, cacheable step) -----------------------
JS_STMT = re.compile(r"(?m)^\s*(?:import\b[^'\"]*?from|export\b[^'\"]*?from|import)\s*['\"]([^'\"]+)['\"]")
JS_CALL = re.compile(r"(?<![\w$.])(?:import|require)\s*\(\s*['\"]([^'\"]+)['\"]")

def strip_js_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"(?<!:)//[^\n]*", "", s)
    return s

def extract_specs(rel_, text):
    """Return the raw import specifiers of a file: list of (kind, spec, level).
    Takes already-read source text; never executes it (ast.parse / regex only)."""
    out = []
    if rel_.endswith(PY_EXT):
        try:
            tree = ast.parse(text)
        except Exception:
            return out
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for n in node.names:
                    out.append(("py", n.name, 0))
            elif isinstance(node, ast.ImportFrom):
                mod, lvl = node.module or "", node.level or 0
                targets = [mod] if mod else []
                for n in node.names:
                    targets.append((mod + "." + n.name) if mod else n.name)
                for t in targets:
                    out.append(("py", t, lvl))
    else:
        clean = strip_js_comments(text)
        for spec in JS_STMT.findall(clean) + JS_CALL.findall(clean):
            out.append(("js", spec, 0))
    return out

# ---- decide full vs incremental, load the parse cache (hash-keyed) ---------
mode = "full"
cached_hash = {}    # rel -> content hash
cached_specs = {}   # rel -> [(kind, spec, level), ...]
if not FULL and os.path.isfile(DB):
    c = None
    try:
        c = sqlite3.connect(DB)
        meta = dict(c.execute("SELECT key,value FROM meta"))
        if meta.get("schema_version") == SCHEMA_VERSION and meta.get("parser_version") == PARSER_VERSION:
            for path, h in c.execute("SELECT path, hash FROM nodes"):
                cached_hash[path] = h
            for path, kind, spec, level in c.execute("SELECT path, kind, spec, level FROM specs"):
                cached_specs.setdefault(path, []).append((kind, spec, level))
            mode = "incremental"
    except Exception:
        mode, cached_hash, cached_specs = "full", {}, {}
    finally:
        if c is not None:
            c.close()

# ---- gather specs: read + hash every file; re-parse only changed content ---
specs = {}
hashes = {}
reparsed = 0
for rel_, (abspath, mt, sz) in cur.items():
    try:
        data = open(abspath, "rb").read()
    except OSError:
        specs[rel_] = []; hashes[rel_] = ""; continue
    h = hashlib.blake2b(data, digest_size=16).hexdigest()
    hashes[rel_] = h
    if mode == "incremental" and cached_hash.get(rel_) == h:
        specs[rel_] = cached_specs.get(rel_, [])
    else:
        specs[rel_] = extract_specs(rel_, data.decode("utf-8", "ignore"))
        reparsed += 1

# ---- resolve all specs -> edges (always full; cheap dict lookups) ----------
edges = set()
for rel_, slist in specs.items():
    for kind, spec, level in slist:
        if kind == "py":
            for d in resolve_py(rel_, spec, level):
                edges.add((rel_, d))
        else:
            d = resolve_js(rel_, spec)
            if d:
                edges.add((rel_, d))
edges = {(s, d) for (s, d) in edges if s != d and d in relset}

# ---- write SQLite atomically (temp + os.replace; never lose the old graph) -
if os.path.exists(DB) and not os.path.isfile(DB):
    sys.exit(f"refusing to overwrite non-file path: {DB}")
os.makedirs(os.path.dirname(DB) or ".", exist_ok=True)
tmp = DB + ".tmp"
if os.path.exists(tmp) and os.path.isfile(tmp):
    os.remove(tmp)
con = sqlite3.connect(tmp)
con.executescript("""
CREATE TABLE nodes(id INTEGER PRIMARY KEY, path TEXT UNIQUE, lang TEXT, is_test INTEGER, mtime INTEGER, size INTEGER, hash TEXT);
CREATE TABLE edges(src INTEGER, dst INTEGER, kind TEXT, PRIMARY KEY(src,dst,kind));
CREATE TABLE specs(path TEXT, kind TEXT, spec TEXT, level INTEGER);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX idx_edges_dst ON edges(dst);
CREATE INDEX idx_edges_src ON edges(src);
CREATE INDEX idx_specs_path ON specs(path);
""")
idof = {}
for r in sorted(relset):
    _, mt, sz = cur[r]
    row = con.execute("INSERT INTO nodes(path,lang,is_test,mtime,size,hash) VALUES(?,?,?,?,?,?)",
                      (r, lang_of(r), 1 if is_test(r) else 0, mt, sz, hashes.get(r, "")))
    idof[r] = row.lastrowid
for (s, d) in sorted(edges):
    con.execute("INSERT OR IGNORE INTO edges(src,dst,kind) VALUES(?,?,'import')", (idof[s], idof[d]))
for r in sorted(specs):
    for kind, spec, level in specs[r]:
        con.execute("INSERT INTO specs(path,kind,spec,level) VALUES(?,?,?,?)", (r, kind, spec, level))
for k, v in (("schema_version", SCHEMA_VERSION), ("parser_version", PARSER_VERSION),
             ("root", ROOT), ("files", str(len(relset))), ("edges", str(len(edges)))):
    con.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (k, v))
con.commit()
con.close()
os.replace(tmp, DB)   # atomic: the old graph is intact until this instant
how = f"incremental, reparsed {reparsed}/{len(relset)}" if mode == "incremental" else f"full build, parsed {reparsed}"
print(f"graph: {len(relset)} files, {len(edges)} import edges ({how}) -> {DB}")
