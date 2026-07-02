## [2026-07-01T21:13:54Z] openclaw — marker recovery guidance

**Action:** Added a `## Marker Recovery` section to the OpenClaw `/hive` skill, placed immediately after Safety Boundaries, so operators inspect with `hive status --json` / `hive daemon status --json`, wait for healer-managed signatures, start a stopped daemon with `hive daemon start --detach`, and ask before guarded manual `hive markers clear` remediation.

**Coverage:** Added `test_umbrella_skill_classifies_recovery_markers` to pin the recovery literals, section ordering, and the existing Safety Boundaries confirmation language. Updated [[operating]] and [[testing]].
