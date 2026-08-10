# Legacy root reviewers now have an upgrade-safe migration

**Action:** Added a narrow read-through compatibility alias for project configs
that place `reviewers` at the root. Hive promotes the value in memory to
`review.reviewers`, validates it normally, and warns once per process and
source path instead of failing every command immediately after a binary update.
`hive migrate` now performs the durable comment-preserving rewrite. Configs
that define both locations fail before mutation so Hive never chooses between
two authored reviewer policies.

**Boundary:** `hive update` continues to replace only the installed CLI; it
does not silently edit or commit every registered project's tracked Hive state.
All unrelated unsupported root keys remain strict exit-78 failures.

**Validation:** Added unit and command-boundary coverage for compatibility,
normal validation after promotion, conflict rejection, status/task strictness,
and review execution. Added integration coverage for comment-preserving,
idempotent project-state migration.

Did not edit compiled [[log]].
