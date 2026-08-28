## Architecture Patrol resumes after no-job merge intake

Architecture Patrol merge catch-up now records the exact processed PR prefix
separately from the subset that produced or adopted jobs. Deterministic
no-manifest classifications can therefore resume after restart without
weakening fail-closed intake-index validation. The v2 progress sidecar has no
runtime compatibility path: explicit `hive migrate` discards v1 continuation
state, then the daemon replays from its authoritative checkpoint.
