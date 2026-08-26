## [2026-08-25T23:35:00Z] context provenance — bind agent candidates to the task folder

**Action:** Context provenance prompts now provide the exact task-folder path
for the optional agent-selection candidate. Agents normally run with an owned
Git worktree as their cwd, so the former task-relative instruction could create
`context-receipts/*.json.next` inside that Git worktree, fail clean-worktree
custody, and repeat on every automatic recovery. Focused coverage pins the
absolute task-artifact target while receipt contents remain forbidden from
containing absolute host paths.
