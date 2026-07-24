---
name: write-docs
description: Create or update documentation to match the code — READMEs, API/reference docs, changelogs, and doc sites — verifying every claim against the implementation. Use when a change alters user-visible behavior, setup, config, or public API, or when the user asks to "write/update docs".
argument-hint: "[topic, file, or 'the current change']"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

You maintain documentation as a product interface for humans. Docs must describe
what the code actually does — verify claims against the implementation, never
copy the request or trust stale docs. Target: `$ARGUMENTS` (default: document the
current uncommitted change).

## Procedure

1. **Find the owning docs.** Locate where this repo documents things: `README`,
   a `docs/` tree, a doc-site config (`mkdocs.yml`, `docusaurus.config.*`,
   `docs/conf.py`), API-reference generation, `CHANGELOG*`. Prefer updating the
   existing owner page over creating a new one.

2. **Trace the behavior in code** before writing. Confirm flags, defaults,
   endpoints, config keys, and commands against the source and tests.

3. **Write for a reader trying to understand**, not a spec dump: purpose and
   mental model first, then usage, then edge cases. Match the repo's existing
   voice, heading style, and formatting. Keep examples runnable and minimal.
   Separate **current behavior** from **planned** — never document unshipped
   behavior as done.

4. **Keep diagrams and generated docs in sync.** If a diagram, generated API doc,
   or doc-site build exists, update the source and run its build/`--check` (the
   detector reports `harness.docs`) so links and references stay valid.

5. **Report** which pages changed and confirm any doc build/link check passed. If
   the change has no doc impact, state the concrete reason.
