---
date: 2026-07-01
slug: review-error-reason-input-contract
pages: [stages/review, state-model, modules/markers]
---

Documented `Hive::ReviewErrorReason.classify`'s input contract after review
found the code comments and wiki overstated what the classifier delivers in
the field. `classify` inspects whatever text the caller passes and never
fetches raw agent output on its own; today's triage/fix plumbing forwards a
condensed wrapper string (`expected output file missing or empty`,
`tmux_session_terminated before writing …`, `triage agent failed (timeout)`)
that matches no PATTERN, so production input almost always resolves to
`unknown` — the named buckets (`merge_conflict`, `network_timeout`,
`tool_permission_denied`, `agent_crashed`) fire only when raw stdout/stderr
carrying their signal is passed through. Added the caveat to the `classify`
docstring and to the review/state-model/markers wiki pages so a maintainer
does not build TUI affordances, healer arms, or metrics around buckets that
rarely appear. The raw cause stays visible in the marker's `message=` attr.
