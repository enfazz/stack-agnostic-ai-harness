#!/usr/bin/env python3
"""build-graph.py — index a repo's file + import dependency graph into SQLite.

Nodes are source files. Edges are intra-repo import dependencies at two grains:
  - FILE edges     (src imports from dst)                     -> table `edges`
  - SYMBOL edges   (src imports name `sym` FROM dst)          -> table `symbol_edges`
plus DEFINITIONS (top-level functions/classes) in table `symbols`.

Python is parsed with `ast` (accurate: relative imports, src/ layouts via
import-root suffix resolution, and submodule-vs-symbol disambiguation). JS/TS use
a comment-stripped, boundary-anchored regex plus tsconfig/jsconfig path-alias +
baseUrl resolution. Only intra-repo edges are recorded. SYMBOL edges capture
EXPLICIT named imports (`from m import foo`, `import {foo} from './m'`) — not
attribute usage (`import m; m.foo()`) or JS default/namespace imports.

INCREMENTAL: a file whose CONTENT HASH is unchanged reuses its cached specifiers
and definitions; only changed/added files are re-parsed. Resolution is always
redone in full, so the result is identical to a full build. --full forces a
rebuild. The DB is written atomically (temp + os.replace).

Usage:  build-graph.py [--full] [repo-root] [db-path]   (defaults: .  and  <root>/.harness/graph.db)
Only dependency: python3 (stdlib). Never executes target code; never follows dir symlinks.
"""
import ast, hashlib, json, os, re, sqlite3, sys

SCHEMA_VERSION = "4"   # +symbols/+symbol_edges/specs.name
PARSER_VERSION = "2"   # extract() now returns defs + per-name imports

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

cur = {}
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

# ---- Python import-root suffix index ---------------------------------------
def py_modpath(r):
    if r.endswith("/__init__.py"):
        return r[: -len("/__init__.py")]
    if r == "__init__.py":
        return ""
    return r[:-3]

SUFFIX_INDEX = {}
for r in relset:
    if r.endswith(PY_EXT):
        mp = py_modpath(r)
        if mp:
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

# ---- JS/TS resolution ------------------------------------------------------
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

# ---- extraction (the cacheable step) ---------------------------------------
JS_STMT = re.compile(r"(?m)^\s*(?:import\b[^'\"]*?from|export\b[^'\"]*?from|import)\s*['\"]([^'\"]+)['\"]")
JS_CALL = re.compile(r"(?<![\w$.])(?:import|require)\s*\(\s*['\"]([^'\"]+)['\"]")
JS_NAMED = re.compile(r"(?m)^\s*import\s+(?:[A-Za-z_$][\w$]*\s*,?\s*)?\{([^}]*)\}\s*from\s*['\"]([^'\"]+)['\"]")
JS_DEF = re.compile(
    r"(?m)^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?"
    r"(?:(function)\s*\*?\s*([A-Za-z_$][\w$]*)"
    r"|(class)\s+([A-Za-z_$][\w$]*)"
    r"|(?:export\s+)?(const|let|var)\s+([A-Za-z_$][\w$]*)\s*=)")

def strip_js_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"(?<!:)//[^\n]*", "", s)
    return s

def blank_js_templates(s):
    """Blank the CONTENTS of backtick template literals (newline-preserving) so
    code-shaped text inside a multi-line template can't produce phantom defs or
    import edges. Single/double-quoted strings are left intact — real import
    specifiers live in those, and line-anchoring already prevents matching an
    import statement embedded in a single-line string."""
    return re.sub(r"`(?:[^`\\]|\\.)*`",
                  lambda m: re.sub(r"[^\n]", " ", m.group(0)), s, flags=re.S)

