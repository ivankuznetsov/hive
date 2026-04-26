---
title: Hive::Reviewers
type: module
source: lib/hive/reviewers.rb, lib/hive/reviewers/{base,agent,synthetic_task}.rb
created: 2026-04-26
updated: 2026-04-26
tags: [reviewer, dispatch, agent, architecture]
---

**TLDR**: Reviewer adapter layer for the 5-review stage's Phase 2. `Hive::Reviewers.dispatch(spec, ctx)` returns an adapter (currently only the agent-based `Reviewers::Agent`) that spawns an LLM CLI with the configured skill and prompt; the agent writes findings to `reviews/<output_basename>-<pass>.md`. `Reviewers::Context` carries per-spawn fields; `Reviewers::Result` is the return shape; `Reviewers::SyntheticTask` is the task-shaped facade `spawn_agent` requires for sub-spawns inside the review stage. Tool-specific linters are NOT a reviewer kind — they belong in `review.ci.command` per ADR-014. References ADR-014 / ADR-015.

## Public API

```ruby
Hive::Reviewers.dispatch(spec, ctx)            # → Reviewers::Agent.new(...)
Hive::Reviewers::Context.new(worktree_path:, task_folder:, default_branch:, pass:)
Hive::Reviewers::Result.new(name:, output_path:, status:, error_message:)
Hive::Reviewers.synthetic_task_for(ctx)        # → SyntheticTask facade
```

`dispatch`'s `kind` discriminator defaults to `"agent"`. An explicit `kind: "linter"` raises `UnknownKindError` (exit code `CONFIG = 78`) with a message pointing the user at `review.ci.command` rather than silently ignoring the request.

## `Reviewers::Base`

Shared shell for adapter classes. Subclasses set:

- `name` — derived from `spec["name"]`.
- `output_path` — `<task_folder>/reviews/<output_basename>-<pass>.md`.
- `ensure_reviews_dir!` — `FileUtils.mkdir_p(File.dirname(output_path))`.

`Result` (from Base) is a `Data.define(:name, :output_path, :status, :error_message)` with a `#error?` predicate.

## `Reviewers::Agent`

The v1 reviewer adapter. `run!`:

1. Resolves the agent profile via `AgentProfiles.lookup(spec["agent"])`.
2. Reads `spec["prompt_template"]`; resolves it via `Stages::Base.resolve_template_path` (path-escape guard).
3. Renders the prompt with bindings: `project_name`, `worktree_path`, `task_folder`, `default_branch`, `pass`, `output_path`, `skill_invocation` (formatted via `profile.skill_syntax_format`), `user_supplied_tag`.
4. Spawns via `Stages::Base.spawn_agent(synthetic_task, prompt:, add_dirs: [task_folder], cwd: worktree_path, profile:, status_mode: :output_file_exists, expected_output: output_path, max_budget_usd: spec["budget_usd"] || 50, timeout_sec: spec["timeout_sec"] || 600, log_label: "review-#{name}-pass#{NN}")`.
5. Returns `Result.new(status: :ok | :error, ...)`.

`status_mode: :output_file_exists` is critical: reviewer spawns own a per-pass output file, not the task marker — the orchestrator's `REVIEW_WORKING` marker must persist across each reviewer's spawn (per ADR-021).

## `Reviewers::SyntheticTask`

`Stages::Base.spawn_agent` expects a task-shaped object (`folder`, `state_file`, `log_dir`, `stage_name`). For sub-spawns inside the review stage there is no real task object per spawn — every reviewer / triage / ci-fix / browser-test invocation needs its own task-like facade so `Hive::Agent` can write per-spawn logs and locks without colliding with the orchestrator's outer task.

`Hive::Reviewers.synthetic_task_for(ctx)` is the shared helper (M-04 dedup). Used by `Reviewers::Agent`, `Stages::Review::Triage`, `Stages::Review::CiFix`, `Stages::Review::BrowserTest`.

## Configuration

Reviewers live in `cfg.review.reviewers`. Each entry:

```yaml
- name: claude-ce-code-review        # required (validated unique)
  kind: agent                        # optional; default "agent"
  agent: claude                      # required (must resolve in AgentProfiles)
  skill: ce-code-review              # required (passed into skill_syntax_format)
  prompt_template: reviewer_claude_ce_code_review.md.erb  # required
  output_basename: claude-ce-code-review                  # required (validated unique, non-empty)
  budget_usd: 50                     # optional; default 50
  timeout_sec: 600                   # optional; default 600
```

`Hive::Config.validate_reviewers!` enforces uniqueness on `name` and `output_basename`, non-empty `output_basename`, registered `agent`, and presence of `name` / `skill` / `prompt_template`. The Array replaces wholesale on per-project override (no per-element merge — see [[modules/config]] deep-merge semantics).

## Tests

- `test/unit/reviewers_test.rb` — dispatch (agent / linter / unknown), Context / Result shape.
- `test/unit/reviewers/agent_test.rb` — adapter render + spawn integration.
- `test/unit/reviewers/synthetic_task_test.rb` — facade shape.

## Backlinks

- [[stages/review]] · [[modules/agent_profile]] · [[modules/config]]
- [[decisions]] (ADR-014 / ADR-015)
