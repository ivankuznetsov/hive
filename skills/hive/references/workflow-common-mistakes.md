# Workflow creator common mistakes

- Editing an existing descriptor after discovering a collision. Stop and
  propose Hive’s deterministic available ID instead.
- Scaffolding before checking the installed version, project, and ID inventory.
- Treating neutral blank scaffolding as permission to select a research,
  writing, or coding template by keyword alone.
- Adding stage indices to YAML. Array order is authoritative.
- Adding `input` to an ordinary agent stage when its instruction can name the
  prior artifact; `input` belongs to supported consumers such as human/council
  stages.
- Emitting agent/model on every stage instead of inheriting project choices.
- Adding checkpoints for harmless local work, or omitting them before a named
  material decision.
- Turning “before publishing” into an inferred publish stage. Approval may mark
  an artifact publish-ready but never publishes it.
- Claiming success after YAML parsing alone. Production workflow resolution and
  `hive workflow validate` are required.
- Creating or running a task when the original request asked only for the
  workflow, or retrying a moved task without its stable idempotency key.
- Using force, overwriting generated paths not returned by the scaffold, or
  repairing invalid output in unrelated existing files.
