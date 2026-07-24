---
name: setup-cicd
description: Generate a CI/CD pipeline tailored to this repo's host (GitHub / GitLab / Bitbucket) and stack — a gate workflow that installs, lints, type-checks, tests, and builds, plus an optional @claude PR responder on GitHub. Use when the user asks to "set up CI", "add a pipeline", or "wire CI/CD".
argument-hint: "[--with-claude] to also add the @claude GitHub responder"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

You are generating a working CI pipeline for the current repository from the
harness templates — with the **actual detected commands** substituted in, not
placeholders.

## Procedure

1. **Detect** host and gate commands:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh"
   ```
   Use `harness.host`, `harness.default_branch`, and the gate commands.

2. **Pick the template** for the host from
   `${CLAUDE_PLUGIN_ROOT}/ci-templates/`:
   - `github`   → `.github/workflows/ci.yml`
   - `gitlab`   → `.gitlab-ci.yml`
   - `bitbucket`→ `bitbucket-pipelines.yml`
   If host is unknown, ask which one to target.

3. **Fill it in.** Replace the `{{INSTALL}} {{LINT}} {{TYPECHECK}} {{TEST}}
   {{BUILD}} {{DEFAULT_BRANCH}}` placeholders with the detected values. Remove
   steps whose command is empty. Set the correct language runtime/setup action
   for the stack (e.g. `actions/setup-node`, `actions/setup-python`,
   `actions/setup-go`). Pin third-party actions to a version.

4. **Optional @claude responder** (GitHub only, when `--with-claude` is in
   `$ARGUMENTS`): also write `.github/workflows/claude.yml` from the
   `ci-templates/github/claude.yml` template. Tell the user which auth to set —
   the workflow is inert without it:
   - **Claude subscription (Pro/Max/Team):** run `claude setup-token` once, add
     the result as the `CLAUDE_CODE_OAUTH_TOKEN` repo secret (this is the default
     in the template).
   - **API billing:** add `ANTHROPIC_API_KEY` and swap the commented line.
   Either way, install the Claude GitHub App (`/install-github-app`).

5. **Do not commit** unless asked. Report the file(s) written, the steps enabled,
   and the exact secret/setup the user still has to add.

Never write secrets into a workflow. Reference them as `${{ secrets.NAME }}`
(GitHub), CI/CD variables (GitLab), or repository variables (Bitbucket).
