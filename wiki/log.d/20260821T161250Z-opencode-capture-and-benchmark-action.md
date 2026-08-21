# Bound OpenCode output drain and align benchmark plan actions

- Extended the post-exit OpenCode capture drain from two to thirty seconds and
  mark the result truncated before forcibly closing a still-live capture. This
  prevents large sanitized session exports from being cut into malformed JSON
  or misreported as an empty terminal message.
- Kept the drain bounded and retained the close, join, and kill fallback for a
  genuinely hung or defensive IO path.
- Accepted a correlated tool-only OpenCode terminal step with empty prose as a
  completed normalized run. Sanitized export, terminal finish evidence, and
  the stage's required artifact remain mandatory, so an empty or partial
  process capture still fails closed.
- Made `TaskAction` ignore plan-review projections when the explicit benchmark
  configuration grant has disabled plan review, matching the existing
  transition guard and execute-entry behavior.
- Added focused lifecycle and classification tests; complete Pi/OpenCode
  benchmark results and judge coverage remain live validation rather than a
  result claimed by this fragment.
