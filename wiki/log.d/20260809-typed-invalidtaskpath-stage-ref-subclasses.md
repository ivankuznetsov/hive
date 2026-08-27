# 2026-08-09 — Typed InvalidTaskPath subclasses for stage-ref resolution

## What changed

`Hive::Workflows.resolve_stage_ref_across_workflows` now raises typed
internal exceptions instead of plain `Hive::InvalidTaskPath`:

- `Hive::Workflows::AmbiguousStageRef` — ref matches >1 workflow
- `Hive::Workflows::UnknownStageRef` — ref matches no workflow

Both subclass `Hive::InvalidTaskPath`, so public rescues, error envelopes,
and the `USAGE` exit-code mapping are unchanged. Messages are identical.

Internal classifiers (`Workflows.stages_for_project`,
`Workflows.assert_known_stage_filter!`, `Approve#known_stage_ref?`) now
rescue by class instead of parsing exception text
(`e.message.start_with?("ambiguous stage")`). Exception messages are no
longer an internal API.

## Why

Message-based classification breaks silently if a diagnostic string is
reworded, and it couples user-facing copy to control flow. The architecture
patrol flagged this pattern (finding
`pr-1166-86c364158108491b:replace-stage-error-message-parsing-with-typed-errors`).

## Tests

- `test/unit/workflows_test.rb`: pins both typed raises and their
  `InvalidTaskPath` compatibility.
- `test/unit/workflows/project_test.rb`: ambiguous filter re-raises as
  `AmbiguousStageRef` through `stages_for_project`.
