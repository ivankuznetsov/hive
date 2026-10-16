# 2026-10-16 — A refused model stops the task for the operator (supersedes #1473)

- New `Hive::ModelUnsupported` classifies Codex's `The '<model>' model is not
  supported when using Codex with a ChatGPT account.` (seen for `gpt-6-sol`
  and `gpt-6.1-sol`) as `model_unsupported`, an operator-owned configuration
  error. `AgentLimit` no longer treats it as a provider limit.
- Agent, execute, open-PR, and review (reviewers/triage/fix) write
  `reason=model_unsupported` with a message that names the model and says to
  set a supported model for the stage/role in `.hive-state/config.yml`.
- The daemon never auto-retries it: `RecoveryCoordinator#assessment` returns
  `operator_required`; disposition `model_unsupported` reads as
  `needs_repair`/`operator` in `hive status --operational`. Operator retries
  still work.
- Babysitter gives up on the PR with the message instead of taking a limit hold.
- See ADR-057 in [[decisions]], [[modules/agent]], [[modules/daemon]],
  [[stages/review]], [[commands/babysit]].
