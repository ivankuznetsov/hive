---
title: hive wiki
type: command
source: lib/hive/commands/wiki.rb, lib/hive/wiki_log.rb, openclaw/skills/hive/SKILL.md
created: 2026-06-05
updated: 2026-11-02
tags: [command, wiki, changelog, generated]
---

**TLDR**: `hive wiki compile-log [PROJECT_PATH]` rebuilds `wiki/log.md`
from per-change fragments under `wiki/log.d/*.md` plus real legacy
changelog entries. Fresh template prose is dropped instead of preserved
as a bogus entry. Agents should add a uniquely named fragment instead of
editing `wiki/log.md` directly; the compiler is for post-merge refreshes
or local aggregate checks, not ordinary feature PR diffs.

## Fragment Flow

Each wiki refresh writes a new Markdown fragment:

```text
wiki/log.d/20260605-220000-short-topic.md
```

The fragment body is a normal changelog entry starting with `## [...]`.
`Hive::WikiLog` reads non-empty `*.md` fragments sorted by filename
descending, wraps the generated section in explicit markers inside
`wiki/log.md`, and leaves any pre-fragment legacy entries below that
section. Legacy extraction starts at the first `## ` entry after the
header; if a fresh wiki template contains prose but no entries, that
prose is discarded. Re-running the compiler is idempotent and does not
duplicate entries already inside the generated block.

## Commands

| Command | Behavior |
|---------|----------|
| `hive wiki compile-log` | Regenerate `wiki/log.md` in the current project. |
| `hive wiki compile-log PATH` | Regenerate another checkout's changelog. |
| `hive wiki compile-log --check` | Exit non-zero if `wiki/log.md` is stale. |

The command exits with `Hive::InvalidTaskPath` / EX_USAGE when the
project has no `wiki/` directory or when `--check` finds stale output.

## Options

`hive wiki compile-log --check` reports whether the compiled log is current
without rewriting it. Omit `--check` to compile the log.

## Output, exceptions, and exit codes

The command has no JSON mode or schema. Output is human-readable text, so JSON
serialization and a serialization fallback are not applicable. `compile-log`
writes the generated aggregate; `--check` is the read-only exception and emits
an error without modifying a stale file.

| Code | Meaning |
|---:|---|
| 0 | Compilation completed, or `--check` found the aggregate current. |
| 64 | The subcommand/project was invalid, the wiki was absent, or `--check` found stale output. |
| 1 | An unclassified filesystem/compiler failure escaped the command. |

## OpenClaw Wrapper

The single ClawHub `hive-cli` skill also advertises this surface through
`/hive wiki compile-log --check`. Its instructions prefer `--check` for
verification and reserve the mutating compile command for merge/rebase
cleanup or explicit user requests. Feature PRs should still add
`wiki/log.d/<timestamp>-<slug>.md` fragments instead of editing the
compiled aggregate directly. See [[commands]] and [[operating]] for the
broader OpenClaw surface.

## Concurrency Rationale

`wiki/log.md` used to be the single append-only changelog file every PR
touched, so concurrent Hive PRs routinely conflicted at the tail even
when the actual source and wiki page edits were independent. Fragments
turn that hot append point into many independent files; the generated
aggregate can be refreshed after rebasing or after merge.

## Known gaps

