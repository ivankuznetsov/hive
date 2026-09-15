### Archive unwanted tasks without delivery claims

- Add `cancelled` to the existing task-closure flow, including CLI, Web, and bot.
- Require an operator reason, not GitHub evidence. Preserve history and dirty
  worktrees, refuse live owners, and skip terminal agents and completion hooks.
- Allow cancellation despite missing prerequisites; cancelled tasks cannot
  satisfy another task's delivery prerequisite.
- Reuse the existing receipt and replay path; no new tables or scheduler jobs.
- Live validation remains pending deployment of a runtime that understands the
  new receipt reason. Do not create these receipts under an older daemon.
