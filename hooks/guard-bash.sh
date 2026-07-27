#!/usr/bin/env bash
# PreToolUse (Bash): block irreversible / history-rewriting / secret-exfil
# commands, enforce the kill switch, and scan diffs for secrets on commit/push.
#
# This is FRICTION for a confused or careless agent, not a sandbox for a
# determined adversary (see README threat model). Three normalizations keep it
# honest: (1) quote-stripping so text in a -m message/echo can't trip matchers;
# (2) comment-stripping so a trailing `# ...` can't smuggle tokens past a gate;
# (3) command-position matching so `echo git push -f` (a string) isn't a push.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_lib.sh"

harness_read_stdin
cmd="$(harness_json command)"
[ -z "$cmd" ] && exit 0

# Strip quoted spans, then shell comments (# at start or after whitespace).
scmd="$(printf '%s' "$cmd" | sed "s/'[^']*'//g" | sed 's/"[^"]*"//g' | sed -E 's/(^|[[:space:]])#.*$/\1/')"

# cmd_has <ERE>: matches at a COMMAND position (start or after a ; | & separator,
# allowing a leading env/sudo/nice prefix). `echo git push` does NOT match.
cmd_has() {
  printf '%s' "$scmd" | grep -Eq "(^|[;&|])[[:space:]]*([a-z_]+=[^[:space:]]*[[:space:]]+|env[[:space:]][^;&|]*[[:space:]]+|sudo[[:space:]]+|nice[[:space:]]+)*$1"
}
# B = a token boundary that also treats command separators and EOL as the end.
B='([[:space:];&|]|$)'

# 0a. Guard-file tamper protection — first, cannot be overridden. Any command
#     referencing guard-overrides.conf that is not a pure read is denied.
if printf '%s' "$cmd" | grep -q 'guard-overrides\.conf'; then
  if ! printf '%s' "$cmd" | grep -Eq '^[[:space:]]*(cat|less|more|head|tail|grep|egrep|fgrep|rg|bat|view|wc|git[[:space:]]+(diff|status|log|show))([[:space:]]|$)' \
     || printf '%s' "$cmd" | grep -Eq '(>>?|[[:space:]]tee[[:space:]])'; then
    harness_deny "modifying .harness/guard-overrides.conf via shell is not allowed — overrides are human-authored by design (only reading it is permitted)."
  fi
fi

# 0b. Kill switch: HARNESS_DISABLED halts all outbound writes machine-wide.
if [ -n "${HARNESS_DISABLED:-}" ]; then
  if cmd_has 'git[[:space:]]+([^;&|]*[[:space:]])?push' || cmd_has 'gh[[:space:]]+pr[[:space:]]+(create|merge)' || cmd_has 'glab[[:space:]]+mr[[:space:]]+(create|merge)'; then
    harness_deny "kill switch active (HARNESS_DISABLED is set) — no pushes or PR/MR creation until a human unsets it."
  fi
fi

# 0c. Human-authored command overrides (cannot bypass 0a/0b above).
if harness_override allow-command "$cmd"; then
  harness_audit "override-used" "allow-command matched: $cmd"
  exit 0
fi

# 1. git push safety (only when git push is an actual command).
if cmd_has 'git[[:space:]]+([^;&|]*[[:space:]])?push'; then
  if printf '%s' "$scmd" | grep -Eq -- "(--force([^-]|$)|[[:space:]]-f$B)" \
     && ! printf '%s' "$scmd" | grep -Eq -- '--force-with-lease'; then
    harness_deny "force-pushing rewrites shared history. Use '--force-with-lease' on your own branch, or open a PR instead."
  fi
  if printf '%s' "$scmd" | grep -Eq 'push[^|;&]*[[:space:]]\+[^[:space:]]'; then
    harness_deny "the '+refspec' form force-updates a remote ref (rewrites history). Push a normal ref or open a PR."
  fi
  if printf '%s' "$scmd" | grep -Eq -- '(push[^|;&]*[[:space:]]:[^[:space:]]|--delete)'; then
    harness_deny "deleting a remote branch is irreversible. Do this by hand if you're sure."
  fi
  # A wiki (<repo>.wiki.git, pushed by URL) has no PR flow — exempt its default
  # branch. Require an actual URL form (scheme or git@), not a bare token, and
  # note comments were already stripped, so a trailing `# ...wiki.git` can't lie.
  is_wiki=0
  printf '%s' "$scmd" | grep -Eq '(https?://|git@|ssh://)[^[:space:]]*\.wiki\.git' && is_wiki=1
  if [ "$is_wiki" = 0 ] && printf '%s' "$scmd" | grep -Eq "push[^|;&]*[[:space:]](\+?([^[:space:]]*:)?(main|master|develop|trunk))$B"; then
    harness_deny "pushing straight to a shared branch (main/master/develop/trunk) is off by default — open a PR, or a human can allow it with 'allow-command' in .harness/guard-overrides.conf."
  fi
fi
cmd_has 'git[[:space:]]+filter-branch' && harness_deny "history rewriting (filter-branch) is destructive; not run by the harness."
cmd_has 'git[[:space:]]+filter-repo'   && harness_deny "history rewriting (filter-repo) is destructive; not run by the harness."

# 2. Catastrophic recursive delete of a root / home / wildcard path.
if cmd_has 'rm[[:space:]]' \
   && printf '%s' "$scmd" | grep -Eq 'rm[[:space:]]([^|;&]*[[:space:]])?(-[[:alnum:]]*r[[:alnum:]]*|--recursive)' \
   && printf '%s' "$scmd" | grep -Eq "[[:space:]](--[[:space:]]+)?(/|~|\\\$HOME|\\\$\{HOME\})/?\*?$B"; then
  harness_deny "refusing a recursive delete against a root/home/wildcard path."
fi

# 3. Reading / copying / exfiltrating secret files (reader at command position,
#    secret path referenced anywhere in the command).
if cmd_has '(cat|less|more|head|tail|bat|xxd|od|hexdump|strings|base64|printenv|env|grep|egrep|fgrep|rg|awk|sed|cut|sort|uniq|tr|cp|mv|rsync|scp|tar|zip|gzip|curl|wget|nc|python|python3|perl|ruby|node|dd)[[:space:]]' \
   && printf '%s' "$scmd" | grep -Eiq "(\.env([[:space:]./;&|]|\$)|(^|/)\.envrc$B|id_(rsa|ed25519|dsa)|\.pem$B|service[-_]?account[^[:space:]]*\.json|(^|/)credentials|\.ssh/|\.aws/credentials|(^|/)\.npmrc|(^|/)\.netrc|(^|/)\.pgpass|\.tfstate)"; then
  if ! printf '%s' "$scmd" | grep -Eiq "\.env\.(example|sample|template|dist|defaults?)$B"; then
    harness_deny "reading, copying, or archiving a secret/credential file is not allowed. If a human needs it, they can access it directly."
  fi
fi

# 4. Secret scan on commit / push — content-level, catches keys pasted into
#    source that the filename guard cannot see.
if cmd_has 'git[[:space:]]+([^;&|]*[[:space:]])?commit'; then
  if ! out="$(bash "$DIR/scan-secrets.sh" --staged 2>&1)"; then
    harness_deny "secret scan failed on the staged diff:
$out"
  fi
  harness_audit "commit" "$cmd"
fi
if cmd_has 'git[[:space:]]+([^;&|]*[[:space:]])?push'; then
  if ! out="$(bash "$DIR/scan-secrets.sh" --outgoing 2>&1)"; then
    harness_deny "secret scan failed on outgoing commits:
$out"
  fi
  harness_audit "push" "$cmd"
fi

exit 0
