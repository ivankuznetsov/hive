# Accept explicitly configured dynamic OpenCode routes

- Observed a later benchmark review fail before its model request after Ox Alpha
  disappeared from `opencode models openrouter --verbose`, even though the
  selected overlay explicitly defined `openrouter/stealth/ox-alpha`, its `high`
  variant, and successful live calls continued.
- OpenCode preparation now treats the exact non-secret provider/model definition
  as route evidence when the dynamic public inventory omits it. CLI version,
  capabilities, auth, requested variant, and exact route remain validated.
- Added regressions for the configured-route fallback and for rejecting a
  configured model whose requested variant is absent.
