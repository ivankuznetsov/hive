## [2026-06-07T20:00:00Z] daemon — tighten terminal agent-loss retry review fixes

**Action:** Fixed the terminal agent-loss exhausted-budget remediation to emit a runnable
`hive run <slug> --project <project> --stage <stage>` command, expanded unit coverage to
the full late-stage/reason allowlist matrix, and pinned negative coverage for the same
reasons outside late stages.

**Files:**
- `lib/hive/daemon/stale_agent_healer.rb`
- `test/unit/daemon/stale_agent_healer_test.rb`

**Impact:** Agents can use the logged manual fallback when retry budget is exhausted, and
future changes are guarded against broadening terminal agent-loss auto-retry beyond
`7-artifacts`/`8-finalize`.
