#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit|NotebookEdit): keep the dependency graph warm.
#
# NO-OP unless a graph already exists in this repo (.harness/graph.db) — repos
# that don't use the graph pay nothing. When a graph does exist, this refreshes
# it INCREMENTALLY (only changed files are re-parsed) in the BACKGROUND, so it
# never adds latency to an edit and never fails the tool. A single-flight lock
# collapses a burst of edits into one refresh. The graph is also rebuilt on use
# by /ai-harness:impact and run-gate, so this hook is an optimization, not a
# correctness dependency.
#
# Test/foreground mode: set AI_HARNESS_REFRESH_SYNC=1 to run synchronously.
set -u

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -f "$root/.harness/graph.db" ] || exit 0          # graph not in use here -> nothing to do
command -v python3 >/dev/null 2>&1 || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GB="$root/.harness/build-graph.py"                  # vendored copy first
[ -f "$GB" ] || GB="$DIR/../scripts/build-graph.py" # else the plugin's copy
[ -f "$GB" ] || exit 0

# Single-flight lock in the system temp dir (keyed by repo path) — no repo churn.
key="$(printf '%s' "$root" | cksum | tr -cd '0-9')"
lock="${TMPDIR:-/tmp}/ai-harness-graph-${key}.lock"
# Clear a genuinely stale lock (a refresh that died long ago). The threshold is
# far above any plausible build time so a live build's lock is never reclaimed.
[ -d "$lock" ] && find "$lock" -maxdepth 0 -mmin +30 -exec rmdir {} + 2>/dev/null

mkdir "$lock" 2>/dev/null || exit 0                 # a refresh is already in flight -> skip

if [ -n "${AI_HARNESS_REFRESH_SYNC:-}" ]; then
  python3 "$GB" "$root" "$root/.harness/graph.db" >/dev/null 2>&1
  rmdir "$lock" 2>/dev/null
else
  GB="$GB" ROOT="$root" LOCK="$lock" nohup bash -c \
    'python3 "$GB" "$ROOT" "$ROOT/.harness/graph.db" >/dev/null 2>&1; rmdir "$LOCK" 2>/dev/null' \
    >/dev/null 2>&1 &
fi
exit 0
