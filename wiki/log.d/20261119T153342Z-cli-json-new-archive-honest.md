---
title: hive new and archive closure --json say exactly what happened
type: fix
created: 2026-11-19
updated: 2026-11-19
tags: [cli, json, new, archive, closure, idempotency, incident]
---

Two `--json` surfaces misled an agent on 2026-11-19.

- `hive new PROJECT "<text>" --json` without `--idempotency-key` printed the
  human `hive: captured …` / `next: mv …` lines, not `hive-new.v1`. The agent's
  parse failed, it assumed the create had failed, and its retry created a
  duplicate task.
- `hive archive TARGET --reason cancelled --attestation … --yes --json` printed
  the `hive-task-closure-input` preview (`ok: true`) and archived nothing. The
  same command without `--json` archived. The agent read `ok: true` as an
  archived task.

Changes:

- **`hive new --json`** always prints exactly one `hive-new.v1` document on
  stdout, success or error, keyed or not. `Commands::New` no longer gates
  `@json` on the key. The empty-text check moved from `CLI#new_task` into
  `New#call`, so it is an error document. `lib/hive/commands/new.rb` declares
  a `new` usage contract (`hive-new`, `error_kind: usage`), so Thor rejections
  before dispatch are JSON too. Notices and the local-context banner were
  already on stderr. The schema is unchanged, and `command_intake_disabled`
  was already JSON.
- **`hive archive … --json`** picks its mode from `--yes`. Without it, the
  preview keeps `hive-task-closure-input` and adds `mode: "preview"`,
  `applied: false`, and `next`, the shell-quoted `--yes --json` command (null
  while blocked). These are additive, optional schema properties. With `--yes`,
  the CLI confirms the closure and prints the new `hive-task-closure-result.v1`
  (`applied: true`, `reason`, `task`, `preview_digest`, `receipt_digest`,
  `receipt`). Every closure JSON failure, in either mode, is that schema's
  error arm with `mode` and, for a blocked `--yes`, the failed `preview`.
  `--idempotency-key` now combines with `--json --yes`; a keyed preview is
  still refused. `Hive::TaskClosureResult` builds all three shapes and owns
  the closed `error_kind` list.
- `hive help new`, `hive help archive`, [[commands/new]],
  [[commands/stage_action]], [[cli]], `docs/cli.md`, and the canonical skill's
  `workflow-actions.md` (OpenClaw projection regenerated) describe the
  contracts.
- **Tests:** single-document stdout for unkeyed `new --json` success, empty
  text, unknown project, missing PROJECT (Thor), and unknown workflow, in
  process and through `bin/hive`; closure preview (`applied: false`, `next`,
  no confirm), `--json --yes` apply, blocked apply, keyed apply, and keyed
  preview refusal; real-process failure documents; an end-to-end cancellation
  that runs the preview's `next` command and lands the task in `9-done`; the
  closure-result error-kind registry.
