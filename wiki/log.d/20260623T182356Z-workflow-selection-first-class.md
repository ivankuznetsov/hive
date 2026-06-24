---
date: 2026-06-23T18:23:56Z
slug: workflow-selection-first-class
pages: [commands/init, commands/web]
---

## init/web — workflow selection is a setup step

`hive init` now renders the TTY workflow chooser as an explicit `Workflow:`
step and includes an inline `author a new workflow` entry. The author entry
prompts for an id, re-prompts on reserved, invalid, or colliding ids, and then
routes through the existing `--new-workflow` scaffold/bind path so the full
setup questionnaire still runs on fresh init.

Hivebox `/repos/new` now has a select-only Workflow control. Fresh setup lists
the built-ins (`coding`, `content`) with `coding` selected; re-run setup lists
built-ins plus project-authored workflows and preselects the project's current
`default_workflow`. The selected value is passed to
`Hive::Commands::Init.new(..., workflow:)`, leaving the `prompts:` answers hash
unchanged.

Updated [[commands/init]] and [[commands/web]]. Coverage now includes CLI
prompt selection, non-TTY skip, inline authoring/re-prompt cases, request-level
web posting, and a Capybara Playwright setup flow that writes real
`config.yml`.
