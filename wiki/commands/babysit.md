---
title: hive babysit
type: command
source: lib/hive/cli.rb, lib/hive/commands/babysit.rb, bin/hive-babysitter-stub-git, bin/hive-babysitter-stub-gh
created: 2026-05-26
updated: 2026-06-09
tags: [command, babysitter, daemon, github]
---

**TLDR**: `hive babysit` manages the experimental PR babysitter. It is a separate process from `hive daemon`: it polls open PRs for projects with `babysitter.enabled: true`, skips ignored labels, and asks the configured development agent to repair conflicts or red CI in an isolated PR worktree.

## Usage

```bash
hive babysit start [--detach] [--dry-run]
hive babysit stop
hive babysit restart [--detach] [--dry-run]
hive babysit status
hive babysit reload
hive babysit tail
hive babysit --once PROJECT [--dry-run]
hive babysit --once --all [--dry-run]
```

The command is bare-text in v1; it does not emit a `--json` envelope.

## Lifecycle

`start` writes `$HIVE_HOME/.babysitter.pid` and runs `Hive::Babysitter::Dispatcher`. The PID payload mirrors `hive daemon`: YAML with `pid`, `process_start_time`, and `started_at`, guarded against PID reuse through shared `Hive::PidFile` helpers. PID reservation and cleanup are serialized by a bounded sidecar lock so `start` cannot replace the PID file while `stop` is comparing and unlinking it, and lifecycle commands fail with a diagnostic instead of hanging forever on a wedged lock holder. `stop` sends TERM, waits up to 600 seconds, then escalates to KILL when ownership can still be verified; the long drain protects active PR repair agents and their temporary worktrees. If ownership becomes reused/unverified, or if the process remains alive after KILL, `stop` leaves the PID file for operator inspection and exits with an error instead of reporting a clean stop. Successful stop cleanup removes the PID file only when it still matches the payload being stopped, so a concurrent replacement `start` cannot lose its freshly-created PID lock. `restart` stops an existing process when the PID file exists and aborts if that stop path deliberately leaves a potentially live PID behind; otherwise it starts a new process. For `restart --detach`, it resolves the stable user-facing Hive wrapper with `Hive::InvokedBinary.path` and re-execs `hive babysit start --detach` before daemonizing so the live process and PID file are not stranded under a stale `restart --detach` argv. `reload` sends HUP, and `status` reports running/not-running plus uptime.

`reload` is only a config/log-settings refresh; it does not reload Ruby code into an already-running detached process. `status` compares the PID-file `started_at` timestamp with the latest mtime under `bin/hive`, `lib/hive.rb`, and `lib/hive/**/*.rb`. When the process predates the current source checkout, `status` prints a restart recommendation and `reload` warns the operator to run `hive babysit restart --detach` instead.

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
  auto_rebase: true
  budget_minutes: 30
  budget_usd: 50
```

`ProjectTick` reloads the project config on every tick, so changing `babysitter.enabled: false` is the kill switch and takes effect within one poll interval. `interval` accepts integer seconds or strings like `10m`, `30s`, and `1h`. `auto_rebase` (default `true`; `false` disables) controls auto-rebasing green-but-`BEHIND` PRs — see PR Processing below.

## PR Processing

For each enabled project, the babysitter:

1. Runs `gh pr list --state open` through `Hive::Gh.list_open_prs`.
2. Skips draft PRs before worktree materialization.
3. Skips PRs whose labels intersect `labels_ignore` case-insensitively.
4. Skips PRs already in the in-process in-flight set.
5. Sorts oldest-updated first and truncates to `max_concurrent_prs`.
6. Runs `Hive::Babysitter::PrFixer` on each selected PR.

`PrFixer` first checks `gh pr view --json mergeable,mergeStateStatus,statusCheckRollup`. If the PR is mergeable and checks are successful or queued (green), it normally records a `noop`/`already-green` event and does not spawn an agent. The exception: a green PR whose `mergeStateStatus` is `BEHIND` cannot merge under strict "branch must be up-to-date" protection. When `auto_rebase` is enabled (default), `PrFixer#handle_green` materializes the PR worktree, runs `GhOps.rebase_onto_base` (resolve `git remote get-url --push origin`, fetch `<base>` from that source with fallback to `origin`, then `git rebase FETCH_HEAD`), and on a clean rebase force-pushes the rebased HEAD to the PR's **real head branch** (`headRefName`, not the internal `hive-babysitter/pr-<n>` worktree branch) with an explicit `--force-with-lease=<headRefName>:<headRefOid>` so the PR becomes `CLEAN`/mergeable (emits `rebase`/`success`, counted as `fixed`). A rebase that conflicts is aborted and left for a human: no force-push, no fix agent, no label (emits `rebase`/`conflict`, counted as `needs_human`); it is re-evaluated cheaply on the next tick. With `auto_rebase: false` a green-but-`BEHIND` PR just `noop`s. If the PR is not green, `PrFixer` materializes the worktree, gathers failing-job logs plus diff stats, renders `templates/babysitter_pr_fix_prompt.md.erb`, and spawns the configured `execute.agent` through `Hive::Stages::Base.spawn_agent` with `status_mode: :exit_code_only`.

On success, the babysitter is silent on the PR. On failure, timeout, or budget exhaustion it applies `babysitter/needs-human` and posts one give-up comment per PR per UTC hour.

