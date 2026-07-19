## 2026-07-18 — Share stage worktree pointer validation

- Moved the identical open-PR and finalize stage-entry checks into
  `Hive::Stages::Base.worktree_pointer_or_exit`.
- Preserved the pointer shape, warnings, and exit status while giving the
  missing-pointer and missing-directory policy one owner.
- Verified the affected stage and base behavior together: 62 runs, 303
  assertions, zero failures, zero errors, and zero skips.
