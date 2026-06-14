---
title: Testing
type: reference
source: test/, Rakefile, .rubocop.yml, .github/workflows/ci.yml, config/brakeman.ignore
created: 2026-04-25
updated: 2026-06-14
tags: [test, minitest, fixtures]
---

**TLDR**: Minitest for unit/integration coverage, plus opt-in outer e2e and eval layers. `test/unit/` covers modules, `test/integration/` covers command/stage behaviour in-process, `test/e2e/` drives the real `bin/hive` subprocess plus tmux for TUI scenarios, `test/eval/` evaluates the Telegram bot signal contract, and CI layers RuboCop, Brakeman, and bundler-audit on top.

## Run all

```bash
bundle exec rake test
```

## Coverage

```bash
bundle exec rake coverage
```

The coverage task uses Ruby's stdlib `Coverage` API. It starts line and branch coverage in the parent test process and prepends `RUBYOPT=-Itest -rhive_coverage_boot` so Ruby subprocess tests dump their own result files under a per-run `coverage/.resultset/<run-id>/` directory. The final merged report is written to `coverage/coverage.json` and prints the lowest-covered source files plus uncovered line numbers.

`bundle exec rake coverage` is the CI coverage-report path. It fails when an executable source file was never loaded, when a subprocess result file cannot be read, or when line coverage drops below the default 100% threshold. Set `HIVE_COVERAGE_MIN_LINE` to a different numeric percentage only when intentionally loosening or tightening that gate.

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
| `config_test.rb` | `Hive::Config` — defaults, deep-merge, register/find, malformed YAML rejection, normal and patrol reviewer validation. |
| `task_test.rb` | `Hive::Task` — path regex, stage validation, derived paths, slug edge cases. |
| `markers_test.rb` | `Hive::Markers` — set/get round-trip, attribute quoting, last-marker semantics. |
| `lock_test.rb` | `Hive::Lock` — acquire/release, stale-PID detection, commit lock parallelism. |
| `worktree_test.rb` | `Hive::Worktree` — create attach-vs-new, remove, exists?, pointer round-trip, prefix validation. |
| `git_ops_test.rb` | `Hive::GitOps` — default-branch detection, orphan worktree bootstrap, idempotent gitignore, empty-diff commit skip. |
| `gh_test.rb` | `Hive::Gh` — PR frontmatter parsing, secret-scan fetch-failure semantics, open/merged PR lookup, `pr_state` success/error parsing, `PushResult`, subprocess timeout/termination, `mergeStateStatus` request shape for open PR listing, and failing-job log clipping. |
| `agent_limit_test.rb` | `Hive::AgentLimit` — provider-limit classifier for Claude usage-credit menus and common quota/rate-limit API errors, with false-positive guards for source line numbers and ordinary "missing rate limit" findings. |
| `agent_test.rb` | `Hive::Agent` — spawn/wait/timeout/SIGINT forwarding, version check, configured Claude model/effort `cli_flags` reaching the headless argv, and provider-limit classification before generic exit-code / expected-output failures. |
| `wiki_log_test.rb` | `Hive::WikiLog` — fragment sorting, generated-block idempotency, stale detection for compiled `wiki/log.md`, and dropping template prose that is not a real legacy `##` entry. |
| `schema_files_test.rb` | Published JSON schema contracts — current-version schema files exist for every `Hive::Schemas::SCHEMA_VERSIONS` entry, back-compat schema files remain for pinned consumers, producer required-key drift is pinned, `hive-dispatch-request` claimed files remain schema-valid, and every schema filename/version matches its `$id` basename or URN suffix plus `title` version text. |
| `cli_test.rb` | `Hive::CLI` — command delegation and option threading for the Thor surface, including `hive generate-name` lookup scoping and internal archive recovery flags. |
| `commands/bench_submit_test.rb` | `Hive::Commands::BenchSubmit` — resolves completed `9-done` tasks from registered projects, derives the source repo from GitHub `origin`, requires `worktree.yml` + `pr.md`, aborts before PR creation on local secret findings, and surfaces missing slugs/checkouts as usage errors. Coverage now includes the default local secret scanner, JSON/text reporting, `run_git`, extractor invocation against a stub `harness/extract.rb`, and PR opening through stub `git`/`gh` binaries; no real hive-bench validator, `git push`, or GitHub PR is exercised. |
| `claude_launcher_test.rb` | `Hive::ClaudeLauncher` — headless/tmux delegation, readiness deadlines, prompt submission, pane logging, tmux-session loss before terminal markers and expected-output waits, provider-limit menu classification, signal cleanup, and wrapper argv policy including model/effort pins. |
| `stages/brainstorm_tmux_sentinel_test.rb` | Claude/tmux sentinel and cleanup behavior — readiness/sentinel delegation, pgrep pattern shape, missing/failing pgrep logging, oversized orphan-sweep log rotation, and the v0.2.3 invariant that a task cleanup kills matched Claude PIDs individually while skipping a matched tmux server. |
| `display_name/generator_test.rb` | `Hive::DisplayName::Generator` — timeout handling, process groups, agent output sanitization, best-effort sidecar updates/commits, and Codex stdin prompt delivery. |
| `tmux_runner_test.rb` | `Hive::TmuxRunner` — detached session startup, environment propagation, prompt injection via tmux buffers, typed tmux failure/timeout classes, bounded pane-tail capture, PID lookup, idempotent teardown, and a lightweight fake-tmux timeout harness so setup commands cannot consume the timeout budget before the intentionally hanging `send-keys` call. |
| `daemon/pr_merge_watcher_test.rb`, `daemon/dispatcher_test.rb` | Finalize merge watcher routing — `MERGED` PR polling returns archive dispatches, carries the internal `--recover-merged-error-reason` flag for whitelisted finalize errors, ignores unknown error reasons, and the dispatcher hands `8-finalize ERROR reason=git_status_failed` rows to the watcher instead of skipping them as generic errors. |
| `daemon/stale_agent_healer_test.rb` | `Hive::Daemon::StaleAgentHealer` — stale `AGENT_WORKING` healing, wedged `REVIEW_WORKING` lock cleanup, and bounded daemon auto-recovery for `review_agent_died`, reviewer partial failures caused only by Claude/tmux expected-output session death, `8-finalize` `ERROR reason=unpushed_commits`, elapsed `limits_reached` cooldown markers, and non-review terminal agent-loss errors (`2-brainstorm`, `3-plan`, `4-execute`, `7-artifacts`, `8-finalize` `ERROR reason=tmux_session_terminated` or `reason=agent_orphaned`). Terminal-error coverage pins marker-id guarded clears, live-lock skips, manual repository-state skips, shared budgets across fresh marker ids, per-task budget isolation, pre-clear dispatch-baseline seeding, the `3-plan` `hive plan ... --from 3-plan` dispatch-request requeue / `heal_requeued` trace for both agent-loss and `limits_reached` clears, the distinct `heal_requeue_failed` event when enqueueing fails after a successful clear, and one-shot `marker_heal_exhausted` logging. |
| `hv_test.rb` | `bin/hv` — refuses unsafe Apache Hive fallback paths (`/usr/bin/hive`, `/opt/hive/bin/hive`) and verifies `HIVE_BIN_OVERRIDE` can point at a custom Hive CLI install path. |
| `gemspec_test.rb`, `install_script_test.rb` | RubyGem/install packaging — `hv` stays out of `spec.executables` so RubyGems does not create a broken Ruby binstub for the bash launcher; the bash installer writes its own `hv` wrapper and does not expect a gem-installed `hv` shim. |
| `babysitter/dry_run_env_test.rb` | `Hive::Babysitter::DryRunEnv` plus `bin/hive-babysitter-stub-git` / `bin/hive-babysitter-stub-gh` — PATH overlay, recording fake binaries, default-deny skips, read-only passthrough, `gh api` implicit-POST payload flag blocking, git executable/write-option skips, env config/command seam skips, hermetic HOME/XDG/local git config passthrough guards, `--textconv` abbreviation and `cat-file --filters` skips, subcommand `-p` passthrough, `grep`/`ls-files` read-option exceptions, grep pager `--open-files-in-pager` abbreviations and `-O` forms including clustered `-nO<cmd>`, value-taking grep short options such as `-eTODO` / `-fNEEDLEFILE.txt`, and pathspec separator handling. |
| `bot/router_test.rb`, `bot/slash_handlers_test.rb`, `bot/supervisor_test.rb` | Telegram bot slash/menu surface — router classification for supported slash commands including first-contact `/start`, `SlashHandlers#start` welcome copy with concrete next steps, and the `setMyCommands` quick-actions list (`/idea`, `/status`, `/queue`, `/answer`, `/approve`, `/autofix`, `/details`, `/done`, `/help`). |
| `openclaw_skills_test.rb` | OpenClaw skill metadata — only the umbrella `hive-cli` listing is published, setup stays visible before the CLI is installed, `/hive` common paths include `wiki compile-log --check`, fragment-first changelog guidance is present, destructive/foreground admin commands require confirmation, and README publish instructions avoid shortcut listings. |
| `commands/babysit_test.rb` | `Hive::Commands::Babysit` — lifecycle command routing, PID-file ownership handling, stale-runtime status/reload warnings, foreground restart, detached restart re-exec into canonical `start --detach` through the stable invoked wrapper, aborting restart and failing direct stop after a refused stop, clear detached re-exec failure reporting, initial/post-grace ownership-probe clean-exit handling, pre-KILL ownership refusal, bounded PID-lock timeout, guarded stop cleanup that preserves a replacement PID file, and skip-KILL PID-file preservation when ownership becomes unverified. |
| `test/unit/web/web_command_test.rb` | `hive web` Rails-app-dir resolution (HIVEBOX_WEB_APP_DIR override, missing-app exit 1), `db:prepare` typed failure guidance, final Rails `Kernel.exec` env/argv, and the public-bind warning. |
| `test/unit/web/dispatcher_test.rb` | `Hive::Web::Dispatcher` — stage-run verb mapping, unknown-action refusal before daemon queue writes, Recover queuing a guarded marker-clear plus stage rerun as one request sequence while refusing manual-only or markerless states, discarding the sequence sidecar if the initial request write fails, Reject's prior-gate derivation, brainstorm answer/intervene writes through `BrainstormAnswerWriter`, and Advanced Drop calling `Commands::Drop` in-process while refusing stale `from` stages with `Hive::WrongStage`. |
| `test/unit/web/status_feed_test.rb`, `web/test/models/status_broadcaster_test.rb` | Hivebox status broadcasting — registered-project snapshots, one shared scan per poll tick, emit-on-connect for independent subscribers, volatile-field dedup that keeps `mtime`/`folder_mtime` significant, poller survival after snapshot errors, and `StatusBroadcaster` resubscription after a raising Turbo broadcast. |
| `web/agents_auth_test.rb`, `web/agents_auth_login_test.rb`, `web/agents_routes_test.rb` | `Hive::Web::AgentsAuth` — Claude/Codex PTY login URL capture, pasted-code relay, `gh auth login --web` URL capture plus auto-Enter prompt handling, rejected-code errors, watchdog/process-group cleanup, concurrent-session cap, Pi token JSON rejection/persistence, and route wiring. |
| `web/config_test.rb`, `web/supervisor_test.rb`, `web/app_coverage_test.rb` | Hivebox config/supervisor packaging support — global web defaults/validation, child restart/backoff/reload/shutdown decisions, and route coverage attribution guardrails. |
| `patrol/pr_opener_test.rb` | `Hive::Patrol::PrOpener` — PR creation, fingerprint mapping, optional `ReviewHandoff` creation of synthetic `6-review` tasks, worktree pointer contents, and `patrol.review_prs: false` cleanup behavior. |
| `stages/review/run_reviewers_test.rb` | `Hive::Stages::Review.run_reviewers` — reviewer list selection for normal vs patrol-sourced tasks, per-reviewer failures, wall-clock deadlines, shared Claude tmux sessions, and GitHub comment mirroring. |
| `commands/status_test.rb`, `archive_filter_test.rb`, `tui/schema_correspondence_test.rb`, `tui/snapshot_test.rb`, `tui/views/archive_pane_test.rb` | Status/TUI archive boundary — required `hive-status` task keys match `Status#task_payload`, `Snapshot::Row` has a field for every emitted task key, `folder_mtime` is preserved, old archives hide only from daily text/grid views by age regardless of marker state, no-target `hive archive` filters to `9-done`, and explicit archive views remain age-unfiltered. |
| `tui/app_test.rb`, `tui/state_source_test.rb` | `Hive::Tui::App` / `StateSource` — charm-only backend selection, synchronous startup snapshot seeding, snapshot-poller dedup/error dispatch, HUP termination hook, WINCH terminal-size seeding/dispatch, unavailable tty-size handling, signal-handler restore failure tolerance, mtime-gated refresh reuse, and liveness-fallback reparsing. |

