#!/usr/bin/env bash
# Stop: user-facing reminder shown in the transcript. If the working tree has
# uncommitted changes, it nudges toward the gate + PR discipline.
#
# NOTE ON MECHANICS: for a Stop hook, exit 0 does NOT feed anything back to the
# model — this message is for the human reading the transcript (printed to
# stderr, which the transcript surfaces). It intentionally does not block. The
# real, model-facing gate is the /ai-harness:run-gate skill, invoked as part of
# "done". Do not rely on this hook to stop the model.
set -euo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "ai-harness reminder: uncommitted changes present. Run /ai-harness:run-gate before calling this done; commit in coherent units; open a PR rather than pushing to a shared branch." >&2
fi

# --- Enforcing mode (opt-in) --------------------------------------------------
# To make the gate model-facing and mandatory, replace the block above with a
# version that emits blocking JSON, guarded against loops via stop_hook_active:
#
#   input="$(cat)"
#   echo "$input" | grep -q '"stop_hook_active":true' && exit 0
#   if [ -n "$(git status --porcelain)" ]; then
#     # run YOUR cheap lint/typecheck here (e.g. from .harness/detect-stack.sh's
#     # harness.lint / harness.typecheck) into /tmp/harness-gate.log, then:
#     printf '{"decision":"block","reason":"Gate not green — fix before finishing."}'
#   fi
# (There is no scripts/gate.sh; wire it to the commands the detector reports.)

exit 0
