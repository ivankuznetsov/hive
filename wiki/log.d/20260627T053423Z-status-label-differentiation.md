## status/task-action - per-pause needs-input labels

**Action:** Split the operator-facing `NEEDS_INPUT` label for coding pauses while
leaving action keys, commands, markers, dispatch, and JSON `next_action` routing
unchanged. `brainstorm_waiting` now renders "Answer questions",
`plan_waiting` renders "Review plan draft", `review_waiting` renders "Needs
review decision", and `finalize_waiting` renders "Confirm finalize".
`execute_waiting` and descriptor-generic waiting rows still render the shared
"Needs your input" label.

`Hive::Commands::Status::ACTION_LABEL_ORDER` now lists every differentiated
label next to the retained generic label so text status groups and TUI snapshots
keep those actionable rows above "Error". Added a consistency guard that fails
if a future `Hive::TaskAction::ACTIONS` label is omitted from the sorter, plus
positive label tests and a TUI column-fit regression for the longest new label.

**Verification:** Focused TaskAction, status, TUI snapshot/tasks-pane, and bot
fixture tests passed, followed by `bundle exec rake test`.

**Pages:** [[modules/task_action]], [[commands/status]], [[commands/stage_action]]
