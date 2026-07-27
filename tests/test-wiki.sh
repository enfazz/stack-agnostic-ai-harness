#!/usr/bin/env bash
# test-wiki.sh — tests for build-wiki.sh, wiki detection, and the guard's
# wiki-push exception.
set -u
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT="$HARNESS/scripts/detect-stack.sh"
BUILD="$HARNESS/scripts/build-wiki.sh"
GB="$HARNESS/hooks/guard-bash.sh"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HARNESS_AUDIT_LOG="$TMP/audit.jsonl"

ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
have() { [ -f "$1" ] && ok "$2" || bad "$2 (missing $1)"; }
bashp(){ printf '{"tool_input":{"command":"%s"}}' "$1"; }
blocks(){ printf '%s' "$(bashp "$1")" | bash "$GB" >/dev/null 2>&1; [ $? -eq 2 ] && ok "$2" || bad "$2 (expected block)"; }
allows(){ printf '%s' "$(bashp "$1")" | bash "$GB" >/dev/null 2>&1; [ $? -eq 0 ] && ok "$2" || bad "$2 (expected allow)"; }

echo "== build-wiki.sh compiles docs -> wiki pages =="
W="$TMP/wiki"; mkdir -p "$W"; git -C "$W" init -q
OUT="$(bash "$BUILD" "$HARNESS/fixtures/docs-site/docs" "$W" 2>&1)"
echo "  ($OUT)"
have "$W/Home.md"          "README -> Home page"
have "$W/getting-started.md" "getting-started page"
have "$W/configuration.md" "configuration page"
have "$W/_Sidebar.md"      "_Sidebar generated"
# link rewrite: .md stripped, README -> Home
if grep -q '(configuration)' "$W/getting-started.md" && ! grep -q 'configuration.md' "$W/getting-started.md"; then
  ok "intra-doc link rewritten (configuration.md -> configuration)"
else bad "intra-doc link rewritten"; fi
grep -q '(Home)' "$W/getting-started.md" && ok "README link -> Home" || bad "README link -> Home"
grep -q '(getting-started#install)' "$W/configuration.md" && ok "fragment preserved" || bad "fragment preserved"
grep -q '\[\[getting-started\]\]' "$W/_Sidebar.md" && ok "sidebar lists pages" || bad "sidebar lists pages"

echo "== build-wiki.sh regenerates (stale pages cleared) =="
echo "# stale" > "$W/old-page.md"
bash "$BUILD" "$HARNESS/fixtures/docs-site/docs" "$W" >/dev/null 2>&1
[ ! -f "$W/old-page.md" ] && ok "stale page removed on re-run" || bad "stale page removed on re-run"

echo "== detector emits wiki_url + wiki_source =="
R="$TMP/repo"; mkdir -p "$R/docs"; git -C "$R" init -q
git -C "$R" remote add origin https://github.com/acme/widget.git
printf '# Guide\n' > "$R/docs/guide.md"
OUT="$(bash "$DETECT" "$R")"
printf '%s\n' "$OUT" | grep -qx 'harness.wiki_url=https://github.com/acme/widget.wiki.git' \
  && ok "wiki_url derived from origin" || { bad "wiki_url derived"; printf '%s\n' "$OUT" | grep wiki; }
printf '%s\n' "$OUT" | grep -qx 'harness.wiki_source=docs' && ok "wiki_source=docs" || bad "wiki_source=docs"

echo "== detector: non-github host has no wiki_url =="
R2="$TMP/repo2"; mkdir -p "$R2/docs"; git -C "$R2" init -q
git -C "$R2" remote add origin https://bitbucket.org/acme/widget.git
printf '# x\n' > "$R2/docs/x.md"
OUT="$(bash "$DETECT" "$R2")"
printf '%s\n' "$OUT" | grep -qx 'harness.wiki_url=' && ok "no wiki_url for bitbucket" || bad "no wiki_url for bitbucket"

echo "== guard: wiki push exception (vs normal shared-branch block) =="
allows  'git push https://github.com/acme/widget.wiki.git HEAD:master' "push to wiki .wiki.git allowed"
allows  'git push git@github.com:acme/widget.wiki.git master'          "push to wiki (ssh) allowed"
allows  'git push https://github.com/acme/widget.wiki.git HEAD:main'   "push to wiki (main default) allowed"
blocks  'git push origin master'                                       "push to normal master blocked"
blocks  'git push origin main'                                         "push to normal main blocked"
allows  'git push origin feature/x'                                    "push to feature branch allowed"
blocks  'git push origin master # x/y.wiki.git'                        "comment bare-token cannot fake exemption"

echo "== build-wiki.sh rewrites query-string links =="
QD="$TMP/qd/docs"; QW="$TMP/qw"; mkdir -p "$QD" "$QW"; git -C "$QW" init -q
printf '# A\n\nSee [b](configuration.md?v=2#install).\n' > "$QD/a.md"
printf '# Configuration\n' > "$QD/configuration.md"
bash "$BUILD" "$QD" "$QW" >/dev/null 2>&1
grep -q '(configuration#install)' "$QW/a.md" && ok "query-string link rewritten" || bad "query-string link rewritten"

echo
echo "wiki: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
