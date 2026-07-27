# Stack- & domain-agnostic AI harness

A portable engineering harness you **plug into any repository** — any language,
any domain — so an AI coding agent can contribute code, tests, docs, and CI/CD
with **minimal involvement from you**, behind guardrails that hold everywhere.

## Purpose

AI agents are capable but need the same things in every repo: the project's
conventions loaded, a reliable way to verify their own work, and hard limits on
what they must never do. Setting that up by hand, per repo, per stack, is the
work that never gets done — so agents run under-informed and under-guarded.

This repo packages that setup **once**, as reusable and stack-neutral. Point it
at a Node app, a Python service, a Go CLI, or a Rust crate and it behaves the
same: detect the stack, wire the conventions, run the real gate, and open a
reviewed PR. Nothing is hardcoded to a language, host, or project.

It is a standalone repo that works three ways:

1. **As a Claude Code plugin** — install once; its skills, subagents, and safety
   hooks appear in *every* project on your machine.
2. **As a directive** — tell the agent *"adapt this harness to this repository"*
   and it inspects the stack and wires everything up.
3. **As a copy-in** — a shell installer vendors the conventions + detector into a
   repo's `.harness/` directory, no plugin required.

## Works with subscription *and* API agents

The harness is **auth-agnostic**. The skills, subagents, and hooks run inside any
Claude Code session regardless of how you signed in — a **Claude Pro / Max / Team
subscription** (like this one) or an **Anthropic API key**. Nothing in the harness
requires an API key.

That distinction only matters for the *unattended* CI responder
(`ci-templates/github/claude.yml`), where you choose the auth once:

| Your plan | Secret to add | How to get it |
| --- | --- | --- |
| Claude subscription | `CLAUDE_CODE_OAUTH_TOKEN` | run `claude setup-token` locally |
| Anthropic API | `ANTHROPIC_API_KEY` | from the Anthropic console |

## Quick start (plugin)

```bash
# In Claude Code — add this repo as a marketplace and install the plugin:
/plugin marketplace add enfazz/stack-agnostic-ai-harness
/plugin install ai-harness@ai-harness
```

Then, inside any project you want to work on:

```
/ai-harness:adapt-repo          # inspect stack → wire CLAUDE.md, settings, gate
/ai-harness:run-gate            # verify: install → lint → typecheck → test → build
/ai-harness:plan-change "#42"   # triage an issue into a reviewed plan first
/ai-harness:ship-change "..."   # implement → test → doc → gate → branch → PR
/ai-harness:review-pr 123       # structured review of a PR/MR (never auto-merges)
/ai-harness:sync-wiki           # publish docs/ to the repo's GitHub/GitLab wiki
/ai-harness:impact src/auth.py  # what depends on this? what tests cover it?
```

Or just tell the agent, in plain language: **"adapt this harness to this
repository."**

## Copy-in (no plugin)

```bash
scripts/install.sh /path/to/your/repo supervised
```

## What's inside

