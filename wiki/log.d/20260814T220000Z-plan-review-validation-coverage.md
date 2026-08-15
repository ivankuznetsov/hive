## [2026-08-14T22:00:00Z] plan review — pin the value-object rejection branches

**Action:** No behavior change. The 100% line-coverage gate was failing with 266
uncovered lines across the new plan-review subsystem; this pass closes the
rejection branches of the four value objects that parse untrusted adapter and
operator input — `Record`, `Decision`, `Finding`, and `ResultParser`.

**Coverage:** New unit cases pin the malformed-envelope, malformed-identity, and
non-JSON-safe rejections on `Record` and `Decision`; coverage-entry binding
(fingerprint, `retry_at`, waiver decision id) and artifact-reference validation
on `Record`; policy-receipt binding to `policy` origin and to the review under
decision; blank-prose, unknown-grade, and unordered-evidence rejection plus
symbol/array attribute stringification on `Finding`; and envelope, identity,
scalar-field, coverage-entry, and snapshot-anchor rejections plus `Parsed#to_h`
round-tripping on `ResultParser`.

**Remaining:** 219 uncovered lines remain in the rest of the subsystem
(`orchestrator`, `ce_doc_review`, `config`, `store`, `transition_guard`,
`plan_signals`, `decision_service`, and the CLI/status commands), so the
coverage gate is still red. See [[testing]] and [[modules/plan_review]].
