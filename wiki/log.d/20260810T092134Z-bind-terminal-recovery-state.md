## 2026-08-10 Bind terminal recovery state to its attempt

- Refresh the persisted edit-resume mtime baseline when a detached durable task attempt becomes terminal, matching the existing local-child completion behavior while preserving edits newer than the attempt's end time.
- Refuse to overlay an old terminal recovery receipt when the current task row belongs to a different live attempt.
- Add focused dispatcher and operational-snapshot regressions for both dogfood failures.
