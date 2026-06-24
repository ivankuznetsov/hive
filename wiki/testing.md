---
title: Testing
type: reference
source: test/, Rakefile, bin/hive-eval, .rubocop.yml, .github/workflows/ci.yml, config/brakeman.ignore
created: 2026-04-25
updated: 2026-06-22
tags: [test, minitest, fixtures]
---

**TLDR**: Minitest for unit/integration coverage, plus opt-in outer e2e, eval, install-smoke, release-verify, and hivebox image smoke layers. `test/unit/` covers modules, `test/integration/` covers command/stage behaviour in-process, `test/e2e/` drives the real `bin/hive` subprocess plus tmux for TUI scenarios, `test/eval/` evaluates the Telegram bot signal contract, and CI layers RuboCop, Brakeman, bundler-audit, installer checks, and Docker smoke tests on top.

## Run all

```bash
bundle exec rake test
```

## Coverage

```bash
bundle exec rake coverage
```

The coverage task uses Ruby's stdlib `Coverage` API. It starts line and branch coverage in the parent test process and prepends `RUBYOPT=-Itest -rhive_coverage_boot` so Ruby subprocess tests dump their own result files under a per-run `coverage/.resultset/<run-id>/` directory. The final merged report is written to `coverage/coverage.json` and prints the lowest-covered source files plus uncovered line numbers.

`bundle exec rake coverage` is the CI coverage-report path. It fails when an executable source file was never loaded, when a subprocess result file cannot be read, or when line coverage drops below the default 100% threshold. Set `HIVE_COVERAGE_MIN_LINE` to a different numeric percentage only when intentionally loosening or tightening that gate. Visual-artifact and Screenote code paths are part of that 100% gate, including error/default branches such as invalid Screenote JSON, default Net::HTTP transport, manifest upload exceptions, missing media directories, screenote config type errors, and dry-run digest completion failures.

Coverage-included tests that only need a generic stdout/stderr subprocess should avoid `RbConfig.ruby` children unless they are explicitly testing Ruby coverage propagation. Those nested Ruby processes inherit the coverage `RUBYOPT`, which can make startup latency part of otherwise unrelated timeout assertions; use a tiny executable fixture script for generic capture/timeout seams.

In CI (`CI=true`), tests that exercise backgrounding commands must force a foreground path (for example `foreground: true`) or stub daemonization. Otherwise the test process can daemonize before Minitest `after_run` writes `coverage/coverage.json`, leaving the parent coverage task with a missing report while child output keeps streaming. Coverage also reloads `lib/hive.rb`, so self-derived enum constants must exclude `:ALL` to stay reload-safe.

`Rakefile`:
```ruby
Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/{unit,integration}/**/*_test.rb"]
  t.warning = false
end
task default: :test
```

## Test helpers (`test/test_helper.rb`)

- `with_tmp_dir` — `Dir.mktmpdir("hive-test", &block)`.
- `with_tmp_git_repo` — `git init -b master`, configures user/email and disables GPG signing, makes one initial commit, yields the path.
- `with_tmp_global_config(home: nil)` — overrides `ENV["HIVE_HOME"]` to a tmp dir, writes an empty `registered_projects: []` YAML, and defaults `HOME` to the same tmp dir so subprocesses and service-installer tests do not touch the operator's real home. Pass `home:` when a test intentionally installs fake user-level skills or plugins under a separate fake HOME.
- `run!(*cmd)` — shells out and raises on non-zero exit (used in setup helpers; not for testing the CLI itself).

## Fixtures

| Path | Purpose |
|------|---------|
| `test/fixtures/fake-claude` | Shell script that takes Claude/Codex headless argv, optionally writes captured args to a log, optionally echoes a scenario-controlled response, optionally writes a file, and can commit a scenario-controlled file in cwd. Pointed at via `HIVE_CLAUDE_BIN` and e2e `HIVE_CODEX_BIN`. |
| `test/fixtures/fake-gh` | Shell script that handles `gh pr create` / `gh auth status` / `gh pr list`, returns a dummy URL. |
| `test/fixtures/voice/voice-idea.oga` | Checked-in Ogg/Opus speech sample saying "voice idea" for the Telegram voice-note E2E path. `run_idea_e2e.sh` uses it by default when `TG_IDEA_MODE=voice`; explicit voice mode hard-fails when `HIVE_WHISPER_API_KEY` is unset. Voice mode uses the same fixture for both new audio idea capture and audio brainstorm answers. |

## Unit suite (`test/unit/`)

