---
title: Hive::Babysitter
type: module
source: lib/hive/babysitter/
created: 2026-05-26
updated: 2026-06-09
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
| `Hive::Babysitter::PrFixer` | `lib/hive/babysitter/pr_fixer.rb` | Per-PR precheck, green-but-`BEHIND` auto-rebase, worktree setup, context gathering, prompt render, agent spawn, give-up handling. |
| `Hive::Babysitter::ContextBuilder` | `lib/hive/babysitter/context_builder.rb` | Builds prompt-ready status rollup, failing-job logs, and diff stat. |
| `Hive::Babysitter::Worktree` | `lib/hive/babysitter/worktree.rb` | Recreates `.hive-state/babysitter/worktrees/<pr>/` from a force-refreshed internal PR-head ref, so rebased or force-pushed PRs do not wedge the babysitter cache. |
| `Hive::Babysitter::GhOps` | `lib/hive/babysitter/gh_ops.rb` | Hive-driven GitHub/git side effects: `force_push_with_lease(worktree, branch, cfg:, dry_run:, expected_oid: nil)` (explicit `--force-with-lease=<branch>:<oid>` when `expected_oid` is given — robust without a local remote-tracking ref — else the bare `--force-with-lease`), `rebase_onto_base` (fetch base over the remote's **push URL** + rebase onto `FETCH_HEAD`, abort-on-conflict, returns a `RebaseResult` of `:success`/`:conflict`/`:failure`), label, comment, rerun. Honors dry-run. |
| `Hive::Babysitter::DryRunEnv` | `lib/hive/babysitter/dry_run_env.rb` + `bin/hive-babysitter-stub-git` / `bin/hive-babysitter-stub-gh` | PATH overlay for agent-side dry-run `git` / `gh` stubs; allowed git reads exec with hermetic user/system/local config controls. |
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
                      -> handle_green (green + BEHIND + auto_rebase):
                           -> Worktree.materialize
                           -> GhOps.rebase_onto_base -> GhOps.force_push_with_lease  (=> :rebased)
                           -> conflict: emit rebase/conflict, no push        (=> :rebase_conflict)
                      -> (not green) Worktree.materialize
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

Closed action enum: `list-prs`, `noop`, `skipped`, `agent-fix`, `rebase`, `force-push`, `pr-comment`, `label-apply`, `give-up`, `dry_run`.

Closed outcome enum: `success`, `failure`, `conflict`, `timeout`, `budget_exhausted`, `gh-error`, `already-green`, `label_ignored`, `draft_pr`, `fork_pr`, `dry_run`.

`emit` raises `ArgumentError` on any action/outcome outside these allowlists.

## Boundaries

- Separate from `Hive::Daemon`; no shared `ConcurrencyController` and no task-folder dispatch.
- Separate PID and log files: `$HIVE_HOME/.babysitter.pid`, `$HIVE_HOME/logs/babysitter.log`. Detached restarts re-exec the stable wrapper resolved by `Hive::InvokedBinary.path` as `hive babysit start --detach` before daemonizing, so the recorded process command is canonical and later restarts do not wait on a child that is still running under the old `restart --detach` argv. Restart aborts when stop leaves a potentially live PID file behind. Stop keeps a long 600-second drain because an active tick can be inside a synchronous PR repair agent with child processes and temporary worktrees; start reservation and successful cleanup take the same bounded sidecar lock and compare the current PID-file payload before removing it so a concurrent replacement start keeps its lock.
- Per-project opt-in only: `babysitter.enabled`.
- `hive babysit reload` is config/log-setting only. The detached process keeps Ruby code loaded from its original start; after checkout updates or release upgrades, use `hive babysit restart --detach`. `hive babysit status` compares the PID-file `started_at` to the current source mtime and prints a restart recommendation when the running process predates the checkout. This prevents stale validators from silently skipping projects after config enum changes such as `patrol.trigger: continuous`.
- `ProjectTick` asks `gh pr list` for `mergeStateStatus` and sorts selected candidates by actionability before applying `babysitter.max_concurrent_prs`: `DIRTY` / `BLOCKED` / `UNSTABLE` first, then `BEHIND` / `UNKNOWN`, then clean or missing states. Updated time remains the tie-breaker. This prevents a large old backlog of neutral PRs from starving conflicted/red PRs such as patrol output that needs immediate repair.
- Draft PRs are skipped before worktree materialization; `labels_ignore: [draft]` is not relied on because draft status is not a GitHub label.
- **Auto-rebase of green-but-`BEHIND` PRs** (default on; `babysitter.auto_rebase: false` to disable): strict branch protection on the base requires a PR head to be up-to-date with the base before it can merge, so a conflict-free, green PR that goes `mergeStateStatus=BEHIND` when the base advances is `mergeable=MERGEABLE` + green and would `noop` forever, staying un-mergeable. `PrFixer#handle_green` detects `BEHIND` (from the status rollup, falling back to the PR object's `mergeStateStatus`) and, when enabled, materializes the worktree, `GhOps.rebase_onto_base` (fetch the base ref then `git rebase FETCH_HEAD`), then `GhOps.force_push_with_lease` to the PR's **real head branch** (`@pr["headRefName"]`, not the internal `hive-babysitter/pr-<n>` worktree branch) with an explicit lease (`expected_oid` = the rollup's `headRefOid`, falling back to `@pr["headRefOid"]`; `nil` → bare lease) so the PR becomes `CLEAN`/mergeable (`:rebased`, counted as `fixed`). A rebase that hits conflicts is aborted and left for a human — no force-push, no fix agent, no label (`:rebase_conflict`, counted as `needs_human`); it is re-evaluated cheaply next tick. Dry-run emits a `rebase`/`dry_run` event and touches no git. A green PR that is not `BEHIND` is the usual `noop`/`already-green`.
- **Headless base fetch over the push URL** (PR #424): `GhOps.rebase_onto_base` resolves the remote's effective push URL via `git remote get-url --push origin` and fetches the base from that URL (`git fetch <push-url> <base>`), not the bare `origin` remote, before `git rebase FETCH_HEAD`. Rationale: `Hive::Gh.capture3` forces `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, and in the babysitter's systemd `--user` service there is no SSH agent (`SSH_AUTH_SOCK` unset). When origin's **fetch** URL is SSH (`git@github.com:…`), the fetch dies with `Permission denied (publickey)`, so `rebase_onto_base` returned `:failure` every tick and BEHIND PRs never rebased. The **push** URL is HTTPS (resolved through gh's credential helper) and the force-push already works over it, so fetching the base over the same transport works headless too. Empirically: plain `git fetch origin main` works interactively; `GIT_SSH_COMMAND="ssh -o BatchMode=yes" git fetch origin main` fails (publickey denied); `git fetch <https-push-url> main` works. If `git remote get-url --push origin` fails or returns empty, it falls back to the literal `"origin"` so non-github / unusual remotes behave as before. `Hive::Gh.capture3`'s BatchMode is intentional for other callers and is unchanged; `force_push_with_lease` is unchanged (push already works).
- No Telegram or install/service integration in v1.
- No success PR comments.
- Dry-run is best-effort because absolute-path binary invocations can bypass the PATH overlay. Within the overlay, the `git` / `gh` stubs are default-deny: they strip leading global options, skip unknown commands, and only pass through known read-only commands to the real binary. The `git` stub rejects every leading `-c` / `--config-env` global config override (glued or separate) before passthrough - rejecting the whole config-override category instead of enumerating dangerous keys, since git keeps adding exec-capable keys (`diff.external`, `diff.<driver>.textconv`/`command`, `filter.<driver>.*`, `gpg.<format>.program`, pagers, hooks, aliases, protocol/include helpers, ...). It also skips leading global pager/exec-path switches (scoped to the global region so a subcommand `-p` like `git log -p` still passes) and the command options `--ext-diff`, `--textconv` (full spelling plus Git's unambiguous long-option prefixes), the grep-only `--open-files-in-pager` (full spelling plus Git's unambiguous long-option prefixes down to `--op`, and the `-O` short form, glued, separate, or clustered - on `diff`/`log`/`show` `-O` is the read-only `--output-ordering`, which stays allowed), and the file-writing `--output` / `-o`. The grep short-cluster scanner now stops when a value-taking option such as `-e`, `-f`, `-m`, `-A`, `-B`, or `-C` consumes the rest of the token, so attached pattern/file/count operands containing uppercase `O` are not mistaken for the pager flag. The file-write guard is scoped past `grep`, whose `-o` / `--only-matching` is a read-only match filter, and past `ls-files -o` / `--others` (a read), while the long-form `--output` write still skips; option scanning stops at the `--` pathspec separator. `git cat-file --filters` is skipped because the `--filters` mode runs configured clean/smudge filter programs. The `git` stub mirrors the `-c` rejection onto git's environment-variable config path, fail-closed: it skips when any of `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_GLOBAL`, or `GIT_CONFIG_SYSTEM` is set, or when `GIT_CONFIG_COUNT` is set to anything that does not cleanly parse to `0` (a positive count carries attacker-controlled `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` exec-capable keys, and a non-numeric value is rejected by default-deny rather than trusted). Before exec, allowed git reads run hermetically with `HOME` and `XDG_CONFIG_HOME` neutralized, `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` pointed at `/dev/null`, `GIT_OPTIONAL_LOCKS=0`, system/global config disabled, `core.fsmonitor=false`, and `--no-ext-diff --no-textconv` injected for `diff` / `log` / `show`, so user config and local `.git/config` cannot re-enable external diff, textconv, or fsmonitor execution during passthrough. These cover both command-naming vars git execs directly and config-injection channels; this is a denylist of the known exec-capable seams, not an exhaustive bar. `GIT_PAGER` / `core.pager` is intentionally left unguarded because non-TTY dry-run stdout does not auto-spawn a pager. `gh api` passes through only when it has no method and no payload flags, or when the method is explicitly GET; payload flags such as `-f`, `-F`, `--raw-field`, `--field`, and `--input` make a no-method call skip because the GitHub CLI can treat them as write payloads. `git config` only passes through for read forms (`--get`, `--get-all`, `--list`).

## Backlinks

- [[commands/babysit]]
- [[state-model]]
- [[modules/config]] · [[modules/agent_profile]] · [[modules/daemon]] · [[modules/events]] · [[modules/worktree]]
- [[operating]]
