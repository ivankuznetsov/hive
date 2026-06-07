---
title: Dependencies
type: dependencies
source: Gemfile, Gemfile.lock
created: 2026-04-25
updated: 2026-06-08
tags: [dependencies, gems, runtime]
---

**TLDR**: Six runtime gems (`thor`, `telegram-bot-ruby`, `bubbletea`, `lipgloss`, `sqlite3`, `unicode-display_width`); seven development/test gems (`minitest`, `rake`, `json_schemer`, `rubocop` + `rubocop-rails-omakase`, `brakeman`, `bundler-audit`). Runtime CLIs are `claude`, `codex`, `gh`, `git`, and QMD for managed llm-wiki search/indexing; e2e TUI tests additionally use `tmux` and optionally `asciinema`.

## Runtime gems

| Gem | Version | Purpose |
|-----|---------|---------|
| `thor` | `~> 1.3` (locked 1.5.0) | CLI framework — used in `Hive::CLI` (`lib/hive/cli.rb`). Subcommand routing, option parsing, help generation. |
| `telegram-bot-ruby` | `~> 2.7` (locked 2.7.0) | Telegram Bot API client for `hive bot`. Chosen because RubyGems shows an April 3, 2026 release, MFA on publish, Ruby >= 2.7 support, and four direct runtime dependencies (`dry-struct`, `faraday`, `faraday-multipart`, `zeitwerk`). The lockfile review keeps the larger dry/faraday transitive set explicit. |
| `bubbletea` | `~> 0.1.4` | MVU runtime for `hive tui`. FFI binding to the Charm Go library. Owns alt-screen lifecycle, raw-mode toggling, resize handling, and the keystroke event stream. `Hive::Tui::App.run_charm` boots a `Bubbletea::Runner` against the `Hive::Tui::BubbleModel` adapter. |
| `lipgloss` | `~> 0.2.2` | Lipgloss-ruby — declarative terminal styles consumed by every `Hive::Tui::Views::*` module (`Style#foreground/.bold/.reverse/.border/.padding/.render`). FFI binding to the Charm Go library. ANSI is stripped when stdout isn't a tty (the v0.2.2 limitation tracked in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`). |
| `sqlite3` | `~> 2.0` | Runtime token-usage store for `Hive::UsageDb`; loaded lazily when agent usage rows are written or queried. |
| `unicode-display_width` | `~> 3.2` | Terminal display-cell measurement for TUI table layout. `Hive::Tui::Views::Format` uses it to truncate and pad wide glyphs such as emoji without shifting fixed columns. |

`telegram-bot-ruby` pulls Faraday and `faraday-multipart` for HTTP
transport. Hive also uses those transitive gems directly in
`Hive::Bot::Transcriber` to POST Telegram voice-note bytes to the
configured OpenAI-compatible audio transcription endpoint. `Gemfile.lock`
keeps `faraday` at `2.14.2` or newer because `bundler-audit` flags
`2.14.1` for CVE-2026-33637 / GHSA-5rv5-xj5j-3484.

The `curses` gem was removed in U11 of plan #003 alongside the legacy curses TUI backend. `HIVE_TUI_BACKEND=curses` now raises a typed error pointing at the removal instead of routing to the deleted code.

Why Thor: de-facto Ruby CLI framework (Rails generators use it), fits the Ruby-heavy stack. Bash rejected for not scaling past three commands; Go/Python rejected for stack mismatch.

Why Bubble Tea + Lipgloss (over the original curses choice): MVU keeps every state transition behind `Hive::Tui::Update.apply` so view regressions reproduce as unit tests; lipgloss styling renders consistently across modern terminals (Ghostty / Alacritty / kitty / iTerm2) where curses' subprocess-takeover dance had alt-screen handoff edge cases. Trade documented in plan #003 (`docs/plans/2026-04-27-003-refactor-hive-tui-charm-bubbletea-plan.md`) and the U2 verification report.

## Development / test gems

| Gem | Version | Purpose |
|-----|---------|---------|
| `minitest` | `~> 6.0` (locked 6.0.6) | Test framework — all tests under `test/` extend `Minitest::Test`. Chosen over RSpec for lower ceremony. Bumped 5.x → 6.0 in commit `429ff4c`. |
| `rake` | `~> 13.0` (locked 13.4.2) | Task runner — `Rakefile` defines `rake test` (default) using `Rake::TestTask`. |
| `json_schemer` | `~> 2.5` (locked 2.5.0) | Test/e2e JSON Schema validator for `schemas/hive-*.json` contracts. Used by `test/e2e/lib/json_validator.rb`; not loaded by runtime commands. |
| `rubocop` | `~> 1.87` (locked 1.87.0) | Linter — config in `.rubocop.yml`. `bin/rubocop` is the canonical lint command. |

