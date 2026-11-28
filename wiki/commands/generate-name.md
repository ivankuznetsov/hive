---
title: hive generate-name
type: command
source: lib/hive/commands/generate_name.rb, lib/hive/display_name/generator.rb, lib/hive/display_name/sanitizer.rb, templates/display_name_prompt.md.erb
created: 2026-06-03
updated: 2026-09-02
tags: [command, display-name, task-id]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-generate-name) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive generate-name TARGET` resolves a task by path, slug, or numeric id, asks the configured execute agent for a short title, sanitizes the final message, writes it into `<task>/meta.yml` as `display_name`, and commits `hive: <stage>/<slug> named` on `hive/state`.

## Pipeline

`Hive::Commands::GenerateName#call`:

1. Resolve `TARGET` via `Hive::TaskResolver`.
2. Run `Hive::DisplayName::Generator.new(task).call`.
3. Print the returned name when present.

`Hive::DisplayName::Generator` loads the project config and uses `Hive::Stages::Base.stage_profile(cfg, "execute")`, so display-name generation follows the same agent selection as execute-stage development. The prompt is rendered from `templates/display_name_prompt.md.erb` and asks for a title of at most five words.

The subprocess command is built from the profile binary, headless flag, Claude permission flags, output-format flags, and the prompt. Codex receives the prompt on stdin (`-`); other profiles receive it as an argv prompt. Output is written to `<task.log_dir>/display-name-<UTC>.log`.

`Hive::Agent::MessageExtractor` parses structured agent streams and extracts the final assistant/result text from Claude/Codex-shaped JSON lines. Streaming text deltas are accumulated in order; a later complete result replaces the accumulated stream. If no structured final message is found, the generator falls back to the last 64 KiB of plain output.

`Hive::DisplayName::Sanitizer` removes markdown/code fences, trims quotes/punctuation, collapses whitespace, and caps the title at 60 characters without splitting the last word when possible. Empty sanitized output is ignored.

## State effects

Successful generation calls the guarded `Hive::TaskMeta.update_display_name` path, which preserves every declared sidecar field, including workflow provenance, then this command commits through the centrally serialized `Hive::GitOps#hive_commit(stage_name:, slug:, action: "named")`. Git commit failures are still swallowed after the sidecar update, matching the command's best-effort display-name posture; ordinary concurrent hive-state writers no longer create an unlocked index race.

`hive new` starts this command asynchronously after the captured-task commit:

```bash
hive generate-name <task_dir>
```

That spawn redirects the wrapper command's stdout/stderr to `<state_home>/logs/display-name.log` and intentionally does not block capture. If it fails, rerun this command for the task. Daemon and status refreshes never retry name generation.

## Tests

- `test/integration/generate_name_test.rb` covers successful sidecar update + commit and failure leaving `display_name` unchanged.
- `test/unit/display_name/generator_test.rb` covers bounded generation diagnostics, task replacement/deletion, lock contention, and the no-update/no-commit failure contract.
- `test/unit/display_name_sanitizer_test.rb` covers sanitization.
- `test/unit/agent_message_extractor_test.rb` covers structured/plain message extraction.

## Backlinks

- [[commands/new]] · [[modules/task_resolver]]
- [[modules/task]] · [[state-model]]
