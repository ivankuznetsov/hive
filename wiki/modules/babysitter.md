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
- Separate PID and log files: `$HIVE_HOME/.babysitter.pid`, `$HIVE_HOME/logs/babysitter.log`. Detached restarts re-exec as `hive babysit start --detach` before daemonizing, so the recorded process command is canonical and later restarts do not wait on a child that is still running under the old `restart --detach` argv. Stop escalation is intentionally short (15 seconds) because babysitter has no task-stage ownership to preserve during a stale-runtime replacement.
- Per-project opt-in only: `babysitter.enabled`.
- `hive babysit reload` is config/log-setting only. The detached process keeps Ruby code loaded from its original start; after checkout updates or release upgrades, use `hive babysit restart --detach`. `hive babysit status` compares the PID-file `started_at` to the current source mtime and prints a restart recommendation when the running process predates the checkout. This prevents stale validators from silently skipping projects after config enum changes such as `patrol.trigger: continuous`.
- `ProjectTick` asks `gh pr list` for `mergeStateStatus` and sorts selected candidates by actionability before applying `babysitter.max_concurrent_prs`: `DIRTY` / `BLOCKED` / `UNSTABLE` first, then `BEHIND` / `UNKNOWN`, then clean or missing states. Updated time remains the tie-breaker. This prevents a large old backlog of neutral PRs from starving conflicted/red PRs such as patrol output that needs immediate repair.
- Draft PRs are skipped before worktree materialization; `labels_ignore: [draft]` is not relied on because draft status is not a GitHub label.
- No Telegram or install/service integration in v1.
- No success PR comments.
- Dry-run is best-effort because absolute-path binary invocations can bypass the PATH overlay. Within the overlay, the `git` / `gh` stubs are default-deny: they strip leading global options, skip unknown commands, and only pass through known read-only commands to the real binary. The `git` stub rejects every leading `-c` / `--config-env` global config override (glued or separate) before passthrough - rejecting the whole config-override category instead of enumerating dangerous keys, since git keeps adding exec-capable keys (`diff.external`, `diff.<driver>.textconv`/`command`, `filter.<driver>.*`, `gpg.<format>.program`, pagers, hooks, aliases, protocol/include helpers, ...). It also skips leading global pager/exec-path switches (scoped to the global region so a subcommand `-p` like `git log -p` still passes) and the command options `--ext-diff`, the grep-only `--open-files-in-pager` (and its `-O` short form, glued or separate - on `diff`/`log`/`show` `-O` is the read-only `--output-ordering`, which stays allowed), and the file-writing `--output` / `-o` - the file-write guard is scoped past `grep`, whose `-o` / `--only-matching` is a read-only match filter, and past `ls-files -o` / `--others` (a read), while the long-form `--output` write still skips; option scanning stops at the `--` pathspec separator. The `git` stub mirrors the `-c` rejection onto git's environment-variable config path, fail-closed: it skips when any of `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_GLOBAL`, or `GIT_CONFIG_SYSTEM` is set, or when `GIT_CONFIG_COUNT` is set to anything that does not cleanly parse to `0` (a positive count carries attacker-controlled `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` exec-capable keys, and a non-numeric value is rejected by default-deny rather than trusted). These cover both command-naming vars git execs directly and config-injection channels; this is a denylist of the known exec-capable seams, not an exhaustive bar. `GIT_PAGER` / `core.pager` is intentionally left unguarded because non-TTY dry-run stdout does not auto-spawn a pager. `gh api` passes through only when it has no method and no payload flags, or when the method is explicitly GET; payload flags such as `-f`, `-F`, `--raw-field`, `--field`, and `--input` make a no-method call skip because the GitHub CLI can treat them as write payloads. `git config` only passes through for read forms (`--get`, `--get-all`, `--list`).

## Backlinks

- [[commands/babysit]]
- [[state-model]]
- [[modules/config]] · [[modules/agent_profile]] · [[modules/daemon]] · [[modules/events]] · [[modules/worktree]]
- [[operating]]
