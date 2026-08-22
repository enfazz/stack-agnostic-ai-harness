# Getting started

Three ways to put the harness into a repository — pick one.

## 1. As a Claude Code plugin (recommended)

Install once; its skills, subagents, and safety hooks then appear in *every*
project you open in Claude Code.

```bash
/plugin marketplace add enfazz/stack-agnostic-ai-harness
/plugin install ai-harness@ai-harness
```

## 2. As a directive

No install step — inside any repo, just tell the agent:

> adapt this harness to this repository

It runs the same wiring the `adapt-repo` skill below does.

## 3. As a copy-in (no plugin)

Vendors the conventions + detector into a target repo's `.harness/` directory
directly, without installing anything into Claude Code:

```bash
scripts/install.sh /path/to/your/repo supervised
```

## First run, inside a target repo

```
/ai-harness:adapt-repo          # inspect the stack → wire CLAUDE.md, permissions, gate commands
/ai-harness:run-gate            # verify: install → lint → typecheck → test → build
```

`adapt-repo` reads what's already there (README, CONTRIBUTING, an existing
CLAUDE.md/AGENTS.md, lint/type configs, current CI) and never overrides it —
the repo's own rules always win over the harness defaults. It writes:

- `CLAUDE.md` — imports `base/CLAUDE.base.md` (stack-agnostic conventions) plus
  a short project section with the real, detected gate commands.
- `.claude/settings.json` — a permission profile (see below) with the
  detected gate commands allowlisted so they run without prompts.
- `.harness/` — a vendored, self-contained copy of the conventions + detector
  scripts, so the setup works for teammates and CI even without the plugin.

## Permission profiles

Pick the autonomy level per repo — `adapt-repo` applies one, and it can be
changed later by editing `.claude/settings.json`:

| Profile | What it allows |
| --- | --- |
| `readonly` | Read/inspect only — no edits, no commits. |
| `supervised` (default) | Edits, commits, and gate commands run without prompts; `git push` and PR/MR creation still ask for confirmation. |
| `autonomous` | Widest allowlist for unattended runs; the same hard denies (secrets, force-push, destructive infra) still apply. |

Push and PR/MR creation are **never** auto-allowed in any profile — see the
"Safety model" section in [../README.md](../README.md) for the full guardrail
list.

## Day-to-day workflow

```
/ai-harness:plan-change "#42"   # triage an issue into a reviewed plan first — no code written yet
/ai-harness:ship-change "..."   # implement → test → doc → gate → branch → PR
/ai-harness:review-pr 123       # structured review of a PR/MR (never auto-merges)
/ai-harness:impact src/auth.py  # blast radius + covering tests, before you change something shared
/ai-harness:sync-wiki           # publish docs/ to the repo's GitHub/GitLab wiki
```

See [SKILLS.md](SKILLS.md) for the full reference of every skill and agent,
and [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and why.