| File | Covers |
|------|--------|
| `config_test.rb` | `Hive::Config` — defaults, `default_workflow`, deep-merge, register/find, malformed YAML rejection, normal and patrol reviewer validation, and global Screenote config URL/token type validation. |
| `workflow_selection_test.rb`, `content_workflow_fixture_test.rb`, `workflows/content_test.rb`, `workflows/descriptor_parser_test.rb`, `workflows/loader_test.rb`, `workflows/project_test.rb`, `commands/workflow_new_test.rb` | Workflow selection, descriptor parsing/loading, project overlay registration, scaffolded workflow authoring, content descriptor shape, and test-only fixture support — CLI selector validation, valid-name listing, scoped fixture registration, runtime project descriptor discovery, cache invalidation, deterministic content-agent artifact writes, registry leak guards, and the built-in `:content` stage order/files/skills/budgets/timeouts. |
| `task_test.rb` | `Hive::Task` — path regex, descriptor-driven stage/index validation, workflow selector/default fallback, derived paths, slug edge cases. |
| `markers_test.rb` | `Hive::Markers` — set/get round-trip, attribute quoting, last-marker semantics. |
| `lock_test.rb` | `Hive::Lock` — acquire/release, stale-PID detection, commit lock parallelism. |
| `worktree_test.rb` | `Hive::Worktree` — create attach-vs-new, dependency override stacking (incl. narrow-refspec and origin-ahead-of-local **and** local-ahead-of-origin placeholders), empty placeholder re-pointing, fail-closed preservation when the emptiness check errors, local-only prerequisite fallback, real-commit preservation, delete-failure errors, `local_branch_ref_exists?` blank-name guard, remove, exists?, pointer round-trip, prefix validation. |
| `git_ops_test.rb` | `Hive::GitOps` — default-branch detection, orphan worktree bootstrap, idempotent gitignore, empty-diff commit skip. |
| `gh_test.rb` | `Hive::Gh` — PR frontmatter parsing, secret-scan fetch-failure semantics, open/merged PR lookup, `pr_state` success/error parsing, `PushResult`, subprocess timeout/termination, `mergeStateStatus` request shape for open PR listing, and failing-job log clipping. |
| `pr_test.rb` | `Hive::Pr` — pull-request-number extraction from `/pull/<number>` URLs, including query/fragment/trailing-slash tolerance, nil for issue/non-number/subpage URLs, and http(s) URL validation including invalid-URI rejection. |
| `agent_limit_test.rb` | `Hive::AgentLimit` — provider-limit classifier for Claude usage-credit menus and common quota/rate-limit API errors, retry-cooldown timestamp helpers, and the shared quota-held display/JSON helpers (`held?`, provider extraction, UTC retry display, label text, and `held` field shape), with runnable false-positive guards for source line numbers and ordinary "missing rate limit" findings. The current file also contains intended UI-feature limit assertions, but they sit below a `private` marker; this refresh treats them as a coverage gap until moved into the public runnable test set. |
| `agent_test.rb` | `Hive::Agent` — spawn/wait/timeout/SIGINT forwarding, version check, configured Claude model/effort `cli_flags` reaching the headless argv, and provider-limit classification before generic exit-code / expected-output failures. |
| `skill_check_test.rb` | `Hive::SkillCheck` — Claude/Codex/Pi skill invocation parsing and discovery, plugin fallback paths, Pi package/settings/git discovery, malformed invocation hints, and deterministic `npm root -g` success/timeout coverage for the global npm root probe. |
| `wiki_log_test.rb` | `Hive::WikiLog` — fragment sorting, generated-block idempotency, stale detection for compiled `wiki/log.md`, and dropping template prose that is not a real legacy `##` entry. |
| `schema_files_test.rb` | Published JSON schema contracts — current-version schema files exist for every `Hive::Schemas::SCHEMA_VERSIONS` entry, back-compat schema files remain for pinned consumers, producer required-key drift is pinned, `hive-status` task properties stay aligned with `Snapshot::Row` including the optional quota `held` object, `hive-dispatch-request` claimed files remain schema-valid, and every schema filename/version matches its `$id` basename or URN suffix plus `title` version text. |
| `cli_test.rb` | `Hive::CLI` — command delegation and option threading for the Thor surface, including `hive workflow new`, `hive generate-name` lookup scoping, and internal archive recovery flags. |
| `commands/bench_submit_test.rb` | `Hive::Commands::BenchSubmit` — resolves completed `9-done` tasks from registered projects, derives the source repo from GitHub `origin`, requires `worktree.yml` + `pr.md`, aborts before PR creation on local secret findings, and surfaces missing slugs/checkouts as usage errors. Coverage now includes the default local secret scanner, JSON/text reporting, `run_git`, extractor invocation against a stub `harness/extract.rb`, and PR opening through stub `git`/`gh` binaries; no real hive-bench validator, `git push`, or GitHub PR is exercised. |
| `commands/digest_test.rb` | `Hive::Commands::Digest` — strict `YYYY-MM-DD` parsing, default runner invocation, dry-run message output, and success-only `hive-digest` JSON. |
| `commands/daemon_test.rb` | `Hive::Commands::Daemon` — lifecycle command routing, PID-file ownership/status handling, detached start/re-exec behavior, service install/enable/disable output, queue inspection, and start-path wiring of daemon/update/digest config into the dispatcher. Start tests stub all three global config blocks so operator-local Telegram digest defaults cannot change unit expectations. |
| `digest/window_test.rb`, `digest/ship_times_test.rb`, `digest/collector_test.rb` | Digest collection primitives — local-date helpers, git-log ship-time preference (`pr_finalized`, `archived`, approval into `9-done`), registered-project grouping, missing artifact tolerance, and local timezone boundaries. |
| `digest/categorizer_test.rb`, `digest/renderer_test.rb`, `digest/run_test.rb`, `digest/sender_test.rb` | Digest generation/delivery — model JSON mapping and fallbacks, prompt rendering with PR bodies, Telegram MarkdownV2 escaping/category ordering, empty/success/failed-notice orchestration, dry-run token bypass, chat-id resolution, and Telegram send arguments through an injected client. These are unit seams; no real agent or Telegram Bot API call is exercised. |
| `daemon/digest_scheduler_test.rb` | `Hive::Daemon::DigestScheduler` — first-run no-history guard, local-midnight due calculation, one-day-at-a-time catch-up, catch-up cap logging, non-zero retry behavior, disabled mode, and DST local-date handling. |
| `claude_launcher_test.rb` | `Hive::ClaudeLauncher` — headless/tmux delegation, readiness deadlines, prompt submission, pane logging, tmux-session loss before terminal markers and expected-output waits, provider-limit menu classification, signal cleanup, and wrapper argv policy including model/effort pins. |
| `commands/run_test.rb`, `stages/agent_test.rb`, `stages/resolver_test.rb` | Descriptor-backed runner dispatch — `Run#pick_runner` passing `task.workflow`, generic `kind: :agent` prompt rendering, prior-artifact nonce wrapping, marker-to-action mapping, spawn kwargs, coding-name bespoke runner precedence, generic non-coding fallback, `StageError` fallback, and lazy require behavior. |
| `task_action_test.rb`, `task_action_generic_test.rb`, `daemon/policy_test.rb` | Status action classification and daemon decision coverage — coding action/command invariants, coding action golden matrix, descriptor-generic marker classification, generic `hive approve ... --from <stage>` and `hive run` command shape, and `ready_to_advance` policy dispatch/block/skip behavior. |
| `stages/brainstorm_tmux_sentinel_test.rb` | Claude/tmux sentinel and cleanup behavior — readiness/sentinel delegation, pgrep pattern shape, missing/failing pgrep logging, oversized orphan-sweep log rotation, and the v0.2.3 invariant that a task cleanup kills matched Claude PIDs individually while skipping a matched tmux server. |
| `display_name/generator_test.rb` | `Hive::DisplayName::Generator` — timeout handling, process groups, agent output sanitization, best-effort sidecar updates/commits, and Codex stdin prompt delivery. |
| `tmux_runner_test.rb` | `Hive::TmuxRunner` — detached session startup, environment propagation, prompt injection via tmux buffers, typed tmux failure/timeout classes, prompt-buffer cleanup, paste-settle polling before Enter submit, bounded pane-tail capture, PID lookup, idempotent teardown, and a lightweight fake-tmux timeout harness so setup commands cannot consume the timeout budget before the intentionally hanging `send-keys` call. |
| `daemon/pr_merge_watcher_test.rb`, `daemon/dispatcher_test.rb` | Finalize merge watcher routing — `MERGED` PR polling returns archive dispatches, carries the internal `--recover-merged-error-reason` flag for whitelisted finalize errors, ignores unknown error reasons, and the dispatcher hands `8-finalize ERROR reason=git_status_failed` rows to the watcher instead of skipping them as generic errors. Dispatcher coverage also pins digest scheduler dispatch/completion, dry-run digest pseudo-child reaping, and fatal-log isolation when `DigestScheduler#complete` raises. |
| `screenote_uploader_test.rb` | `Hive::ScreenoteUploader` — credential/no-file skips, multipart framing and binary/UTF-8 safety, content type selection, filename quoting, HTTP failure/exception handling, invalid/non-object/blank/non-http success payload diagnostics, screenshot-id passthrough, and default Net::HTTP transport timeouts. |
| `stages/artifacts_test.rb` | `Hive::Stages::Artifacts` — marker/idempotent behavior, manifest-driven still uploads, skipped/failed/future-schema manifests, screenote config errors, unexpected upload exceptions, upload budget partial writes, folder mtime touch, filename eligibility, traversal/nested/null-byte/missing/symlinked media path refusal, and run-time manifest upload after agent completion. |
| `daemon/status_consumer_test.rb` | `Hive::Daemon::StatusConsumer` — `hive status --json` envelope parsing, schema-version skew handling, strict `live_task_lock` coercion, legacy project filtering, and local `state_file` mtime re-stat so daemon edit-resume decisions keep subsecond precision even though public JSON timestamps are whole-second ISO8601. |
| `daemon/stale_agent_healer_test.rb` | `Hive::Daemon::StaleAgentHealer` — stale `AGENT_WORKING` healing, wedged `REVIEW_WORKING` lock cleanup, and bounded daemon auto-recovery for `review_agent_died`, reviewer partial failures caused only by Claude/tmux expected-output session death, `8-finalize` `ERROR reason=unpushed_commits`, elapsed `limits_reached` cooldown markers (including terminal `ERROR reason=limits_reached` on `4-execute`), and non-review terminal agent-loss errors (`2-brainstorm`, `3-plan`, `4-execute`, `7-artifacts`, `8-finalize` `ERROR reason=tmux_session_terminated` or `reason=agent_orphaned`). Terminal-error coverage pins marker-id guarded clears, live-lock skips, manual repository-state skips, shared budgets across fresh marker ids, per-task budget isolation, pre-clear dispatch-baseline seeding, the `3-plan` `hive plan ... --from 3-plan` dispatch-request requeue / `heal_requeued` trace for both agent-loss and `limits_reached` clears, the distinct `heal_requeue_failed` event when enqueueing fails after a successful clear, and one-shot `marker_heal_exhausted` logging. |
| `hv_test.rb` | `bin/hv` — refuses unsafe Apache Hive fallback paths (`/usr/bin/hive`, `/opt/hive/bin/hive`) and verifies `HIVE_BIN_OVERRIDE` can point at a custom Hive CLI install path. |
| `gemspec_test.rb`, `install_script_test.rb` | RubyGem/install packaging — `hv` stays out of `spec.executables` so RubyGems does not create a broken Ruby binstub for the bash launcher; the bash installer writes its own `hv` wrapper and does not expect a gem-installed `hv` shim. |
| `babysitter/dry_run_env_test.rb` | `Hive::Babysitter::DryRunEnv` plus `bin/hive-babysitter-stub-git` / `bin/hive-babysitter-stub-gh` — PATH overlay wrapper handoff, command-local `HIVE_BABYSITTER_REAL_*` and `HIVE_BABYSITTER_DRY_RUN_LOG` override resistance, recording fake binaries pinned to the current test runner Ruby so git-stub PATH pinning cannot switch fixture interpreters, default-deny skips, read-only passthrough, argv-wide and positional `gh` host-override skips, `GH_HOST` / `GH_REPO` / enterprise-token env scrubbing, `gh` config env scrubbing plus fresh empty `HOME`/`GH_CONFIG_DIR` passthrough roots, `gh api` implicit-POST payload flag blocking plus explicit-GET file/cache guards, host-default non-token `gh auth status` passthrough with token-display and hostname skips, browser-launch flag skips plus `w` inside value-taking `gh` read-option values, git executable/write-option skips, `remote show` without `-n` skipping before repo-configured transport helpers can run, exact read-only `git branch` forms and mixed branch mutation skips, env config/command seam skips including `GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS`, hermetic HOME/XDG/local git config passthrough guards, `--textconv` abbreviation, `cat-file --filters`, and git signature-verification skips, subcommand `-p` passthrough, `grep`/`ls-files` read-option exceptions, grep pager `--open-files-in-pager` abbreviations and `-O` forms including clustered `-nO<cmd>`, value-taking grep short options such as `-eTODO` / `-fNEEDLEFILE.txt`, pathspec separator handling, symlinked skip-log refusal, FIFO skip-log refusal through a timeout-bounded stub capture, and ASCII control-character escaping in skip logs/stderr. It does not currently include a focused invalid/non-UTF-8 argv regression for the stub log path. |
| `bot/router_test.rb`, `bot/slash_handlers_test.rb`, `bot/supervisor_test.rb`, `bot/status_watcher_test.rb`, `bot/format_test.rb`, `bot/notification_builders_test.rb`, `bot/notification_dispatcher_test.rb` | Telegram bot slash/menu/status/notification surface — router classification for supported slash commands including first-contact `/start`, `SlashHandlers#start` welcome copy with concrete next steps, the `setMyCommands` quick-actions list (`/idea`, `/status`, `/queue`, `/answer`, `/approve`, `/autofix`, `/details`, `/done`, `/help`), `StatusWatcher` parsing of status rows including id/display name/`pr_url`, HTML escaping and PR-link formatting, `/status` and `/queue` PR-link rows, ready-for-review push enrichment, parse-mode forwarding, and fingerprint stability. |
| `openclaw_skills_test.rb` | OpenClaw skill metadata — only the umbrella `hive-cli` listing is published, setup stays visible before the CLI is installed, `/hive` common paths include `wiki compile-log --check`, fragment-first changelog guidance is present, destructive/foreground admin commands require confirmation, and README publish instructions avoid shortcut listings. |
| `commands/babysit_test.rb` | `Hive::Commands::Babysit` — lifecycle command routing, PID-file ownership handling, stale-runtime status/reload warnings, foreground restart, detached restart re-exec into canonical `start --detach` through the stable invoked wrapper, aborting restart and failing direct stop after a refused stop, clear detached re-exec failure reporting, initial/post-grace ownership-probe clean-exit handling, pre-KILL ownership refusal, bounded PID-lock timeout, guarded stop cleanup that preserves a replacement PID file, and skip-KILL PID-file preservation when ownership becomes unverified. |
| `test/unit/web/web_command_test.rb` | `hive web` Rails-app-dir resolution (HIVEBOX_WEB_APP_DIR override, missing-app exit 1), `db:prepare` typed failure guidance, final Rails `Kernel.exec` env/argv, and the public-bind warning. |
| `test/unit/web/dispatcher_test.rb` | `Hive::Web::Dispatcher` — stage-run verb mapping, unknown-action refusal before daemon queue writes, Recover queuing a guarded marker-clear plus stage rerun as one request sequence while refusing manual-only or markerless states, discarding the sequence sidecar if the initial request write fails, Reject's prior-gate derivation, brainstorm answer/intervene writes through `BrainstormAnswerWriter`, and Advanced Drop calling `Commands::Drop` in-process while refusing stale `from` stages with `Hive::WrongStage`. |
| `test/unit/web/status_feed_test.rb`, `web/test/models/status_broadcaster_test.rb` | Hivebox status broadcasting — registered-project snapshots, one shared scan per poll tick, emit-on-connect for independent subscribers, volatile-field dedup that keeps `mtime`/`folder_mtime` significant, poller survival after snapshot errors, and `StatusBroadcaster` resubscription after a raising Turbo broadcast. |
| `web/agents_auth_test.rb`, `web/agents_auth_login_test.rb`, `web/agents_routes_test.rb` | `Hive::Web::AgentsAuth` — Claude paste-back PTY login URL capture, Codex `--device-auth` URL sanitize/poll-login behavior, `gh auth login --web` URL capture plus auto-Enter prompt handling, binary PTY output scrubbing, rejected-code errors, watchdog/process-group cleanup, concurrent-session cap, Pi token JSON rejection/persistence, and route wiring. |
| `web/config_test.rb`, `web/supervisor_test.rb`, `web/app_coverage_test.rb` | Hivebox config/supervisor packaging support — global web defaults/validation, child restart/backoff/reload/shutdown decisions, and route coverage attribution guardrails. |
| `patrol/pr_opener_test.rb` | `Hive::Patrol::PrOpener` — PR creation, fingerprint mapping, optional `ReviewHandoff` creation of synthetic `6-review` tasks, worktree pointer contents, and `patrol.review_prs: false` cleanup behavior. |
| `stages/review/{ci_fix,triage,browser_test,fix_guardrail,suppression}_test.rb` | Review phase helpers — CI-fix retries, triage prompt/bias/custom-template/protected-file behavior, triage `review_triage` default fallback values (75 / 1800), browser-test protocol handling, fix-guardrail approval gates, and no-fix suppression fingerprint/strip/seed behavior. |
| `stages/review/run_reviewers_test.rb` | `Hive::Stages::Review.run_reviewers` — reviewer list selection for normal vs patrol-sourced tasks, per-reviewer failures, wall-clock deadlines, shared Claude tmux sessions, and GitHub comment mirroring. |
| `stages/review/phase_failure_helpers_test.rb` | `Hive::Stages::Review` phase-failure helpers — bounded `message=` summary truncation through `review_phase_error_summary`, capped exponential `triage_retry_backoff` delay through stubbed sleep, and the `run_triage_with_retries` wall-clock bail that returns `:wall_clock_exceeded` instead of launching another long triage spawn after the review budget is spent. |
| `commands/status_test.rb`, `archive_filter_test.rb`, `tui/schema_correspondence_test.rb`, `tui/snapshot_test.rb`, `tui/views/archive_pane_test.rb` | Status/TUI archive and scan boundary — required `hive-status` task keys match `Status#task_payload`, `Snapshot::Row` has a field for every emitted task key, `folder_mtime` is preserved, old archives hide only from daily text/grid views by age regardless of marker state, no-target `hive archive` filters to `9-done`, explicit archive views remain age-unfiltered, and stage-move race coverage pins vanished-folder skips, surviving-folder `ENOENT` re-raises, and duplicate-pruning behavior. |
| `commands/status_test.rb`, `archive_filter_test.rb`, `tui/schema_correspondence_test.rb`, `tui/snapshot_test.rb`, `tui/views/archive_pane_test.rb`, `tui/views/tasks_pane_test.rb`, `tui/views/hyperlink_test.rb` | Status/TUI archive, dependency state, quota-held state, PR column, and scan boundary — required `hive-status` task keys match `Status#task_payload`, `Snapshot::Row` has a field for every emitted task key, `folder_mtime` and `pr_url` are preserved, dependency fields render blocked/unblocked states, `ERROR`/`REVIEW_ERROR reason=limits_reached` rows render the shared held label and JSON `held` field without overloading `blocked_by`, text status/archive rows and the tasks pane render fixed PR-number columns with dash fallback, OSC 8 links validate/sanitize http URLs and stay disabled in captured non-TTY output, old archives hide only from daily text/grid views by age regardless of marker state, no-target `hive archive` filters to `9-done`, explicit archive views remain age-unfiltered, stage-move race coverage pins vanished-folder skips, surviving-folder `ENOENT` re-raises, duplicate-pruning behavior, and quiet `pr.md` ENOENT degradation during PR URL reads. |
| `tui/clipboard_test.rb` | `Hive::Tui::Clipboard` — Wayland/X11/macOS clipboard-command selection, image-byte/file probes, image signature and size guards, test-only fixture clipboard sequencing, timeout sentinels, and `DefaultShim.capture3` stdout/stderr/timeout behavior. Generic subprocess checks use tiny executable fixture scripts rather than nested `RbConfig.ruby` children so coverage-injected `RUBYOPT` does not dominate unrelated timeout assertions. |
| `tui/app_test.rb`, `tui/state_source_test.rb` | `Hive::Tui::App` / `StateSource` — charm-only backend selection, synchronous startup snapshot seeding, snapshot-poller dedup/error dispatch, HUP termination hook, WINCH terminal-size seeding/dispatch, unavailable tty-size handling, signal-handler restore failure tolerance, mtime-gated refresh reuse, and liveness-fallback reparsing. |

