# 2026-10-15 — Babysitter holds on provider usage limits

- A provider usage limit no longer ends a babysitter repair as `failure`
  (needs-human label plus give-up comment). `PrFixer` now classifies
  `limits_reached`, records a per-provider hold in
  `.hive-state/babysitter/agent-limit-hold.json`, and skips that provider's
  spawns until the hourly `AgentLimit.retry_due?` cooldown passes. Observed on
  2026-10-13–15: 24 Codex runs failed the same way and labelled dependency PRs
  needs-human.
- Give-up comments lead with the classified `Error:` line; the raw agent tail
  had shown only Codex MCP startup noise (`rmcp` AuthRequired lines from the
  operator's Cloudflare MCP servers), hiding the usage-limit cause.
- See [[commands/babysit]].
