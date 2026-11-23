## 2026-11-22 — `hive stack` changes a task's dependency after creation

- Request: stacking one task on another was only possible at capture
  (`hive new --depends-on`); the only later route was hand-editing `meta.yml`
  (no lease, no commit, no validation) or letting the plan stage adopt a
  frontmatter declaration.
- Change: new `hive stack TARGET (--on REF... | --clear) [--project NAME] [--json]`
  (`Hive::Commands::Stack`, schema `hive-stack.v1`). Same grammar and field as
  `hive new --depends-on`; works at every unfinished stage; one `hive/state`
  commit per change, with `meta.yml` restored if the commit fails.
- Validation matches creation (grammar, cycle, self-reference refused; missing
  or unhealthy prerequisites written and reported as a hold). Added: refuse a
  terminal-stage task, a draft-PR workflow, and a value that disagrees with the
  task's own `plan.md` frontmatter (never edits the reviewed plan).
- Custody: observe → commit lock → task lease, like display-name. A running
  stage agent's lease makes the command fail retryably (exit 75).
- No rebase: a task that already has a worktree keeps its branch; the change
  gates scheduling and open-pr's PR base, and the command notes the recorded
  `base_ref`.
- `DependencySnapshot.proposed_dependency_verdict` and the
  `dependency_overrides:` option on `targeted_admission_context` replace an
  existing task's snapshot in place (an overlay would duplicate its identity).
- `stack` is `LOCAL_ONLY` in `Remote::CommandPolicy`.
- Pages: [[commands/stack]] (new), [[modules/task_dependencies]],
  [[commands/new]], [[cli]].
