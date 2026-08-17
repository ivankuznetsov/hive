## 2026-08-17 — Cover both refusal arms of authoritative receipt restore

**Problem:** `Hive::TaskActivity::Operation#restore_authoritative!` shipped with
only its happy path pinned. The merged exact-coverage gate reported
`lib/hive/task_activity.rb` at 99.48% with two uncovered lines — the
"journal does not corroborate the receipt" refusal and the rescue that converts
a damaged journal into `Conflict` — and `rake test (Ruby 3.4)` failed on the
coverage gate result.

**Fix:** Added `test_restore_authoritative_refuses_when_the_journal_does_not_corroborate`
and `test_restore_authoritative_refuses_when_the_journal_cannot_be_read` to
`test/unit/task_activity_test.rb`. The second test exposed a real defect: the
rescue arm called `safe_error`, a private instance method of `Hive::TaskActivity`
that `Operation` cannot see, so a damaged journal raised `NoMethodError` instead
of the intended `Conflict`. Promoted the redactor to `Hive::TaskActivity.safe_error`
(the instance method now delegates, matching how `Operation` already reaches
`Hive::TaskActivity.fingerprint`) and called it from the rescue.

**Verification:** `ruby -Itest -Ilib test/unit/task_activity_test.rb` passes
(18 runs), `task_journal_test.rb`, `task_projection_test.rb`, and
`recovery_api_test.rb` stay green, and a scoped coverage run leaves both refusal
lines covered. See [[testing]].
