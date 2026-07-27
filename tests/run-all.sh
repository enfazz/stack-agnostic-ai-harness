#!/usr/bin/env bash
# run-all.sh — the harness's own gate. Run before every commit to this repo.
set -u
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "### JSON manifests valid"
for f in "$HARNESS"/.claude-plugin/plugin.json "$HARNESS"/.claude-plugin/marketplace.json \
         "$HARNESS"/hooks/hooks.json "$HARNESS"/settings/*.json; do
  if python3 -c "import json;json.load(open('$f'))" 2>/dev/null; then echo "ok   ${f#"$HARNESS"/}"
  else echo "FAIL ${f#"$HARNESS"/} is not valid JSON"; FAIL=1; fi
done

echo
echo "### Skill & agent frontmatter"
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
