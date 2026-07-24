#!/usr/bin/env bash
# install.sh — copy-in installer for the AI harness (the no-plugin path).
#
# Vendors the harness conventions + stack detector into a target repo's
# `.harness/` directory and seeds a CLAUDE.md import + a permission profile.
# For the full, AI-driven adaptation, install the plugin instead and run
# `/ai-harness:adapt-repo` (see README).
#
# Usage:  scripts/install.sh <target-repo-path> [supervised|autonomous|readonly]

set -euo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?usage: install.sh <target-repo-path> [profile]}"
PROFILE="${2:-supervised}"

[ -d "$TARGET" ] || { echo "no such directory: $TARGET" >&2; exit 1; }
[ -f "$HARNESS/settings/settings.$PROFILE.json" ] || { echo "unknown profile: $PROFILE" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

echo "Installing AI harness into $TARGET (profile: $PROFILE)"

mkdir -p "$TARGET/.harness"
cp "$HARNESS/base/CLAUDE.base.md"      "$TARGET/.harness/CLAUDE.base.md"
cp "$HARNESS/scripts/detect-stack.sh"  "$TARGET/.harness/detect-stack.sh"
chmod +x "$TARGET/.harness/detect-stack.sh"

# Seed CLAUDE.md (don't clobber an existing one).
if [ ! -f "$TARGET/CLAUDE.md" ]; then
  printf '@.harness/CLAUDE.base.md\n\n## Project\n\n<!-- Run `/ai-harness:adapt-repo` (plugin) to fill this in from the detected stack. -->\n' \
    > "$TARGET/CLAUDE.md"
  echo "  created CLAUDE.md"
else
  echo "  CLAUDE.md exists — add '@.harness/CLAUDE.base.md' to its top if not already present"
fi

# Seed permission profile (don't clobber).
mkdir -p "$TARGET/.claude"
if [ ! -f "$TARGET/.claude/settings.json" ]; then
  cp "$HARNESS/settings/settings.$PROFILE.json" "$TARGET/.claude/settings.json"
  echo "  created .claude/settings.json ($PROFILE)"
else
  echo "  .claude/settings.json exists — merge $HARNESS/settings/settings.$PROFILE.json by hand"
fi

echo
echo "Detected stack:"
bash "$TARGET/.harness/detect-stack.sh" "$TARGET" || true
echo
echo "Done. Next: open Claude Code in the repo and run /ai-harness:adapt-repo for full wiring,"
echo "or /ai-harness:run-gate to verify the gate."
