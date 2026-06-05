---
title: hive generate-name
type: command
source: lib/hive/commands/generate_name.rb, lib/hive/display_name/generator.rb, lib/hive/display_name/sanitizer.rb, templates/display_name_prompt.md.erb
created: 2026-06-03
updated: 2026-06-03
tags: [command, display-name, task-id]
---

**TLDR**: `hive generate-name TARGET` resolves a task by path, slug, or numeric id, asks the configured execute agent for a short title, sanitizes the final message, writes it into `<task>/meta.yml` as `display_name`, and commits `hive: <stage>/<slug> named` on `hive/state`.

## Usage

```bash
hive generate-name TARGET [--project NAME] [--stage STAGE]
```

`TARGET` is resolved through `Hive::TaskResolver`, so it accepts:

- A task folder path.
- A bare slug.
- A numeric task id from `<task>/meta.yml`.

`--project` scopes slug/id lookup to one registered project. `--stage` accepts a full stage dir (`2-brainstorm`) or short name (`brainstorm`) and narrows slug/id lookup or validates a path target.

There is no `--json` payload for this command. On success it prints the generated display name. On failure inside the display-name generator it prints nothing and returns nil; resolver failures still surface through the normal `Hive::Error` path.

## Pipeline

`Hive::Commands::GenerateName#call`:

1. Resolve `TARGET` via `Hive::TaskResolver`.
2. Run `Hive::DisplayName::Generator.new(task).call`.
3. Print the returned name when present.

`Hive::DisplayName::Generator` loads the project config and uses `Hive::Stages::Base.stage_profile(cfg, "execute")`, so display-name generation follows the same agent selection as execute-stage development. The prompt is rendered from `templates/display_name_prompt.md.erb` and asks for a title of at most five words.

The subprocess command is built from the profile binary, headless flag, Claude permission flags, output-format flags, and the prompt. Codex receives the prompt on stdin (`-`); other profiles receive it as an argv prompt. Output is written to `<task.log_dir>/display-name-<UTC>.log`.

`Hive::Agent::MessageExtractor` parses structured agent streams and extracts the final assistant/result text from Claude/Codex-shaped JSON lines. If no structured final message is found, the generator falls back to the last 64 KiB of plain output.

`Hive::DisplayName::Sanitizer` removes markdown/code fences, trims quotes/punctuation, collapses whitespace, and caps the title at 60 characters without splitting the last word when possible. Empty sanitized output is ignored.

## State effects

Successful generation calls `Hive::TaskMeta.update_display_name(task.folder, name)`, preserving the existing id and slug, then commits through `Hive::GitOps#hive_commit(stage_name:, slug:, action: "named")`. Git commit failures are swallowed after the sidecar update, matching the command's best-effort display-name posture.

`hive new` starts this command asynchronously after the captured-task commit:

```bash
hive generate-name <task_dir>
```

That spawn redirects the wrapper command's stdout/stderr to `<state_home>/logs/display-name.log` and intentionally does not block capture.

## Tests

- `test/integration/generate_name_test.rb` covers successful sidecar update + commit and failure leaving `display_name` unchanged.
- `test/unit/display_name_sanitizer_test.rb` covers sanitization.
- `test/unit/agent_message_extractor_test.rb` covers structured/plain message extraction.

## Backlinks

- [[commands/new]] · [[modules/task_resolver]]
- [[modules/task]] · [[state-model]]