## Integration suite (`test/integration/`)

| File | Covers |
|------|--------|
| `init_test.rb` | `hive init` — preconditions, force flag, idempotent re-init, `hive-init.v1` JSON payload, Claude model/effort answer/template defaults, normal reviewer rendering, patrol reviewer rendering, and prompt defaults. |
| `new_test.rb` | `hive new` — slug derivation, reserved rejection, captured commit. |
| `run_brainstorm_test.rb` | `hive run` of `2-brainstorm/`. |
| `run_plan_test.rb` | `hive run` of `3-plan/`. |
| `run_execute_test.rb` | `hive run` of `4-execute/` — init pass, iteration pass, stale handling, worktree-missing recovery. |
| `run_open_pr_test.rb` | `hive run` of `5-open-pr/` — push, draft PR creation, idempotent existing-PR path. |
| `run_finalize_test.rb` | `hive run` of `8-finalize/` — clean/pushed verification, PR-ready wrap-up, summary rendering. |
| `run_done_test.rb` | `hive run` of `9-done/` — cleanup instructions, complete marker. |
| `run_stage_action_test.rb` | Workflow verbs — archive idempotency plus internal merged-error archive recovery, including rejection when the current `ERROR reason=` does not match the recovery reason or when the PR still reports `OPEN`. |
| `status_test.rb` | `hive status` — empty registry, multi-stage rendering, stale-lock decoration. |
| `daemon_stale_agent_healing_test.rb` | Status-to-healer integration — real `hive status --json` rows feed `Hive::Daemon::StaleAgentHealer`, pinning stale `AGENT_WORKING` classification, on-disk healing, closed logger events (`marker_healed`, `heal_requeued`, `marker_heal_failed`), `daemon.agent_marker_grace_sec` threading, and the `3-plan` terminal-loss healer writing a real allowlisted dispatch request. |
| `full_flow_test.rb` | End-to-end: idea → brainstorm → plan → execute → open-pr → review → finalize → done. |
| `cli_version_test.rb` | `bin/hive` wrapper contract — top-level `--version`, command-local help after option-bearing invocations (`hive approve --from 2-brainstorm --help`), leading `--json=true`, and malformed `--json=1` / `--json=yes` assignment rejection. |
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
malformed JSON assignment rejection, replay path safety, cleanup retention
validation, and the single-dispatch invariant for successful JSON commands.

