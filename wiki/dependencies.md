---
title: Dependencies
type: dependencies
source: Gemfile, Gemfile.lock
created: 2026-04-25
updated: 2026-04-27
tags: [dependencies, gems, runtime]
---

**TLDR**: Two runtime gems (`thor`, `curses`); six development gems (`minitest`, `rake`, `rubocop` + `rubocop-rails-omakase`, `brakeman`, `bundler-audit`). Three external CLI dependencies (`claude`, `gh`, `git`).

## Runtime gems

| Gem | Version | Purpose |
|-----|---------|---------|
| `thor` | `~> 1.3` (locked 1.5.0) | CLI framework — used in `Hive::CLI` (`lib/hive/cli.rb`). Subcommand routing, option parsing, help generation. |
| `curses` | `~> 1.6` (locked 1.6.0) | Terminal UI runtime — used in `Hive::Tui` (`lib/hive/tui.rb`) for the `hive tui` command. Stdlib-extracted, ruby-core maintained; ships `def_prog_mode` / `reset_prog_mode` / `endwin` / injected `KEY_RESIZE`. |

Why Thor: de-facto Ruby CLI framework (Rails generators use it), fits the Ruby-heavy stack. Bash rejected for not scaling past three commands; Go/Python rejected for stack mismatch.

Why Curses: the `hive tui` plan needs subprocess takeover (suspend the screen, exec `claude`, restore), resize handling, and zero-cost frame redraws. Curses 1.6 covers all three from stdlib lineage; alternatives (`tty-cursor` + ANSI, `ratatui`-style Rust deps) either lacked subprocess takeover or pulled in a 22 MB native dep (KTD-1 in the TUI plan).

## Development / test gems

| Gem | Version | Purpose |
|-----|---------|---------|
| `minitest` | `~> 5.20` (locked 5.27.0) | Test framework — all tests under `test/` extend `Minitest::Test`. Chosen over RSpec for lower ceremony. |
| `rake` | `~> 13.0` (locked 13.4.2) | Task runner — `Rakefile` defines `rake test` (default) using `Rake::TestTask`. |
| `rubocop` | `~> 1.60` (locked 1.86.1) | Linter — config in `.rubocop.yml`. `bin/rubocop` is the canonical lint command. |

## Standard library reliance

The codebase leans heavily on stdlib (no extra gems for these):

| Stdlib | Used for | Where |
|--------|----------|-------|
| `Open3.capture3` | All git/gh/claude version subprocess invocations | `git_ops.rb`, `worktree.rb`, `pr.rb`, `init.rb`, `agent.rb` |
| `Process.spawn` (with `pgroup: true`) | Long-running claude subprocess + signal forwarding | `agent.rb` |
| `IO.pipe` | Streaming claude stdout/stderr to the log file in real time | `agent.rb` |
| `File#flock(LOCK_EX)` | `Markers.set` (per-state-file lock) and `Lock.with_commit_lock` (per-project commit lock) | `markers.rb`, `lock.rb` |
| `File.open(... LOCK_EX \| EXCL)` | Per-task lock acquisition | `lock.rb` |
| `YAML.safe_load` | All config / lock / pointer files | `config.rb`, `lock.rb`, `task.rb`, `worktree.rb` |
| `ERB` (`trim_mode: "-"`) | Prompt and config templates | `commands/init.rb`, `commands/new.rb`, `stages/base.rb` |
| `SecureRandom.hex` | 4-char slug suffix | `commands/new.rb` |
| `Digest::SHA256` | Reviewer-tamper detection on `plan.md` / `worktree.yml` | `stages/execute.rb` |
| `Time.now.utc.iso8601` | Lock timestamps, marker `started=`, `worktree.yml#created_at` | `lock.rb`, `agent.rb`, `worktree.rb` |
| `/proc/<pid>/stat` (Linux) | PID-reuse defence in stale-lock detection | `lock.rb#process_start_time` |

The `/proc/<pid>/stat` reliance is Linux-specific. macOS would need a `ps -o lstart= -p <pid>` fallback (noted as a known limitation in the plan but not implemented in MVP).

## External CLI dependencies

These are not gems but the CLI tools the runtime invokes:

| Tool | Min version | Used by |
|------|-------------|---------|
| `claude` | 2.1.118 | every active stage; verified by `Hive::Agent.check_version!` |
| `gh` | (any auth-supporting recent) | `Stages::Pr` only — `gh auth status`, `gh pr list`, `gh pr create` |
| `git` | 2.40+ (worktree, symbolic-ref, etc.) | `Hive::GitOps`, `Hive::Worktree`, `Init`/`New` commands |

`HIVE_CLAUDE_BIN` env var overrides the `claude` binary, used by tests with `test/fixtures/fake-claude` and `fake-gh`.

## Ruby version

`Gemfile` declares `ruby "~> 3.4"`. `.rubocop.yml` pins `TargetRubyVersion: 3.4`. `Gemfile.lock` records 3.4.7 as the resolved version.

## Backlinks

- [[architecture]]
- [[modules/agent]]
