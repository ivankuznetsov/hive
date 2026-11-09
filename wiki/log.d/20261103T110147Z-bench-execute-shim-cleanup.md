---
title: Clean replanted benchmark shims before execute
type: fix
date: 2026-11-03
pages: [modules/workflows, testing]
tags: [bench, agent, shell, cleanup, review]
---

The non-sealed stage caller repeats managed-bin validation and legacy-agent
cleanup immediately before `hive develop`, closing the plan-to-execute
shadowing window. Failures retain the existing diagnostics and exit 4.

Full-caller tests now plant a PATH-resolved Codex wrapper during plan with
review enabled and disabled, and independently plant one during develop to
prove review-entry cleanup. Symlinked-bin and managed-directory failures are
covered at both boundaries. Reuse rows replant entries before every invocation;
fixtures use `/tmp` explicitly, retaining the zero-residual rebasing guard.
The supplementary source assertion checks removal status and absence of a
re-probe without pinning the whole loop's formatting.

The new execute regression failed against the previous script because the
replanted entry survived. After the fix, both focused workflow files passed:
64 tests, 3,066 assertions, no failures, errors, or skips, with `TMPDIR`
containing `/work`. Ruby lint and shell syntax passed. ShellCheck was not
installed. The changed-test selector fell back to broad offline suites, so
the explicit focused files were used; no full suite or coverage run is claimed.