## Integration suite (`test/integration/`)

| File | Covers |
|------|--------|
| `init_test.rb` | `hive init` — preconditions, force flag, idempotent re-init, `--workflow` project defaults, TTY workflow prompt/default behavior, unknown-workflow fail-fast, in-flight field-less task warnings on default changes, `hive-init.v1` JSON payload, Claude model/effort answer/template defaults, normal reviewer rendering, patrol reviewer rendering, and prompt defaults. |
| `new_test.rb` | `hive new` — slug derivation, reserved rejection, `--workflow` task overrides, non-coding project-default pinning, coding override in non-coding projects, unknown-workflow fail-fast, marker handling for non-coding inert versus agent entries, captured commit, and per-project commit-lock serialization around the `hive/state` write. |
| `run_brainstorm_test.rb` | `hive run` of `2-brainstorm/`. |
| `run_plan_test.rb` | `hive run` of `3-plan/`. |
| `stages/execute_test.rb`, `run_execute_test.rb` | `Hive::Stages::Execute` and `hive run` of `4-execute/` — init pass, iteration pass, stale handling, worktree-missing recovery, execute-agent quota wall classification from `error_message` and raw `limit_text`, and the non-limit `implementer_failed` marker invariant. |
| `run_open_pr_test.rb` | `hive run` of `5-open-pr/` — push, draft PR creation, idempotent existing-PR path. |
| `run_review_test.rb` | `hive run` of `6-review/` — pre-flight states, reviewer/triage/fix/browser branching, no-fix suppression convergence and negative cases, manual wait and stale/error recovery, auto-commit/guardrail boundaries, provider-limit marker behavior for reviewers, triage limit vs non-limit failures, bounded transient triage retry recovery including wall-clock handoff to `REVIEW_STALE`, and `message=` surfacing on terminal phase-agent (triage and fix) errors — the CI phase writes `reason=ci_unrunnable` directly and carries no `message=`. |
| `run_finalize_test.rb` | `hive run` of `8-finalize/` — clean/pushed verification, already-merged PR short-circuit (`merged=true`, no `gh pr ready`, no `summary.md`), PR-ready wrap-up, and summary rendering. |
| `run_done_test.rb` | `hive run` of `9-done/` — cleanup instructions, complete marker. |
| `run_stage_action_test.rb` | Workflow verbs — archive idempotency plus internal merged-error archive recovery, including rejection when the current `ERROR reason=` does not match the recovery reason or when the PR still reports `OPEN`. |
| `status_test.rb` | `hive status` — empty registry, multi-stage rendering, stale-lock decoration, and stage-move race behavior through the command surface. |
| `content_workflow_daemon_e2e_test.rb`, `content_workflow_stage_test.rb`, `content_workflow_e2e_test.rb` | Content workflow proof layers — the test-only fixture e2e advances `1-inbox -> 4-done`; the built-in `:content` tests pin per-stage slash-skill prompt rendering plus marker→runner-result mapping and drive real init/new/status/daemon/policy/approve/run to `6-done/article.md` with non-empty carried artifacts. |
| `user_workflow_e2e_test.rb` | Project-authored workflow acceptance — `hive workflow new` scaffolds a descriptor, `hive new --workflow` creates a pinned task, generic run/approve drives it from `1-inbox -> 2-work -> 3-done`, and a same-process coding capture still uses the default coding path. |
| `daemon_stale_agent_healing_test.rb` | Status-to-healer integration — real `hive status --json` rows feed `Hive::Daemon::StaleAgentHealer`, pinning stale `AGENT_WORKING` classification, on-disk healing, closed logger events (`marker_healed`, `heal_requeued`, `marker_heal_failed`), `daemon.agent_marker_grace_sec` threading, and the `3-plan` terminal-loss healer writing a real allowlisted dispatch request. |
| `full_flow_test.rb` | End-to-end: idea → brainstorm → plan → execute → open-pr → review → finalize → done. |
| `cli_version_test.rb`, `cli_usage_error_json_test.rb`, `new_wrapper_argv_test.rb` | `bin/hive` wrapper contract — top-level `--version`, command-local help after option-bearing invocations (`hive approve --from 2-brainstorm --help`), leading `--json=true`, malformed `--json=1` / `--json=yes` assignment rejection before command text/targets, `hive new PROJECT` preserving post-project `--help` and `--json=yes` as literal task text while lifting allow-listed `new` options (`--workflow`, `--depends-on`, and JSON booleans) from before project, between project and text, or after text, and pre-dispatch JSON usage-error envelopes for missing required arguments on representative command schemas (`hive-run`, `hive-approve`, `hive-markers-clear`, `hive-drop`, `hive-findings`, `hive-rebase-status`, `hive-stage-action`, and the patrol-specific `hive-patrol` / `error_kind: "error"` case). |
| `patrol_command_test.rb` | `hive patrol` — JSON envelope, dry-run behavior, scan-state recording, inbox non-interference, retry/backoff outcomes, and schema validation with fake mapper/reviewer/fixer/PR opener collaborators. |
| `wiki_command_test.rb` | `hive wiki` — compile-log writes the generated aggregate, `--check` distinguishes stale vs up-to-date output, invalid subcommands/missing wiki dirs raise usage errors, CLI dispatch reaches the command, and help lists the wiki surface. |
| `tui_smoke_test.rb`, `tui_smoke_charm_test.rb` | PTY-driven `bin/hive tui` smokes — boot, first useful paint with a seeded project, clean `q` exit, horizontal and vertical resize handling, and the startup regression gate (a generous 5s bound that catches a revert to the starved-poll loading grid without flaking; the 10s read_until is the hard gate). |
| `skip_worktree_test.rb` | Verifies hive-state commits on master don't leak into feature worktrees. |

