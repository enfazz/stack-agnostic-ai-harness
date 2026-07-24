#!/usr/bin/env bash
# Shared helpers for ai-harness hooks. Hooks receive the event as JSON on stdin.

harness_read_stdin() { HARNESS_INPUT="$(cat)"; }

# harness_json <leaf-key-under-tool_input>  -> prints the value or empty
harness_json() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$HARNESS_INPUT" | jq -r ".tool_input.${key} // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$HARNESS_INPUT" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print(d.get('tool_input',{}).get('$key','') or '')
except Exception:
    pass" 2>/dev/null
  else
    printf '%s' "$HARNESS_INPUT" \
      | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
      | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"
  fi
}

# harness_audit <event> <detail>
# Appends one JSONL line to the audit log (default ~/.ai-harness/audit.jsonl,
# override with HARNESS_AUDIT_LOG). Never fails the caller.
harness_audit() {
  local log="${HARNESS_AUDIT_LOG:-$HOME/.ai-harness/audit.jsonl}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  local repo detail
  repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  detail="$(printf '%s' "$2" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"ts":"%s","repo":"%s","event":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo" "$1" "$detail" >> "$log" 2>/dev/null || true
}

# harness_deny <message>  -> block the tool call (exit 2) with feedback to Claude
harness_deny() {
  harness_audit "deny" "$1"
  printf '🛑 ai-harness blocked this: %s\n' "$1" >&2
  exit 2
}

# harness_override <type> <target>  -> 0 if a human-authored override matches.
# Overrides live in <repo>/.harness/guard-overrides.conf, one rule per line:
#   allow-path <glob>        e.g.  allow-path fixtures/*.pem
#   allow-command <glob>     e.g.  allow-command git push --force origin sandbox-*
#   allow-secret <regex>     e.g.  allow-secret EXAMPLE_KEY_[A-Z]+
# The file is HUMAN-ONLY: the harness refuses to write it (see protect-paths /
# guard-bash tamper checks), so every override implies human review.
harness_override() {
  local type="$1" target="$2" conf line pat
  conf="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.harness/guard-overrides.conf"
  [ -f "$conf" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "#"*|"") continue ;;
      "$type "*) pat="${line#"$type" }" ;;
      *) continue ;;
    esac
    if [ "$type" = "allow-secret" ]; then
      printf '%s' "$target" | grep -Eq "$pat" 2>/dev/null && return 0
    else
      # shellcheck disable=SC2254  # unquoted $pat is intentional: glob match
      case "$target" in $pat) return 0 ;; esac
    fi
  done < "$conf"
  return 1
}
