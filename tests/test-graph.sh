#!/usr/bin/env bash
# test-graph.sh — tests for the dependency graph (build-graph.py + graph-query.py)
# against fixtures/graph-sample (Python package + JS/TS tree with a cycle + tests).
set -u
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HARNESS/scripts/build-graph.py"
QUERY="$HARNESS/scripts/graph-query.py"
SAMPLE="$HARNESS/fixtures/graph-sample"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DB="$TMP/graph.db"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available"; exit 0
fi

ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
Q(){ python3 "$QUERY" --db "$DB" "$@"; }
# same_set <expected-newline-list> <actual-newline-list> <label>
same(){ if [ "$(printf '%s' "$1" | sort)" = "$(printf '%s' "$2" | sort)" ]; then ok "$3"; else bad "$3"; echo "    expected: $(echo "$1" | tr '\n' ' ')"; echo "    actual:   $(echo "$2" | tr '\n' ' ')"; fi; }
has(){ printf '%s\n' "$2" | grep -qx "$1" && ok "$3" || { bad "$3"; echo "    (missing '$1' in: $(echo "$2" | tr '\n' ' '))"; }; }
absent(){ printf '%s\n' "$2" | grep -qx "$1" && { bad "$3"; } || ok "$3"; }

echo "== build =="
OUT="$(python3 "$BUILD" "$SAMPLE" "$DB" 2>&1)"; echo "  ($OUT)"
[ -f "$DB" ] && ok "graph.db created" || { bad "graph.db created"; echo "$OUT"; exit 1; }

echo "== dependents (transitive impact) =="
same "$(printf 'py/app.py\npy/db.py\npy/test_app.py')" "$(Q dependents py/util.py)" "dependents py/util.py = app,db,test_app"

echo "== deps (transitive) =="
same "$(printf 'py/const.py\npy/db.py\npy/util.py')" "$(Q deps py/app.py)" "deps py/app.py = const,db,util"

echo "== tests (affected test files) =="
same "py/test_app.py" "$(Q tests py/util.py)" "tests py/util.py = test_app"
same "web/index.test.ts" "$(Q tests web/helpers.ts)" "tests web/helpers.ts = index.test"

echo "== affected (blast radius incl self) =="
A="$(Q affected web/helpers.ts)"
has "web/helpers.ts"     "$A" "affected includes self"
has "web/index.ts"       "$A" "affected includes importer index.ts"
has "web/widgets/button.tsx" "$A" "affected includes transitive button.tsx"
has "web/index.test.ts"  "$A" "affected includes covering test"

echo "== cycles =="
C="$(Q cycles 2>/dev/null)"
has "py/cyclic_a.py" "$C" "cycle detects cyclic_a"
has "py/cyclic_b.py" "$C" "cycle detects cyclic_b"
absent "py/util.py"  "$C" "util (acyclic) not flagged as cycle"

echo "== js/ts relative import resolution =="
same "web/helpers.ts" "$(Q deps web/widgets/button.tsx)" "button.tsx deps = helpers (../helpers)"

echo "== stats =="
Q stats | grep -q '^files=12$' && ok "stats files=12" || bad "stats files=12"
Q stats | grep -q '^test_files=2$' && ok "stats test_files=2" || bad "stats test_files=2"

echo "== unknown file is reported, not crashed =="
python3 "$QUERY" --db "$DB" dependents does/not/exist.py >/dev/null 2>&1 && ok "unknown file handled gracefully" || bad "unknown file handled gracefully"

echo "== regression: src/ layout absolute imports =="
R="$TMP/srclayout"; mkdir -p "$R/src/mypkg" "$R/tests"
printf 'def compute():\n    return 1\n' > "$R/src/mypkg/core.py"
touch "$R/src/mypkg/__init__.py"
printf 'from mypkg.core import compute\n' > "$R/tests/test_core.py"
DBS="$TMP/src.db"; python3 "$BUILD" "$R" "$DBS" >/dev/null 2>&1
python3 "$QUERY" --db "$DBS" dependents src/mypkg/core.py | grep -qx 'tests/test_core.py' \
  && ok "src/ layout: absolute import edge resolved" || bad "src/ layout: absolute import edge resolved"

