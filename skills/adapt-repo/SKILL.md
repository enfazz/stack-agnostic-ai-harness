---
name: adapt-repo
description: Adapt the AI harness to THIS repository — inspect its stack, host, and conventions, then generate a tailored CLAUDE.md, permission settings, gate commands, and optional CI/CD. Use when the user says "adapt this harness/blueprint to this repo", "set up the harness here", "onboard this repository", or opens a fresh project with the harness installed.
argument-hint: "[supervised|autonomous|readonly] (default: supervised)"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

You are wiring the AI harness into the current repository so future sessions are
"ready to go". Work in the target repo's root. Be **non-destructive**: merge into
existing files, never clobber; if a file already has content, augment it.

Profile requested: `$ARGUMENTS` (default `supervised` if empty).

## Procedure

1. **Detect the stack.** Run the harness detector and read the report:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh"
   ```
   Note the `harness.install/lint/typecheck/test/build/docs`, `harness.host`,
   `harness.default_branch`, and `harness.confidence` values. If a value is
   empty, that step doesn't exist for this repo — skip it, don't invent it.
   If the report shows `harness.subproject=` lines this is a **monorepo**: run
   the detector once per sub-project (`--roots` lists them) and record each
   sub-project's gate in `CLAUDE.md`; tell future sessions to verify with
   `--affected` so only changed sub-projects run.

2. **Respect what's already here.** Read (if present): `README*`, `CONTRIBUTING*`,
   any existing `CLAUDE.md`/`AGENTS.md`/`.cursorrules`, lint/format/type configs,
   and the current CI. The repo's own rules win over the harness defaults —
   reference them, don't override them.

3. **Vendor the base conventions + detector.** Copy them into the repo so it is
   self-contained (works for teammates, CI, and without the plugin):
   ```
   mkdir -p .harness
   cp "${CLAUDE_PLUGIN_ROOT}/base/CLAUDE.base.md" .harness/CLAUDE.base.md
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh" .harness/detect-stack.sh
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/build-wiki.sh"   .harness/build-wiki.sh
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/build-graph.py"  .harness/build-graph.py
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/graph-query.py"  .harness/graph-query.py
   chmod +x .harness/detect-stack.sh .harness/build-wiki.sh .harness/*.py
   printf 'graph.db\n' >> .harness/.gitignore   # the graph is a generated snapshot, not source
   ```
   **Commit `.harness/` (the scripts)** — the `.harness/.gitignore` written above
   already excludes only the generated `graph.db`. Do NOT gitignore the whole
   `.harness/` dir: the wiki CI reads `.harness/build-wiki.sh` from the checkout,
   and teammates/no-plugin checkouts need the vendored scripts. (`build-wiki.sh`
   powers the wiki; `build-graph.py` + `graph-query.py` power `/ai-harness:impact`
   and file-level test selection in `run-gate`.)

4. **Write/merge `CLAUDE.md`** at repo root. If it exists, append a clearly
   marked harness section; otherwise create it. It must contain:
   - a first line importing the base conventions: `@.harness/CLAUDE.base.md`
   - a short **Project** section written from what you actually found: the stack,
     the **exact gate commands** from step 1, how to run the app/tests locally,
     the key directories, and the branch/PR policy (default: branch + PR; only
     push to `harness.default_branch` if the repo's own docs say so).
   Keep it under ~40 lines. Describe reality, not aspirations.

5. **Write/merge `.claude/settings.json`** from the requested profile:
   ```
   mkdir -p .claude
   # start from the profile, then add the detected gate commands to permissions.allow
   ```
   Base it on `${CLAUDE_PLUGIN_ROOT}/settings/settings.<profile>.json`. Add
   each non-empty detected gate command to `permissions.allow` (e.g. the install,
   lint, typecheck, test, build commands) so the gate runs without prompts. Keep
   the profile's `deny` list (secrets, destructive infra) intact. If a
   `.claude/settings.json` already exists, merge — union the allow lists, keep
   existing `defaultMode` unless the user asked to change it.

6. **Attribution.** Ensure agent-authored commits are attributable: note in
   `CLAUDE.md` the co-author trailer to append to commit messages. Do not change
   the user's global git identity.

6b. **Guard overrides (only if needed).** If the repo legitimately tracks files
   the secret guard would block (e.g. `fixtures/*.pem` test certificates),
   explain that a **human** must create `.harness/guard-overrides.conf` with
   `allow-path <glob>` / `allow-secret <regex>` lines — the agent is
   deliberately unable to write that file.

7. **Verify.** Run `/ai-harness:run-gate` once. Adaptation is complete only if the
   gate passes (or you clearly report why it can't — e.g. notebooks/IaC that the
   generic gate can't verify).

8. **Offer CI.** If `harness.host` is known and the repo lacks Claude CI, offer to
   run `/ai-harness:setup-cicd`. Don't add it silently.

## Output

Summarize exactly which files you created or merged, the detected gate commands,
the profile applied, and the gate result. **Do not commit** — leave everything
staged-or-unstaged for the user to review, unless they explicitly ask you to
commit and open a PR (then use `/ai-harness:ship-change`).
