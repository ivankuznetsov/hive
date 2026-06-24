## bot/task-action - canonical Telegram row actions

**Action:** Added `Hive::Bot::RowActions` as the canonical status-row to
Telegram-action resolver and moved push notifications plus `/status` buttons to
consume it. Needs-input rows now get a working action (`Answer`, plan `Approve`,
review findings triage, execute `Re-run`, finalize/generic `Run`) or are
suppressed when the row is incoherent (`marker=none` / `marker=complete`).
Details now renders the cached `Supervisor#render_details` summary with a
next-step hint instead of dead-ending through `hive status --diagnose`.

**TaskAction:** Markerless coding brainstorm/execute rows and markerless
finalize rows with an existing `pr.md` classify as `READY_TO_RUN`, not
`NEEDS_INPUT`; execute-stage `:complete` maps to `READY_TO_OPEN_PR`.

**Tests:** Added `test/unit/bot/button_coverage_test.rb` to enumerate
representative `(action, marker, stage, workflow)` rows, assert resolver and
`/status` agreement, and forbid non-terminal needs-input rows whose only action
is Details.

**Refreshed pages:**
- [[modules/bot]]
- [[modules/task_action]]
