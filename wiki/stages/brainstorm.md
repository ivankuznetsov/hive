---
title: 2-brainstorm stage
type: stage
source: lib/hive/stages/brainstorm.rb, lib/hive/claude_launcher.rb, lib/hive/attempts/dispatcher.rb, templates/brainstorm_prompt.md.erb
created: 2026-04-25
updated: 2026-11-03
tags: [stage, brainstorm, qa]
---

**TLDR**: Round-by-round Q&A. Agent reads `idea.md`, writes `brainstorm.md` with `## Round N` questions and a `<!-- WAITING -->` marker. User answers inline. Re-running the stage parses answers and either appends `## Round N+1` or finalises with `## Requirements` and `<!-- COMPLETE -->`. Process exit and attempt receipts are not completion evidence by themselves: WAITING must contain a numbered Round, COMPLETE must contain non-empty Requirements, and a failed spawn cannot reuse an unchanged stale artifact. When the resolved `brainstorm.agent` is Claude, the stage launches headless `claude -p` through `Hive::Stages::Base.spawn_claude_with_failure_marker!` → `Hive::ClaudeLauncher`; other agents use the normal `spawn_agent` profile path. `brainstorm.runtime` is unsupported and rejected during config loading; `brainstorm.agent` selects the agent.

## Setup

- **State file**: `brainstorm.md` (touched empty if absent so the marker write has a target).
- **Prompt**: `templates/brainstorm_prompt.md.erb`, rendered with `project_name`, `task_folder`, `idea_text`. Idea text is wrapped in `<user_supplied content_type="idea_text">…</user_supplied>` per the prompt-injection boundary policy.
- **Inspection and writes**: The prompt permits read-only shell inspection of local task artifacts, project files, and skill instructions. Only `brainstorm.md` may be modified; network requests and commands that change other files or Git state remain forbidden. This lets shell-based agents inspect context without expanding the brainstorm write boundary.
- **Agent invocation**: `cwd = task.folder`, `--add-dir <task.folder>`, `log_label = "brainstorm"`, `status_mode: :state_file_marker`. `Brainstorm.run!` routes a profile that supports the Claude `:Launch` facet through `run_claude!` (`spawn_claude_with_failure_marker!`), and every other profile through `run_headless!` (`spawn_agent`). Both resolve the stage permission scope with `default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS` (`Read,Write,Edit,LS`). The Claude path passes `claude.permission_mode` (default `bypassPermissions` → `--dangerously-skip-permissions`, otherwise `--permission-mode <mode>`), delivers the rendered prompt over stdin, unsets Claude API-key env vars through the profile's subscription environment, and denies `AskUserQuestion` (no `runtime_policy`). A Claude launch that raises a non-routing `Hive::AgentError` is stamped `ERROR reason=claude_launch_failed` with the exception class and message.
- **Legacy scratch settings**: before each Claude launch, `Hive::ClaudeLauncher.repair_legacy_scratch_settings` restores a `.claude/settings.json.hive-pre-install` backup or deletes a Stop-hook `.claude/settings.json` stub left in the task folder by the retired tmux launch mode.
- **Profile**: `Hive::Stages::Base.stage_profile(cfg, "brainstorm")` — reads `cfg.dig("brainstorm", "agent")` with `|| "claude"` fallback so legacy configs keep working. Spawn pins `status_mode: :state_file_marker` regardless of profile, because brainstorm's lifecycle contract is the WAITING/COMPLETE marker the agent writes to `brainstorm.md` — codex's profile default `:output_file_exists` would never satisfy that.
- **Budgets**: `cfg["budget_usd"]["brainstorm"]` (default 50), `cfg["timeout_sec"]["brainstorm"]` (default 1800). Bumped ~5× in plan 2026-05-04-001 — generous sanity caps for runaway agents, not cost targets.
- **Outcome reconciliation**: both the Claude and non-Claude launches snapshot
  `brainstorm.md` before spawning and consume the launch result afterward.
  `WAITING` is valid only with a numbered `## Round N` section; `COMPLETE` is
  valid only with a non-empty `## Requirements` section. A changed valid
  artifact wins over a trailing launch error (for example Claude emitting its
  structured max-budget result while unwinding), while an unchanged
  pre-existing artifact cannot hide a failed spawn. Missing/invalid output is
  stamped `ERROR reason=brainstorm_artifact_invalid` or
  `brainstorm_agent_failed`; an already-specific launcher/agent `ERROR`,
  including `budget_exhausted`, is retained.
- **Durable acceptance**: the stage publishes handled/accepted disposition and
  the accepted output digest through the bounded diagnostic channel used by
  detached attempts and supervised commands. A later command-reporting failure
  cannot turn accepted new questions or Requirements into a failed-edit retry.
  A touch with unchanged bytes or an operator edit without stage acceptance is
  not accepted output.
