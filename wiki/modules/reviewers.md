---
title: Hive::Reviewers
type: module
source: lib/hive/reviewers.rb, lib/hive/reviewers/{base,agent,codex_review,synthetic_task,plan_context}.rb
created: 2026-04-26
updated: 2026-06-10
tags: [reviewer, dispatch, agent, codex, patrol, architecture]
---

**TLDR**: Reviewer adapter layer for the 6-review stage's Phase 2. `Hive::Reviewers.dispatch(spec, ctx)` returns an adapter keyed by the spec's `kind`: `"agent"` (default → `Reviewers::Agent`, spawns an LLM CLI with the configured CE skill+prompt; the agent writes the findings file itself) or `"codex_review"` (→ `Reviewers::CodexReview`, runs codex's native single-pass `codex review` and CAPTURES its stdout into the findings file — the cheap patrol default). Either way findings land in `reviews/<output_basename>-<pass>.md` in the GFM-checkbox format the triage/fix loop consumes. `Reviewers::Context` carries per-spawn fields; `Reviewers::Result` is the return shape; `Reviewers::SyntheticTask` is the task-shaped facade `spawn_agent` requires for headless sub-spawns inside the review stage. `Reviewers::PlanContext` renders the task's `plan.md` into an authoritative-on-scope block embedded in every reviewer system prompt, so reviewers stop flagging plan-deferred scope as defects. Tool-specific linters are NOT a reviewer kind — they belong in `review.ci.command` per ADR-014. References ADR-014 / ADR-015.

## Public API

```ruby
Hive::Reviewers.dispatch(spec, ctx)            # → Reviewers::Agent.new(...)
Hive::Reviewers::Context.new(worktree_path:, task_folder:, default_branch:, pass:)
Hive::Reviewers::Result.new(name:, output_path:, status:, error_message:)
Hive::Reviewers.synthetic_task_for(ctx)        # → SyntheticTask facade
```

`dispatch`'s `kind` discriminator defaults to `"agent"`; `"codex_review"` selects `Reviewers::CodexReview`. An explicit `kind: "linter"` raises `UnknownKindError` (exit code `CONFIG = 78`) with a message pointing the user at `review.ci.command` rather than silently ignoring the request. Any other value also raises `UnknownKindError`.

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
3. Renders the prompt with bindings: `project_name`, `worktree_path`, `task_folder`, `default_branch`, `pass`, `output_path`, `skill_invocation` (formatted via `profile.format_skill_invocation`, which honors profile-specific syntax — pi receives `/skill:<name>`), `user_supplied_tag`.
4. Spawns via `Stages::Base.spawn_agent(synthetic_task, prompt:, add_dirs: [task_folder], cwd: worktree_path, profile:, status_mode: :output_file_exists, expected_output: output_path, max_budget_usd: spec["budget_usd"] || 50, timeout_sec: spec["timeout_sec"] || 3600, log_label: "review-#{name}-pass#{NN}")`.
5. Returns `Result.new(status: :ok | :error, ...)`.

When `claude.mode: tmux`, `Stages::Review.run_reviewers` opens one shared `Hive::ClaudeLauncher` session per pass for Claude agent reviewers. `Reviewers::Agent#run_in_session!` sends each Claude reviewer prompt into that same pane sequentially and still waits on that reviewer's own `output_path`. Non-Claude reviewers and all reviewers under `claude.mode: headless` keep the `run!` / `spawn_agent` path.

`status_mode: :output_file_exists` is critical: reviewer spawns own a per-pass output file, not the task marker — the orchestrator's `REVIEW_WORKING` marker must persist across each reviewer's spawn (per ADR-021).

## `Reviewers::CodexReview`

Native-`codex review` adapter (added 2026-06-10). The **patrol-default** reviewer: one cheap, tuned, read-only `codex review` pass instead of the multi-persona `ce-code-review` fan-out (6–18 subagents). `run!`:

1. Resolves the codex profile via `AgentProfiles.lookup(spec["agent"])` and calls `check_version!` (preflight; missing binary → `:error "preflight failed: …"`).
2. Renders `templates/reviewer_codex_native_review.md.erb` (no `skill_invocation` binding — codex review takes no CE skill).
3. Spawns `codex review --title <title> <prompt>` with `cwd = worktree_path`, capturing combined stdout+stderr under a wall-clock timeout (`spec["timeout_sec"]`, default 7200; process-group TERM on timeout).
4. Validates: stdout must contain at least one `## High|Medium|Nit` header. Valid → trims the codex banner to the first severity header and writes the rest to `output_path`. Invalid / non-zero exit / timeout → deletes any partial file and returns `:error` (so triage never sees a malformed findings file). Shares Agent's `max_attempts` retry + monotonic `deadline:` handling.

**Why no `--base`**: the codex CLI's parser makes `--base <BRANCH>` mutually exclusive with a custom `[PROMPT]` (`"the argument '--base <BRANCH>' cannot be used with '[PROMPT]'"`), and the native `--base` review emits codex's own free-form summary, not Hive's GFM-checkbox format. So the adapter uses custom-PROMPT mode and the prompt itself scopes the review to `git diff <default_branch>...HEAD` and coerces the output format. argv never includes `--base`.

**Usage**: `codex review` emits a human-readable transcript with no machine-parseable per-token usage event (that exists only for `codex exec --json`), so the adapter intentionally does NOT record `UsageDb` usage — fabricating zeros would pollute the ledger.

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
  timeout_sec: 3600                  # optional; default 3600
```

A `codex_review` entry omits `skill` and `budget_usd`:

```yaml
- name: codex-native-review
  kind: codex_review
  agent: codex
  prompt_template: reviewer_codex_native_review.md.erb
  output_basename: codex-native-review
  timeout_sec: 5400
```

`Hive::Config.validate_reviewers!` enforces uniqueness on `name` and `output_basename`, non-empty `output_basename`, registered `agent`, a `kind` in `REVIEWER_KINDS = %w[agent codex_review linter]`, and presence of `name` / `prompt_template`. `skill` is required for every kind EXCEPT `codex_review` (which runs codex's built-in review and needs none). The Array replaces wholesale on per-project override (no per-element merge — see [[modules/config]] deep-merge semantics).

The DEFAULTS `patrol.review.reviewers` is the single `codex-native-review` entry above; normal `review.reviewers` (human PRs) keeps the ce-code-review set. `hive init`'s patrol-reviewer multiselect now offers `codex-native-review` (index 1, the blank default), `codex-ce-code-review`, and `claude-ce-code-review`.

## Tests

- `test/unit/reviewers_test.rb` — dispatch (agent / linter / unknown), Context / Result shape.
- `test/unit/reviewers/agent_test.rb` — adapter render + spawn integration.
- `test/unit/reviewers/codex_review_test.rb` — `codex review` argv (no `--base`), cwd, stdout→findings, banner trim, malformed/empty/non-zero → error + no file, timeout kill, version gate, retry/deadline, dispatch, prompt render. Fakes the codex subprocess via `test/fixtures/fake-codex` + `HIVE_CODEX_BIN`.
- `test/unit/reviewers/synthetic_task_test.rb` — facade shape.

## Backlinks

- [[stages/review]] · [[modules/agent_profile]] · [[modules/config]]
- [[decisions]] (ADR-014 / ADR-015)
