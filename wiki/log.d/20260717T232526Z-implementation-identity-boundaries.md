## [2026-07-17T23:25:26Z] implementation identity — harden durable ownership boundaries

**Action:** Bound legacy identity reconstruction to the current durable attempt's project, task, and numeric generation; made downstream generation reads validate journal records against the Attempts store and fail closed on malformed, empty, unreadable, or unbound journals; and carried the persisted provider into execute failure markers.

**Protection:** Implementation-owning stages now resolve identity before their protected-file snapshot and pass that exact resolution into the agent spawn, avoiding heartbeat-driven projection rebuilds inside the protected interval. `task-journal.jsonl` plus `task-projection.json` are orchestrator-owned files. Review synthetic tasks carry the durable slug/id required by journal events. Focused regression coverage exercises cross-project attempt collisions, CI task identity, journal tampering, generation corruption, and provider drift.

**Compatibility:** Provider-default discovery accepts a top-level Codex TOML model assignment with an inline comment. The web golden-path fixture pins the concrete model exposed by its fake Claude CLI, and the CLI E2E sandbox pins its synthetic Codex model, so clean runners capture execute identity before launch without borrowing operator-owned provider settings.
