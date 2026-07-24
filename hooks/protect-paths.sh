#!/usr/bin/env bash
# PreToolUse (Edit|Write|MultiEdit|NotebookEdit): refuse to create or modify
# secret / credential files, regardless of project or stack.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_lib.sh"

harness_read_stdin
fp="$(harness_json file_path)"
# NotebookEdit uses notebook_path, not file_path.
[ -z "$fp" ] && fp="$(harness_json notebook_path)"
[ -z "$fp" ] && exit 0

# The guard-overrides file is HUMAN-ONLY — never editable by the agent.
if printf '%s' "$fp" | grep -Eq '(^|/)\.harness/guard-overrides\.conf$'; then
  harness_deny "the agent may not edit .harness/guard-overrides.conf — overrides are human-authored by design. Ask the user to add the rule."
fi

# Example/sample env templates are safe to author — they carry no real secrets.
if printf '%s' "$fp" | grep -Eiq '\.env\.(example|sample|template|dist|defaults?)$'; then
  exit 0
fi

# Known credential files, by name/extension (block always).
CRED_RE='(^|/)\.env($|\.|/)|(^|/)\.envrc$|(^|/)\.npmrc$|(^|/)\.netrc$|(^|/)\.pgpass$|(^|/)kubeconfig$|(^|/)\.kube/config$|\.tfstate(\.backup)?$|(^|/)\.(ssh|aws|gnupg)/|id_(rsa|ed25519|dsa)|\.(pem|p12|pfx|keystore)$|service[-_]?account[^/]*\.json$|(^|/)credentials(\.json)?$|(^|/)\.git-credentials$|\.key$'
if printf '%s' "$fp" | grep -Eiq "$CRED_RE"; then
  if harness_override allow-path "$fp"; then
    harness_audit "override-used" "allow-path matched for $fp"; exit 0
  fi
  harness_deny "writing a secret/credential file is not allowed: '$fp'. Secrets belong in a secret manager or an untracked, gitignored file created by a human — never authored or committed by the harness. (Known-safe test fixtures can be allow-listed by a HUMAN in .harness/guard-overrides.conf.)"
fi

# A 'secret(s)/' directory OFTEN holds credentials — but is also a common source
# or docs module name. Block only files there that are NOT obviously source/docs.
if printf '%s' "$fp" | grep -Eiq '(^|/)secrets?/'; then
  if ! printf '%s' "$fp" | grep -Eiq '\.(md|markdown|rst|txt|adoc|ts|tsx|js|jsx|mjs|cjs|py|pyi|go|rs|java|kt|kts|rb|php|cs|swift|scala|clj|ex|exs|c|h|cc|cpp|hpp|hs|html|css|scss|less|sh|bash|zsh|sql|proto|graphql|vue|svelte|toml|lock)$'; then
    if harness_override allow-path "$fp"; then
      harness_audit "override-used" "allow-path matched for $fp"; exit 0
    fi
    harness_deny "'$fp' is under a secrets/ directory and doesn't look like source or docs — refusing in case it holds credentials. A HUMAN can allow-list it in .harness/guard-overrides.conf."
  fi
fi

exit 0
