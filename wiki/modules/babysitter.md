---
title: Hive::Babysitter
type: module
source: lib/hive/babysitter/
created: 2026-05-26
updated: 2026-06-07
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
| `Hive::Babysitter::Worktree` | `lib/hive/babysitter/worktree.rb` | Recreates `.hive-state/babysitter/worktrees/<pr>/` from a force-refreshed internal PR-head ref, so rebased or force-pushed PRs do not wedge the babysitter cache. |
| `Hive::Babysitter::GhOps` | `lib/hive/babysitter/gh_ops.rb` | Hive-driven GitHub side effects: force-with-lease push, label, comment, rerun. Honors dry-run. |
| `Hive::Babysitter::DryRunEnv` | `lib/hive/babysitter/dry_run_env.rb` + `bin/hive-babysitter-stub-git` / `bin/hive-babysitter-stub-gh` | PATH overlay for agent-side dry-run `git` / `gh` stubs. |
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

Closed outcome enum: `success`, `failure`, `timeout`, `budget_exhausted`, `gh-error`, `already-green`, `label_ignored`, `draft_pr`, `fork_pr`, `dry_run`.

## Boundaries

- Separate from `Hive::Daemon`; no shared `ConcurrencyController` and no task-folder dispatch.
- Separate PID and log files: `$HIVE_HOME/.babysitter.pid`, `$HIVE_HOME/logs/babysitter.log`.
- Per-project opt-in only: `babysitter.enabled`.
- Draft PRs are skipped before worktree materialization; `labels_ignore: [draft]` is not relied on because draft status is not a GitHub label.
- No Telegram or install/service integration in v1.
- No success PR comments.
- Dry-run is best-effort because absolute-path binary invocations can bypass the PATH overlay. Within the overlay, the `git` / `gh` stubs are default-deny: they strip leading global options, skip unknown commands, and only pass through known read-only commands to the real binary. `gh api` passes through only when it has no method and no payload flags, or when the method is explicitly GET; payload flags such as `-f`, `-F`, `--raw-field`, `--field`, and `--input` make a no-method call skip because the GitHub CLI can treat them as write payloads. Allowed `gh` reads still screen unsafe passthrough flags: `--web` and any bundled short-flag cluster containing `w` skip, and `gh auth status` treats `--show-token` plus any cluster containing `t` as unsafe, so `gh pr view 42 -cw` and `gh auth status -at` do not reach real `gh`. `git config` only passes through for read forms (`--get`, `--get-all`, `--list`). Even after a subcommand is allowed, the git stub screens for exec/write options in the regions where git honors them: global `-c`, `--config-env`, and `--exec-path`; exact `--output` / `--output=...` anywhere; and `git grep`'s pager options (`-O`, bundled forms like `-nO...`, and `--open-files-in-pager[=...]`). This blocks read-looking invocations such as `git -c diff.external=<cmd> diff`, `git -c core.pager=<cmd> show`, `git --exec-path=/tmp/evil diff`, `git grep -nO<cmd> needle`, and `git diff --output=patch.diff`, while allowing non-exec read flags that reuse the spelling in safe contexts (`git grep -c`, `git diff -Oorderfile`, and `git diff --output-indicator-*`). Before handing off to real git, the stub scrubs `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `GIT_SSH`, `GIT_SSH_COMMAND`, and the `GIT_CONFIG*` family from the environment.

## Backlinks

- [[commands/babysit]]
- [[state-model]]
- [[modules/config]] · [[modules/agent_profile]] · [[modules/daemon]] · [[modules/events]] · [[modules/worktree]]
- [[operating]]