## Standard library reliance

The codebase leans heavily on stdlib (no extra gems for these):

| Stdlib | Used for | Where |
|--------|----------|-------|
| `Open3.capture3` | All git/gh/claude version subprocess invocations | `git_ops.rb`, `worktree.rb`, `pr.rb`, `init.rb`, `agent.rb` |
| `Process.spawn` (with `pgroup: true`) | Long-running claude subprocess + signal forwarding | `agent.rb` |
| `IO.pipe` | Streaming claude stdout/stderr to the log file in real time | `agent.rb` |
| `File#flock(LOCK_EX)` | `Markers.set` (per-state-file lock), `Lock.with_commit_lock` (per-project commit lock), and global config registry writes | `markers.rb`, `lock.rb`, `config.rb` |
| `File.open(... LOCK_EX \| EXCL)` | Per-task lock acquisition | `lock.rb` |
| `YAML.safe_load` | All config / lock / pointer files | `config.rb`, `lock.rb`, `task.rb`, `worktree.rb` |
| `ERB` (`trim_mode: "-"`) | Prompt and config templates | `commands/init.rb`, `commands/new.rb`, `stages/base.rb` |
| `SecureRandom.hex` | 4-char slug suffix and unique global-config tempfile names | `commands/new.rb`, `config.rb` |
| `Digest::SHA256` | Reviewer-tamper detection on `plan.md` / `worktree.yml` | `stages/execute.rb` |
| `Time.now.utc.iso8601` | Lock timestamps, marker `started=`, `worktree.yml#created_at` | `lock.rb`, `agent.rb`, `worktree.rb` |
| `/proc/<pid>/stat` (Linux) | PID-reuse defence in stale-lock detection | `lock.rb#process_start_time` |

The `/proc/<pid>/stat` reliance is Linux-specific. macOS would need a `ps -o lstart= -p <pid>` fallback (noted as a known limitation in the plan but not implemented in MVP).

## External CLI dependencies

These are not gems but the CLI tools the runtime invokes:

| Tool | Min version | Used by |
|------|-------------|---------|
| `claude` | 2.1.118 | every active stage; verified by `Hive::Agent.check_version!` |
| `gh` | (any auth-supporting recent) | `Hive::Gh` (`auth status`, `pr list`, `pr view` for PR state checks, secret-scan, dedupe, status rollups, and babysitter context), `Stages::OpenPr` (agent invokes `gh pr create` from its prompt), `Stages::Finalize` (runner owns `gh pr ready`; agent does `gh pr edit --body-file`), `Stages::Review::GithubPublisher` (`gh pr comment` for review mirroring). |
| `git` | 2.40+ (worktree, symbolic-ref, etc.) | `Hive::GitOps`, `Hive::Worktree`, `Init`/`New` commands |
| `tmux` | 3.0+ (3.6a verified locally) | runtime dependency when `claude.mode: tmux`; also used by TUI/e2e tests on private sockets |
| `qmd` | installed from `@tobilu/qmd` when npm is available | managed llm-wiki semantic search/index maintenance; installed by `install.sh` into `${XDG_DATA_HOME:-~/.local/share}/hive/qmd` and discovered by generated wiki scripts through `HIVE_QMD_BIN`, PATH, or Hive's managed install path |
| `npm` | any recent npm with Node.js | installer for the QMD npm package; Hive reports missing npm but does not install Node.js/npm itself |
| `asciinema` | 2.4+ (3.x accepted with v2 output flag) | test-time optional; `test/e2e/lib/asciinema_driver.rb` records TUI failure casts when installed |

`HIVE_CLAUDE_BIN` env var overrides the `claude` binary, used by tests with `test/fixtures/fake-claude` and `fake-gh`.

## Ruby version

`Gemfile` declares `ruby "~> 3.4"`. `.rubocop.yml` pins `TargetRubyVersion: 3.4`. `Gemfile.lock` records 3.4.7 as the resolved version.

## Backlinks

- [[architecture]]
- [[modules/gh]]
- [[modules/agent]]
- [[commands/bot]]
- [[e2e]]