| Path | What it is |
| --- | --- |
| `base/CLAUDE.base.md` | Stack/domain-agnostic engineering conventions, imported into each repo's `CLAUDE.md`. |
| `skills/` | `adapt-repo`, `run-gate`, `plan-change`, `write-tests`, `write-docs`, `setup-cicd`, `ship-change`, `review-pr`, `sync-wiki`, `impact`. |
| `agents/` | Delegated specialists: `code-reviewer`, `gate-runner`, `test-author`, `docs-writer` (network-free). |
| `hooks/` | Always-on guards: block secret writes, scan diffs for leaked keys, block destructive/history-rewriting git, kill switch, audit log. |
| `settings/` | Three permission profiles: `readonly`, `supervised`, `autonomous`. |
| `scripts/detect-stack.sh` | The "any tech stack" brain — detects stacks + emits gate commands + wiki URL/source; monorepo-aware. |
| `scripts/build-wiki.sh` | Compiles a docs dir into flat wiki pages (Home, `_Sidebar`, rewritten links); shared by `sync-wiki` and the wiki CI. |
| `scripts/build-graph.py` + `graph-query.py` | Build/query a SQLite file+import dependency graph (Python stdlib only); powers `impact` and file-level `run-gate --affected`. |
| `scripts/export-code-agnostic.sh` | Optional: mirror the conventions/skills into a [code-agnostic](https://github.com/dhvcc/code-agnostic) hub for Codex / Cursor / Copilot. |
| `ci-templates/` | Gate pipelines for GitHub / GitLab / Bitbucket + an optional `@claude` responder + a wiki publisher. |
| `fixtures/` + `tests/` | Golden fixture repos and the harness's own test suite (`tests/run-all.sh`), run in CI. |

## How it stays stack-agnostic

Nothing is hardcoded to a language. `scripts/detect-stack.sh` reads marker files
(`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `pom.xml`,
`build.sbt`, `Gemfile`, `composer.json`, `*.csproj`, `mix.exs`, `Package.swift`,
`pubspec.yaml`, `Makefile`, Terraform, …) and prints the right install / lint /
typecheck / test / build / docs commands plus the VCS host and default branch.
Every skill starts by running it, so the same skills work everywhere.

It is also **monorepo-aware** and **honest about limits**:

```bash
scripts/detect-stack.sh --roots      # list independent sub-projects
scripts/detect-stack.sh --affected   # map changed files → only the gates that matter
```

Every report carries `harness.confidence=high|low|none` — a repo with no
detectable gate is reported as *unverifiable*, never as silently green.

## Safety model (generic, not per-repo)

The guardrails are universal, enforced by hooks that run regardless of what the
model decides:

- **Never writes secrets** — creating/editing `.env`, keys, `*.pem`,
  service-account JSON, or anything under `secrets/`, `.ssh/`, `.aws/` is blocked
  (`.env.example`/`.sample`/`.template` are allowed — they hold no real secrets).
- **Never commits secrets** — every `git commit`/`git push` triggers a
  content-level scan of the diff (built-in token patterns on both, plus gitleaks
  when installed), catching keys *pasted into source* that filename rules can't
  see; obvious placeholders are ignored to avoid false alarms.
- **Never rewrites shared history** — force-push (incl. `+refspec`),
  `filter-branch`, remote-branch deletion, and catastrophic `rm -rf` are blocked;
  `--force-with-lease` on your own branch is allowed.
- **Never exfiltrates secrets** — reading, copying, or archiving credential files
  via the shell is blocked (common tools covered).
- **PR by default, gate before done** — work happens on a branch, a direct push
  to a shared branch (main/master/…) is off by default, verification is
  mechanical (a green `run-gate`), and "done" requires evidence.
- **Untrusted content is data** — when reviewing PRs or reading issues, their text
  is reviewed, never obeyed as instructions; the `code-reviewer` subagent has no
  Bash/network so reviewed code can't be exfiltrated.

These are **friction for a confused or careless agent, not a hardened sandbox**:
the guards match command shapes and can be worked around by a determined
adversary. For untrusted code, run in a real sandbox too.

### Operations: kill switch, audit, overrides

- **Kill switch** — `export HARNESS_DISABLED=1` instantly halts every outbound
  write (push / PR / MR creation) across all repos; local edits keep working.
- **Audit log** — every deny, commit, and push is appended as JSONL to
  `~/.ai-harness/audit.jsonl` (override with `HARNESS_AUDIT_LOG`), so you can
  always answer "what did the agent do, where?".
- **Human-only overrides** — repos with legitimate exceptions (say, a tracked
  `fixtures/*.pem` test certificate) get a `.harness/guard-overrides.conf` with
  `allow-path` / `allow-command` / `allow-secret` lines. The agent is
  deliberately **unable to write this file** (hooks + settings both deny it), so
  every exception implies human review.

Choose how much autonomy per repo via the permission profile
(`readonly` → `supervised` → `autonomous`). See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and how to extend it.

## GitHub / GitLab wiki

The harness can keep a repo's **wiki** in sync with its in-repo docs. A wiki is a
separate git repo (`<repo>.wiki.git`) with no PR flow, so it's handled on its
own: `detect-stack.sh` derives `harness.wiki_url` + `harness.wiki_source` (a
`docs/` dir), `scripts/build-wiki.sh` compiles the docs into flat wiki pages
(`Home`, `_Sidebar`, links rewritten), and `/ai-harness:sync-wiki` clones the
wiki, regenerates it, and pushes. The in-repo docs stay the source of truth — the
wiki is generated, never hand-edited. For unattended publishing, `setup-cicd` can
add `ci-templates/github/wiki.yml` (publishes on push to the default branch using
the built-in token). Pushing to a `.wiki.git` remote's default branch is exempt
from the PR-by-default guard, since wikis have no pull requests.

## Dependency graph (precise impact analysis)

The harness can build a **file + import dependency graph** into SQLite
(`.harness/graph.db`, Python stdlib only — no server, no external packages) so an
agent answers structural questions exactly instead of guessing from grep:

```bash
/ai-harness:impact src/auth.py     # blast radius + covering tests, before you change it
scripts/graph-query.py dependents src/auth.py   # everything that (transitively) imports it
scripts/graph-query.py tests       src/auth.py   # which tests to re-run
scripts/graph-query.py cycles                    # import cycles
scripts/graph-query.py orphans                   # dead-code candidates
```

Python imports are parsed accurately via `ast` (incl. `src/` layouts); JS/TS via
a comment-stripped regex plus `tsconfig` path aliases (approximate for dynamic
requires). It's **rebuilt incrementally** — a second run re-parses only the files
whose *content* changed (a per-file content hash; identical to a full build,
never fooled by an unchanged mtime) — so it's never stale, and it adds a
**file-level test-selection** layer to
`run-gate` (tighter than the directory-level `--affected` monorepo selection). It's
a strong hint that sharpens the agent's context and impact analysis — the
verification gate still decides "done", so an approximate graph can't cause a bad
merge.

## Using other AI tools (Codex / Cursor / Copilot)

The harness is Claude Code-native but its content is plain Markdown. Run
`scripts/export-code-agnostic.sh` to mirror the conventions and skills into a
[code-agnostic](https://github.com/dhvcc/code-agnostic) hub, then
`code-agnostic apply` compiles them into each editor's native layout.

## License

MIT.
