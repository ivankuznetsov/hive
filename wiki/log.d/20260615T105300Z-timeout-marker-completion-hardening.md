# tmux-mode stage completion hardening (marker-skip stranding)

Two levers so a tmux agent that finishes its work but returns to idle WITHOUT
stamping the terminal marker no longer strands the stage at `reason=timeout`:

- **Prompt hardening (U1):** `templates/{open_pr,artifacts,finalize,plan}_prompt.md.erb`
  gain a "## Completion — REQUIRED" section restating the exact terminal marker
  as the literal last line ("write it even if all work is already done; no other
  line follows it"). Marker strings unchanged. Runner-owned templates
  (`execute`, `review`) deliberately untouched — there the runner stamps the
  marker. New `test/unit/templates/marker_last_line_test.rb` renders each
  template and pins the marker as the last line.

- **Single bounded timeout re-entry (U2):** `StaleAgentHealer#auto_recoverable_error?`
  now clears-and-re-dispatches `reason=timeout` EXACTLY ONCE
  (`TIMEOUT_RECOVERY_LIMIT = 1`), gated to `TIMEOUT_RECOVERABLE_STAGES`
  (`5-open-pr`, `7-artifacts`). Capped via a new per-reason
  `error_auto_recovery_limit_for` (the general agent-loss budget stays 3), keyed
  by `[project, slug, stage, reason]` so a fresh timeout `marker_id` can't earn a
  fresh budget. After one retry it stays red with a `stage_timeout` exhaustion +
  remediation. open-pr re-enters its `open_pr_already_open` arm; artifacts
  idempotently re-collects `artifact.md`; only `3-plan` (unaffected here) needs
  the explicit requeue.

This **deliberately revises** the rule in
`docs/solutions/architecture-patterns/background-spawn-and-signal-aware-marker-healing-2026-04-28.md`
that `reason=timeout` is never auto-healed: the carve-out is narrow (two stages
whose re-entry is provably idempotent) and bounded (one attempt). See the
refinement note appended to that learning.

Plan: `docs/plans/2026-06-15-001-fix-tmux-marker-completion-hardening-plan.md`.
The separate primary fix (a nudge-on-idle inside `wait_for_terminal_marker`)
remains tracked on its own.
