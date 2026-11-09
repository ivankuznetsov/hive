# 2026-11-02 — Preserve granted-fix guardrail admission across restarts

- Keep a granted fix slot spent after sealing its completion, while requiring
  a separate HEAD-bound post-guardrail success sentinel before advancing.
  Recover missing disposition by checking the sealed input/output diff before
  CI or reviewers run; preserve existing approval pauses and refuse changed
  HEAD or dirty edits. Cover crashes after the receipt, after the trip report,
  and before the success sentinel, including approval and mandatory verification.
- Share the runner's accepted-finding predicate with grant eligibility for
  reviewer files and legacy escalations, excluding checked suppressed and
  resolved/no-fix entries. Cover mixed evidence without rewriting artifacts.

Pages: [[commands/review-grant]], [[stages/review]], [[gaps]].
