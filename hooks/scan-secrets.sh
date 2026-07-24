#!/usr/bin/env bash
# scan-secrets.sh — scan a diff for leaked credentials before commit/push.
#
# The real leak control: the filename guard (protect-paths.sh) cannot catch a
# key PASTED INTO SOURCE — this scans diff content.
#
# Usage:
#   scan-secrets.sh --staged      scan the staged diff (pre-commit)
#   scan-secrets.sh --outgoing    scan commits about to be pushed (pre-push)
#   scan-secrets.sh <file>        scan one file's content
#
# Engine: gitleaks when installed (staged AND outgoing), plus a built-in pass on
# added lines. High-confidence token shapes always flag; a generic
# name=value heuristic flags only when the value doesn't look like a placeholder.
# Human overrides: `allow-secret <regex>` in .harness/guard-overrides.conf.
#
# Exit: 0 clean · 1 findings (caller converts to a deny).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_lib.sh"

MODE="${1:---staged}"

added_lines() {
  case "$MODE" in
    --staged) git diff --staged -U0 --no-color 2>/dev/null ;;
    --outgoing)
      local range=""
      if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        range='@{upstream}..HEAD'
      else
        local def
        def="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@')"
        if [ -n "$def" ] && git merge-base "$def" HEAD >/dev/null 2>&1; then
          range="$(git merge-base "$def" HEAD)..HEAD"
        fi
      fi
      if [ -n "$range" ]; then git diff -U0 --no-color "$range" 2>/dev/null
      else git show -U0 --no-color HEAD 2>/dev/null; fi ;;
    *) [ -f "$MODE" ] && sed 's/^/+/' "$MODE" ;;
  esac | grep -E '^\+' | grep -Ev '^\+\+\+' || true
}

# gitleaks (when present) — staged uses `protect`, outgoing scans the diff.
GITLEAKS_HIT=0
if command -v gitleaks >/dev/null 2>&1; then
  case "$MODE" in
    --staged)   gitleaks protect --staged --redact --no-banner >/dev/null 2>&1 || GITLEAKS_HIT=1 ;;
    --outgoing) added_lines | gitleaks detect --pipe --redact --no-banner >/dev/null 2>&1 || GITLEAKS_HIT=1 ;;
  esac
fi

# High-confidence token shapes — always flag (real credential formats).
HIGH='-----BEGIN [A-Z ]*PRIVATE KEY
AKIA[0-9A-Z]{16}
(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{30,}
glpat-[A-Za-z0-9_-]{20,}
xox[baprs]-[A-Za-z0-9-]{10,}
AIza[0-9A-Za-z_-]{35}
sk-ant-[A-Za-z0-9_-]{20,}
sk-proj-[A-Za-z0-9_-]{20,}
eyJ[A-Za-z0-9_/+-]{17,}\.eyJ[A-Za-z0-9_/+-]{17,}'

# Generic name=value assignment — flag only when the value is NOT a placeholder.
GENERIC='(password|passwd|secret|token|api[_-]?key|access[_-]?key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_/+=.-]{16,}["'"'"']'
PLACEHOLDER='your[_-]|change[_-]?me|replace|example|placeholder|xxxx|dummy|insecure|sample|fake|foobar|redacted|todo|<[a-z_]+>|\.\.\.|test[_-]|env\.|os\.getenv|process\.env|getenv|\$\{'

FINDINGS=""
flag() { # <label> <line>
  harness_override allow-secret "$2" && return 0
  FINDINGS="${FINDINGS}  ${1}  line: $(printf '%s' "$2" | cut -c1-46)«redacted»\n"
}
while IFS= read -r line; do
  [ -z "$line" ] && continue
  hit=""
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    printf '%s' "$line" | grep -Eq "$pat" 2>/dev/null && { hit="high:${pat%% *}"; break; }
  done <<< "$HIGH"
  if [ -z "$hit" ] && printf '%s' "$line" | grep -Eiq "$GENERIC" 2>/dev/null; then
    printf '%s' "$line" | grep -Eiq "$PLACEHOLDER" 2>/dev/null || hit="generic:name=value"
  fi
  [ -n "$hit" ] && flag "pattern: $hit" "$line"
done < <(added_lines)

if [ "$GITLEAKS_HIT" = 1 ] || [ -n "$FINDINGS" ]; then
  echo "Potential secrets detected in the diff ($MODE):"
  [ "$GITLEAKS_HIT" = 1 ] && echo "  gitleaks: findings (run 'gitleaks protect --staged -v' for detail)"
  [ -n "$FINDINGS" ] && printf '%b' "$FINDINGS"
  echo "If this is a FALSE POSITIVE (dummy/test value), a HUMAN may add an"
  echo "'allow-secret <regex>' line to .harness/guard-overrides.conf and retry."
  exit 1
fi
exit 0
