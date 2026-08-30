## 2026-08-30 — Plan signal Markdown normalization

`Hive::PlanReview::PlanSignals` now accepts the planning syntax emitted by the
current plan workflow: unquoted YAML dates, list-prefixed or inline bold field
labels, and numbered as well as bulleted test scenarios. This removes false
`malformed_frontmatter`, `files_not_declared`, and `tests_not_explicit`
uncertainties without weakening the requirement for an explicit implementation
rollback section.

Focused regression tests cover both list-prefixed unified-plan fields and
inline file declarations. Re-analysis of the four plans that exposed the issue
finds all declared files and test scenarios; their remaining rollback warning
is accurate because none contains a dedicated implementation rollback section.

See [[modules/plan_review]] and [[testing]].
