# 2026-11-02 — Preserve later escalation answers and archived grant replay

- Use sealed completion answer proofs to route newly answered escalations to
  an unused logical slot after restart, without repeating already applied
  findings or changing earlier completion receipts. Cover Q&A and checkbox
  answers with equal artifact mtimes.
- Bind later-slot guardrail admission to decision/slot identity as well as
  HEAD, and recover only the latest completion for each reviewer pass.
- Return archived decisions as inert historical replays even after the reset
  review becomes eligible or receives an active grant.

Pages: [[commands/review-grant]], [[stages/review]].
