# Skills & agents reference

Skills are on-demand procedures that run in the main context — invoke them as
`/ai-harness:<name>`. Agents are delegated specialists with their own tool
access, run in an isolated context. See
[ARCHITECTURE.md](ARCHITECTURE.md#why-these-shapes) for why the split exists.

## Skills

| Skill | Argument hint | What it does | Use when |
| --- | --- | --- | --- |
| `adapt-repo` | `[supervised\|autonomous\|readonly]` (default: supervised) | Inspects the stack, host, and conventions, then generates a tailored `CLAUDE.md`, permission settings, gate commands, and optional CI/CD. | "adapt this harness to this repo", "set up the harness here", or opening a fresh project with the harness installed. |
| `run-gate` | `[--cheap]` (lint+typecheck only) | Auto-detects the stack, then runs install → lint → typecheck → test → build in order and reports pass/fail with evidence. | Before claiming any change is done; whenever asked to "run the checks/tests/gate". |
| `plan-change` | `[issue number/URL or a description]` | Triages an issue or request into success criteria, affected files, steps, risks, and a test plan — before any code is written. | "triage issue #N", "plan this change", or as the first step of unattended work. |
| `write-tests` | `[path or description]` | Adds or extends automated tests in the repo's own framework and style. | "write/add tests", "improve coverage", or after a change lacks tests. |
| `write-docs` | `[topic, file, or 'the current change']` | Creates or updates docs to match the code, verifying every claim against the implementation. | A change alters user-visible behavior, setup, config, or public API. |
| `setup-cicd` | `[--with-claude]` | Generates a CI/CD pipeline for the repo's host (GitHub/GitLab/Bitbucket) and stack, plus an optional `@claude` PR responder. | "set up CI", "add a pipeline", "wire CI/CD". |
| `ship-change` | `[what to build/fix]` | End-to-end delivery: implement → test → document → gate → branch → commit → PR, with minimal involvement. | A feature/fix described and wanted delivered end-to-end; "ship this". |
| `review-pr` | `[PR/MR number or URL]` (default: current branch vs. base) | Fetches the diff/description, delegates to `code-reviewer`, runs the gate, and produces a must-fix vs. nice-to-have review. Never approves or merges. | "review this PR", or before merging. |
| `sync-wiki` | `[source docs dir]` (default: `docs`) | Compiles the docs directory into wiki pages (Home, sidebar, rewritten links) and pushes to `<repo>.wiki.git`. | "update/sync/publish the wiki", or after docs change in a repo whose wiki is in use. |
| `impact` | `[dependents\|deps\|affected\|tests\|cycles\|orphans <file...>]` | Answers structural questions from a fresh dependency graph: blast radius, what a file depends on, covering tests, import cycles, dead files. | Before changing shared code, scoping a change, "what breaks if I change X". |

## Agents

Delegated via the `Agent`/`Task` tool; each runs in its own context with a
fixed tool set.

| Agent | Tools | What it does | Delegate when |
| --- | --- | --- | --- |
| `code-reviewer` | Read, Grep, Glob (no Bash, no network) | Reviews a diff or PR for correctness, security, and convention adherence. Reports findings, does not edit. | After implementing a change and before opening a PR. |
| `gate-runner` | Read, Grep, Glob, Bash | Detects the stack and runs the verification gate, reporting pass/fail with evidence. Does not edit code. | You want the gate run in isolated context without flooding the main transcript. |
| `test-author` | Read, Grep, Glob, Bash, Edit, Write | Writes or extends automated tests in the repo's own framework and style. | Tests are needed and you want them authored in isolated context. |
| `docs-writer` | Read, Grep, Glob, Bash, Edit, Write | Creates or updates documentation to match the implementation, verifying claims against code. | A change needs docs written in isolated context. |

`code-reviewer` is deliberately network-free and has no `Bash` — so code it
reviews (including untrusted PR content) cannot be exfiltrated through it.
