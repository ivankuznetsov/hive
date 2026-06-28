## [2026-06-26T19:19:59Z] wiki - refresh e2e background-process lifecycle coverage

**Action:** Refreshed LLM wiki coverage after recent history showed commit
`efb669b6` changed `test/e2e/lib/background_process.rb` and
`test/e2e/lib/background_process_test.rb`. Read `.llm-wiki/config.json`,
`AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], and recent [[log]] entries first.
`qmd search "bot row_actions poll_health dry-run stubs invalid bytes hive-eval background process v0.3.1"`
returned no results, and the configured main wiki path
`/home/asterio/wikis/master/wiki` plus existing default cross-project paths had
no relevant background-process hits. Inspected recent git history through
`16fff941` plus source commits `f817c8ea`, `fb60b8b1`, `efb669b6`,
`57901655`, `c916d89e`, and the latest bot commits. Existing bot, dry-run-stub,
CLI invalid-byte, eval-report, and release-smoke pages already matched the
source/log fragments; the stale gap was the attached e2e background-process
lifecycle.

**Refresh:** Updated [[e2e]] and [[testing]] to document that
`Hive::E2E::BackgroundProcess` starts daemon/bot children attached with
`pgroup: true`, keeps the original child unreaped until cleanup, uses
`waitpid(WNOHANG)` to detect reaped children, signals TERM/KILL only while the
original child is still unreaped, and detaches only as final cleanup. Updated
[[gaps]] to include the source/test coverage and to record the remaining
uncertainty: no checked-in full `bin/hive-e2e run` or hivebox golden-path
artifact proves the reused-process-group failure mode in a complete scenario.
Page count stayed 84, so [[index]] needed only freshness metadata. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[e2e]]
- [[testing]]
- [[gaps]]
- [[index]]
