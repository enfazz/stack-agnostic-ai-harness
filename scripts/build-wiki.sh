#!/usr/bin/env bash
# build-wiki.sh — compile an in-repo docs directory into GitHub/GitLab wiki
# pages. Used by the sync-wiki skill and the wiki CI template so both share one
# implementation. The in-repo source stays authoritative; the wiki is generated.
#
# Usage:  build-wiki.sh <source-docs-dir> <wiki-checkout-dir>
#
# Behavior:
#   - Each <source>/**/*.md becomes a flat wiki page named by its basename
#     (README/index/home -> Home). Basenames must be unique across the source.
#   - Intra-doc links `](path/name.md?query#frag)` are rewritten to wiki links
#     `](name#frag)`; links to README/index become `](Home)`. (Note: rewriting
#     is line-based and not code-fence aware — a literal markdown link shown
#     inside a ``` code block is also rewritten. Keep example links out of fences
#     if that matters.)
#   - Generates _Sidebar.md listing all pages, and a Home page if the source has
#     no README/index.
#   - Old *.md at the wiki root are cleared first, so the source is the source of
#     truth (the wiki's .git is preserved).

set -u

SRC="${1:?usage: build-wiki.sh <source-docs-dir> <wiki-checkout-dir>}"
WIKI="${2:?usage: build-wiki.sh <source-docs-dir> <wiki-checkout-dir>}"
[ -d "$SRC" ]  || { echo "source dir not found: $SRC"  >&2; exit 1; }
[ -d "$WIKI" ] || { echo "wiki dir not found: $WIKI"   >&2; exit 1; }

page_name() { # <relpath> -> wiki page base name
  local b; b="$(basename "$1")"; b="${b%.md}"
  case "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" in
    readme|index|home) echo "Home" ;;
    *)                 echo "$b" ;;
  esac
}

# Clear previously generated pages (keep .git and any non-.md assets).
find "$WIKI" -maxdepth 1 -type f -name '*.md' -delete 2>/dev/null

pages=""; home_set=0; collisions=""
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  base="$(basename "$rel")"
  [ "$base" = ".md" ] && { echo "WARNING: skipping source file named '.md' ($rel)" >&2; continue; }
  name="$(page_name "$rel")"
  out="$WIKI/$name.md"
  [ -e "$out" ] && collisions="${collisions}${name} "
  [ "$name" = "Home" ] && home_set=1
  # Rewrite intra-doc links to wiki page names (strip dir + .md, keep ?query#frag),
  # then map README/index links to Home. `@` delimiter avoids the `#` in the
  # fragment group; two passes avoid the non-portable `I` flag.
  sed -E 's@\]\(([^)#?]*/)?([^)/#?]+)\.md(\?[^)#]*)?(#[^)]*)?\)@](\2\4)@g' "$f" \
    | sed -E 's@\]\((README|readme|Readme|index|Index|INDEX)\)@](Home)@g' > "$out"
  pages="${pages}${name}\n"
done < <(find "$SRC" -type f -name '*.md' \
           -not -path '*/node_modules/*' -not -path '*/.git/*' \
           -not -path '*/dist/*' -not -path '*/build/*' -print0 | sort -z)

[ -z "$pages" ] && { echo "no markdown found under $SRC" >&2; exit 1; }
upages="$(printf '%b' "$pages" | sort -u)"

# _Sidebar.md (Home first, then the rest alphabetically).
{
  echo "## Pages"
  echo "$upages" | grep -qx "Home" && echo "* [[Home]]"
  printf '%s\n' "$upages" | while IFS= read -r p; do
    [ -n "$p" ] && [ "$p" != "Home" ] && echo "* [[$p]]"
  done
} > "$WIKI/_Sidebar.md"

# Ensure a Home page exists.
if [ "$home_set" = 0 ]; then
  {
    echo "# Home"
    echo
    echo "Documentation index (generated from \`$SRC\`)."
    echo
    printf '%s\n' "$upages" | while IFS= read -r p; do
      [ -n "$p" ] && echo "* [[$p]]"
    done
  } > "$WIKI/Home.md"
fi

echo "wiki: $(printf '%s\n' "$upages" | grep -c .) page(s) + _Sidebar$([ "$home_set" = 0 ] && echo ' + generated Home')"
[ -n "$collisions" ] && echo "WARNING: duplicate page basenames overwrote each other: $collisions(rename the source files to be unique)" >&2
exit 0
