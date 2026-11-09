## 2026-11-09 — Opt-in review agent fallback on provider usage limits

- Symptom: the hive project runs every review role on Codex. When the Codex
  subscription hit its usage limit until 2026-11-11, every review parked on
  `REVIEW_ERROR reason=limits_reached` or `reviewer_partial_failure` for about
  two days, with no way to substitute another provider automatically.
- Change: new opt-in `review.limit_fallback`
  (`{ enabled: false, min_wait_sec: 3600, agents: {} }` by default) and
  `Hive::Stages::Review::LimitFallback`. On a classified provider limit whose
  explicit reset hint is absent or at least `min_wait_sec` away, a reviewer,
  triage, fix, or CI-fix role retries once on the mapped fallback profile.
  The fallback is never the same provider and never runs under explicit
  provider routing.
- Audit: each substitution is logged, appended to
  `reviews/limit-fallback-NN.jsonl`, and given a `-fallback-<agent>`
  log-label suffix. Reviewer output lands in
  `<output_basename>-fallback-<agent>-NN.md`. A failed or also-limited
  substitute keeps the primary's `limits_reached` marker, annotated with
  `primary_agent` / `fallback_agent` / `fallback_outcome`.
- Pinning: the fix and CI-fix fallbacks bypass the task's pinned
  implementation identity for that one run, without re-pinning or observing
  it, and log that they did. Substitutes run on the fallback profile's
  default model.
- `ReviewResidualCommit.agent_profile_hint` now suggests the option, or
  reports an already-failed fallback. The project config template gained a
  commented example, and the config defaults doc was regenerated.
- Pages: [[stages/review]], [[modules/config]], [[gaps]].
