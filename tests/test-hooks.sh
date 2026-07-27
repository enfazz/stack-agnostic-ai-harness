#!/usr/bin/env bash
# test-hooks.sh — payload-level tests for the safety hooks.
# Each case pipes a synthetic tool-call JSON into a hook and asserts the exit:
# exit 2 = BLOCK, exit 0 = allow. Secret-scan cases run in throwaway git repos
# (fake keys are generated at runtime, never committed to the harness repo).
set -u
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PP="$HARNESS/hooks/protect-paths.sh"
GB="$HARNESS/hooks/guard-bash.sh"
SS="$HARNESS/hooks/scan-secrets.sh"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HARNESS_AUDIT_LOG="$TMP/audit.jsonl"   # keep test noise out of ~

check() { # <hook> <payload> <expected: block|allow> <label>
  printf '%s' "$2" | bash "$1" >/dev/null 2>&1
  local ec=$?
  local got="allow"; [ "$ec" -eq 2 ] && got="block"
  if [ "$got" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $4"
  else FAIL=$((FAIL+1)); echo "FAIL $4 (expected $3, got $got, exit $ec)"; fi
}
edit()  { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
bashp() { printf '{"tool_input":{"command":"%s"}}' "$1"; }

echo "== protect-paths =="
check "$PP" "$(edit .env)"                                 block "write .env"
check "$PP" "$(edit config/service-account-prod.json)"     block "write service-account json"
check "$PP" "$(edit deploy/tls.pem)"                       block "write .pem"
check "$PP" "$(edit .env.example)"                         allow "write .env.example"
check "$PP" "$(edit config/.env.template)"                 allow "write .env.template"
check "$PP" "$(edit src/app/main.ts)"                      allow "write normal source"
check "$PP" "$(edit .harness/guard-overrides.conf)"        block "agent edits its own guard file"

echo "== guard-bash: git safety =="
check "$GB" "$(bashp 'git push --force origin main')"      block "force push"
check "$GB" "$(bashp 'git push --force-with-lease origin feat/x')" allow "force-with-lease"
check "$GB" "$(bashp 'git push origin :old-branch')"       block "delete remote branch"
check "$GB" "$(bashp 'git filter-branch --tree-filter x')" block "filter-branch"
check "$GB" "$(bashp 'rm -rf ~')"                          block "rm -rf ~"
check "$GB" "$(bashp 'rm -rf /')"                          block "rm -rf /"
check "$GB" "$(bashp 'rm -rf node_modules')"               allow "rm -rf node_modules"
check "$GB" "$(bashp 'cat .env')"                          block "cat .env"
check "$GB" "$(bashp 'cat .env.example')"                  allow "cat .env.example"
check "$GB" "$(bashp 'npm test')"                          allow "npm test"

echo "== guard-bash: tamper + kill switch =="
check "$GB" "$(bashp 'echo x >> .harness/guard-overrides.conf')" block "append to guard file"
check "$GB" "$(bashp 'sed -i s/a/b/ .harness/guard-overrides.conf')" block "sed -i guard file"
check "$GB" "$(bashp 'cat .harness/guard-overrides.conf')" allow "reading guard file is fine"
HARNESS_DISABLED=1 bash -c "printf '%s' '$(bashp 'git push origin feat/x')' | bash '$GB'" >/dev/null 2>&1
[ $? -eq 2 ] && { PASS=$((PASS+1)); echo "ok   kill switch blocks push"; } || { FAIL=$((FAIL+1)); echo "FAIL kill switch blocks push"; }
HARNESS_DISABLED=1 bash -c "printf '%s' '$(bashp 'git status')' | bash '$GB'" >/dev/null 2>&1
[ $? -eq 0 ] && { PASS=$((PASS+1)); echo "ok   kill switch leaves reads alone"; } || { FAIL=$((FAIL+1)); echo "FAIL kill switch leaves reads alone"; }

echo "== scan-secrets (throwaway repos, fake keys built at runtime) =="
# fake AWS example key, assembled so it never sits in this file verbatim
FAKE_AWS="AKIA""IOSFODNN7EXAMPLE"
R1="$TMP/leak"; mkdir -p "$R1"; git -C "$R1" init -q
printf 'aws_key = "%s"\n' "$FAKE_AWS" > "$R1/config.py"
git -C "$R1" add -A
( cd "$R1" && bash "$SS" --staged >/dev/null 2>&1 )
[ $? -ne 0 ] && { PASS=$((PASS+1)); echo "ok   staged AWS key detected"; } || { FAIL=$((FAIL+1)); echo "FAIL staged AWS key detected"; }

R2="$TMP/clean"; mkdir -p "$R2"; git -C "$R2" init -q
printf 'def add(a, b):\n    return a + b\n' > "$R2/lib.py"
git -C "$R2" add -A
( cd "$R2" && bash "$SS" --staged >/dev/null 2>&1 )
[ $? -eq 0 ] && { PASS=$((PASS+1)); echo "ok   clean diff passes"; } || { FAIL=$((FAIL+1)); echo "FAIL clean diff passes"; }

# human-authored override lets a known-fake value through
mkdir -p "$R1/.harness"
printf 'allow-secret %s\n' "$FAKE_AWS" > "$R1/.harness/guard-overrides.conf"
( cd "$R1" && bash "$SS" --staged >/dev/null 2>&1 )
[ $? -eq 0 ] && { PASS=$((PASS+1)); echo "ok   allow-secret override honored"; } || { FAIL=$((FAIL+1)); echo "FAIL allow-secret override honored"; }

# guard-bash wires the scan into `git commit`
( cd "$R1" && rm .harness/guard-overrides.conf && printf '%s' "$(bashp 'git commit -m leak')" | bash "$GB" >/dev/null 2>&1 )
[ $? -eq 2 ] && { PASS=$((PASS+1)); echo "ok   commit with staged key blocked"; } || { FAIL=$((FAIL+1)); echo "FAIL commit with staged key blocked"; }

echo "== overrides: allow-path =="
R3="$TMP/fixrepo"; mkdir -p "$R3/.harness"; git -C "$R3" init -q
printf 'allow-path fixtures/*.pem\n' > "$R3/.harness/guard-overrides.conf"
( cd "$R3" && printf '%s' "$(edit fixtures/test-cert.pem)" | bash "$PP" >/dev/null 2>&1 )
[ $? -eq 0 ] && { PASS=$((PASS+1)); echo "ok   allow-path lets fixture .pem through"; } || { FAIL=$((FAIL+1)); echo "FAIL allow-path lets fixture .pem through"; }
( cd "$R3" && printf '%s' "$(edit prod/real.pem)" | bash "$PP" >/dev/null 2>&1 )
[ $? -eq 2 ] && { PASS=$((PASS+1)); echo "ok   non-matching .pem still blocked"; } || { FAIL=$((FAIL+1)); echo "FAIL non-matching .pem still blocked"; }

echo "== regression: expanded path protection =="
check "$PP" "$(edit .envrc)"                          block "write .envrc"
check "$PP" "$(edit infra/terraform.tfstate)"         block "write terraform.tfstate"
check "$PP" "$(edit .npmrc)"                           block "write .npmrc"
check "$PP" "$(edit docs/secrets/overview.md)"        allow "docs under secrets/ (source/doc)"
check "$PP" "$(edit internal/secrets/manager.go)"     allow "go module under secrets/"
check "$PP" "$(edit secrets/prod.json)"               block "credential-ish file under secrets/"
check "$PP" '{"tool_input":{"notebook_path":".env"}}' block "NotebookEdit .env via notebook_path"

echo "== regression: force-push false positives + new bypasses =="
check "$GB" "$(bashp 'git commit -m \"note: never git push --force here\"')" allow "commit msg mentioning force-push"
check "$GB" "$(bashp 'echo git push -f origin main')"      allow "echo mentioning force-push"
check "$GB" "$(bashp 'git push origin +main:main')"        block "+refspec force push"
check "$GB" "$(bashp 'rm --recursive --force /')"          block "rm --recursive --force /"

echo "== regression: PR-by-default (push to shared branch) =="
check "$GB" "$(bashp 'git push origin main')"              block "push to main"
check "$GB" "$(bashp 'git push origin master')"            block "push to master"
check "$GB" "$(bashp 'git push origin feature/x')"         allow "push to feature branch"
check "$GB" "$(bashp 'git push origin maintenance')"       allow "push to 'maintenance' (not main)"
# separator-boundary evasion (a ; or && right after the branch name)
check "$GB" "$(bashp 'git push origin master;:')"          block "push to master; (separator evasion)"
check "$GB" "$(bashp 'git push origin master&&echo hi')"   block "push to master&& (separator evasion)"
# comment cannot smuggle the wiki exemption onto a normal repo push
check "$GB" "$(bashp 'git push origin master # x/y.wiki.git')" block "comment cannot fake wiki exemption"

echo "== regression: broadened secret-read/exfil coverage =="
check "$GB" "$(bashp 'grep SECRET .env')"                  block "grep .env"
check "$GB" "$(bashp 'cp .env /tmp/x')"                    block "cp .env"
check "$GB" "$(bashp 'tar czf /tmp/e.tgz .env')"           block "tar .env"
check "$GB" "$(bashp 'grep KEY .env.example')"             allow "grep .env.example"

echo "== regression: guard-file tamper via interpreters =="
check "$GB" "$(bashp 'python3 -c open(.harness/guard-overrides.conf,w)')" block "python writes guard file"
check "$GB" "$(bashp 'ln -sf /tmp/evil .harness/guard-overrides.conf')"    block "symlink over guard file"
check "$GB" "$(bashp 'grep allow .harness/guard-overrides.conf')"          allow "grep reads guard file"

echo "== regression: scan-secrets placeholder tolerance =="
R5="$TMP/placeholder"; mkdir -p "$R5"; git -C "$R5" init -q
printf 'SECRET_KEY = "django-insecure-changeme-please-replace-000000"\n' > "$R5/settings.py"
git -C "$R5" add -A
( cd "$R5" && bash "$SS" --staged >/dev/null 2>&1 )
[ $? -eq 0 ] && { PASS=$((PASS+1)); echo "ok   placeholder secret not flagged"; } || { FAIL=$((FAIL+1)); echo "FAIL placeholder secret not flagged"; }

echo "== audit log =="
[ -s "$HARNESS_AUDIT_LOG" ] && { PASS=$((PASS+1)); echo "ok   audit log written ($(wc -l < "$HARNESS_AUDIT_LOG") events)"; } || { FAIL=$((FAIL+1)); echo "FAIL audit log written"; }

echo
echo "hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