## Dry Run

`--dry-run` sets the dispatcher dry-run flag. The agent prompt tells the agent to write `.babysitter-dry-run-plan.md` instead of mutating GitHub, and `Hive::Babysitter::DryRunEnv` prepends a PATH overlay where `git` and `gh` point at babysitter stubs. The stubs are default-deny: they strip safe leading global path/repo options, reject unsafe global options, pass through only known read-only commands, screen exec/write-capable options in the regions where the real CLI honors them, and skip anything mutating or unknown while appending the skipped invocation to `.babysitter-dry-run-skipped.log`.

The current `git` stub read-only allowlist is `branch` (bare, `--show-current`, or `--contains`), `cat-file`, `describe`, `diff`, `grep`, `log`, `ls-files`, `ls-tree`, `merge-base`, `remote` only for listing, `remote show [-n]`, and `remote get-url` forms, `rev-list`, `rev-parse`, `show`, `status`, and `config` when paired with `--get`, `--get-all`, or `--list`. Even for allowlisted commands, the stub skips executable-affecting options first. Global config overrides are rejected wholesale: **any** leading `-c` / `--config-env` (glued or separate) is treated as unsafe, because git keeps adding exec-capable keys (`diff.external`, `diff.<driver>.textconv`/`command`, `filter.<driver>.clean`/`smudge`/`process`, `gpg.<format>.program`, pagers, hooks, aliases, protocol/include helpers, ...) and rejecting the whole config-override category is more robust than enumerating each dangerous key. The stub also skips leading global pager/exec-path switches (`--paginate`/`--exec-path`, scoped to the global-option region so a read-only subcommand `-p` like `git log -p` still passes), and the command options `--ext-diff`, the grep-only `--open-files-in-pager` (full spelling plus Git's unambiguous long-option prefixes down to `--op`, and the `-O` short form, glued, separate, or clustered - on `diff`/`log`/`show`, `-O` is the read-only `--output-ordering` and stays allowed), and the file-writing `--output` / `-o`. The grep short-cluster scanner stops when value-taking options such as `-e`, `-f`, `-m`, `-A`, `-B`, or `-C` consume the rest of the token, so read-only patterns like `git grep -eTODO` are not skipped merely because their operand contains uppercase `O`. The file-write guard is scoped past `grep`, so `git grep -o` / `--only-matching` stays allowed, and past `git ls-files -o` / `--others` (a read), while the long-form `--output` write still skips; option scanning stops at the `--` pathspec separator so `git log -- -o` reads a file literally named `-o`. Because the same exec-capable config can arrive through git's environment, the stub also mirrors the `-c` rejection onto the env path, fail-closed: it skips when any of `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_GLOBAL`, or `GIT_CONFIG_SYSTEM` is set, or when `GIT_CONFIG_COUNT` is set to anything that does not cleanly parse to `0` (a positive count carries attacker-controlled `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`; a non-numeric value is rejected by default-deny). This is a denylist of git's known exec-capable env seams rather than an exhaustive bar. `GIT_PAGER` / `core.pager` is left unguarded because non-TTY dry-run stdout does not auto-spawn a pager. The current `gh` stub read-only allowlist is `api` with no mutating method and no payload flags, `api --method GET ...` / `api -XGET ...`, `auth status`, `pr checks/diff/list/status/view`, `run list/view/watch`, `repo view`, and `workflow list/view`.

For `gh api`, payload-bearing forms are treated as writes unless the command explicitly sets GET. Dry-run skips implicit-POST calls such as `gh api repos/owner/repo/issues/123/comments -f body=hi`, `-F body=@comment.md`, `--raw-field body=hi`, `--field body=hi`, and `--input payload.json`, while still passing explicit GET reads such as `gh api --method GET repos/owner/repo/issues -f state=open`.

The dry-run guard is best-effort: an agent that invokes absolute binary paths can bypass the PATH overlay. Use throwaway repos for destructive validation until a stronger sandbox exists. If `HIVE_BABYSITTER_REAL_GIT` is unset or points at an invalid binary, the stub exits 127 with a one-line diagnostic instead of guessing a system path.

## Tests

- `test/unit/commands/babysit_test.rb` covers CLI flag validation, lifecycle helpers, foreground `restart`, detached restart re-exec into `start --detach`, stale-runtime status recommendations, stale-runtime reload warnings, refused-stop failures, PID-file cleanup races, and bounded PID-lock behavior.
- `test/unit/babysitter/*_test.rb` covers interval parsing, dispatcher ticks, PR filtering, context building, PR fixing, GitHub ops, worktree materialization, and dry-run PATH wrappers, including the `gh api` implicit-POST payload flag guard, git executable/write-option skips, subcommand `-p` passthrough, grep/`ls-files` read-option exceptions, grep pager `--open-files-in-pager` abbreviations and `-O` forms including clustered `-nO<cmd>`, value-taking grep short options such as `-eTODO` / `-fNEEDLEFILE.txt`, pathspec separator handling, and env config/command seams such as `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_GLOBAL`, and `GIT_CONFIG_SYSTEM`.
- `test/babysitter/run.rb` runs the acceptance smoke suite for early-green, ignored-label, dry-run, and give-up paths.

## Backlinks

- [[cli]]
- [[modules/babysitter]] · [[modules/config]] · [[modules/agent_profile]]
- [[operating]]
