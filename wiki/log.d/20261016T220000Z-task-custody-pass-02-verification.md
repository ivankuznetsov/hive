---
title: Verify and complete the task-custody pass-02 fixes
date: 2026-10-16
tags: [task, rollback, decide, approve, workflow-package]
---

- Decide's return-to-stage rollback now restores decision files under the project commit lock (Approve has already released custody when it raises), and both return and repeat rollbacks raise `Hive::RollbackFailed` when a stale or replaced task blocks restoration.
- Removed decide's `rollback_failed` error-kind mapping: `hive-decide.v1` has no such enum value, so a `--json` rollback failure would have failed envelope validation; it now reports `error`.
- Approve revalidates the observation before renaming, so a same-path replacement is never moved into the destination stage.
- Approve and `TaskMigrator` share `TaskMeta.relocate_across_devices!`, which creates the cross-device copy exclusively and holds it by handle before copying, so no cleanup path can delete a pre-existing or replaced destination.