The browser layer lives in the Rails app: `web/test/integration/*` (device-flow auth via the http DI seam, ownerless first-login claim and later non-owner refusal, plain `/health` versus daemon-backed `/health?deep=1`, ideas with uploads, task Q&A/actions including Advanced Drop, stale-stage 422, red-task Retry recovery queueing, task artifact ordering/markdown rendering/log layout, bounded oversized task diff rendering, repos questionnaire, Repos SSH-origin normalization, non-directory clone-target refusal, Telegram setup guide, and strict blank/@handle chat-ID rejection) and `web/test/system/pipeline_flow_test.rb` (Capybara + Playwright: login gate, composer image attach both paths, Turbo Stream live update, status-grid scroll and composer draft preservation across a live broadcast, Q&A round replacement plus typed-answer survival across morph refreshes, both approve outcomes, log-tail follow/pause/resume, node-preserving log-frame morph reloads, and artifact open-state preservation across broadcast-triggered morphs with live content refresh). CI runs them in the `web` job, installs the root bundle into `vendor/root-bundle`, passes that path as `GOLDEN_E2E_BUNDLE_PATH`, and explicitly runs `web/test/e2e/golden_path_e2e.rb`. The golden-path E2E pins `BUNDLE_GEMFILE`, points `BUNDLE_PATH` at the supplied root bundle, deletes inherited web-bundle deployment/config keys, and preflights the daemon spawn environment with `bundle exec ruby -Ilib bin/hive --version` before starting the foreground daemon, so a broken Bundler/Ruby env fails with the real stderr/stdout instead of a later browser timeout.