## E2E suite (`test/e2e/`)

The e2e layer is documented in [[e2e]]. It is opt-in:

```bash
bundle exec rake e2e:lib_test
bin/hive-e2e list
bin/hive-e2e run
```

The current scenarios copy `test/e2e/sample-project/` into a per-run sandbox, set `HIVE_HOME` to a run-local directory, and call the real `bin/hive` as a subprocess. `SandboxEnv` routes both Claude and Codex profile binaries to `test/fixtures/fake-claude`; scenarios that exercise `4-execute` with the default Codex profile must ask the fixture to create a real worktree commit, or execute will correctly stop at `EXECUTE_WAITING reason=no_worktree_changes`. TUI scenarios use private tmux sockets (`hive-e2e-<run-id>`) so they never touch the operator's daily tmux server.
`test/e2e/lib/hive_e2e_binary_test.rb` pins the harness binary contract:
scenario inventory JSON, cleanup JSON, the single-document stdout invariant for
successful `list --json` / `clean --json` calls, unknown-command JSON errors,
missing argument errors, top-level version output, command-local help after
command options (`run --filter tui --help`), leading JSON option normalization,
malformed JSON assignment rejection, last-JSON-boolean-wins usage-error mode,
replay path safety, missing, non-executable, and symlinked replay artifact
validation, cleanup retention validation, and the single-dispatch invariant for
successful JSON commands.

