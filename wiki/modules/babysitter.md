---
title: Hive::Babysitter
type: module
source: lib/hive/babysitter/
created: 2026-05-26
updated: 2026-05-26
tags: [babysitter, module, daemon, github, agents]
---

**TLDR**: `Hive::Babysitter::*` is an experimental out-of-band PR repair daemon. It does not move task folders through the 1→9 pipeline; it watches GitHub PRs for enrolled projects and delegates repair work to the project's development agent.

## Module Map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Babysitter::Dispatcher` | `lib/hive/babysitter/dispatcher.rb` | Poll loop, signal traps, enabled-project enumeration, in-flight PR set. |
| `Hive::Babysitter::Logger` | `lib/hive/babysitter/logger.rb` | Rotated JSON-line process log at `$HIVE_HOME/logs/babysitter.log`. |
| `Hive::Babysitter::Interval` | `lib/hive/babysitter/interval.rb` | Parses integer seconds or `\d+[smh]` duration strings. |
| `Hive::Babysitter::ProjectTick` | `lib/hive/babysitter/project_tick.rb` | One-project tick: reload config, list PRs, filter labels, enforce `max_concurrent_prs`, call `PrFixer`. |
| `Hive::Babysitter::PrFixer` | `lib/hive/babysitter/pr_fixer.rb` | Per-PR precheck, worktree setup, context gathering, prompt render, agent spawn, give-up handling. |
| `Hive::Babysitter::ContextBuilder` | `lib/hive/babysitter/context_builder.rb` | Builds prompt-ready status rollup, failing-job logs, and diff stat. |
| `Hive::Babysitter::Worktree` | `lib/hive/babysitter/worktree.rb` | Recreates `.hive-state/babysitter/worktrees/<pr>/` from the PR head branch. |
| `Hive::Babysitter::GhOps` | `lib/hive/babysitter/gh_ops.rb` | Hive-driven GitHub side effects: force-with-lease push, label, comment, rerun. Honors dry-run. |
| `Hive::Babysitter::DryRunEnv` | `lib/hive/babysitter/dry_run_env.rb` | PATH overlay for agent-side dry-run `git` / `gh` stubs. |
| `Hive::Babysitter::Events` | `lib/hive/babysitter/events.rb` | Append-only per-project JSONL events under `.hive-state/babysitter/events.jsonl`. |
| `Hive::Babysitter::StatusWriter` | `lib/hive/babysitter/status_writer.rb` | Human-readable loop summary appended to `.hive-state/babysitter/status.md`. |

## Wiring

```
hive babysit start
  -> Hive::Commands::Babysit
       -> writes $HIVE_HOME/.babysitter.pid
       -> Hive::Babysitter::Dispatcher.run_forever
            -> ProjectTick.run(project, cfg, dry_run:, logger:, inflight:)
                 -> Gh.list_open_prs
                 -> PrFixer.run(pr, project, cfg, dry_run:, logger:, inflight:)
                      -> Gh.pr_status_rollup
                      -> Worktree.materialize
                      -> ContextBuilder.build
                      -> Stages::Base.spawn_agent(profile: execute.agent)
                      -> GhOps.add_label / post_pr_comment on give-up
```

The babysitter deliberately reuses `Hive::Stages::Base.spawn_agent` instead of spawning profiles directly. That keeps the normal agent status contract, timeout kill behavior, and usage accounting path available to the experimental daemon.

## Event Shape

Each action appends one JSON object:

```json
{"ts":"2026-05-26T11:40:00Z","stage":"babysitter","project":"demo","pr":42,"action":"agent-fix","outcome":"success","duration_ms":612000}
```

Closed action enum: `list-prs`, `noop`, `skipped`, `agent-fix`, `force-push`, `pr-comment`, `label-apply`, `give-up`, `dry_run`.

Closed outcome enum: `success`, `failure`, `timeout`, `budget_exhausted`, `gh-error`, `already-green`, `label_ignored`, `dry_run`.

## Boundaries

- Separate from `Hive::Daemon`; no shared `ConcurrencyController` and no task-folder dispatch.
- Separate PID and log files: `$HIVE_HOME/.babysitter.pid`, `$HIVE_HOME/logs/babysitter.log`.
- Per-project opt-in only: `babysitter.enabled`.
- No Telegram or install/service integration in v1.
- No success PR comments.
- Dry-run is best-effort because absolute-path binary invocations can bypass the PATH overlay.

## Backlinks

- [[commands/babysit]]
- [[state-model]]
- [[modules/config]] · [[modules/agent_profile]] · [[modules/daemon]] · [[modules/events]] · [[modules/worktree]]
- [[operating]]
