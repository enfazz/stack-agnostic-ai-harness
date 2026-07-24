#!/usr/bin/env bash
# test-detect.sh — golden-fixture tests for scripts/detect-stack.sh
set -u
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT="$HARNESS/scripts/detect-stack.sh"
PASS=0; FAIL=0

expect() { # <label> <output> <regex-that-must-match>
  if printf '%s\n' "$2" | grep -Eq "$3"; then
    PASS=$((PASS+1)); echo "ok   $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL $1  (wanted /$3/)"
    printf '%s\n' "$2" | sed 's/^/       | /' | head -25
  fi
}

echo "== node-app =="
OUT="$(bash "$DETECT" "$HARNESS/fixtures/node-app")"
expect "node install"    "$OUT" '^harness\.install=npm ci$'
expect "node lint"       "$OUT" '^harness\.lint=npm run lint$'
expect "node typecheck"  "$OUT" '^harness\.typecheck=npm run typecheck$'
expect "node test"       "$OUT" '^harness\.test=npm run test$'
expect "node build"      "$OUT" '^harness\.build=npm run build$'
expect "node confidence" "$OUT" '^harness\.confidence=high$'

echo "== python-app =="
OUT="$(bash "$DETECT" "$HARNESS/fixtures/python-app")"
expect "py install (uv)" "$OUT" '^harness\.install=uv sync$'
expect "py lint (ruff)"  "$OUT" 'harness\.lint=.*ruff check'
expect "py type (mypy)"  "$OUT" 'harness\.typecheck=.*mypy'
expect "py test"         "$OUT" 'harness\.test=.*pytest -q'
expect "py confidence"   "$OUT" '^harness\.confidence=high$'

echo "== go-cli =="
OUT="$(bash "$DETECT" "$HARNESS/fixtures/go-cli")"
expect "go lint"         "$OUT" 'harness\.lint=go vet \./\.\.\.'
expect "go test"         "$OUT" '^harness\.test=go test \./\.\.\.$'
expect "go confidence"   "$OUT" '^harness\.confidence=high$'

echo "== empty dir (honest none) =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUT="$(bash "$DETECT" "$TMP")"
expect "empty languages"  "$OUT" 'Languages      : unknown'
expect "empty confidence" "$OUT" '^harness\.confidence=none$'
expect "empty warning"    "$OUT" 'WARNING.*proves nothing'

echo "== --json =="
OUT="$(bash "$DETECT" --json "$HARNESS/fixtures/node-app")"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['install']=='npm ci' and d['confidence']=='high'" 2>/dev/null; then
    PASS=$((PASS+1)); echo "ok   json parses + fields"
  else
    FAIL=$((FAIL+1)); echo "FAIL json parses + fields"; printf '%s\n' "$OUT" | head -20
  fi
fi

echo "== monorepo --roots =="
OUT="$(bash "$DETECT" --roots "$HARNESS/fixtures/monorepo")"
expect "roots web"       "$OUT" '^harness\.project=web$'
expect "roots api"       "$OUT" '^harness\.project=api$'
if printf '%s\n' "$OUT" | grep -Eq '^harness\.project=\.$'; then
  FAIL=$((FAIL+1)); echo "FAIL root itself must NOT be a project (no root marker)"
else
  PASS=$((PASS+1)); echo "ok   root not listed as project"
fi

echo "== monorepo --affected (temp git repo) =="
MONO="$TMP/mono"; mkdir -p "$MONO"
cp -r "$HARNESS/fixtures/monorepo/." "$MONO/"
git -C "$MONO" init -q
git -C "$MONO" -c user.email=t@t -c user.name=t add -A
git -C "$MONO" -c user.email=t@t -c user.name=t commit -qm init
echo "// change" >> "$MONO/web/index.js"
OUT="$(bash "$DETECT" --affected "$MONO")"
expect "affected web"     "$OUT" 'affected: web'
if printf '%s\n' "$OUT" | grep -q 'affected: api'; then
  FAIL=$((FAIL+1)); echo "FAIL api must not be affected (only web changed)"
else
  PASS=$((PASS+1)); echo "ok   api not affected"
fi
expect "affected web gate" "$OUT" '^harness\.web\.lint=npm run lint$'

echo "== regression: npm without lockfile => npm install (not npm ci) =="
NL="$TMP/nolock"; mkdir -p "$NL"; printf '{"scripts":{"test":"x"}}' > "$NL/package.json"
OUT="$(bash "$DETECT" "$NL")"
expect "no-lock => npm install" "$OUT" '^harness\.install=npm install$'

echo "== regression: dependency named 'lint' must NOT create a lint gate =="
DL="$TMP/deplint"; mkdir -p "$DL"; printf '{"scripts":{},"dependencies":{"lint":"^0.8.19"}}' > "$DL/package.json"
OUT="$(bash "$DETECT" "$DL")"
if printf '%s\n' "$OUT" | grep -q '^harness\.lint=npm run lint$'; then
  FAIL=$((FAIL+1)); echo "FAIL dep-named-lint wrongly produced a lint gate"
else PASS=$((PASS+1)); echo "ok   dep-named-lint => no phantom lint gate"; fi

echo "== node-app fixture now has a lockfile => npm ci =="
OUT="$(bash "$DETECT" "$HARNESS/fixtures/node-app")"
expect "fixture npm ci" "$OUT" '^harness\.install=npm ci$'

echo
echo "detect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
