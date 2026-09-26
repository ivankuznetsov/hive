# 2026-09-26 — Already-green babysitter noops count as a turn

- The round-robin selection counted only `agent-fix`, `rebase` and
  `force-push` as attempts. Already-green PRs log `noop` / `already-green`, so
  they always looked never-attempted and took both `max_concurrent_prs` slots
  every tick with instant noops. A red finalized PR went six hours without a
  turn.
- Every `PrFixer` action (`noop`, `give-up`, `pr-comment`, `label-apply`
  included) now counts as that PR's turn.
