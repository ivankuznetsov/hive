---
title: Verify guarded attached retry and caller-loss replay
date: 2026-11-08
---

Completed the local manual workflow.retry contract. Effective daemon.enabled
selects attached execution or the existing queued path; process presence does
not select policy. Disabled-project remote retries return 503
`dispatcher_unavailable` with an exact local attached action command and persist
no recovery request. No remote envelope or API version changed.

The coordinator validates revision-bound existing requests and owns marker
repair. Shared transactional admission fences post-clear progress. Concurrent
manual and daemon consumers converge on one attempt, including a winner between
lookup and the admission transaction. The loser reads its bound canonical
attempt instead of returning a misleading claim failure. Observation and
attachment go through Attempts::API, preserving the internal component boundary.

Caller interruption preserves live ownership; a canonical terminal result wins
an attachment-detachment race. Interruption after terminalization but before
failure-marker repair remains actionable through fresh status, without another
retry charge or attempt. Lost attempts report `lost` and the canonical end time,
including caller loss before the recovery dispatch phase was recorded. Ambiguous
request bindings refuse before repair. Status only observes bounded task-scoped
evidence and never performs recovery mutations.

Act emits one v2 envelope and refreshed task state. Failed terminal outcomes
exit nonzero after the success arm records that the action was evaluated;
keyed replay preserves that result without re-execution. Inner stage stdout
cannot become a second act document. Canonical operating guidance was updated
and OpenClaw's checked-in reference, manifest and SKILL digest were regenerated
through CanonicalSkill, retaining the 20-reference contract.

Local verification:

- Inspected `bin/test --changed --list` throughout. Shared skill changes visibly
  select offline suites; explicit focused files were used between checkpoints.
- The final combined recovery/API/admission/status/action/remote/boundary/schema/
  skill/release selection passed 397 tests and 4,039 assertions. The strengthened
  real daemon-consumer lifecycle fixture then passed 16 tests and 121 assertions.
- `bundle exec rails test test/controllers/api/v1/mutations_test.rb` in web
  passed 15 tests and 142 assertions, including disabled refusal, failed-receipt
  replay and unchanged enabled-project admission.
- Opt-in disposable systemd policy probes plus unchanged reconciler/healer tests
  passed 33 tests and 231 assertions. See the separate bounded restart matrix;
  this does not establish actual application-service restart behavior.
- `bin/test test/integration/wiki_command_index_test.rb` passed alone:
  2 tests and 52 assertions.
- The broad `bin/test --all` checkpoint ran 16,340 tests across root/component
  workers and was not green (4 failures, 26 errors, 16 skips). Three component
  construction errors introduced here were fixed and the relevant suite passed.
  Other failures reproduce the already documented procfs ESRCH/custody and
  process-registry mismatch; those implementation files are unchanged. An
  isolated recheck of those existing suites still failed. The broad wiki
  snapshot saw concurrent ignored scratch/log writes and passed in isolation.
- Final facade/recovery API, component boundary, canonical/projection and release
  checks passed 105 tests and 2,276 assertions. Targeted RuboCop inspected
  19 changed Ruby files with no offenses; `git diff --check` passed.
- Exhaustive coverage, live provider execution, browser flows, the caller-loss
  E2E scenario and installed application-service restarts were not run. No
  production orphan policy, service template or release metadata was changed.
