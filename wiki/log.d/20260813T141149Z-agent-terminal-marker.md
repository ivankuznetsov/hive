# 2026-08-13 — fail closed when an agent return leaves AGENT_WORKING

**Action:** `Hive::Agent` now rewrites a marker-owned run that returns with a
zero or unavailable captured exit status while still carrying Hive's pre-spawn
`AGENT_WORKING` marker to
`ERROR reason=agent_exited_without_terminal_marker`. The marker records the
observed transient state and provider, so stage actions no longer report
success before the agent produced a terminal artifact and the universal
recovery coordinator can retry the failure normally.

**Boundary:** This change stays in Hive's stage supervisor. The separate
`agent-cli-runtime` library remains the compatibility layer for provider
profiles, argument compilation, probes, and observable CLI results.

**Coverage:** Added focused Agent regressions for zero and nil exit statuses
with the transient marker, plus an integration plan-stage action case proving
JSON mode returns a typed error envelope, never a success envelope with
`marker_after=agent_working`, while persisting the recoverable error. Existing
successful `WAITING` and `COMPLETE` plan behavior remains unchanged. Finalize's
clean-exit backstop integration fixture now writes the terminal `COMPLETE`
marker required by the marker-owned agent contract.