def _collect_py_defs(body, out):
    """Top-level function/class defs, descending into module-level guard/control
    blocks (if/try/with/for/while) — so `if TYPE_CHECKING:`-guarded defs count —
    but NOT into function/class bodies (methods/nested defs are not top-level)."""
    for node in body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            out.append((node.name, "function", node.lineno))
        elif isinstance(node, ast.ClassDef):
            out.append((node.name, "class", node.lineno))
        elif isinstance(node, (ast.If, ast.Try, ast.With, ast.For, ast.While,
                               ast.AsyncWith, ast.AsyncFor)):
            for attr in ("body", "orelse", "finalbody"):
                _collect_py_defs(getattr(node, attr, []) or [], out)
            for h in getattr(node, "handlers", []) or []:
                _collect_py_defs(h.body, out)

def extract(rel_, text):
    """-> (specs, defs). specs: (kind, spec, level, name) with name='' for a
    module/side-effect import. defs: (name, kind, line) for top-level defs."""
    specs, defs = [], []
    if rel_.endswith(PY_EXT):
        try:
            tree = ast.parse(text)
        except Exception:
            return specs, defs
        _collect_py_defs(tree.body, defs)
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for n in node.names:
                    specs.append(("py", n.name, 0, ""))            # module import
            elif isinstance(node, ast.ImportFrom):
                mod, lvl = node.module or "", node.level or 0
                for n in node.names:
                    if n.name != "*":
                        specs.append(("py", mod, lvl, n.name))     # `from mod import name`
                    else:
                        specs.append(("py", mod, lvl, ""))         # `from mod import *`
    else:
        clean = blank_js_templates(strip_js_comments(text))
        for spec in JS_STMT.findall(clean) + JS_CALL.findall(clean):
            specs.append(("js", spec, 0, ""))                      # file-level edge
        for braces, spec in JS_NAMED.findall(clean):
            for part in braces.split(","):
                nm = part.strip().split(" as ")[0].strip()
                if nm:
                    specs.append(("js", spec, 0, nm))              # named symbol import
        for m in JS_DEF.finditer(clean):
            line = clean[:m.start()].count("\n") + 1
            if m.group(1):   defs.append((m.group(2), "function", line))
            elif m.group(3): defs.append((m.group(4), "class", line))
            elif m.group(5): defs.append((m.group(6), m.group(5), line))
    return specs, defs

# ---- cache load ------------------------------------------------------------
mode = "full"
cached_hash, cached_specs, cached_defs = {}, {}, {}
if not FULL and os.path.isfile(DB):
    c = None
    try:
        c = sqlite3.connect(DB)
        meta = dict(c.execute("SELECT key,value FROM meta"))
        if meta.get("schema_version") == SCHEMA_VERSION and meta.get("parser_version") == PARSER_VERSION:
            for path, h in c.execute("SELECT path, hash FROM nodes"):
                cached_hash[path] = h
            for path, kind, spec, level, name in c.execute("SELECT path, kind, spec, level, name FROM specs"):
                cached_specs.setdefault(path, []).append((kind, spec, level, name))
            for path, name, kind, line in c.execute("SELECT path, name, kind, line FROM symbols"):
                cached_defs.setdefault(path, []).append((name, kind, line))
            mode = "incremental"
    except Exception:
        mode, cached_hash, cached_specs, cached_defs = "full", {}, {}, {}
    finally:
        if c is not None:
            c.close()

# ---- gather: read + hash; re-parse only changed content --------------------
specs_by, defs_by, hashes = {}, {}, {}
reparsed = 0
for rel_, (abspath, mt, sz) in cur.items():
    try:
        data = open(abspath, "rb").read()
    except OSError:
        specs_by[rel_], defs_by[rel_], hashes[rel_] = [], [], ""
        continue
    h = hashlib.blake2b(data, digest_size=16).hexdigest()
    hashes[rel_] = h
    if mode == "incremental" and cached_hash.get(rel_) == h:
        specs_by[rel_] = cached_specs.get(rel_, [])
        defs_by[rel_] = cached_defs.get(rel_, [])
    else:
        specs_by[rel_], defs_by[rel_] = extract(rel_, data.decode("utf-8", "ignore"))
        reparsed += 1

