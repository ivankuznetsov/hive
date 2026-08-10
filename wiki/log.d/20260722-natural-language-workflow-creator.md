## 2026-07-22 — Natural-language workflow creator

- Added the `hive-workflow-creator` route inside the one canonical `/hive`
  AgentSkill. It inventories the installed version/project/workflow IDs,
  scaffolds only through Hive, validates the normalized graph, reports every
  inferred default, and creates no task unless the original request asks.
- Added durable descriptor-declared human outcomes and
  `hive decide TARGET OUTCOME --from STAGE [--note TEXT] [--json]`. Human
  stages remain `WAITING`, are never daemon-dispatched, record idempotent
  decisions, and can complete with an artifact or return to a named stage.
- Added read-only `hive workflow validate ID --json`, no-write
  `hive init --new-workflow ID --minimal --preview --json`, and idempotent
  machine-readable `hive new ... --idempotency-key KEY --json`.
- The editorial acceptance path is exactly
  `research -> draft -> approval`: approve records non-empty `draft.md` as
  publish-ready and completes; reject records the decision and resets draft to
  `WAITING`. No publish stage or external action is inferred.
- Added hermetic AE1–AE5 acceptance coverage plus a separate protected OpenClaw
  proof whose attestation binds the exact candidate skill, prompt, commands,
  created files, validation graph, creation-only no-task result, explicit
  create/run no-op retry, operational status, secret scan, and cleanup.
- Updated manual/natural-language workflow docs and the canonical OpenClaw
  projection. Hive-site `#23116` remains a non-blocking wording handoff; this
  change does not select a release version, publish, tag, or deploy.
