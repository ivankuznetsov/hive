## [2026-06-23T04:44:31+01:00] init — harden `--new-workflow` rollback, binding durability, and YAML safety

**Action:** Review fix-pass on the `hive init --new-workflow` feature:
- The fresh path now commits `config.yml` alongside the descriptor on `hive/state`, so the `default_workflow` binding is durable against a hive-state `reset --hard`/`clean` — symmetric with the existing-project path.
- The existing-project rollback now resets the `.hive-state` index for the scaffold pathspecs after a commit failure (`Init#reset_hive_state_index`), so a half-rolled-back rebind can no longer ride the next unrelated bare `git commit`.
- `default_workflow` is now emitted quoted (`default_workflow: "ID"`) in both the template and `write_default_workflow!`, so keyword-like ids (`yes`/`on`/`null`/…) are not coerced to booleans/nil by `YAML.safe_load`.
- Human next-step hints shell-escape the project basename; the `--workflow`/`--new-workflow` mutual-exclusivity check now runs before the clean-tree check for a clearer error.
- Internal cleanups: collapsed the `WorkflowDescriptorRef` stand-in (the existing path now carries the real resolved descriptor), extracted a shared `Workflow.commit_workflow_scaffold` helper, promoted the stateless `Workflow` scaffold helpers to class methods, and added a cleanup-failure warning to `rollback_scaffold`.

**Refreshed pages:**
- [[commands/init]]
