@base/CLAUDE.base.md

## Project

This repo **is** the AI harness itself (the plugin's source) — not a consumer of
it. There is no `.harness/` vendor copy here: `base/CLAUDE.base.md` and
`scripts/*` above are the canonical originals, so this file imports the root
copy directly rather than duplicating it.

- **Stack**: plain Bash + Python 3 stdlib + Markdown/JSON. No package manager,
  no lint/typecheck/build step — `scripts/detect-stack.sh` correctly reports
  `confidence=none` for this repo; that is expected, not a gap.
- **Gate** (run before every commit): `bash tests/run-all.sh` — validates JSON
  manifests (`.claude-plugin/*.json`, `hooks/hooks.json`, `settings/*.json`),
  skill/agent frontmatter, convention invariants baked into
  `base/CLAUDE.base.md`, the stack detector (`tests/test-detect.sh`), the
  dependency graph builder (`tests/test-graph.sh`), the safety hooks
  (`tests/test-hooks.sh`), and the wiki compiler (`tests/test-wiki.sh`).
- **`fixtures/`** holds golden fixture repos (`node-app`, `python-app`,
  `go-cli`, `monorepo/*`) that `tests/test-detect.sh` runs the detector
  against — they are test data, not sub-projects of this repo. Ignore
  `detect-stack.sh --roots` monorepo output here.
- **Key directories**: `base/` (conventions imported into target repos),
  `skills/` + `agents/` (the plugin's Claude Code skills/subagents),
  `hooks/` (safety guards), `settings/` (permission profiles), `scripts/`
  (detector, wiki builder, graph tools, copy-in installer), `ci-templates/`
  (pipelines this harness generates for *other* repos), `docs/ARCHITECTURE.md`.
- **Branch/PR policy**: branch + PR, per the base convention — never push
  directly to `main`.

## Commit hygiene

Commits use the human's git identity with clear, human-style messages —
**no AI co-author trailers** (`Co-Authored-By: Claude`/`Codex`/etc. or
"Generated with" lines). This is also enforced as a convention invariant in
`tests/run-all.sh`.
