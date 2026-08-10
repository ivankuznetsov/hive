---
title: Align managed prompts with target write authority
---

**Action:** Generic managed workflow prompts now defer target edits to the
descriptor's stage instructions and runtime permission scope. This removes the
contradictory task-folder-only sentence that caused a managed `yolo` repair
actor to refuse edits even though Hive had deliberately supplied the registered
project root as target context. Ordinary authored agents retain the exact
task-folder-only prompt boundary.

**Tests:** Extended the managed-yolo agent regression to require target-context
wording and reject the contradictory constraint, and added an unmanaged control
that preserves the task-folder-only wording.
