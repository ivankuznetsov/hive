---
date: 2026-07-14
slug: legacy-bench-workflow-migration
---

## Legacy bench workflow migration

- Keep tasks using the exact pre-built-in project `bench.yml` visible and
  runnable after upgrading to the built-in `bench` workflow.
- Teach `hive init PROJECT --workflow bench` to archive that legacy descriptor
  and a copy of its instructions while retaining the shared instruction path
  and installing the packaged runtime in the same hive-state commit.
- Restore the legacy descriptor, prior runtime, and clean index state when that
  hive-state commit fails, so a rejected migration remains retryable.
- Preserve strict built-in collision failures for modified or independently
  authored project workflows named `bench`.
- Live-smoke the migration against hive-bench's existing state: retain the
  shared instruction path used by `bench-generate`, pin the one field-less
  coding task before rebinding the default, and preserve all nine status rows
  plus the unrelated dirty-state fingerprint.
