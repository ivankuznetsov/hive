## Execution entry and pause safeguards

- Validate the task branch and recorded baseline ancestry before launching an
  implementation agent, retaining post-execution checks and existing repair
  reasons. Do not rewrite pointers or require every task to match latest main.
- Classify known technical execute pauses as execution repair in marker and
  condition status paths. Preserve real input pauses and manual recovery.
- Add real-Git regressions for rewritten history, missing baseline objects,
  wrong branches, valid older bases, and post-launch branch changes.
- Preserve explicit branch/history repair reasons when the condition gate also
  reports no changes; marker, status, and recovery instructions share one
  primary-diagnostic selector.
