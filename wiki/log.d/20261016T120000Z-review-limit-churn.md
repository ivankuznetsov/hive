# 2026-10-16 — 6-review stops re-spending healthy reviewers on limited retries

- Root cause of the Oct 2026 pass-1 churn (~240–264 hourly retries on each of
  four tasks): triage's Codex model hit its ChatGPT-plan wall, and every cooled
  retry re-ran the whole pass — the healthy Codex reviewer (≈905 redundant
  successful reviews, ≈47 agent-hours) plus a `-retry1` of the limited Claude
  reviewer. The hourly cadence itself was already correct.
- `Hive::Reviewers::Agent` no longer retries a provider-limit failure inline.
- New `Hive::Stages::Review::ReviewerReuse`: a triage limit records the
  single-use `reviews/reviewer-reuse-NN.json` receipt; the retry skips
  reviewers whose output is unchanged at the same pass and HEAD. See
  [[stages/review]].
