---
pr_url: https://github.com/ivankuznetsov/hive/pull/854
pr_number: 854
---

## Summary

- Add a natural-language workflow creator to Hive's single canonical `/hive` skill, with generated OpenClaw projections and supporting schema, design, safety, testing, and troubleshooting guidance.
- Add the runtime contracts needed by the accepted editorial flow: durable human approve/reject stages, read-only workflow validation, consent-gated minimal initialization previews, and optional idempotent task creation.
- Keep creation safe and explicit: existing or reserved workflow IDs are never overwritten, fresh projects are unchanged before confirmation, task creation is opt-in, and approval never infers or performs external publication.

The acceptance workflow is exactly `research -> draft -> approval`: approval records a non-empty task-local draft as publish-ready and completes, while rejection records the decision and returns the same task to `draft`.

## Test plan

- [x] `bundle exec rake coverage` — 55,153/55,153 lines covered (100%)
- [x] Full suite — 10,087 runs, 140,468 assertions, zero failures
- [x] `bundle exec rake e2e:lib_test` — 203 runs, zero failures
- [x] `bundle exec rake e2e` — 16/16 scenarios passed
- [x] `bundle exec rubocop --parallel --format github` — clean
- [x] Hermetic workflow-creator acceptance covers editorial approve/reject, collision safety, consent-gated minimal initialization, durable graph commit, old-version and validation refusals, and idempotent task retries
- [x] Focused review-fix verification covers no-follow file handling, read-only routes, human-decision concurrency, state rollback/locking, minimal-init isolation, and fail-closed idempotency
- [ ] Protected OpenClaw workflow-creator smoke — hosted credential gate; unavailable locally

## Review summary

- Two review/fix passes completed against the implementation.
- All 29 actionable findings were auto-fixed, the one plan-directed compatibility concern was resolved without a code change, and no escalations remain.
- Hardening concentrated on filesystem containment, truly read-only preview/validation paths, durable approval identity and concurrency, atomic state mutation/rollback, deterministic retry identity, shell-safe generated commands, and end-to-end refusal/commit evidence.
- Final reviewed and pushed head: `f611b1a51d5e37996add924043ad7c554e9747f2`.

## Linked task

- Hive pipeline task: `create-and-ship-a-first-260719-7fa2`
- Non-blocking downstream wording coordination: `hive-site:23116` (no website or release changes are included here)

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/hive/pull/854 is_draft=false -->
