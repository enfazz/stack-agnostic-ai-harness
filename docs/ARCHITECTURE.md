# Architecture

The harness has five layers. Each is independent — you can use the conventions
without the autonomy, or the skills without CI.

```
┌── Conventions ─────────────────────────────────────────────┐
│  base/CLAUDE.base.md  — universal engineering rules,        │
│  imported into each repo's CLAUDE.md by adapt-repo.         │
├── Detection ───────────────────────────────────────────────┤
│  scripts/detect-stack.sh — maps marker files → gate         │
│  commands + host + default branch + confidence + wiki.      │
│  Monorepo-aware: --roots lists sub-projects, --affected     │
│  maps changed files → only the gates that matter.           │
├── Execution ───────────────────────────────────────────────┤
│  skills/  (procedures)      agents/  (delegated specialists)│
│  adapt-repo · run-gate ·    code-reviewer · gate-runner ·   │
│  plan-change · write-tests ·  test-author · docs-writer     │
│  write-docs · setup-cicd ·                                  │
│  ship-change · review-pr ·                                  │
│  sync-wiki (build-wiki.sh) · impact (build-graph.py)        │
├── Guardrails & autonomy ───────────────────────────────────┤
│  hooks/  (always-on, deterministic):                        │
│    protect-paths · guard-bash · scan-secrets · stop-gate    │
│    + audit log · kill switch · human-only overrides         │
│  settings/  (readonly | supervised | autonomous profiles)   │
│  ci-templates/ (GitHub/GitLab/Bitbucket gate + @claude +    │
│                 wiki publisher)                             │
├── Self-verification ───────────────────────────────────────┤
│  fixtures/ (golden repos) + tests/run-all.sh, run in the    │
│  harness's own CI — the harness eats its own gate.          │
└─────────────────────────────────────────────────────────────┘
```

## Why these shapes

**Detection is a script, not a prompt.** Stack detection must be deterministic
and reusable from both skills and CI, so it lives in `detect-stack.sh` and emits
machine-parseable `harness.*` lines. Adding a language means editing one file.

**Skills are procedures; agents are personas.** A skill is an on-demand workflow
that runs in the main context (`run-gate`, `adapt-repo`). An agent is a separate
context you delegate to when you want isolation (a `code-reviewer` that reads a
big diff without flooding the main transcript). `ship-change` composes both.

**The gate is split.** The Stop hook does *not* run tests — installing deps and
running a suite on every turn is too slow and often needs services that aren't
present. The hook is a non-blocking nudge; `run-gate` is the mechanical gate
(with a `--cheap` lint+typecheck mode for fast loops and a full mode for "done");
CI is the authoritative gate where infra exists. Nothing silently downgrades a
red or missing gate to "passed".

**Guards are hooks, not vibes.** Secret-write blocking, destructive-git blocking,
and secret-read blocking are `PreToolUse` hooks that fail closed (exit 2)
regardless of the model's intent or the permission profile. Profiles tune
*autonomy*; hooks enforce *safety*. The `code-reviewer` subagent is granted only
Read/Grep/Glob (no Bash, no network), so code it reviews cannot be exfiltrated;
`gate-runner`/`test-author`/`docs-writer` need Bash to run the repo's own tools.
The guards are **friction for a confused or careless agent, not a sandbox for a
determined adversary** — they match command *shapes*, which a deliberately
evasive actor can work around.

**Secrets are scanned by content, not just filename.** `scan-secrets.sh` runs on
every `git commit` (staged diff) and `git push` (outgoing range): built-in
patterns on both, plus gitleaks when installed. High-confidence token shapes
(AWS/GitHub/GitLab/Slack/Google/Anthropic keys, private-key headers, JWTs)
always flag; a generic `name=value` heuristic flags long token-shaped values but
skips obvious placeholders. This is the control that catches a key pasted into
source.

**Operations are observable and stoppable.** Every deny, commit, and push is
audited as JSONL (`~/.ai-harness/audit.jsonl`, override via
`HARNESS_AUDIT_LOG`). Setting `HARNESS_DISABLED=1` blocks all outbound writes
(push / PR / MR) machine-wide — the kill switch for a misbehaving unattended run.

**Exceptions require a human.** `.harness/guard-overrides.conf`
(`allow-path` / `allow-command` / `allow-secret` lines) relaxes a guard for a
specific repo — but the agent cannot create or edit that file: the write is
denied in the hooks (before any override lookup) *and* in every settings
profile. Overrides can never bypass the tamper check or the kill switch.

**Config is vendored into the target repo.** `adapt-repo` copies
`CLAUDE.base.md`, `detect-stack.sh`, and `build-wiki.sh` into the repo's
`.harness/` and imports the conventions from `CLAUDE.md`, so they travel with the
repo and work for teammates and CI even without the plugin installed (the wiki CI
calls `.harness/build-wiki.sh`).

**The dependency graph is rebuilt, not cached.** `build-graph.py` indexes files
+ intra-repo import edges into SQLite (`ast` for Python, regex for JS/TS; Python
stdlib only). The `impact` skill and `run-gate`'s file-level test selection
rebuild it on use — parsing is cheap and a fresh graph can't go stale, which is
the failure mode that makes a code graph worse than none. It's advisory (sharpens
context
and impact analysis); the gate, not the graph, decides "done", so an approximate
JS/TS graph can't cause a bad merge. `.harness/graph.db` is generated and
gitignored; the two scripts are vendored + committed.

**The wiki is a generated mirror, not a source.** A wiki lives in a separate
`<repo>.wiki.git` repo with no PR flow. `build-wiki.sh` compiles the in-repo docs
into flat pages (one implementation shared by the `sync-wiki` skill and the wiki
CI); the source docs stay authoritative. Because a wiki has no pull requests, a
push to a `.wiki.git` remote's default branch is the one case exempted from the
PR-by-default guard — detected by the remote URL shape, not by branch name.

## Extending

- **Add a language/stack:** add a detection block to `scripts/detect-stack.sh`
  that sets `INSTALL/LINT/TYPECHECK/TEST/BUILD` for its marker files, plus a
  fixture under `fixtures/` and assertions in `tests/test-detect.sh`. Every
  skill and CI template picks it up automatically.
- **Add a skill:** create `skills/<name>/SKILL.md` with a `description` (the
  keywords Claude matches on) and a numbered procedure. It becomes
  `/ai-harness:<name>`.
- **Add a guard:** add a `PreToolUse` matcher + script in `hooks/`, register it in
  `hooks/hooks.json`, have it `harness_deny` on the dangerous shape, and add
  payload cases to `tests/test-hooks.sh`.
- **Add a secret pattern:** append to `PATTERNS` in `hooks/scan-secrets.sh` (and
  a runtime-generated case in `tests/test-hooks.sh` — never commit a real-shaped
  key, even a fake one).
- **Tune autonomy:** edit or add a profile in `settings/`; `adapt-repo` applies it
  and unions in the repo's detected gate commands.
- **Other editors:** `scripts/export-code-agnostic.sh` mirrors rules/skills into
  a code-agnostic hub for Codex / Cursor / Copilot compilation.

## Non-goals

- It does not manage secrets, deploy, or apply infrastructure — those stay with a
  human and are explicitly denied by default.
- It does not hardcode any project, host, or per-repo risk policy — the safety
  model is universal guardrails, and autonomy is chosen per repo via the profile.