- [2026-06-16/17 refresh uncertainty domain items](web.md#hive-web-agents-page-login-fixes-are-sourcerails-integration-pinned-not-live-provider-smoked)

- [Native reviewer June refresh evidence](../modules/reviewers.md#native-codex-reviewer-transcript-trimming-is-unit-pinned-not-live-flow-smoked)

### Main-wiki QMD freshness

#### Source S15, lines 264–271: Main-wiki QMD freshness

LLM-wiki bootstrap now resolves the live `hive-wiki` collection from QMD's
local `index.yml` before legacy filesystem conventions, so stale deleted
`main_wiki_path` values can migrate to the collection's current directory.
This validates directory presence, not index freshness: QMD indexing remains
owned by the bounded refresh runner, and an old collection index can still
return stale search results until its next successful update.

### Source-file coverage overview

#### Source S17, lines 348–349: Patrol dispatch incident demand baseline (2026-08-26)

**TLDR**: The wiki has broad domain coverage for the current `lib/`, command, stage, TUI, daemon, bot, native Hive web, testing/static-analysis, template/prompt, and release surfaces, but the source-file map below is representative rather than an automatically verified one-file-per-source audit. Remaining gaps are mainly live behavioral verification and a few deeper reference pages.

### Source-file coverage (representative map)

#### Source S27, lines 717–748: Source-file coverage (representative map)

| Area / file set | Page |
|-----------------|------|
| `bin/hive`, `lib/hive/cli.rb`, command registration | ✓ [[cli]], [[commands]] cover command registration plus the wrapper-level `--version`, command-local help rewrite, leading JSON boolean grammar contracts, first-`--` option-scan termination, snapshot-based last-recognized-JSON-boolean error-mode semantics, and the `hive new PROJECT` lift-and-rebuild contract that lifts recognized `--workflow`/`--depends-on` (and their `=VALUE`/JSON-boolean forms) from anywhere outside an explicit `--`, rebuilds the `PROJECT TEXT...` tail behind a protective `--`, and leaves a trailing/value-less value option as literal task text. |
| `bin/hive`, `lib/hive/cli.rb`, command registration | ✓ [[cli]], [[commands]] cover command registration plus the wrapper-level `--version`, command-local help rewrite, leading JSON boolean grammar, and pre-dispatch JSON usage-error contracts for required-argument command surfaces. |
| `lib/hive/commands/*.rb` | ✓ `wiki/commands/*` pages cover the active command surface, including setup, daemon, bot, web, init, new, generate-name, status/archive listing, run, stage-action, markers, migrate, findings, metrics, update, uninstall, wiki, bench-submit, and rebase-status. |
| `bin/hive`, `lib/hive/cli.rb`, command registration | ✓ [[cli]], [[commands]] cover command registration plus the wrapper-level `--version`, command-local help rewrite, and leading JSON boolean grammar contracts. |
| `lib/hive/commands/*.rb` | ✓ `wiki/commands/*` pages cover the active command surface, including daemon, bot, web, init, new, generate-name, status/archive listing, run, stage-action, markers, migrate, findings, metrics, update, uninstall, wiki, bench-submit, digest, and rebase-status. |
| `lib/hive/commands/{connect,disconnect}.rb`, `lib/hive/screenote/**` | ✓ [[commands/screenote]], [[modules/config]], and [[stages/artifacts]] cover Screenote OAuth setup, credential storage, MCP injection, and fail-soft artifact behavior. |
| `lib/hive/stages/*.rb`, `lib/hive/stages/review/**` | ✓ [[stages/index]] plus per-stage pages; review submodules are covered by [[stages/review]]. |
| `lib/hive/patrol/*`, `lib/hive/commands/patrol.rb` | ✓ [[modules/patrol]] and [[commands/patrol]] cover ordinary discovery, native finding state, direct Patrol Fix admission, scheduling, and launch allowances. |
| `lib/hive/refactor_patrol/*`, `lib/hive/commands/refactor_patrol.rb`, daemon architecture-patrol scheduling | ✓ [[commands/refactor-patrol]], [[modules/daemon]], [[modules/config]], [[modules/gh]], [[state-model]], and [[testing]] cover merge classification, frozen batches, direct v4 jobs, scheduled slices, discovery claims/checkpoints, and direct Patrol Fix admission. |
| `lib/hive/daemon/*` | ✓ [[modules/daemon]] and [[commands/daemon]] cover dispatcher, healer, queues, merge watcher, status consumer, logging, and service/queue command surfaces. |
| `lib/hive/babysitter/**`, `lib/hive/commands/babysit.rb`, `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh.rb` | ✓ [[modules/babysitter]] and [[commands/babysit]] cover the experimental PR babysitter process, lifecycle command, GitHub PR repair loop, generated dry-run launcher handoff, and executable `git`/`gh` default-deny stub API boundaries. |
| `lib/hive/bot/*` | ✓ [[modules/bot]] and [[commands/bot]] |
| `lib/hive/web/**`, `public/`, `hive.gemspec`, `lib/hive/commands/web.rb`, `lib/hive/commands/setup.rb`, `.github/workflows/release.yml` | ✓ [[commands/web]], [[commands/setup]], [[commands]], [[architecture]], [[modules/config]], [[dependencies]], and [[testing]] cover the web routes, managed bundle/install payload, config/API surface, agent-login relay/polling boundaries, favicon assets, and manual e2e contract. |
| `lib/hive/tui/**` | ✓ [[commands/tui]], [[architecture]], and [[token-usage]] cover the MVU/TUI surfaces. |
| `lib/hive/agent.rb`, `lib/hive/agent_limit.rb`, `lib/hive/claude_launcher.rb`, `lib/hive/scripts/interactive_claude_wrapper.sh`, `lib/hive/agent_profile*.rb`, `lib/hive/agent_profiles/**` | ✓ [[modules/agent]], [[modules/agent_profile]], [[stages/index]], [[stages/brainstorm]], [[token-usage]] |
| `lib/hive/config.rb`, `templates/project_config.yml.erb` | ✓ [[modules/config]], [[commands/init]], [[state-model]] cover config defaults/validation plus init-rendered `claude.model` / `claude.effort` pins. |
| `Gemfile`, `hive.gemspec`, `Gemfile.lock` | ✓ [[dependencies]] covers runtime gem constraints, development/test gems, Ruby/Bundler lockfile metadata, the local path gem version, and external CLI dependencies. |
| `.github/workflows/ci.yml`, `config/brakeman.ignore`, `web/config/ci.rb` | ✓ [[testing]] and [[dependencies]] cover the RuboCop, Brakeman, and bundler-audit CI/tooling surface; [[commands/web]] covers the task log-tail and media routes behind the current Brakeman false-positive ignores. |
| `lib/hive/task_action.rb`, `lib/hive/diagnostic_evidence.rb`, status/recovery helpers | ✓ [[modules/task_action]], [[commands/status]], [[modules/execute_waiting_action]], [[modules/diagnosis_agent]] cover red-row diagnostics, read-only `--diagnose` evidence fallback, recovery hints, and the diagnosis-agent write path. |
| `lib/hive/gh.rb` | ✓ [[modules/gh]] covers the shared GitHub CLI helper surface; [[dependencies]], stage pages, [[commands/stage_action]], and [[modules/babysitter]] cover its command-level consumers. |
| `lib/hive/pr.rb` | ✓ [[modules/pr]] covers the local PR URL → `#number` formatter used by the TUI PR column. |
| Core task/state helpers: `task`, `markers`, `lock`, `worktree`, `git_ops`, `rebase`, `workflows`, `metrics`, `secret_patterns`, `protected_files`, `events` | ✓ `wiki/modules/*` pages exist for each named domain. |
| `templates/*.erb` and prompt files | ✓ [[templates]] plus stage pages |
| `openclaw/skills/hive/SKILL.md`, `openclaw/README.md` | ✓ [[commands]], [[operating]], and [[commands/wiki]] cover the single ClawHub `hive-cli` skill, `/hive` slash-command dispatch, guided setup, wiki changelog verification, and publish-shape constraints. |
| `test/unit`, `test/integration`, `test/e2e`, `test/eval`, `Rakefile`, `bin/hive-e2e`, `bin/hive-eval` | ✓ [[testing]] and [[e2e]], including manual-gated Hive web Playwright coverage and eval-runner selector coverage. |
| `test/unit`, `test/integration`, `test/e2e`, `test/eval`, `Rakefile`, `bin/hive-e2e`, `bin/hive-eval` | ✓ [[testing]] and [[e2e]], including manual-gated Hive web Playwright coverage and the checkout-only Telegram bot eval runner. |
| `test/unit`, `test/integration`, `test/e2e`, `test/eval`, `Rakefile`, `bin/hive-e2e`, `bin/hive-eval` | ✓ [[testing]] and [[e2e]], including manual-gated Hive web Playwright coverage, eval-runner selector coverage, `bin/hive-eval`'s checkout-local usage boundary, the explicit `HIVE_EVAL_NO_JUDGE` env-clearing contract, and `bin/hive-e2e` replay / leading-JSON-help contracts. |

Uncertainty: this table was refreshed manually from targeted source, dependency-manifest, executable-entrypoint, and wiki reads on 2026-06-16, with the eval-runner row targeted again on 2026-06-17. It verifies domain coverage, not exact one-to-one file coverage or installed release-bundle behavior. The 2026-06-15 wrapper refresh source-inspected `bin/hive` and `test/integration/cli_version_test.rb`, and the 2026-06-16 e2e refresh source-inspected `bin/hive-e2e` plus `test/e2e/lib/hive_e2e_binary_test.rb`; neither found an in-tree artifact proving packaged RubyGems/Homebrew/AUR `hive` wrapper behavior or live patrol/babysitter consumption of `bin/hive-e2e` replay error envelopes. The 2026-06-16 clipboard refresh source-inspected `lib/hive/tui/clipboard.rb` and `test/unit/tui/clipboard_test.rb`; it found the fixture stabilization documented in [[testing]], but no checked-in artifact proving the hosted Ruby 3.4.9 coverage job passed after commit `5389920e` or that the real Wayland/X11/macOS clipboard probes were live-smoked after the test-only fixture change. A future refresh could add a small script that compares `rg --files lib/hive` to `wiki/**/source:` patterns and reports unmapped files.

### 2026-06-16/17 refresh uncertainty

#### Source S29, lines 911–914: 2026-06-16/17 refresh uncertainty

The 2026-06-17 audit rechecked recent source, tests, git history, project wiki
pages, and the configured master wiki path, and did not find new in-tree live
evidence closing the following June 16 gaps.

### Open enhancements

#### Source S32, lines 953–953: Open enhancements


### Areas the wiki could be expanded

#### Source S36, lines 1001–1006: Areas the wiki could be expanded

- `wiki/troubleshooting.md` — currently lives only in README's Troubleshooting section. Could be lifted into a dedicated page once the project sees real-world failures.
- `wiki/security.md` — dedicated page for the trust model, prompt-injection policy, and the protected-files SHA-256 check. Currently spread across `[[architecture]]`, `[[decisions]]` ADR-008, and `[[modules/agent]]`.
- `wiki/operating.md` — expand the existing page with deeper log rotation, `.hive-state` backup strategy, recovering from a deleted feature worktree, and live daemon restart playbooks once ops practice exists.
- `wiki/roadmap.md` — Phase 2/3 work is listed in [[active-areas]]; a dedicated roadmap with status columns would be more navigable once Phase 2 work begins.

### Backlinks

#### Source S37, lines 1008–1012: Backlinks

- [[active-areas]]
- [[index]]
- [[e2e]]

### Resolved

#### Resolved Bootstrap Validation

##### Source S38, lines 1014–1018: Resolved Bootstrap Validation

- 2026-05-14: Managed llm-wiki config, agent context, post-commit hook, and daily systemd timer were validated for `hive`.
- 2026-05-15: `qmd status` reports Vulkan GPU offload on AMD Radeon 890M Graphics (RADV STRIX1) after installing the Arch Vulkan stack.
- 2026-05-15: `qmd query "llm wiki managed bootstrap" -c hive --no-rerank -n 3` completed with local Vulkan-backed generation; sandboxed agent sessions still need qmd cache write access via `--add-dir` or host-side maintenance hooks.

#### Large LLM-wiki backlog recovery verified (2026-07-22)

##### Source S48, lines 1192–1210: Large LLM-wiki backlog recovery verified (2026-07-22)

The repaired runner drained the live Hive backlog from 637 complete queue
entries plus five interrupted temp writes to zero pending, hidden, or failed
entries. All five temp writes were reconstructed; 658 receipt refs now cover
the recovered history, and no source-pin, consecutive-failure, or publication
breaker remains. The local and published `llm-wiki/refresh` heads match with a
wiki-only diff from the current default branch. The primary checkout stayed
clean, and the scheduler remained at 13 repository-owned timer/service pairs
before and after recovery; every service retains its 4 GiB memory ceiling and
none was left active or failed.

Live closure also exposed one additional downgrade path: startup
reconciliation invoked from an older linked checkout could overwrite the
shared runner after recovery. Shared-runtime installation is now pinned to the
primary worktree whenever its managed files exist, with regression coverage
for a deliberately stale linked copy. The bootstrap-only fallback remains for
repositories whose primary worktree does not yet contain managed wiki files.
No unresolved recovery gap remains for this incident.
