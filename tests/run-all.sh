#!/usr/bin/env bash
# run-all.sh — the harness's own gate. Run before every commit to this repo.
set -u
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
HAVE_PY=1; command -v python3 >/dev/null 2>&1 || HAVE_PY=0

echo "### JSON manifests valid"
if [ "$HAVE_PY" = 1 ]; then
  for f in "$HARNESS"/.claude-plugin/plugin.json "$HARNESS"/.claude-plugin/marketplace.json \
           "$HARNESS"/hooks/hooks.json "$HARNESS"/settings/*.json; do
    if python3 -c "import json;json.load(open('$f'))" 2>/dev/null; then echo "ok   ${f#"$HARNESS"/}"
    else echo "FAIL ${f#"$HARNESS"/} is not valid JSON"; FAIL=1; fi
  done
else
  echo "SKIP python3 unavailable (JSON validation, frontmatter, py_compile, graph tests all skipped)"
fi

echo
echo "### Skill & agent frontmatter"
if [ "$HAVE_PY" = 1 ]; then
python3 - "$HARNESS" <<'PY' || FAIL=1
import re, glob, sys
root = sys.argv[1]; bad = 0
for f in sorted(glob.glob(f'{root}/skills/*/SKILL.md') + glob.glob(f'{root}/agents/*.md')):
    t = open(f).read()
    m = re.match(r'^---\n(.*?)\n---\n', t, re.S)
    rel = f[len(root)+1:]
    if not m or 'description:' not in m.group(1):
        print(f'FAIL {rel} — missing frontmatter or description'); bad = 1
    else:
        print(f'ok   {rel}')
sys.exit(bad)
PY
fi

echo
echo "### Convention invariants (harness rules baked into base/CLAUDE.base.md)"
if grep -q '^## No AI co-author trailers' "$HARNESS/base/CLAUDE.base.md"; then echo "ok   base forbids AI co-author trailers"; else echo "FAIL base missing no-co-author-trailers rule"; FAIL=1; fi
if grep -qi 'update docs before you push' "$HARNESS/base/CLAUDE.base.md"; then echo "ok   base requires docs-update-before-push"; else echo "FAIL base missing docs-before-push rule"; FAIL=1; fi
if grep -rIlq 'trailer the harness configures\|repo.s co-author trailer\|co-author trailer to append' "$HARNESS/base" "$HARNESS/skills" "$HARNESS/agents" 2>/dev/null; then
  echo "FAIL a rule still instructs ADDING a co-author trailer"; FAIL=1
else echo "ok   no rule instructs adding a co-author trailer"; fi
if grep -qi 'user-triggered only' "$HARNESS/base/CLAUDE.base.md"; then echo "ok   base gates push/PR to explicit user input"; else echo "FAIL base missing push/PR user-triggered rule"; FAIL=1; fi
if [ "$HAVE_PY" = 1 ]; then
  if python3 - "$HARNESS" <<'PY'
import json, sys, glob, os
root = sys.argv[1]; bad = 0
for f in glob.glob(f"{root}/settings/settings.*.json"):
    perm = json.load(open(f)).get("permissions", {})
    if "Bash(git push*)" not in perm.get("ask", []):
        print("   missing push ask-gate in", os.path.basename(f)); bad = 1
    if any("git push" in a for a in perm.get("allow", [])):
        print("   push is auto-allowed in", os.path.basename(f)); bad = 1
sys.exit(bad)
PY
  then echo "ok   push/PR-create require a prompt in every profile (never auto-allowed)"
  else echo "FAIL a profile auto-allows push or lacks the push ask-gate"; FAIL=1; fi
fi

echo
echo "### Shell syntax (bash -n)"
for f in "$HARNESS"/scripts/*.sh "$HARNESS"/hooks/*.sh "$HARNESS"/tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then echo "ok   ${f#"$HARNESS"/}"
  else echo "FAIL ${f#"$HARNESS"/} has syntax errors"; FAIL=1; fi
done

echo
echo "### Python syntax (py_compile)"
if command -v python3 >/dev/null 2>&1; then
  for f in "$HARNESS"/scripts/*.py; do
    if python3 -m py_compile "$f" 2>/dev/null; then echo "ok   ${f#"$HARNESS"/}"
    else echo "FAIL ${f#"$HARNESS"/} has syntax errors"; FAIL=1; fi
  done
else
  echo "SKIP python3 not available (graph scripts unchecked)"
fi

echo
echo "### Detector fixture tests"
bash "$HARNESS/tests/test-detect.sh" || FAIL=1

echo
echo "### Hook payload tests"
bash "$HARNESS/tests/test-hooks.sh" || FAIL=1

echo
echo "### Wiki tests (build-wiki + detection + guard exception)"
bash "$HARNESS/tests/test-wiki.sh" || FAIL=1

echo
echo "### Graph tests (dependency graph + impact queries)"
bash "$HARNESS/tests/test-graph.sh" || FAIL=1

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL SUITES GREEN"; else echo "SUITES FAILED"; fi
exit "$FAIL"