The packaged hivebox image smoke lives at `packaging/docker/smoke.sh`: it
boots a fresh container on a random host port, polls `/health`, asserts the
ownerless `/login` page is claimable, and verifies unauthenticated `/` is
owner-gated with a 302. The image's runtime Docker `HEALTHCHECK` is deeper
than that smoke and hits `/health?deep=1`, so a stale/missing daemon pidfile
turns the container unhealthy even when Rails is still serving. `.github/workflows/ci.yml` builds a local image and
runs that smoke on Linux for every push/PR; `.github/workflows/release.yml`
runs the same smoke against the amd64 image before any GHCR push, then pulls
the published arm64 image on `macos-15` under Colima and smokes it again. The
Windows CI surface is `packaging/docker/test-install-box.ps1`: real PowerShell
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

`test/e2e/lib/hive_e2e_binary_test.rb` is the focused contract suite for the executable itself. It pins `list --json`, `clean --json`, leading JSON option normalization including `--json=true`, malformed `--json=1` / `--json=yes` rejection, error-envelope shapes, help/version handling, replay path validation, and the usage exit-code contract: unknown commands and missing required arguments exit `64` in both human and `--json` modes. Human usage errors are expected to print a `hive-e2e:`-prefixed prose message on stderr.

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

`test/eval/support/` provides an in-process fake Telegram transport, a programmable status watcher, a CLI child-supervisor capture, a scenario DSL, typed-reason contract assertions, scripted/Codex personas, and a Codex prose judge. Scenario files live under `test/eval/scenarios/` and drive the real `Hive::Bot::Supervisor#process_update` / `#status_tick` entrypoints without changing production bot behavior.

`bin/hive-eval` runs only scenario files, writes a `hive-eval-report` JSON document with per-scenario assertions/messages/log events, and exits non-zero on scenario failure. `--no-judge` is the explicit structural-only mode; otherwise Codex judge/persona calls are real subprocess calls. Scenario `s3_noise` is intentionally baseline-failing today: it demonstrates that proactive ready/finished notifications violate the v1 signal contract where only `agent_blocked_question` and `fatal_error` may be proactive.

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
The first task-page navigation deliberately re-resolves the grid link on
stale-element errors because Turbo can replace the row while the daemon
advances the task from `1-inbox` to `2-brainstorm`.
The daemon is preflighted with the exact spawn env via `bin/hive --version`
before `Process.spawn`, so CI boot failures surface synchronously. In CI that
env uses `GOLDEN_E2E_BUNDLE_PATH` to force the daemon onto the root bundle
instead of the Rails app's `web/vendor` bundle. The Telegram leg lives in
`test/e2e/tg` (real Bot API, secret-gated) and now asserts the /start welcome
ahead of the idea flow.

## Backlinks

- [[architecture]]
- [[modules/agent]]
- [[e2e]]
- [[gaps]]
