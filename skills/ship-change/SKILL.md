---
name: ship-change
description: Take a change from request to reviewed PR with minimal involvement — understand, implement, test, document, run the gate, commit on a branch, and open a pull/merge request. Use when the user describes a feature/fix and wants it delivered end-to-end, or says "ship this", "make a PR for this".
argument-hint: "[what to build/fix]"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

You are delivering `$ARGUMENTS` end-to-end. Move fast, but the guardrails in
`.harness/CLAUDE.base.md` are non-negotiable: never commit secrets, PR by
default, no force-push, no destructive/deploy commands without approval.

## Procedure

1. **Understand.** Read the relevant code and the repo's conventions. State the
   success criterion for this change in one line before editing.

2. **Branch.** Create a descriptive branch off the default branch
   (`git switch -c <type>/<slug>`). Never develop on the default branch.

3. **Implement** the smallest correct change that meets the criterion. Match the
   surrounding style. Touch only what the task needs.

4. **Test.** Add/extend tests with `/ai-harness:write-tests` for the behavior you
   changed (including a regression test for any bug fixed).

5. **Document.** If the change alters user-visible behavior, API, config, or
   setup, update docs with `/ai-harness:write-docs`.

6. **Gate.** Run `/ai-harness:run-gate`. Do not proceed until it is green (or
   report precisely what is unverified and why, and stop for the human).

7. **Commit** in coherent units with clear, human-style messages. Stage only
   files belonging to this change (`git status` first). Do **not** add any AI
   co-author trailer (`Co-Authored-By: Claude`/`Codex`/etc.) or "Generated with"
   line — commit under the human's git identity only.

8. **Open a PR/MR.** Push the branch and open a pull/merge request via the host's
   CLI/API (`gh pr create` for GitHub; `glab mr create` for GitLab; the Bitbucket
   API for Bitbucket). Fill title + body: what changed, why, how it was verified
   (paste the gate result), and any follow-ups. **Do not merge** — leave it for
   human review unless the user explicitly authorizes auto-merge.

## Output

Link to the PR/MR (or the branch name if the host CLI isn't available), the gate
result, and a short summary of files changed, tests added, and docs updated.
