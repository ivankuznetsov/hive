# 2026-09-24 — Codex plan-model quota wall and open-PR limits

- `AgentLimit` now classifies Codex's `model is not supported when using Codex
  with a ChatGPT account` response as a provider limit. Codex returns it when a
  ChatGPT plan's allowance for that model is exhausted; the same model works
  after the allowance resets.
- Open-PR authoring publishes `limits_reached` (with `retry_after` when known)
  for a classified or recognizable provider wall instead of
  `open_pr_authoring_failed`, so the daemon applies the provider cooldown rather
  than spending identical retries and parking the task as a deterministic
  failure.