- **Attempt replay repair**: the durable dispatcher does not treat a successful
  `2-brainstorm` receipt as replayable unless `brainstorm.md` currently passes
  the same structural validation. One legacy successful receipt without its
  artifact admits one repair attempt for that task generation, regardless of
  which request ID observes it. Once that repair terminalizes, its newest
  receipt is replayed instead of admitting an unbounded repair loop.

## Recovery after a failed answer resume

A failed dispatch before stage result handling can leave a fully answered
WAITING document whose mtime baseline was already consumed. The daemon now
observes attributable durable failure evidence before that baseline brake and
admits `failed_edit` recovery through the existing coordinator. WAITING and the
latest answers remain intact. A rejected spawn that this stage already handled
and stamped ERROR continues through marker recovery, without a duplicate
failed-edit admission.

The failure source stays bound to its task ID, stage, request, attempt, and
dispatch input. Later answer edits refresh the successor input binding under
lock while preserving retry count, fingerprint history, next eligibility, and
parking. Clearing an answer holds dispatch; refilling it still respects the
existing deadline and debounce. Recovery queue deadlines trigger another
observation without requiring a new edit. Restored baselines plus completed
answers alone never replay an unchanged successful result. Legacy failures are
adopted only when surviving terminal receipts prove current unchanged input;
missing attribution requires operator inspection. See [[modules/daemon]] for
binding, custody, and restart details.

The existing recovery backoff and deterministic parking policy apply. Failed
edit parks say “edits do not release this park; use the current workflow.retry
action”. The explicit Retry affordance uses a fresh observation token and
rechecks safety; ordinary answer edits do not release the park or reset its
deadline. Other recovery variants retain their existing remediation text.

CLI, TUI, and web show complete-answer cooldown/queue as Needs recovery, active
retry as running, and parking as Needs execution repair. Known retry time is
shown; absent time is explicitly unavailable. Genuine missing answers retain
the input editor with recovery detail underneath, unless a repair/parking or
dependency block takes precedence. Stale/unavailable status preserves durable
recovery detail beneath its freshness label without promising an imminent retry.
Complete answers without failure evidence do not fabricate a recovery action
or an answer prompt.

## Agent behaviour (per `templates/brainstorm_prompt.md.erb`)

1. If `brainstorm.md` is empty/missing, read `idea.md` and produce **Round 1** as a Q&A block:
   ```
   ## Round 1
   ### Q1. <question>
   ### A1.
   ### Q2. <question>
   ### A2.
   ```
   End with `<!-- WAITING -->`.
2. If `brainstorm.md` already has rounds, parse the most recent `## Round N`. If all answers are filled in, append `## Requirements` (actor / flow / acceptance examples) and end with `<!-- COMPLETE -->`. Otherwise append `## Round N+1` with follow-ups and end with `<!-- WAITING -->`.
3. Use `/ce-brainstorm` skill where available. Legacy `compound-engineering:ce-*` config values are normalized before rendering.

Agent must not modify any file other than `brainstorm.md` and must not run shell or network tools.

## Marker → commit action mapping (`Stages::Brainstorm.action_for`)

| Marker | Commit action |
|--------|---------------|
| `:waiting` | `round_waiting` |
| `:complete` | `complete` |
| `:error` | `error` |
| (other) | `<marker>.to_s` |

The runner returns `{commit: action, status: marker.name}` so `Commands::Run` writes a `hive: 2-brainstorm/<slug> <action>` commit on `hive/state`.

## Tests

- `test/integration/run_brainstorm_test.rb` exercises the prompt shape and marker transitions using the fake-claude fixture.
- `test/unit/stages/brainstorm_runtime_test.rb` pins Claude/non-Claude routing, failure reconciliation, structural artifact validation, changed-artifact precedence, and stale-artifact rejection.
- `test/unit/attempts/dispatcher_test.rb` pins one repair admission for a successful Brainstorm receipt whose required artifact is absent, failed-edit terminal attribution, and accepted-result precedence.
- `test/unit/daemon/recovery_coordinator_test.rb` and `test/unit/daemon/dispatcher_test.rb` cover retained WAITING, latest edits, completeness/debounce, retry pacing, parking, and token-guarded operator retry.
- `test/integration/daemon_auto_retry_test.rb` covers failed launch, restart, time-only retry, edits during failure/backoff, and successful-work negatives with fake children.
- Shared status/action/TUI tests plus Rails consumers and `web/test/system/edit_resume_recovery_test.rb` cover recovery display and actual Retry controls.

## Backlinks

- [[stages/inbox]] · [[stages/plan]]
- [[modules/agent]] · [[modules/markers]]
- [[state-model]]
