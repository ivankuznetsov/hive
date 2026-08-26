## [2026-08-25T16:32:11Z] workflows/bench — retry deliberation quota failures

**Problem:** The judge stage already scheduled exact quota-backed rejudge gaps,
but Fable session exhaustion during adversarial deliberation only produced a
truncated warning and `final: null`. Final validation therefore parked the
campaign as generic `WAITING`, so the daemon had no cooldown marker to resume.

**Action:** Deliberation now emits typed cell/judge quota events for both rounds.
Final validation schedules `ERROR reason=limits_reached` only when every
incomplete transcript or verdict is backed by matching quota evidence and every
failure emitted for that retried cell is quota-typed; mixed, unmatched,
structural, effort, malformed, and non-quota failures remain manual. The
packaged Sol judge ceiling is also 60 minutes for `ultra` calls under load.

**Proof:** `test/unit/workflows/bench_test.rb` covers typed round-one and
round-two evidence, quota-backed null finals, missing transcripts, same-judge
and cross-judge mixed failures, malformed events, effort mismatch, the 60-minute
Sol ceiling, and non-quota rejection. The focused file passes with 35 runs and
337 assertions, and the embedded judge stage script passes `bash -n`.
The full Ruby suite passes with 13,533 runs and 275,313 assertions (10 skips).
