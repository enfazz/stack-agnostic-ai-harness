---
name: impact
description: Answer structural questions about the codebase from a dependency graph — what depends on a file (blast radius), what a file depends on, which tests cover a change, import cycles, and dead/orphan files. Use before changing shared code, when scoping a change, or when the user asks "what breaks if I change X", "what uses X", "what tests cover X". Builds a fresh SQLite graph so answers are never stale.
argument-hint: "[dependents|deps|affected|tests|cycles|orphans <file...>]  (default: impact of the current change)"
allowed-tools: Read, Grep, Glob, Bash
---

You answer impact/structure questions precisely from a **file + import
dependency graph**, instead of guessing from grep. Requires `python3` (stdlib
only — no external packages or services).

## Procedure

1. **Build a fresh graph** (parsing is cheap; rebuilding each time avoids
   staleness). Prefer the vendored copy so it works without the plugin:
   ```
   GB=.harness/build-graph.py; [ -f "$GB" ] || GB="${CLAUDE_PLUGIN_ROOT}/scripts/build-graph.py"
   GQ=.harness/graph-query.py; [ -f "$GQ" ] || GQ="${CLAUDE_PLUGIN_ROOT}/scripts/graph-query.py"
   mkdir -p .harness
   python3 "$GB" . .harness/graph.db
   ```
   Then query with `python3 "$GQ" --db .harness/graph.db <subcommand> ...`.
   The graph indexes Python (via `ast`, accurate) and JS/TS (via regex) files;
   only intra-repo import edges are recorded. Other languages get file nodes but
   no edges yet — say so if the repo is mostly another stack.

2. **Answer the question** with `graph-query.py` (db = `.harness/graph.db`):
   - `dependents <file>` — everything that (transitively) imports it = the blast
     radius of changing it.
   - `deps <file>` — everything it imports.
   - `affected <file...>` — dependents + the files themselves.
   - `tests <file...>` — the affected files that are tests (what to re-run).
   - `cycles` — files in an import cycle.
   - `orphans` — non-test files nothing imports (dead-code candidates).
   If `$ARGUMENTS` names a subcommand, run it. If empty, treat the **current
   change** as the target: `tests`/`affected` on the changed files
   (`git diff --name-only` + staged + untracked).

3. **Report** the result as a short list, and translate it into action: e.g.
   "changing `X` affects these 3 modules and is covered by these 2 tests — run
   `/ai-harness:run-gate` which will scope to them," or "these files are in an
   import cycle," or "`orphans` suggests dead code — confirm before deleting."

Be honest about the graph's limits: JS/TS resolution is regex-based (approximate
for dynamic requires/aliases); dynamic languages can have edges it can't see.
Treat it as a strong hint that sharpens context, not as proof — the gate still
decides "done".