The install-smoke workflow's `verify-release.sh (end-to-end behavior)` job
runs `packaging/verify-release.sh --version=v0.1.0` against the published
release after the pinned-release existence gate. The script itself requires
`jq` for envelope assertions; CI first uses runner-provided `jq` when present
and only falls back to apt provisioning when missing. If that fallback's
`apt-get update` is blocked by transient `packages.microsoft.com` repository
errors, the workflow disables those Microsoft source files and retries so an
unrelated third-party apt outage does not hide the verifier's actual behavior.

The browser layer lives in the Rails app: `web/test/integration/*` (device-flow auth via the http DI seam, ownerless first-login claim and later non-owner refusal, plain `/health` versus daemon-backed `/health?deep=1`, ideas with uploads, task Q&A/actions including Advanced Drop, stale-stage 422, red-task Retry recovery queueing, task artifact ordering/markdown rendering/log layout, bounded oversized task diff rendering, media route streaming/refusal plus captured/skipped/failed Demo gallery rendering, repos questionnaire, Repos SSH-origin normalization, non-directory clone-target refusal, Agents-page binary PTY rendering plus operator-ward login polling, favicon/icon serving, Telegram setup guide, and strict blank/@handle chat-ID rejection) and `web/test/system/pipeline_flow_test.rb` (Capybara + Playwright: login gate, composer image attach both paths, Turbo Stream live update, status-grid scroll and composer draft preservation across a live broadcast, Q&A round replacement plus typed-answer survival across morph refreshes, both approve outcomes, log-tail follow/pause/resume, node-preserving log-frame morph reloads, artifact open-state preservation across broadcast-triggered morphs with live content refresh, visible Demo media, and failed-capture banners). CI runs them in the `web` job, installs the root bundle into `vendor/root-bundle`, passes that path as `GOLDEN_E2E_BUNDLE_PATH`, and explicitly runs `web/test/e2e/golden_path_e2e.rb`. The golden-path E2E pins `BUNDLE_GEMFILE`, points `BUNDLE_PATH` at the supplied root bundle, deletes inherited web-bundle deployment/config keys, and preflights the daemon spawn environment with `bundle exec ruby -Ilib bin/hive --version` before starting the foreground daemon, so a broken Bundler/Ruby env fails with the real stderr/stdout instead of a later browser timeout.
After adding the sample idea, the golden-path E2E captures the task slug from a
single current-DOM query while the status grid is still visible, then re-resolves
and clicks the current task link. It does not retain a `.task-row` Capybara
element across daemon-driven Turbo replacements, because a grid broadcast can
detach the row while Playwright is preparing a click. Before submitting the
brainstorm answer, it waits for the daemon to classify the
`needs_input` row and for the current `brainstorm.md` mtime second to pass, so
the answer write is strictly newer than the daemon's edit-resume baseline even
on coarse CI filesystems. The production path also depends on
`hive status --json` preserving subsecond task mtimes; otherwise a newer answer
written in the same second as the baseline can be reported as older or equal.

