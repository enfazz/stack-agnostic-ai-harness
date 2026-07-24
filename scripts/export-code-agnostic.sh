#!/usr/bin/env bash
# export-code-agnostic.sh — optional cross-tool export.
#
# Mirrors the harness's base conventions and skills into a code-agnostic hub
# (https://github.com/dhvcc/code-agnostic) as rule/skill bundles, so the SAME
# content can be compiled into Codex / Cursor / Copilot / OpenCode layouts —
# making the harness genuinely tool-agnostic, not just Claude-native.
#
# Usage:  scripts/export-code-agnostic.sh [hub-dir]
#         (default hub: ~/.config/code-agnostic)
# Then:   code-agnostic plan && code-agnostic apply
#
# The export is one-way (harness repo -> hub). Re-run after harness updates.

set -euo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB="${1:-$HOME/.config/code-agnostic}"

echo "Exporting ai-harness -> code-agnostic hub at $HUB"

# --- base conventions as a rule bundle ---------------------------------------
RULE="$HUB/rules/ai-harness-base"
mkdir -p "$RULE"
cat > "$RULE/meta.yaml" <<'YAML'
name: ai-harness-base
description: Stack- and domain-agnostic engineering conventions from the ai-harness.
YAML
cp "$HARNESS/base/CLAUDE.base.md" "$RULE/prompt.md"
echo "  rule:  ai-harness-base"

# --- each skill as a skill bundle --------------------------------------------
for d in "$HARNESS"/skills/*/; do
  name="$(basename "$d")"
  [ -f "$d/SKILL.md" ] || continue
  SK="$HUB/skills/ai-harness-$name"
  mkdir -p "$SK"
  # description: from the SKILL.md frontmatter (first description: line)
  desc="$(grep -m1 '^description:' "$d/SKILL.md" | sed 's/^description:[[:space:]]*//')"
  printf 'name: ai-harness-%s\ndescription: %s\n' "$name" "${desc:-ai-harness skill}" > "$SK/meta.yaml"
  # prompt: the SKILL.md body without frontmatter
  awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2||fm==0{print}' "$d/SKILL.md" > "$SK/prompt.md"
  echo "  skill: ai-harness-$name"
done

echo
echo "Done. Review and compile with:"
echo "  code-agnostic validate && code-agnostic plan && code-agnostic apply"
echo "Note: Claude Code users don't need this — install the plugin directly."
