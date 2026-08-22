# Contributing

Thanks for looking at improving the harness. It's a small, stack-agnostic
toolkit (plain Bash + Python 3 stdlib + Markdown/JSON) — no build step, no
package manager, no dependencies to install.

## Making a change

1. Branch off `main`: `git switch -c <type>/<slug>` (e.g. `fix/…`, `feat/…`,
   `docs/…`). Never commit directly to `main`.
2. Make the smallest correct change. Touch only what the task needs — no
   drive-by reformatting of unrelated files.
3. Run the gate (below) until it's green.
4. Open a pull request. PRs are reviewed by a human before merge; nothing in
   this repo auto-merges.

## Running the gate

```bash
bash tests/run-all.sh
```

This is the repo's whole verification story — there's no separate
install/lint/typecheck/build step. It checks:

- `.claude-plugin/*.json`, `hooks/hooks.json`, and `settings/*.json` are valid
  JSON.
- Every `skills/*/SKILL.md` and `agents/*.md` has frontmatter with a
  `description`.
- Convention invariants baked into `base/CLAUDE.base.md` (no AI co-author
  trailers, docs-before-push, push/PR gated to explicit user input) haven't
  regressed.
- `tests/test-detect.sh` — `scripts/detect-stack.sh` against the golden
  fixtures under `fixtures/*`.
- `tests/test-graph.sh` — `scripts/build-graph.py` / `graph-query.py`.
- `tests/test-hooks.sh` — the safety guards in `hooks/`.
- `tests/test-wiki.sh` — `scripts/build-wiki.sh`.

`fixtures/*` (`node-app`, `python-app`, `go-cli`, `monorepo/*`) are golden test
data for the detector, not sub-projects of this repo — don't try to gate them
individually.

## Extending the harness

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#extending) for the full
rationale. In short:

- **Add a language/stack** — a detection block in `scripts/detect-stack.sh`
  (marker files → `INSTALL/LINT/TYPECHECK/TEST/BUILD`), a fixture under
  `fixtures/`, and assertions in `tests/test-detect.sh`.
- **Add a skill** — `skills/<name>/SKILL.md` with a `description` (the
  keywords Claude matches on) and a numbered procedure; it becomes
  `/ai-harness:<name>`.
- **Add a guard** — a `PreToolUse` matcher + script in `hooks/`, registered in
  `hooks/hooks.json`, that `harness_deny`s the dangerous shape, plus cases in
  `tests/test-hooks.sh`.
- **Add a secret pattern** — append to `PATTERNS` in `hooks/scan-secrets.sh`
  and add a runtime-generated test case (never commit a real-shaped key, even
  a fake one).
- **Tune autonomy** — edit or add a profile under `settings/`.

## Commit conventions

Commit under your own git identity with a clear, human-style message. **Never
add an AI co-author trailer** (`Co-Authored-By: Claude`/`Codex`/etc. or a
"Generated with" line) — this rule is load-bearing enough that
`tests/run-all.sh` asserts it's still documented in `base/CLAUDE.base.md` (it
doesn't scan commit messages themselves, so this is on you at review time).

## License

By contributing, you agree your changes are licensed under this repo's
[MIT License](LICENSE).