# ---- resolve -> file edges + symbol edges ----------------------------------
file_edges, symbol_edges = set(), set()
for src, slist in specs_by.items():
    for kind, spec, level, name in slist:
        if kind == "py":
            if name == "":
                for f in resolve_py(src, spec, level):
                    file_edges.add((src, f))
            else:
                # Resolve the module `spec`, then decide per resolved file whether
                # `name` is a SUBMODULE of it (only if a package AND name.py exists
                # right inside that package dir — exact, never the fuzzy suffix
                # index) or a SYMBOL imported from it.
                modfiles = resolve_py(src, spec, level) if (spec or level) else []
                matched = False
                for mf in modfiles:
                    subfile = None
                    if mf.endswith("/__init__.py"):
                        pkgdir = mf[: -len("/__init__.py")]
                        subfile = next((c for c in (pkgdir + "/" + name + ".py",
                                                    pkgdir + "/" + name + "/__init__.py")
                                        if c in relset), None)
                    if subfile:
                        file_edges.add((src, subfile))        # `name` is a submodule file
                    else:
                        file_edges.add((src, mf))             # `name` is a symbol in the module
                        symbol_edges.add((src, mf, name))
                    matched = True
                if not matched and not spec and level:
                    # `from . import name` in a namespace package (no __init__)
                    for f in resolve_py(src, name, level):
                        file_edges.add((src, f))
        else:
            f = resolve_js(src, spec)
            if f:
                file_edges.add((src, f))
                if name:
                    symbol_edges.add((src, f, name))
file_edges = {(s, d) for (s, d) in file_edges if s != d and d in relset}
symbol_edges = {(s, d, n) for (s, d, n) in symbol_edges if s != d and d in relset}

# ---- write SQLite atomically -----------------------------------------------
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
CREATE TABLE symbol_edges(src INTEGER, dst INTEGER, symbol TEXT);
CREATE TABLE symbols(path TEXT, name TEXT, kind TEXT, line INTEGER);
CREATE TABLE specs(path TEXT, kind TEXT, spec TEXT, level INTEGER, name TEXT);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX idx_edges_dst ON edges(dst);
CREATE INDEX idx_edges_src ON edges(src);
CREATE INDEX idx_symedges_sym ON symbol_edges(symbol);
CREATE INDEX idx_symbols_name ON symbols(name);
CREATE INDEX idx_specs_path ON specs(path);
""")
idof = {}
for r in sorted(relset):
    _, mt, sz = cur[r]
    row = con.execute("INSERT INTO nodes(path,lang,is_test,mtime,size,hash) VALUES(?,?,?,?,?,?)",
                      (r, lang_of(r), 1 if is_test(r) else 0, mt, sz, hashes.get(r, "")))
    idof[r] = row.lastrowid
for (s, d) in sorted(file_edges):
    con.execute("INSERT OR IGNORE INTO edges(src,dst,kind) VALUES(?,?,'import')", (idof[s], idof[d]))
for (s, d, n) in sorted(symbol_edges):
    con.execute("INSERT INTO symbol_edges(src,dst,symbol) VALUES(?,?,?)", (idof[s], idof[d], n))
for r in sorted(defs_by):
    for name, kind, line in defs_by[r]:
        con.execute("INSERT INTO symbols(path,name,kind,line) VALUES(?,?,?,?)", (r, name, kind, line))
for r in sorted(specs_by):
    for kind, spec, level, name in specs_by[r]:
        con.execute("INSERT INTO specs(path,kind,spec,level,name) VALUES(?,?,?,?,?)", (r, kind, spec, level, name))
for k, v in (("schema_version", SCHEMA_VERSION), ("parser_version", PARSER_VERSION),
             ("root", ROOT), ("files", str(len(relset))), ("edges", str(len(file_edges))),
             ("symbol_edges", str(len(symbol_edges)))):
    con.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (k, v))
con.commit()
con.close()
os.replace(tmp, DB)
how = f"incremental, reparsed {reparsed}/{len(relset)}" if mode == "incremental" else f"full build, parsed {reparsed}"
print(f"graph: {len(relset)} files, {len(file_edges)} file edges, {len(symbol_edges)} symbol edges ({how}) -> {DB}")
