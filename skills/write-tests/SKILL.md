---
name: write-tests
description: Add or extend automated tests for changed or specified code, in the repository's own test framework and style. Use when the user asks to "write/add tests", "improve coverage", or after implementing a change that lacks tests.
argument-hint: "[path or description of what to test]"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

You are adding tests that match how this repository already tests, not a generic
template. Target: `$ARGUMENTS` (if empty, cover the current uncommitted change —
inspect `git diff`).

## Procedure

1. **Learn the test conventions.** Detect the stack
   (`bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh"`) and read 2–3
   existing test files to copy the framework, file layout, naming, fixtures,
   assertion style, and mocking approach. Match them exactly.

2. **Find what needs covering.** For the target code, identify the meaningful
   behaviors: the happy path, boundary/edge cases, error handling, and any bug
   this change fixes (add a regression test that fails without the fix).

3. **Write focused tests.** Prefer clear, isolated unit tests; add an integration
   test only where the behavior genuinely spans units. Don't test the framework
   or trivial getters. Don't weaken assertions to make tests pass.

4. **Run them** with the detected test command (or `/ai-harness:run-gate`). Iterate
   until green. If a test can't run here (needs external services), say so and
   leave it correct rather than skipped-to-green.

5. **Report** which files you added/changed, what behaviors are now covered, and
   any gap you deliberately left (with the reason).
