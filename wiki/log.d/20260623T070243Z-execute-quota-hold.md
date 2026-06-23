## [2026-06-23T07:02:43Z] execute/status — quota walls now park on cooldown

**Action:** `4-execute` now preserves provider quota walls as
`ERROR reason=limits_reached provider=<execute-agent> retry_after=<iso8601>`
instead of collapsing them into `reason=implementer_failed`. The runner checks
the implementation result's raw `limit_text` first and then the formatted
`error_message`, writes the shared `Hive::AgentLimit.retry_after` cooldown stamp,
and leaves non-limit implementation failures on the existing
`implementer_failed` marker shape.

`Hive::AgentLimit` now owns quota-held rendering helpers used by text status,
JSON status, and the TUI. Human/TUI rows render `held: agent quota (...) —
retry after ... UTC; top up or switch execute agent`; JSON rows add
`held: {reason: quota, provider: ..., retry_after: ...}` without overloading
dependency `blocked_by`.

**Tests:** Added execute unit coverage for quota detection via `error_message`
and raw `limit_text`, plus the non-limit marker invariant. Added
`AgentLimit` held-helper coverage, status text/JSON coverage, and TUI
`ERROR` / `REVIEW_ERROR` held-label coverage. Added status-schema coverage for
the optional `held` object so `Snapshot::Row` and `hive-status.v4.json` stay
aligned. Re-ran
`test/unit/daemon/stale_agent_healer_test.rb`, whose existing terminal
`limits_reached` tests cover `4-execute` cooldown hold/retry behavior.

**Follow-ups:** The provider's literal wall-clock reset time and a
provider-level circuit breaker remain separate follow-up tasks; this change
continues using the existing fixed cooldown contract.
