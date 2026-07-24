---
name: run-gate
description: Run this repository's verification gate — auto-detect the stack, then run install, lint, typecheck, test, and build in order and report pass/fail with evidence. Use before claiming any change is done, and whenever the user asks to "run the checks/tests/gate" or "verify this".
argument-hint: "[--cheap] (skip install/build/tests; lint+typecheck only)"
allowed-tools: Read, Grep, Glob, Bash
---

You are running the mechanical "is it done?" gate for the current repository.
"Done" is never your opinion — it is a green gate with evidence.

## Procedure

1. **Detect** the gate commands:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh"
   ```
   Read the `harness.install/lint/typecheck/test/build` lines and
   `harness.confidence`. If the report lists `harness.subproject=` lines this is
   a **monorepo** — prefer running only what the change touches:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh" --affected
   ```
   and run each affected sub-project's gate from its own directory. Fall back to
   all roots (`--roots`) when the change spans everything (e.g. repo-wide config).

2. **Run the steps that exist**, in this order, stopping at the first failure:
   - `--cheap` mode (argument `$ARGUMENTS` contains `--cheap`): run **lint** and
     **typecheck** only. This is the fast, no-network gate suitable for a quick
     loop or a Stop hook. It does **not** prove runtime behavior.
   - full mode (default): **install → lint → typecheck → test → build**.
   Show the command before each step. Capture output.

3. **Interpret honestly:**
   - Heed `harness.confidence`: `none` means a "green" run proves nothing —
     say so; `low` means the gate is thin (missing lint/typecheck or tests) —
     qualify the verdict accordingly.
   - A step with no detected command is **skipped**, not passed — say so.
   - Tests that need external services (a database, broker, cloud creds) may not
     run in this environment. If so, report the step as **unverified** with the
     reason; never silently downgrade a red or missing gate to "passed".
   - Notebooks / infrastructure-as-code are inspect-only: the generic gate can't
     verify them — flag for human review.

4. **Report** a compact result table: each step → `pass | fail | skip | unverified`,
   with the failing output quoted for any `fail`. End with a one-line verdict:
   `GATE GREEN`, `GATE RED (fix: …)`, or `GATE PARTIAL (unverified: …)`.

Do not edit code in this skill — only run and report. If the gate is red, hand
back the exact failure so the caller can fix it.
