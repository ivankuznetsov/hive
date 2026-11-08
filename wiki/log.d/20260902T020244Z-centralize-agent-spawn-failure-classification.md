# Centralize agent spawn failure classification

date: 2026-09-02
tags: [stages, agent, agent-worktree, limits, patrol-fix]

- Extracted the provider-limit spawn-failure classifier into one shared
  predicate, `Hive::Stages::Agent.limit_error_envelope?`, and both spawn
  surfaces now route through it: the generic agent stage runner
  (`lib/hive/stages/agent.rb`) and the worktree agent stage's
  `AgentWorktree.managed_failure_result` (`lib/hive/stages/agent_worktree.rb`).
- The worktree stage previously recognized quota only from a non-empty
  `limit_text` and wrote no provider or `retry_after` attributes, diverging
  from the generic stage's envelope recognition. It now recognizes the same
  envelopes (typed `limit_text`, formatted `limits reached[ for <provider>]:`
  messages, and raw provider wall text in `error_message`) and stamps the
  selected profile as `provider` plus a computed `retry_after` on the
  controller `fix-report.md` error marker, matching the generic stage's quota
  metadata contract.
- Added `Hive::Stages::Agent.limit_error_text` as the single source for the
  envelope text used to compute `retry_after` (raw provider wall when present,
  otherwise the error message that carried the envelope); the generic stage's
  previously duplicated `result[:limit_text] || result[:error_message]`
  selection now uses it too.
- Regression: `test_managed_failure_classifies_limit_envelopes_like_the_generic_agent_stage`
  in `test/unit/stages/agent_test.rb`.