The packaged hivebox image smoke lives at `packaging/docker/smoke.sh`: it
boots a fresh container on a random host port, polls `/health`, asserts the
ownerless `/login` page is claimable, and verifies unauthenticated `/` is
owner-gated with a 302. The image's runtime Docker `HEALTHCHECK` is deeper
than that smoke and hits `/health?deep=1`, so a stale/missing daemon pidfile
turns the container unhealthy even when Rails is still serving.
`.github/workflows/release.yml` runs that smoke against the amd64 image before
any GHCR push, then is intended to pull the published arm64 image on `macos-15`
under Colima and smoke it again. Current `.github/workflows/ci.yml` does not
build or smoke a local hivebox Docker image on push/PR; it covers the Rails web
tests, the golden-path browser E2E, and the Windows installer-script harness.
Commit `abb62aae` records a current hosted-runner failure before the macOS
Docker smoke starts: `colima start --cpu 2 --memory 4` can die when Lima's VZ VM
exits, so the macOS leg remains a verification gap until a qemu fallback/retry
or passing run artifact exists. The Windows CI surface is
`packaging/docker/test-install-box.ps1`: real PowerShell
syntax, `$LASTEXITCODE` behavior, and failure-output capture with a stubbed
Docker CLI for missing-Docker diagnostics, happy-path pull/run argv including
the default `127.0.0.1:4567:4567` bind, and existing-container refusal. The
harness invokes `install-box.ps1` inside child `pwsh` and redirects all streams
to a temp file that the parent reads after exit, because `exit` inside the
installer tears down piped capture before `Out-String` flushes on failure paths.
Installer failures write their user-facing copy with `Write-Host` rather than
`Write-Error` so the file-backed capture sees the message before the child
process exits.
These tests do not exercise real GitHub, Claude, Codex, or Telegram provider
credentials inside a running box.

