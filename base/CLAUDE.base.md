# Engineering conventions (AI harness base)

These are stack- and domain-agnostic working rules. They are imported into a
target project's `CLAUDE.md` by the harness (`@.harness/CLAUDE.base.md` or copied
in) and apply to every session, alongside anything the project defines itself.
Project-specific instructions always win over this file.

## Operating principle

Do the smallest correct change, prove it works, and leave the repository in a
state a reviewer can trust. Bias to action once the goal is clear; ask only when
a decision is genuinely the user's to make.

## Before changing anything

- Read enough of the surrounding code to match its patterns, naming, and idioms.
  Write code that reads like the code already there.
- Prefer the language/framework-native solution over a new abstraction or
  dependency. A new dependency needs a reason: it must remove more complexity
  than it adds.
- Touch only what the task needs. No drive-by refactors, renames, or
  reformatting of code you aren't changing. Note unrelated problems; don't fix
  them silently.

## Boundaries and inputs

- Treat every external input as untrusted: HTTP responses, files, env, CLI args,
  message payloads, third-party APIs. Validate/parse at the boundary before use.
- Never hardcode secrets, tokens, hostnames, or environment-specific values. Read
  them from config or environment.

## Verification — "done" means proven

- State the success criterion before non-trivial work.
- Run the project gate with the `run-gate` skill (it auto-detects the stack):
  install → lint → typecheck → test → build, whichever exist.
- Never claim completion without evidence. If the gate can't run, say exactly
  why and what remains unverified. A red gate is not done.
- Add or update tests for behavior you change (`write-tests` skill).

## Documentation is part of done

- When a change alters user-visible behavior, public API, config, setup, or
  workflow, update the owning docs in the same change (`write-docs` skill).
- Keep docs accurate to the code, not to the request. Verify claims against the
  implementation.

## Git and safety guardrails

These are enforced by harness hooks; follow them so hooks never have to intervene:

- **Never commit secrets.** No `.env`, credential files, private keys, tokens,
  `*.pem`, `id_rsa`, service-account JSON, or data dumps. If one is already
  tracked, flag it — don't propagate it.
- **PR by default.** Do work on a branch and open a pull/merge request for
  review. Push straight to a shared/default branch only when the project's own
  rules explicitly say to, and only after a green gate.
- **Never force-push a shared branch, never rewrite published history, never
  hard-reset away others' work.**
- Commit in coherent units with clear messages. Stage only files belonging to
  your change (check `git status` first).
- Do not run destructive or irreversible commands (mass delete, `db drop`,
  infra `apply`/`deploy`, `terraform apply`) without explicit approval.

## Commit message trailer

End commit messages you author with the co-author trailer the harness configures
for the project, so machine-authored changes are attributable.
