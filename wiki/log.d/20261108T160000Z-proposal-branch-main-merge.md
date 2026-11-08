## 2026-11-08 — merge main into track-skill-and-workflow-proposal

Brought the proposal-tracking branch up to date with `main`. Main's
current-format-only runtime database model (single `001` migration, base schema
v2) superseded the branch's no-op `002_version_proposal_subject_binding.rb`
version fence, so that migration and its incremental v1→v2 test were dropped;
`Hive::Attempts::Record` keeps attempt value contract v5 alongside main's
terminal receipt v2. The `proposal` pre-dispatch JSON usage contract moved from
`bin/hive` into `Hive::CliUsageContracts.declare` in
`lib/hive/commands/proposal.rb`, matching main's per-command boundary layout.

**Verification:** Focused attempts, runtime-control-plane, config, proposal,
schema-file, and CLI usage-error tests, plus RuboCop over the changed Ruby files.

Follow-up merge-integration fixes: `proposal` is explicitly `LOCAL_ONLY` in
`Hive::Remote::CommandPolicy` (main's remote CLI requires every command to be
classified); the task-journal kinds `proposal_source_recorded` and
`proposal_context_supplied` are `:noise` in the daily-digest materiality
matrix; and `wiki/modules/config.md` was regenerated with
`script/generate-config-defaults-doc` to include the `proposals` defaults.