The live Telegram bot E2E wrapper lives at `test/e2e/tg/run_idea_e2e.sh` and is also opt-in because it uses a real Bot API test token plus a Telethon user session. In default text mode it drives `/idea <nonce>` through the project picker. With `TG_IDEA_MODE=voice`, the wrapper requires the voice fixture and `HIVE_WHISPER_API_KEY`, starts the bot from the current checkout, drives a new voice idea through transcript confirmation/project selection, seeds a temporary `2-brainstorm/<slug>/brainstorm.md` in the scratch project, then sends `/answer <slug>` and answers Q1 with the same voice note. Cleanup resets the scratch state repo to the captured baseline and removes temporary inbox/brainstorm folders.

`test/e2e/lib/hive_e2e_binary_test.rb` is the focused contract suite for the executable itself. It pins `list --json`, `clean --json`, leading JSON option normalization including `--json=true`, duplicate JSON boolean handling where a final false flag chooses prose, malformed `--json=1` / `--json=yes` rejection, error-envelope shapes, help/version handling, replay path validation, missing/non-executable/symlinked replay artifact errors (`missing_repro` / `unusable_repro`, exit `78`), and the usage exit-code contract: unknown commands and missing required arguments exit `64` in both human and `--json` modes. Human usage errors are expected to print a `hive-e2e:`-prefixed prose message on stderr.

## Live Claude tmux dogfood

The global `claude.mode: tmux` path was manually dogfooded on 2026-05-25 in a disposable git project with a temporary `HIVE_HOME` and private `HIVE_TMUX_SOCKET`. The run used Claude Code 2.1.133 and tmux 3.6a.

Run shape:

- `hive init .` in non-TTY mode rendered `claude.mode: tmux`.
- `hive doctor --json` reported `claude/tmux` present (`tmux 3.6`) and all configured stage/reviewer skills present.
- `hive new project "Dogfood..."`, then `hive brainstorm <slug> --project project --json`, launched real Claude through tmux and returned `marker_after: waiting`.
- After filling `A1`, `hive brainstorm <slug> --from 2-brainstorm --project project --json` returned `marker_after: complete`.
- `events.jsonl` recorded `round_waiting` then `round_complete`; `hive status --json` reported `marker: complete`, `action: ready_to_plan`, and `claude_pid: null`; both private tmux sockets were gone after cleanup.

That smoke predates the 2026-06-12 `claude.model` / `claude.effort`
argv pins, so it proves tmux-mode launch/cleanup but not the new
`--model default` or `--effort <level>` behavior against a live Claude
Code binary.

## Eval suite (`test/eval/`)

The Telegram bot eval harness is opt-in and separate from the default suite:

```bash
bundle exec rake test:eval
bin/hive-eval --scenario s1_status --no-judge --report /tmp/hive-eval.json
```

`test/eval/support/` provides an in-process fake Telegram transport, a programmable status watcher, child-supervisor and dispatch-request captures, a scenario DSL, typed-reason contract assertions, scripted/Codex personas, and a Codex prose judge. Scenario files live under `test/eval/scenarios/` and drive the real `Hive::Bot::Supervisor#process_update` / `#status_tick` entrypoints without changing production bot behavior. Queue-routable bot verbs are captured through the fake `DispatchRequestWriter`, and `Harness#dispatched_commands` lets scenarios assert command intent across both queued and child-spawned dispatch paths.

