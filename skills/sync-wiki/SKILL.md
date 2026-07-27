---
name: sync-wiki
description: Publish the repo's in-repo docs to its GitHub or GitLab wiki — compile a docs directory into wiki pages (Home, sidebar, rewritten links) and push to the <repo>.wiki.git repository. Use when the user asks to "update/sync/publish the wiki", or after docs change in a repo whose wiki is in use. The in-repo docs stay the source of truth; the wiki is generated, never hand-edited.
argument-hint: "[source docs dir; default: docs]"
allowed-tools: Read, Grep, Glob, Bash
---

You are publishing in-repo documentation to the project's wiki. The wiki is a
SEPARATE git repo (`<repo>.wiki.git`); you regenerate it from the source, you
never edit wiki pages by hand.

## Procedure

1. **Detect host + wiki URL.** Run the detector:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh"
   ```
   Read `harness.host`, `harness.wiki_url`, and `harness.wiki_source`. Wikis are
   supported on **GitHub and GitLab** (both use `<repo>.wiki.git`); for any other
   host, stop and say wiki sync isn't supported there.

2. **Pick the source dir.** Use `$ARGUMENTS` if given, else `harness.wiki_source`
   (default `docs`). Confirm it contains Markdown. If the repo has no docs to
   publish, stop and say so.

3. **Clone the wiki.** Into a temp dir:
   ```
   git clone "<wiki_url>" /tmp/ai-harness-wiki.$$ 2>&1
   ```
   If the clone fails with "repository not found", the wiki hasn't been
   initialized yet — tell the user to create it once (open the repo's **Wiki**
   tab on GitHub/GitLab and save any first page), then re-run. Don't try to
   create the wiki repo yourself.

4. **Compile.** Regenerate the pages from the source:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/build-wiki.sh" <source-dir> /tmp/ai-harness-wiki.$$
   ```
   Heed any duplicate-basename warning (wiki pages are flat — rename colliding
   source files). Optionally show a `git -C /tmp/ai-harness-wiki.$$ status` diff
   so the user sees what will change.

5. **Publish.** Commit and push **with the explicit wiki URL** (the harness guard
   recognizes a `.wiki.git` URL and allows the push to its default branch — wikis
   have no PR flow). Push to the branch you actually cloned, not a hardcoded name
   (GitHub wikis default to `master`, modern GitLab wikis to `main`):
   ```
   cd /tmp/ai-harness-wiki.$$
   DEF="$(git symbolic-ref --short HEAD 2>/dev/null || echo master)"   # the wiki's default branch
   git add -A
   git commit -m "Sync wiki from <source-dir>"     # no AI co-author trailer
   git push "<wiki_url>" "HEAD:$DEF"
   ```
   The secret scan still runs on this push — do not let credentials reach the
   wiki either.

6. **Clean up** the temp clone and **report**: the wiki URL, how many pages were
   published, and any renames the user should make for colliding basenames.

Never hand-author or commit wiki content that isn't generated from the in-repo
source. If the user wants a wiki-only page, tell them to add it to the source
docs so it stays version-controlled and reviewable.
