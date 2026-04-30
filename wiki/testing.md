---
title: Testing
type: reference
source: test/, Rakefile, .rubocop.yml
created: 2026-04-25
updated: 2026-04-29
tags: [test, minitest, fixtures]
---

**TLDR**: Minitest for unit/integration coverage, plus an opt-in outer e2e layer. `test/unit/` covers modules, `test/integration/` covers command/stage behaviour in-process, and `test/e2e/` drives the real `bin/hive` subprocess plus tmux for TUI scenarios.

## Run all

```bash
bundle exec rake test
```

`Rakefile`:
```ruby
Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end
task default: :test
```

## Test helpers (`test/test_helper.rb`)

- `with_tmp_dir` — `Dir.mktmpdir("hive-test", &block)`.
- `with_tmp_git_repo` — `git init -b master`, configures user/email and disables GPG signing, makes one initial commit, yields the path.
- `with_tmp_global_config` — overrides `ENV["HIVE_HOME"]` to a tmp dir and writes an empty `registered_projects: []` YAML so tests don't touch `~/Dev/hive/config.yml`.
- `run!(*cmd)` — shells out and raises on non-zero exit (used in setup helpers; not for testing the CLI itself).

## Fixtures

| Path | Purpose |
|------|---------|
| `test/fixtures/fake-claude` | Shell script that takes the `claude -p` argv, optionally writes captured args to a log, optionally echoes a scenario-controlled response, exit 0. Pointed at via `HIVE_CLAUDE_BIN`. |
| `test/fixtures/fake-gh` | Shell script that handles `gh pr create` / `gh auth status` / `gh pr list`, returns a dummy URL. |

## Unit suite (`test/unit/`)

| File | Covers |
|------|--------|
| `config_test.rb` | `Hive::Config` — defaults, deep-merge, register/find, malformed YAML rejection. |
| `task_test.rb` | `Hive::Task` — path regex, stage validation, derived paths, slug edge cases. |
| `markers_test.rb` | `Hive::Markers` — set/get round-trip, attribute quoting, last-marker semantics. |
| `lock_test.rb` | `Hive::Lock` — acquire/release, stale-PID detection, commit lock parallelism. |
| `worktree_test.rb` | `Hive::Worktree` — create attach-vs-new, remove, exists?, pointer round-trip, prefix validation. |
| `git_ops_test.rb` | `Hive::GitOps` — default-branch detection, orphan worktree bootstrap, idempotent gitignore, empty-diff commit skip. |
| `agent_test.rb` | `Hive::Agent` — spawn/wait/timeout/SIGINT forwarding, version check. |

## Integration suite (`test/integration/`)

| File | Covers |
|------|--------|
| `init_test.rb` | `hive init` — preconditions, force flag, idempotent re-init. |
| `new_test.rb` | `hive new` — slug derivation, reserved rejection, captured commit. |
| `run_brainstorm_test.rb` | `hive run` of `2-brainstorm/`. |
| `run_plan_test.rb` | `hive run` of `3-plan/`. |
| `run_execute_test.rb` | `hive run` of `4-execute/` — init pass, iteration pass, stale handling, worktree-missing recovery. |
| `run_pr_test.rb` | `hive run` of `6-pr/` — push, idempotent existing-PR path, fake-gh PR create. |
| `run_done_test.rb` | `hive run` of `7-done/` — cleanup instructions, complete marker. |
| `status_test.rb` | `hive status` — empty registry, multi-stage rendering, stale-lock decoration. |
| `full_flow_test.rb` | End-to-end: idea → brainstorm → plan → execute → pr → done. |
| `skip_worktree_test.rb` | Verifies hive-state commits on master don't leak into feature worktrees. |

## E2E suite (`test/e2e/`)

The e2e layer is documented in [[e2e]]. It is opt-in:

```bash
bundle exec rake e2e:lib_test
bin/hive-e2e list
bin/hive-e2e run
```

The five starter scenarios copy `test/e2e/sample-project/` into a per-run sandbox, set `HIVE_HOME` to a run-local directory, and call the real `bin/hive` as a subprocess. TUI scenarios use private tmux sockets (`hive-e2e-<run-id>`) so they never touch the operator's daily tmux server.

## Lint

`bundle exec rubocop` is the lint command. Config in `.rubocop.yml`:

- `TargetRubyVersion: 3.4`
- `Style/StringLiterals: double_quotes`
- `Style/FrozenStringLiteralComment: disabled`
- `Layout/LineLength: max 120`
- `Metrics/MethodLength: max 30`, `Metrics/AbcSize: max 35`, `Metrics/ClassLength: max 200`

Excludes `vendor/**/*`, `tmp/**/*`, `test/fixtures/**/*` (the shell-script fixtures are not Ruby).

Per the user's CLAUDE.md rule: never pass non-Ruby files to rubocop.

## Backlinks

- [[architecture]]
- [[modules/agent]]
- [[e2e]]
- [[gaps]]