echo "== regression: backslash path arg normalizes =="
python3 "$QUERY" --db "$DBS" dependents 'src\mypkg\core.py' 2>/dev/null | grep -qx 'tests/test_core.py' \
  && ok "backslash path resolves" || bad "backslash path resolves"

echo "== regression: root-level build/ pruned, nested build/ kept =="
R="$TMP/prune"; mkdir -p "$R/build" "$R/pkg/build"
printf 'x=1\n' > "$R/build/root_artifact.py"
printf 'def h():\n    return 1\n' > "$R/pkg/build/helper.py"
touch "$R/pkg/__init__.py" "$R/pkg/build/__init__.py"
DBP="$TMP/prune.db"; python3 "$BUILD" "$R" "$DBP" >/dev/null 2>&1
python3 "$QUERY" --db "$DBP" dependents build/root_artifact.py 2>&1 | grep -q 'not in graph: build/root_artifact.py' \
  && ok "root-level build/ pruned" || bad "root-level build/ pruned"
python3 "$QUERY" --db "$DBP" stats | grep -q '^files=3$' && ok "nested build/ kept (3 files, root artifact excluded)" || bad "nested build/ kept"

echo "== regression: JS comment/string/boundary false positives =="
R="$TMP/jsfp"; mkdir -p "$R"
cat > "$R/app.js" <<'EOF'
// import legacy from './commented.js'
const s = "import x from './stringed.js'";
myrequire('./nonboundary.js');
import real from './real.js';
EOF
for n in commented stringed nonboundary real; do printf 'export const v=1;\n' > "$R/$n.js"; done
DBJ="$TMP/js.db"; python3 "$BUILD" "$R" "$DBJ" >/dev/null 2>&1
DJS="$(python3 "$QUERY" --db "$DBJ" deps app.js)"
[ "$DJS" = "real.js" ] && ok "JS: only the real import edge" || { bad "JS false positives present"; echo "    got: $(echo "$DJS" | tr '\n' ' ')"; }

echo "== regression: tsconfig path-alias resolution =="
R="$TMP/tsalias"; mkdir -p "$R/src/app"
cat > "$R/tsconfig.json" <<'EOF'
{ "compilerOptions": { "baseUrl": ".", "paths": { "@app/*": ["src/app/*"] } } }
EOF
printf 'export const t=1;\n' > "$R/src/app/target.ts"
printf "import x from '@app/target';\n" > "$R/src/app/entry.ts"
DBT="$TMP/ts.db"; python3 "$BUILD" "$R" "$DBT" >/dev/null 2>&1
python3 "$QUERY" --db "$DBT" deps src/app/entry.ts | grep -qx 'src/app/target.ts' \
  && ok "tsconfig @alias resolved" || bad "tsconfig @alias resolved"

echo "== regression: cycles via SCC (3-cycle; acyclic dependent excluded) =="
R="$TMP/cyc"; mkdir -p "$R"
printf 'from .b import x\n' > "$R/a.py"; printf 'from .c import x\n' > "$R/b.py"
printf 'from .a import x\n' > "$R/c.py"; printf 'from .a import x\n' > "$R/d.py"
touch "$R/__init__.py"
DBC="$TMP/cyc.db"; python3 "$BUILD" "$R" "$DBC" >/dev/null 2>&1
CY="$(python3 "$QUERY" --db "$DBC" cycles 2>/dev/null)"
has "a.py" "$CY" "3-cycle: a"; has "b.py" "$CY" "3-cycle: b"; has "c.py" "$CY" "3-cycle: c"
absent "d.py" "$CY" "acyclic d not reported"

echo "== regression: build-graph refuses to clobber a directory =="
mkdir -p "$TMP/adir"
python3 "$BUILD" "$TMP/srclayout" "$TMP/adir" >/dev/null 2>&1 \
  && bad "should refuse a directory as db path" || ok "refuses directory as db path"

echo
echo "graph: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
