---
title: hive babysit
type: command
source: lib/hive/cli.rb, lib/hive/commands/babysit.rb
created: 2026-05-26
updated: 2026-06-03
tags: [command, babysitter, daemon, github]
---

**TLDR**: `hive babysit` manages the experimental PR babysitter. It is a separate process from `hive daemon`: it polls open PRs for projects with `babysitter.enabled: true`, skips ignored labels, and asks the configured development agent to repair conflicts or red CI in an isolated PR worktree.

## Usage

```bash
hive babysit start [--detach] [--dry-run]
hive babysit stop
hive babysit status
hive babysit reload
hive babysit tail
hive babysit --once PROJECT [--dry-run]
hive babysit --once --all [--dry-run]
```

The command is bare-text in v1; it does not emit a `--json` envelope.

## Lifecycle

`start` writes `$HIVE_HOME/.babysitter.pid` and runs `Hive::Babysitter::Dispatcher`. The PID payload mirrors `hive daemon`: YAML with `pid`, `process_start_time`, and `started_at`, guarded against PID reuse through shared `Hive::PidFile` helpers. `stop` sends TERM, `reload` sends HUP, and `status` reports running/not-running plus uptime.

The log file is `$HIVE_HOME/logs/babysitter.log`, written by `Hive::Babysitter::Logger` as rotated JSON lines using the same global log-size knobs as the daemon.

`--once PROJECT` runs one dispatcher tick for the named registered project. `--once --all` runs one tick across every enabled registered project. These paths are intended for smoke tests and manual dry-run checks.

## Project Contract

Per-project config lives in `<project>/.hive-state/config.yml`:

```yaml
babysitter:
  enabled: true
  interval: 10m
  max_concurrent_prs: 2
  labels_ignore: [wip, do-not-merge, draft]
  dry_run: false
  budget_minutes: 30
  budget_usd: 50
```

`ProjectTick` reloads the project config on every tick, so changing `babysitter.enabled: false` is the kill switch and takes effect within one poll interval. `interval` accepts integer seconds or strings like `10m`, `30s`, and `1h`.

## PR Processing

For each enabled project, the babysitter:

1. Runs `gh pr list --state open` through `Hive::Gh.list_open_prs`.
2. Skips draft PRs before worktree materialization.
3. Skips PRs whose labels intersect `labels_ignore` case-insensitively.
4. Skips PRs already in the in-process in-flight set.
5. Sorts oldest-updated first and truncates to `max_concurrent_prs`.
6. Runs `Hive::Babysitter::PrFixer` on each selected PR.

`PrFixer` first checks `gh pr view --json mergeable,statusCheckRollup`. If the PR is mergeable and checks are successful or queued, it records a `noop` event and does not spawn an agent. Otherwise it materializes `<project>/.hive-state/babysitter/worktrees/<pr-number>/`, gathers failing-job logs plus diff stats, renders `templates/babysitter_pr_fix_prompt.md.erb`, and spawns the configured `execute.agent` through `Hive::Stages::Base.spawn_agent` with `status_mode: :exit_code_only`.

On success, the babysitter is silent on the PR. On failure, timeout, or budget exhaustion it applies `babysitter/needs-human` and posts one give-up comment per PR per UTC hour.

## Dry Run

`--dry-run` sets the dispatcher dry-run flag. The agent prompt tells the agent to write `.babysitter-dry-run-plan.md` instead of mutating GitHub, and `Hive::Babysitter::DryRunEnv` prepends a PATH overlay where `git` and `gh` point at babysitter stubs. The stubs are default-deny: they strip leading global options, pass through only known read-only commands, and skip anything mutating or unknown while appending the skipped invocation to `.babysitter-dry-run-skipped.log`.

The current `git` stub read-only allowlist is `branch` (bare, `--show-current`, or `--contains`), `cat-file`, `describe`, `diff`, `grep`, `log`, `ls-files`, `ls-tree`, `merge-base`, `remote`, `rev-list`, `rev-parse`, `show`, `status`, and `config` when paired with `--get`, `--get-all`, or `--list`. The current `gh` stub read-only allowlist is `api` with no method or GET, `auth status`, `pr checks/diff/list/status/view`, `run list/view/watch`, `repo view`, and `workflow list/view`.

The dry-run guard is best-effort: an agent that invokes absolute binary paths can bypass the PATH overlay. Use throwaway repos for destructive validation until a stronger sandbox exists.

## Tests

- `test/unit/commands/babysit_test.rb` covers CLI flag validation and lifecycle helpers.
- `test/unit/babysitter/*_test.rb` covers interval parsing, dispatcher ticks, PR filtering, context building, PR fixing, GitHub ops, worktree materialization, and dry-run PATH wrappers.
- `test/babysitter/run.rb` runs the acceptance smoke suite for early-green, ignored-label, dry-run, and give-up paths.

## Backlinks

- [[cli]]
- [[modules/babysitter]] · [[modules/config]] · [[modules/agent_profile]]
- [[operating]]