`bin/hive-eval` is a checkout-local OptionParser wrapper over `rake test:eval`. It accepts only `--scenario NAME`, `--report PATH`, and `--no-judge`; invalid options, missing option values, stray positional arguments, missing scenarios, and unsafe scenario names exit `64` before a report file is created, and the runner removes any existing selected report path before those usage exits so callers cannot read stale JSON from a previous run. Unexpected positional-argument errors label the count as `argument` or `arguments`; `--scenario` resolves a basename under the scenario root after stripping an optional `_test` suffix. Slash and backslash path separators get a distinct usage error, and separator-free names still must match `[A-Za-z0-9_-]+` before being joined under `test/eval/scenarios/` or `HIVE_EVAL_SCENARIO_ROOT`. All-scenario runs clear inherited `TEST` and set `HIVE_EVAL_SCENARIOS_ONLY=1` so ambient test selection cannot execute support or unit files. The wrapper also owns `HIVE_EVAL_NO_JUDGE`: it passes `1` only when `--no-judge` is present and otherwise clears any inherited value so caller environment cannot silently disable judges. Tests may point `HIVE_EVAL_SCENARIO_ROOT` at a temporary scenario directory for throwaway fixtures.

Successful eval runs write a `hive-eval-report` JSON document with per-scenario assertions/messages/log events, and scenario failures make the wrapper exit non-zero. `--no-judge` is the explicit structural-only mode; otherwise Codex judge/persona calls are real subprocess calls. Scenario `s3_noise` is now a passing daemon-enabled noise regression: ready-to-action rows should not become proactive Telegram alerts when the daemon owns dispatch, and the scenario still asserts no duplicate messages plus the proactive allowlist (`agent_blocked_question`, `fatal_error`). Reporter failure-path coverage no longer relies on a production scenario staying red; `test/eval/support/reporter_test.rb` creates a tmpdir-scoped intentional-failure scenario through `HIVE_EVAL_SCENARIO_ROOT`.

## Lint

`bundle exec rubocop` is the lint command. Config in `.rubocop.yml`:

- `TargetRubyVersion: 3.4`
- `Style/StringLiterals: double_quotes`
- `Style/FrozenStringLiteralComment: disabled`
- `Layout/LineLength: max 120`
- `Metrics/MethodLength: max 30`, `Metrics/AbcSize: max 35`, `Metrics/ClassLength: max 200`

Excludes `vendor/**/*`, `tmp/**/*`, `test/fixtures/**/*` (the shell-script fixtures are not Ruby).

Per the user's CLAUDE.md rule: never pass non-Ruby files to rubocop.

## Static Analysis

CI has dedicated `rubocop`, `brakeman`, and `bundler-audit` jobs in
`.github/workflows/ci.yml`. The Brakeman job runs:

```bash
bundle exec brakeman --force --no-pager --quiet --format github --ignore-config config/brakeman.ignore
```

`config/brakeman.ignore` is the root ignore file for scanner false positives.
Each entry carries a rationale for the trust boundary Brakeman cannot see,
such as argv-form subprocess calls, integer coercion before shell use, or
registry-laundered filesystem paths. Commit `83f0a800` added the current
task-log-path ignore: `TasksController#latest_log` receives the project through
`ApplicationController#find_project!`, which resolves only registered project
entries before exposing `hive_state_path`; the route constrains `:slug`, and
the log path still applies `File.basename(params[:slug])` before joining under
that registry-derived log root. See [[commands/web]] for the task log-tail
surface.

The hivebox task media route also carries a Brakeman file-access ignore. The
route constrains `:filename` to a single PNG/JPEG/GIF component, then
`TasksController#resolved_media_path` applies `File.basename`, repeats the
extension check, resolves the real task folder and media directory, refuses a
symlinked `media/` root, and streams only files whose realpath remains below
that media root. `web/test/integration/tasks_test.rb` covers inline streaming,
traversal/extension/missing-file refusal, and symlinked media-root refusal.

Commit `c4e2cab5` adds the current `hive bench submit` Brakeman ignore for
`gh pr create`: `Open3.capture3` is argv-form, and the resolved `9-done` slug
is interpolated only into PR title/body text. The paired source change splits
the extractor's `ruby -I` flag and harness path into separate argv elements.
See [[commands/bench-submit]] for the command surface.

## Hivebox Golden-Path E2E

`web/test/e2e/golden_path_e2e.rb` (deliberately not `*_test.rb` — the
default suites skip it; run `cd web && bin/rails test
test/e2e/golden_path_e2e.rb`, ~35s): a real browser drives the full
mother-test path — claim-by-first-login through the REAL device-flow logic
against a stubbed GitHub HTTP seam, an idea composed in the UI, a REAL
`hive daemon` subprocess advancing brainstorm→plan→execute with the
stage-aware fake claude (`web/test/e2e/support/claude`, keyed on cwd
because a daemon launches every stage with the same binary), the Q&A
answered in the browser, ending at the network-free boundary "Ready to
open PR" with a real commit in a real worktree. Failure artifacts (daemon
event log, daemon stdout, daemon PID liveness, HIVE_HOME log inventory,
task files, agent logs) are printed or copied under `/tmp/golden-e2e-debug`.
The first task-page navigation deliberately re-resolves the grid link through
brief row-lookup misses or Playwright "not attached to the DOM" click errors
because Turbo can replace the row while the daemon advances the task from
`1-inbox` to `2-brainstorm`.
The daemon is preflighted with the exact spawn env via `bin/hive --version`
before `Process.spawn`, so CI boot failures surface synchronously. In CI that
env uses `GOLDEN_E2E_BUNDLE_PATH` to force the daemon onto the root bundle
instead of the Rails app's `web/vendor` bundle. After the idea submit, the
test resolves the task slug from a single current-DOM query and visits the task
page directly, avoiding a saved `.task-row` element that Turbo may detach while
the daemon broadcasts grid replacements. Before submitting the brainstorm
answer, it waits for the daemon's `needs_input` classification and for the
current `brainstorm.md` mtime second to pass, avoiding equality with the
daemon's edit-resume baseline on coarse CI filesystems. `status_test.rb` pins
the matching production contract: JSON task `mtime` and `folder_mtime` keep
subsecond precision for the daemon's mtime-to-mtime comparison. The Telegram
leg lives in `test/e2e/tg` (real Bot API, secret-gated) and now asserts the
/start welcome ahead of the idea flow.

## Backlinks

- [[architecture]]
- [[modules/agent]]
- [[e2e]]
- [[gaps]]
