---
title: Gaps
type: gaps
source: wiki/* vs lib/, templates/, test/, bin/
created: 2026-04-25
updated: 2026-07-18
tags: [gap, todo]
---

**TLDR**: The wiki has broad domain coverage for the current `lib/`, command, stage, TUI, daemon, bot, hivebox web, testing/static-analysis, template/prompt, and release surfaces, but the source-file map below is representative rather than an automatically verified one-file-per-source audit. Remaining gaps are mainly live behavioral verification and a few deeper reference pages.

## Current release gap

- Cross-project dependency admission is covered with local-path remotes and
  anonymized multi-project integration fixtures, including stored/live remote
  mismatch. It has not yet been dogfooded end-to-end against two separately
  hosted repositories through daemon dispatch and merge/archive. The current
  implementation intentionally performs no network identity lookup; it trusts
  only normalized enrolled/live `origin` strings and fails closed on missing
  or ambiguous evidence.
- Durable task attempts are race/unit/integration-pinned and the local Linux
  1849 subprocess replay proves caller-loss survival without a daemon. There
  is not yet a checked-in macOS/BSD detachment run or a paid-provider,
  multi-hour daemon-restart artifact; unsupported platforms reject before
  acceptance rather than weakening ownership guarantees.
- Durable attempt capabilities prevent ordinary worker-environment inheritance,
  a dedicated attempt-context store override, public context construction,
  cross-task argv reuse, and PID/session/group substitution. The process-level
  `HIVE_HOME`, `XDG_STATE_HOME`, and `HOME` inputs still select Hive's global
  state root and are part of the trusted launch configuration. These guards do
  not provide privilege separation from hostile same-UID Ruby code with
  arbitrary environment, store, or process-internal access. Closing that
  stronger boundary requires a broker under a separate OS identity (or
  equivalent protected signing/storage authority), not another in-process
  Ruby guard.

- Hive now resolves and verifies the current `honeycomb-catalog/v2` and
  `packages/NAME/VERSION/manifest.yml` contract, but the manifest's coarse
  permission disclosure is not generally convertible to Hive's exact managed
  runtime policy. Only low-risk task-local read-only is admitted losslessly.
  The current Bench and Docs Sync seeds therefore resolve/verify but fail
  admission before any install/update write. Close this by adding exact v2
  runtime-policy data or an equally precise Hive enforcement path, then run a
  live install/run smoke. Do not advertise either seed install as working yet.
- `hive workflow publish` still creates the legacy
  `workflows/NAME/manifest.json` submission layout. It does not author the
  current immutable version directory/canonical YAML contract and needs a
  separate v2 publication migration before its pending-review output can feed
  the deployed registry.
- The built-in `bench` descriptor, packaged stage instructions, self-contained
  runtime snapshot, and `hive init . --workflow bench` path are covered locally,
  but they have not yet shipped in a Hive release or completed a live
  paid-provider campaign from a fresh standalone benchmark project. Honeycomb
  is not a dependency of this named-workflow path.
- The packaged mixed Sol/Terra/Grok profiles, stage-specific Codex shim, sole
  Sol `ce-code-review` policy, and combined Sol-runner selection are locally
  test-pinned but still need their first paid end-to-end cell.

## Source-file coverage (representative map)

| Area / file set | Page |
|-----------------|------|
| `bin/hive`, `lib/hive/cli.rb`, command registration | ✓ [[cli]], [[commands]] cover command registration plus the wrapper-level `--version`, command-local help rewrite, leading JSON boolean grammar contracts, first-`--` option-scan termination, snapshot-based last-recognized-JSON-boolean error-mode semantics, and the `hive new PROJECT` lift-and-rebuild contract that lifts recognized `--workflow`/`--depends-on` (and their `=VALUE`/JSON-boolean forms) from anywhere outside an explicit `--`, rebuilds the `PROJECT TEXT...` tail behind a protective `--`, and leaves a trailing/value-less value option as literal task text. |
| `bin/hive`, `lib/hive/cli.rb`, command registration | ✓ [[cli]], [[commands]] cover command registration plus the wrapper-level `--version`, command-local help rewrite, leading JSON boolean grammar, and pre-dispatch JSON usage-error contracts for required-argument command surfaces. |
| `lib/hive/commands/*.rb` | ✓ `wiki/commands/*` pages cover the active command surface, including setup, daemon, bot, web, init, new, generate-name, status/archive listing, run, stage-action, markers, migrate, findings, metrics, update, uninstall, wiki, bench-submit, and rebase-status. |
| `bin/hive`, `lib/hive/cli.rb`, command registration | ✓ [[cli]], [[commands]] cover command registration plus the wrapper-level `--version`, command-local help rewrite, and leading JSON boolean grammar contracts. |
| `lib/hive/commands/*.rb` | ✓ `wiki/commands/*` pages cover the active command surface, including daemon, bot, web, init, new, generate-name, status/archive listing, run, stage-action, markers, migrate, findings, metrics, update, uninstall, wiki, bench-submit, digest, and rebase-status. |
| `lib/hive/commands/{connect,disconnect}.rb`, `lib/hive/screenote/**` | ✓ [[commands/screenote]], [[modules/config]], and [[stages/artifacts]] cover Screenote OAuth setup, credential storage, MCP injection, and fail-soft artifact behavior. |
| `lib/hive/stages/*.rb`, `lib/hive/stages/review/**` | ✓ [[stages/index]] plus per-stage pages; review submodules are covered by [[stages/review]]. |
| `lib/hive/patrol/*`, `lib/hive/commands/patrol.rb` | ✓ [[modules/patrol]] and [[commands/patrol]] cover the repository-patrol engine, PR opener, fingerprint/dismissal state, and patrol-to-`6-review` handoff. |
| `lib/hive/refactor_patrol/*`, `lib/hive/commands/refactor_patrol.rb`, daemon architecture-patrol scheduling | ✓ [[commands/refactor-patrol]], [[modules/daemon]], [[modules/config]], [[modules/gh]], [[state-model]], and [[testing]] cover language-neutral merge discovery, durable jobs/actions, scheduling, fencing, publication, and recovery. |
| `lib/hive/daemon/*` | ✓ [[modules/daemon]] and [[commands/daemon]] cover dispatcher, healer, display-name backfiller, queues, merge watcher, status consumer, logging, and service/queue command surfaces. |
| `lib/hive/babysitter/**`, `lib/hive/commands/babysit.rb`, `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh` | ✓ [[modules/babysitter]] and [[commands/babysit]] cover the experimental PR babysitter process, lifecycle command, GitHub PR repair loop, dry-run wrapper-launcher handoff, and executable `git`/`gh` default-deny stub API boundaries. |
| `lib/hive/bot/*` | ✓ [[modules/bot]] and [[commands/bot]] |
| `lib/hive/web/**`, `public/`, `hive.gemspec`, `lib/hive/commands/web.rb`, `lib/hive/commands/setup.rb`, `packaging/docker/`, `.github/workflows/release.yml` hivebox image job | ✓ [[commands/web]], [[commands/setup]], [[commands]], [[architecture]], [[modules/config]], [[dependencies]], and [[testing]] cover the web routes, managed bundle/install payload, config/API surface, Docker entrypoints/install scripts, GHCR image publish job, agent-login relay/polling boundaries, favicon assets, and manual e2e contract. |
| `lib/hive/tui/**` | ✓ [[commands/tui]], [[architecture]], and [[token-usage]] cover the MVU/TUI surfaces. |
| `lib/hive/agent.rb`, `lib/hive/agent_limit.rb`, `lib/hive/claude_launcher.rb`, `lib/hive/scripts/interactive_claude_wrapper.sh`, `lib/hive/agent_profile*.rb`, `lib/hive/agent_profiles/**` | ✓ [[modules/agent]], [[modules/agent_profile]], [[stages/index]], [[stages/brainstorm]], [[token-usage]] |
| `lib/hive/config.rb`, `templates/project_config.yml.erb` | ✓ [[modules/config]], [[commands/init]], [[state-model]] cover config defaults/validation plus init-rendered `claude.model` / `claude.effort` pins. |
| `Gemfile`, `hive.gemspec`, `Gemfile.lock` | ✓ [[dependencies]] covers runtime gem constraints, development/test gems, Ruby/Bundler lockfile metadata, the local path gem version, and external CLI dependencies. |
| `.github/workflows/ci.yml`, `config/brakeman.ignore`, `web/config/ci.rb` | ✓ [[testing]] and [[dependencies]] cover the RuboCop, Brakeman, and bundler-audit CI/tooling surface; [[commands/web]] covers the task log-tail and media routes behind the current Brakeman false-positive ignores. |
| `lib/hive/task_action.rb`, `lib/hive/diagnostic_evidence.rb`, status/recovery helpers | ✓ [[modules/task_action]], [[commands/status]], [[modules/execute_waiting_action]], [[modules/diagnosis_agent]] cover red-row diagnostics, read-only `--diagnose` evidence fallback, recovery hints, and the diagnosis-agent write path. |
| `lib/hive/gh.rb` | ✓ [[modules/gh]] covers the shared GitHub CLI helper surface; [[dependencies]], stage pages, [[commands/stage_action]], and [[modules/babysitter]] cover its command-level consumers. |
| `lib/hive/pr.rb` | ✓ [[modules/pr]] covers the local PR URL → `#number` formatter used by the TUI PR column. |
| `lib/hive/digest.rb`, `lib/hive/digest/**`, `lib/hive/commands/digest.rb`, `templates/digest_prompt.md.erb` | ✓ [[commands/digest]], [[modules/digest]], [[modules/config]], [[templates]], and [[testing]] cover the shipped-digest command, direct API, agent categorizer prompt, Telegram delivery seam, and focused unit tests. |
| Core task/state helpers: `task`, `markers`, `lock`, `worktree`, `git_ops`, `rebase`, `workflows`, `metrics`, `secret_patterns`, `protected_files`, `events` | ✓ `wiki/modules/*` pages exist for each named domain. |
| `templates/*.erb` and prompt files | ✓ [[templates]] plus stage pages |
| `openclaw/skills/hive/SKILL.md`, `openclaw/README.md` | ✓ [[commands]], [[operating]], and [[commands/wiki]] cover the single ClawHub `hive-cli` skill, `/hive` slash-command dispatch, guided setup, wiki changelog verification, and publish-shape constraints. |
| `test/unit`, `test/integration`, `test/e2e`, `test/eval`, `Rakefile`, `bin/hive-e2e`, `bin/hive-eval` | ✓ [[testing]] and [[e2e]], including manual-gated hivebox Playwright coverage and eval-runner selector coverage. |
| `test/unit`, `test/integration`, `test/e2e`, `test/eval`, `Rakefile`, `bin/hive-e2e`, `bin/hive-eval` | ✓ [[testing]] and [[e2e]], including manual-gated hivebox Playwright coverage and the checkout-only Telegram bot eval runner. |
| `test/unit`, `test/integration`, `test/e2e`, `test/eval`, `Rakefile`, `bin/hive-e2e`, `bin/hive-eval` | ✓ [[testing]] and [[e2e]], including manual-gated hivebox Playwright coverage, eval-runner selector coverage, `bin/hive-eval`'s checkout-local usage boundary, the explicit `HIVE_EVAL_NO_JUDGE` env-clearing contract, and `bin/hive-e2e` replay / leading-JSON-help contracts. |

Uncertainty: this table was refreshed manually from targeted source, dependency-manifest, executable-entrypoint, and wiki reads on 2026-06-16, with the eval-runner row targeted again on 2026-06-17. It verifies domain coverage, not exact one-to-one file coverage or installed release-bundle behavior. The 2026-06-15 wrapper refresh source-inspected `bin/hive` and `test/integration/cli_version_test.rb`, and the 2026-06-16 e2e refresh source-inspected `bin/hive-e2e` plus `test/e2e/lib/hive_e2e_binary_test.rb`; neither found an in-tree artifact proving packaged RubyGems/Homebrew/AUR `hive` wrapper behavior or live patrol/babysitter consumption of `bin/hive-e2e` replay error envelopes. The 2026-06-16 clipboard refresh source-inspected `lib/hive/tui/clipboard.rb` and `test/unit/tui/clipboard_test.rb`; it found the fixture stabilization documented in [[testing]], but no checked-in artifact proving the hosted Ruby 3.4.9 coverage job passed after commit `5389920e` or that the real Wayland/X11/macOS clipboard probes were live-smoked after the test-only fixture change. A future refresh could add a small script that compares `rg --files lib/hive` to `wiki/**/source:` patterns and reports unmapped files.

Latest refresh note (2026-06-16): the babysitter gh-hostname dry-run audit remains source- and unit-pinned only. This refresh found no in-tree artifact for a full live-agent `hive babysit --once PROJECT --dry-run` run after commits `a86ca033` and `ede81ac7`.

## Open questions about the codebase

### 2026-06-22 dependency-stacking placeholder branch investigation

Branch-creator inventory for the U1-U10 inversion dogfood found no separate
in-`lib/` creator for normal task slug branches. The only normal slug branch
creator is `Hive::Worktree#create!`'s `git worktree add -b <slug> <base>` path;
`Hive::Babysitter::Worktree` creates only `hive-babysitter/pr-*` branches from
PR refs, and `Hive::GitOps` branch operations in this area delete/drop branches
rather than pre-create task slugs.

The leading root cause is therefore a stale placeholder left by an earlier
collapsed execute attempt: the first run resolved a dependency override to the
default branch, created `<slug>` from that default, then halted with
`EXECUTE_WAITING reason=no_worktree_changes` or otherwise removed the worktree
while leaving `refs/heads/<slug>` behind. Later runs hit the existing-branch
attach path and kept the placeholder on the default branch. The current fix is
the `Hive::Worktree` hardening documented in [[modules/worktree]] and
[[modules/task_dependencies]]: empty placeholders with a stacked override are
re-pointed, local prerequisite branches are preferred over default fallback,
and branches with real commits remain preserved. Remaining uncertainty: no
checked-in live dogfood artifact yet proves the U1-U10 stacked sequence after
this fix.

1. **Has `hive run` been smoke-tested against a live `claude` v2.1.118?** The plan calls for this before declaring the MVP done. No evidence in tree (no `docs/solutions/` notes, no `docs/smoke-results.md`).
2. **Has `hive init` been run against a real project yet?** Planned pilot, but the working tree shows no first commit on `~/Dev/hive` itself, so the pilot may not have started.
3. **Is `hive/state` reachable after `git gc`?** The plan recommends `git config --add gc.reflogExpire never refs/heads/hive/state`. This is documented in [[decisions]] ADR-003 but not enforced in `Init#call`.
4. **Does the pilot project's pre-commit hook chain (lefthook/overcommit/husky) misbehave on `.hive-state/` commits?** The plan flags this as a known caveat to verify on first init; outcome unrecorded.
5. ~~**macOS PID-reuse fallback**~~ — closed 2026-04-25. `Lock#process_start_time` now tries `/proc/<pid>/stat` first, falls back to `ps -o lstart= -p <pid>` on macOS / BSD / containers without `/proc`. Returns nil only when neither source works.
6. **E2E surface matrix** — `bin/hive-e2e run` is green locally on Linux with tmux 3.6a, but the follow-up matrix across macOS and a different tmux minor version is still open.
7. ~~**Asciinema local verification**~~ — closed 2026-04-30. `/usr/bin/asciinema` 3.2.0 is visible on this shell's PATH, and a smoke run created an asciicast v2 file. `HIVE_ASCIINEMA_BIN=/absolute/path/to/asciinema` remains the fallback for installs outside PATH.
8. **R2 misdiagnosis artifact validation** — e2e artifacts exist, but the "fresh agent course-corrects from a wrong first diagnosis" case needs the first organic failure or a third-party synthetic failure.
9. **Codex and Pi token usage payloads need real-stream refinement.** [[token-usage]] ships zero-fill extractors for missing or unrecognized usage payloads so hive-driven spawns still record rows, but the exact non-zero JSON shapes should be updated after one captured Codex and one captured Pi spawn.
10. **`live_task_lock` daemon behavior is unit-pinned but not live-smoked.** PR #151 adds StatusConsumer parsing, stale-healer skips, and dispatcher capacity accounting for rows whose only liveness signal is a verified task `.lock`. Unit tests cover the contracts; no live daemon restart/rebase smoke artifact was found in-tree.
11. **Claude launch flags should be live-checked against current Claude Code.** Config, init prompts/schema, tmux wrapper docs, and headless/tmux argv tests now cover `claude.permission_mode` plus the new `claude.model` / `claude.effort` pins. There is still no recorded live run proving every accepted permission mode, `--model default`, and explicit `--effort low|medium|high` still match the installed Claude CLI's current behavior.
12. **Local git index health affected the 2026-06-01 wiki refresh.** `git status --short` failed with `fatal: unable to read 7afa1ea39e410defd0219acecd295e3108f5f93a`; `git ls-files -s` mapped that blob to `plugins/zoom/CONTRIBUTING.md`. The index also staged deletions for several wiki pages while the files still existed in the working tree. This refresh verified the committed docs change via `git show HEAD` and direct source reads, but a normal clean-tree check remains unresolved in this checkout.
13. **PR #244 final verification remains before merge.** The 2026-06-03 repair adds focused coverage for queue claim sidecars, recovery-sequence continuations, and the unbounded timeout default, but the branch still needs its final focused test/rubocop pass, `/ce-code-review`, and hosted CI before merge.
14. **`Markers.current` can mis-read example markers embedded in a tmux-pane-capture `task.md`.** `MARKER_RE` in `lib/hive/markers.rb` scans the *entire* state file and `current` returns the *last* match (and `set` -> `replace_last_marker` rewrites the last match). In tmux-mode stages, `task.md` is a pane capture that includes the stage prompt, whose instructions contain literal example markers (e.g. ``the hive runner sets `<!-- REVIEW_COMPLETE pass=1 browser=skipped -->` after...``). Normally the real terminal marker is appended after the capture, so `current` returns it. But the documented manual re-review recovery (`markers.rb:21` - "hand-edit `task.md` and delete the marker comment") removes that trailing marker, after which `current` falls back to an embedded *example* marker and mis-classifies the task - e.g. a reset 6-review task reads as `review_complete`, so the daemon dispatches `hive artifacts` (advance) instead of re-reviewing, and `hive run` short-circuits "already complete". Observed 2026-05-26 forcing a re-review on writero tasks; worked around by appending an authoritative `<!-- EXECUTE_COMPLETE -->` at EOF. Fix options: anchor markers to a sentinel region / dedicated trailing block, strip prompt bodies from the state file, or have `current`/`set` only honor markers outside fenced/quoted prompt content. See [[modules/markers]].
15. **Babysitter dry-run default-deny stubs are unit-pinned but not live-agent-smoked.** As of the 2026-06-24 relative real-binary hardening, `Hive::Babysitter::DryRunEnv` generates `git` / `gh` wrapper launchers that overwrite `HIVE_BABYSITTER_REAL_GIT` / `HIVE_BABYSITTER_REAL_GH` with parent-resolved absolute realpaths and `HIVE_BABYSITTER_DRY_RUN_LOG` with the worktree-root skip log before invoking the shared stubs, so command-local overrides cannot redirect allowlisted passthrough or skipped-command audit records. The shared stubs also exit 127 on unset or non-absolute real-binary handoffs, so relative values such as `bin/git` and `bin/gh` cannot be re-resolved inside the PR worktree. The `gh` stub deletes command-local `HOME`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`, `HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR`, `GH_HOST`, `GH_REPO`, and enterprise-token env before passthrough, then points both `HOME` and `GH_CONFIG_DIR` at a fresh empty temp dir so `gh` cannot read caller/user config while still having a writable state location. The stubs allow only known read-only `git` / `gh` commands, skip implicit-write `gh api` payload calls unless the method is explicitly GET, still skip explicit-GET local file/input/cache writes, pass plain/non-token `gh auth status` while skipping token-revealing `--show-token`, bare `-t`, clustered shorthand forms such as `-at`, `-ta`, and `-ath`, and hostname forms such as `-h`; block browser-launch flags; block gh host-redirection selectors (`--hostname`, host-qualified `-R` / `--repo`, host-qualified repo/PR operands, and full URL `api` operands); reject read-looking `git` invocations with executable or file-writing options; skip `git log` / `git show` `--show-signature` plus `log` / `show` / `rev-list` `%G` formats; skip `git log` / `git show` remerge-diff options and pin `log.diffMerges=separate` so `-m` / `--diff-merges=on` cannot inherit a repo-local remerge default; reject every leading global config override; fail-closed on known exec-capable git environment seams (`GIT_EXEC_PATH`, `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_ASKPASS`, `SSH_ASKPASS`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_GLOBAL`, and `GIT_CONFIG_SYSTEM`); run git read passthrough hermetically with user config neutralized (HOME/XDG_CONFIG_HOME redirected, `GIT_CONFIG_*=/dev/null`, `GIT_OPTIONAL_LOCKS=0`) plus `core.fsmonitor=false`, `core.askPass=`, `log.showSignature=false`, `--no-ext-diff --no-textconv`, and local external diff/textconv/fsmonitor/helper-path/signature verification disabled; and write skipped-command audit logs only after a regular-file/current-uid preflight plus a no-follow, nonblocking open with control-character escaping. `test/unit/babysitter/dry_run_env_test.rb` verifies those guards with recording fake binaries, including PATH overlay wrapper handoff, relative PATH real-binary canonicalization, non-absolute real-binary refusal, real-binary and skip-log override resistance, gh tempdir config isolation against command-local home/config env, gh host selector skips and host/config env scrubbing, fresh empty gh HOME/config roots, `GIT_EXEC_PATH` skips, `remote show` without `-n`, exact read-only `git branch` forms versus mixed branch mutations, `gh api` file/cache variants, symlinked skip-log refusal, FIFO skip-log refusal without blocking, escaped ASCII control characters, env seam skips including malformed `GIT_CONFIG_COUNT`, `GIT_ASKPASS` / `SSH_ASKPASS`, HOME/XDG config isolation, invalid-real-git diagnostics, subcommand `-p` passthrough, grep/ls-files read-option exceptions, textconv/filter/signature/remerge blocking, and pathspec separator handling. The 2026-06-19 post-fix audit found no artifact showing a full `hive babysit --once PROJECT --dry-run` live-agent run after these dry-run stub changes.
Residual audits of commits `6a6cf990`, `2d15e9ee`, and `5e8723fa` carried this babysitter dry-run uncertainty forward after checking the residual diffs, source commit `f12c46c7`, and current source/tests; no additional in-tree live-agent smoke artifact was found.

16. **Bot suppress-while-answering behavior is unit-pinned but not live-smoked.** Commits `0d9bf875` (merged PR #281) and the PR #281 review follow-up add `ConversationStore#active_for_slug?`, inject the store into `NotificationDispatcher`, wire the same store through `Supervisor` startup and SIGHUP reload, mutex-guard the store for Telegram/status-poll thread sharing, scope suppression by project+slug where possible, and log `notification_skipped_active_conversation`. `test/unit/bot/conversation_store_test.rb` and `test/unit/bot/notification_dispatcher_test.rb` cover TTL expiry, same-slug suppression, different-slug/project non-suppression, nil-project fallback, recovery/error non-suppression, no stale dedup entry, re-alert after conversation end, and concurrent access. No artifact was found showing a live Telegram bot plus daemon WAITING-flap reproduction after the change.
17. **Tmux-session disappearance is unit-pinned but not live-smoked.** Commit `71db09c7` added `test/unit/claude_launcher_test.rb` coverage proving that `Hive::ClaudeLauncher.wait_for_terminal_marker` stamps `ERROR reason=tmux_session_terminated` when `runner.session_exists?` turns false before a marker arrives, and reports a pane-readability error if the tmux session check itself fails. The daemon healer now also has focused unit coverage for clearing non-review terminal agent-loss `ERROR reason=tmux_session_terminated` / `reason=agent_orphaned` markers in `2-brainstorm`, `3-plan`, `4-execute`, `7-artifacts`, and `8-finalize` with marker-id guards and bounded retry budgets; the `3-plan` variant additionally queues `hive plan <slug> --project <project> --from 3-plan` and logs `heal_requeued`. Branch `fix-claude-tmux-ready-detector-260629-50cc` documents the correct local-gem validation path for Claude tmux launcher-script packaging fixes in [[operating]], and source/tests show the gemspec includes `lib/hive/scripts/**/*.sh`; this refresh still found no in-tree artifact of a locally built `hive-cli` install replaying the affected Claude tmux task to `WAITING` or later. No in-tree artifact was found for the full live or integration path: kill a real managed tmux session during a Claude-backed brainstorm/plan/execute/artifacts/finalize run, observe the marker through `hive status`, let the daemon clear it, and verify the stage re-dispatches or stops red after the retry budget.
17a. **Claude/tmux review-fix Stop-hook fallback is integration-pinned but not live-replayed.** Branch HEAD narrows the manual recovery note for `REVIEW_ERROR phase=fix reason=fix_failed message="claude stop hook did not signal completion"` to require a live tmux session and code-change evidence: a new fix commit, dirty worktree pending Hive post-fix auto-commit, or whole-pass no-change where all findings were dispositioned `RESOLVED/NO-FIX:` with no unapplied `[x] AUTO-FIX:` line. Current source and `test/integration/run_review_test.rb` cover the same predicate through `handle_fix_completion_fallback`, including `claude_completion_fallback` audit emission for commit/no-change evidence and rejection when commit/no-change evidence or escalation clearance is missing; `test/unit/daemon/stale_agent_healer_test.rb` covers bounded daemon auto-clear for the residual known stop-hook marker. This refresh did not find an in-tree artifact replaying a real stuck task through a live Claude/tmux review-fix session, nor one proving the documented recovery tasks advanced after applying the narrowed evidence check.
18. **Telegram idea attachments and voice notes need live Bot API/download smoke evidence.** The 2026-06-03 wiki refresh verified commit `af183c0b` against router/handler source and the local unit/integration tests that cover media classification, project-pick collection, and `commit_idea` routing. The 2026-06-05 voice refresh verified commits `e96e024b`, `1e61c1ff`, `9a79198a`, `a740bab7`, and `21813bb2` against Telegram voice metadata parsing, `Hive::Bot::Transcriber`, transcription config validation, transcript draft phases, router/handler confirm/edit/discard routing, and focused unit tests. The checked-in `test/fixtures/voice/voice-idea.oga` fixture now lets the secret-gated voice E2E run when credentials are present, and `TG_IDEA_MODE=voice test/e2e/tg/run_idea_e2e.sh` seeds both a new audio idea and an audio `/answer` path. There is still no in-tree artifact proving a real Telegram `getFile` + download + `Hive::Commands::New#call!` capture or audio answer write has been smoke-tested against the live Bot API, nor an artifact proving live OpenAI audio transcription with `HIVE_WHISPER_API_KEY`.
19. **`hv` unsafe fallback-path removal is unit-pinned but not live-smoked.** Commit `00a8bca5` removed `/usr/bin/hive` and `/opt/hive/bin/hive` from `bin/hv`'s implicit candidate list so the fallback launcher does not accidentally exec Apache Hive from common system locations; `test/unit/hv_test.rb` covers the removed path strings and the `HIVE_BIN_OVERRIDE` custom-path escape hatch. This refresh did not find an in-tree artifact showing a live host with Apache Hive at one of those paths and the installed `hv` wrapper returning the new exit-127/custom-override behavior.
20. **v0.3.0 release prep is source-synced but not artifact-verified in-tree.** Commit `64b11b41` sets `Hive::VERSION` and `Gemfile.lock`'s path gem to `0.3.0`, adds the `CHANGELOG.md` release section for hivebox alpha, session-limit healing, dispatch-request/drop schema v2, golden-path E2E, and Windows installer harness coverage, and points README/install Linux installer snippets at `v0.3.0`. The committed `Gemfile.lock` diff changes only the local `hive-cli` path-gem version; no third-party dependency constraints or resolved versions changed. Commit `aa160a2c` hardens the pinned v0.1.0 install-smoke verifier's `jq` provisioning path, and PR #474's post-push GitHub Actions run `27500473396` passed `verify-release.sh (end-to-end behavior)` at that head. This refresh still did not find an in-tree artifact showing `packaging/verify-release.sh --version=v0.3.0`, channel verification against a published GitHub Release, Homebrew tap update, AUR package, or a published `ghcr.io/ivankuznetsov/hivebox:0.3.0` image after the tag exists.
21. **Daemon/TUI latency reductions are unit-pinned but not live-smoked.** Commits `0f4d9373`, `c1a63370`, and `7375c51d` remove the daemon SUCCESS cooldown, add the `daemon.fast_poll_sec` cheap child-reap/state-file mtime probe, and make `Hive::Tui::StateSource` skip `Status#json_payload` reparses when its watched mtime fingerprint is unchanged. Unit tests cover the controller, dispatcher, config bounds, and TUI state source. This refresh did not find an in-tree artifact showing a live daemon plus `hive tui` run where a completed child advances to the next stage within the intended ~1s window and the TUI avoids unchanged-status reparse work under real project load.
22. **Patrol-to-review handoff and scoped patrol reviewers are unit-pinned but not live-smoked.** Commit `4d0541d6` adds `Hive::Patrol::ReviewHandoff`, defaults `patrol.review_prs` to true, and updates `PrOpener` so opened patrol PRs keep their local worktree and create synthetic `.hive-state/stages/6-review/patrol-.../` tasks with `task.md`, `worktree.yml`, `pr.md`, `reviews/`, and `meta.yml` display names. Commit `464b64a9` adds `patrol.review.reviewers`, adds `patrol_reviewers` to the `hive-init.v1` success payload, and makes `Hive::Stages::Review.reviewer_specs_for` select that list when `task.md` frontmatter has `source: patrol`. Commit `b2e568ba` changes the patrol default to `codex-native-review` (`kind: codex_review`), with optional Codex/Claude CE `ce-code-review` entries still available from `hive init`; `852cc10c` keeps the patrol mode default at `medium`. `test/unit/patrol/pr_opener_test.rb`, `test/unit/config_test.rb`, `test/unit/commands/init/prompts_test.rb`, `test/unit/stages/review/run_reviewers_test.rb`, `test/unit/reviewers/codex_review_test.rb`, and `test/integration/patrol_command_test.rb` cover the handoff, config, prompt, schema, selector, native-reviewer, and handoff shapes, but no in-tree artifact was found showing a real `hive patrol PROJECT` run opening a GitHub PR and the daemon/TUI subsequently picking up the synthetic review task with only the scoped native Codex patrol reviewer.
23. **Archive listing is unit-pinned but not live-smoked.** Commits `01e86e1a` through `93fb45fb` add `Hive::ArchiveFilter`, required `tasks[].folder_mtime`, daily text/TUI hiding for old `9-done` rows, an unfiltered TUI Archive pane, and no-target `hive archive` listing/JSON filtering through `Hive::Commands::Status`; the archive-filter cleanup removes the dead `marker_name` input from `ArchiveFilter.hide?`, making the marker-agnostic age policy explicit. Focused unit/integration tests cover the policy, status text/JSON boundaries, TUI projection/cursor behavior, CLI routing, and empty archive message, including marker-independent hiding and fail-open behavior when no timestamp is available. This refresh did not find an in-tree live artifact from a real registered project showing the full operator workflow (`hive status`, `hive tui` -> `z`, `hive archive --json`) after aged done folders exist.
24. **Provider-limit recovery is unit/integration-pinned but not post-fix live-smoked.** `Hive::AgentLimit` and the headless/tmux/review writers classify quota/rate/usage-credit walls as `limits_reached` while filtering healthy UI-limit text. Provider reset dates remain visible estimates, but the daemon now schedules readiness solely from the latest quota marker mtime, retries after the default one-hour interval even when the provider advertises a later date, and does not exhaust ordinary recovery budgets. `test/unit/agent_limit_test.rb`, `test/unit/daemon/stale_agent_healer_test.rb`, and `test/integration/daemon_stale_agent_healing_test.rb` pin the display/scheduling split, missing/malformed hint compatibility, repeated unbounded retries, and a real status-row mtime clearing a five-day reset hold after one hour. No in-tree live artifact yet shows an installed daemon observing a real July-25-style hold, retrying after a user resets usage/switches account/tops up credits, and advancing the task while status/TUI retains the provider estimate. A large cohort limited at the same time can also become eligible in the same daemon tick; normal concurrency caps still bound dispatch, but that synchronized recovery shape has not been live load-smoked.
25. **Babysitter stale-runtime restart was live-smoked and exposed a restart argv bug.** On 2026-06-07, a live detached babysitter started before the current checkout correctly printed the stale-runtime restart recommendation, but `hive babysit restart --detach` daemonized after running through the `restart` code path and left the long-lived process recorded as `ruby bin/hive babysit restart --detach`. A second restart then blocked while waiting on that same process. The fix re-execs detached restart as the canonical `hive babysit start --detach` command before daemonizing, resolves the stable installed wrapper through `Hive::InvokedBinary.path`, aborts restart if stop leaves a potentially live PID behind, keeps the 600-second stop drain for active PR repair agents, and removes stopped/stale PID files only when the current payload still matches the one being stopped; `test/unit/commands/babysit_test.rb` covers the detached re-exec, wrapper resolution failure, refused-stop abort, re-exec failure, post-grace exit race, and replacement-PID preservation contracts. The branch was live-smoked locally by replacing the stale process and verifying the long-lived argv became `ruby bin/hive babysit start --detach`.
26. **Babysitter dirty-priority selection and pre-fix residue snapshots are test-pinned but not live-smoked.** The dirty-priority change has `Hive::Gh.list_open_prs` request `mergeStateStatus`, sorts `DIRTY` / `BLOCKED` / `UNSTABLE` PRs ahead of `BEHIND` / `UNKNOWN` and neutral states before applying `babysitter.max_concurrent_prs`, and changes the 6-review pre-fix `CleanExit` path so `reason: :pre_fix_dirty_worktree` snapshots all residue even when it is outside `review.fix.auto_commit.scope_check`. `test/unit/babysitter/project_tick_test.rb`, `test/unit/gh_test.rb`, and `test/integration/run_review_test.rb` cover the selector and in/out-of-scope pre-fix residue commits. No in-tree artifact was found showing a live `hive babysit PROJECT` run recovering a newer `DIRTY` PR from a large open-PR backlog, nor a live Claude/Codex-backed 6-review run where an out-of-scope pre-fix residue snapshot is inspected/reverted by an operator.
27. **`bin/hive-e2e` executable JSON/usage contract is focused-test pinned but not live-wrapper smoked.** Commit `d51455e6` starts Thor in `debug: true` and maps `Thor::Error` through the outer rescue so human unknown-command and missing-argument invocations exit `64`, matching the JSON envelope path. Commit `96242e97` removes a duplicate `Hive::E2E::Binary.start` call so successful `list --json`, `clean --json`, and `clean --json --dry-run` invocations emit exactly one top-level JSON document on stdout. Commit `cb986b33` changes `hive-e2e replay` so an existing `repro.sh` must be a regular executable file before `exec`; non-executable repro scripts now exit `78` with JSON `error_kind: unusable_repro` instead of falling through to a generic process failure. Branch HEAD keeps `--json --help run` / `--json -h run` on the human command-help path while preserving JSON envelopes for non-command help trailers such as `--json --help missing` and option trailers such as `--json --help --filter tui`. `test/e2e/lib/hive_e2e_binary_test.rb` covers the source-tree executable, including a temp-run `repro.sh` with mode `0644` and the recognized-command help variants. This refresh did not find an in-tree artifact showing a live patrol/babysitter wrapper consuming those `bin/hive-e2e` JSON surfaces, the `unusable_repro` replay path, or the leading-JSON command-help path; `bin/hive-e2e` is a checkout-only harness rather than a packaged `hive-cli` executable.
28. **Finalize unpushed-commit auto-retry is unit-pinned but not live-smoked.** The healer change makes `Hive::Daemon::StaleAgentHealer` clear `8-finalize` `ERROR reason=unpushed_commits` rows when no task lock is live, with a bounded per-process retry budget, so normal daemon dispatch can rerun finalize's clean-exit, auth, and push path. `test/unit/daemon/stale_agent_healer_test.rb` covers the retryable marker, live-lock skip, non-finalize skip, manual clean-exit skip, retry-budget exhaustion, marker-id race guard, and marker-clear failure logging; `test/integration/run_finalize_test.rb` covers finalize writing the marker on persistent push failure. This refresh did not find an in-tree artifact showing a live daemon observing such a finalized red row, clearing it, dispatching `hive finalize`, and successfully pushing or stopping red after repeated real push failures.
29. **Wrapper help/JSON/new-text grammar is checkout-pinned but not release-install-smoked.** The PR #427 wrapper work keeps `bin/hive` and `bin/hive-e2e` aligned with Thor's boolean grammar: option-bearing help requests like `hive approve --from 2-brainstorm --help` / `bin/hive-e2e run --filter tui --help` stay non-mutating, leading accepted JSON booleans like `--json=true status` dispatch as command-local options, malformed JSON assignments such as `--json=1` / `--json=yes` fail before Thor treats the value as a command argument, task target, or e2e run pattern, and duplicate wrapper booleans use the last recognized flag so a final `--no-json` or `--json=false` chooses prose. Commit `36f7499a` expands `bin/hive`'s pre-dispatch JSON usage-error mapping beyond the original `run` / `approve` / `markers` cases to the required-argument workflow, drop, findings, and rebase-status surfaces; commit `25082ee4` adds the missing patrol mapping so `hive patrol --json` without `PROJECT` emits the `hive-patrol` envelope with `error_kind: "error"` instead of prose-only stderr. Registered schemas use `Hive::Schemas::ErrorEnvelope`, while `hive-rebase-status` remains an unversioned sibling payload. PR #478 added the `hive new PROJECT` text-tail boundary, later superseded by the lift-and-rebuild contract in `bin/hive`'s `lift_new_options!`: allow-listed `--workflow`/`--depends-on` (and their `=VALUE` and JSON-boolean forms) are lifted from anywhere outside an explicit `--`, the remaining `PROJECT TEXT...` tail is rebuilt with a protective `--`, and a trailing/value-less value option stays literal text instead of eating PROJECT; `test/integration/new_wrapper_argv_test.rb` pins this argv behavior. `test/integration/cli_version_test.rb`, `test/integration/cli_usage_error_json_test.rb`, and `test/e2e/lib/hive_e2e_binary_test.rb` cover the checkout binaries and representative schema/new-text mappings. This refresh did not find an in-tree artifact showing the packaged `hive` executable generated by RubyGems/Homebrew/AUR exercising the expanded wrapper path; `bin/hive-e2e` is intentionally excluded from the gem payload and remains a checkout harness only.
30. **Bot Codex draft-assist retirement is source/unit-pinned but not live-smoked.** Commit `723906be` deletes `Hive::Bot::CodexConversation` and `templates/bot_brainstorm_codex_prompt.md.erb`, removes the `codex_write:` / `codex_edit:` / `codex_cancel:` callback parser branches, removes `start_codex` / `confirm_codex_draft` router actions, drops `bot.codex_budget_usd` / `bot.codex_timeout_sec`, and bumps bot structured logs to `hive-bot-log.v2` without the three `codex_*` events. Commit `c680ac29` then removes the leftover `ConversationStore` draft/confirm fields (`history`, `draft`, `awaiting_confirm`), deletes `pending_confirm_count`, and drops the unreachable `/done` pending-draft guard. Focused source-tree tests cover deterministic `:path_a` answer writes, legacy `path_a_yes` / `path_a_type` retirement replies, retired `codex_*` callback-data classification as `:unknown`, config-key removal, schema v2 validation, the smaller conversation-state shape, and `/done` dispatching directly from the active conversation. This refresh did not find an in-tree live Telegram artifact showing old Path-A buttons in a real chat steering to the deterministic answer flow, retired `codex_*` buttons degrading through the unknown-callback path, a live `:path_a` conversation writing an answer and sending the next question, or an installed log consumer accepting `hive-bot-log.v2`.
31. **Daemon display-name backfill is unit-pinned but not live-smoked.** Commit `9516efb1` adds `Hive::Daemon::DisplayNameBackfiller`, wires it into dispatcher ticks and SIGHUP reloads, and adds the closed `display_name_backfill` daemon-log event. Commit `a0b0ca3b` bounds per-folder inflight entries with `MAX_INFLIGHT_AGE_SEC = 120` so pid reuse or EPERM cannot suppress a blank-name retry forever, and logs unexpected reap/backfill failures as `:fatal` while keeping daemon ticks non-raising. `test/unit/daemon/display_name_backfiller_test.rb`, `test/unit/daemon/dispatcher_test.rb`, and `test/unit/daemon/logger_test.rb` cover missing/blank-name selection, `max_per_tick`, inflight suppression, dead-pid reap, EPERM retention, TTL eviction, dry-run logging, nil-pid retry behavior, bad-row/backfill/reap/spawn degradation, dispatcher invocation/rescue, and event enum acceptance. No in-tree artifact was found showing a live daemon observing an existing task with blank `meta.yml` `display_name`, spawning `hive generate-name`, emitting `display_name_backfill`, and later surfacing the generated label through `hive status`, the TUI, or the bot.
32. **TUI scrollable help overlay is unit-pinned but not live-terminal-smoked.** Commits `4d31fc65`, `f760bfa0`, and `0f70918a` added the bounded/wrapped help view, scroll keys, offset clamping, resize reclamping, Bubbletea mouse-cell reporting, and mouse-wheel translation. `test/unit/tui/views/help_overlay_test.rb`, `test/unit/tui/key_map_test.rb`, `test/unit/tui/update_test.rb`, and `test/unit/tui/bubble_model_test.rb` cover the renderer, key mapping, state transitions, and mouse-message adapter. This refresh did not find an in-tree PTY or Charm smoke artifact proving the full operator path in a real terminal: launch `hive tui`, press `?`, scroll with keys and mouse wheel, resize while scrolled, close with `q` / `Esc` / `?`, and verify the tiny-terminal fallback.
33. **Finalize merged-PR recovery is unit/integration-pinned but not live-smoked.** The merged-error archive recovery change routes whitelisted `8-finalize` `ERROR reason=git_status_failed` / `reason=claude_launch_failed` rows to `Hive::Daemon::PrMergeWatcher`; when GitHub reports the PR as `MERGED`, the watcher dispatches `hive archive --recover-merged-error-reason <reason>`, and `Hive::Commands::StageAction` re-confirms the current marker reason plus `Hive::Gh.pr_state(pr_url) == "MERGED"` before moving the task to `9-done`. Commit `118ed2fd` also adds an earlier `Stages::Finalize.pr_already_merged?` short-circuit: if `pr.md` points at a PR that is already `MERGED`, finalize stamps `COMPLETE pr_url=... is_draft=false merged=true` and returns `finalize_already_merged` before auth, git status, body-refresh agent spawn, or `gh pr ready`. `test/unit/daemon/pr_merge_watcher_test.rb`, `test/unit/daemon/dispatcher_test.rb`, `test/unit/gh_test.rb`, `test/integration/run_stage_action_test.rb`, and `test/integration/run_finalize_test.rb` cover the archive command generation, routing, `pr_state` success/error parsing, accept/reject boundaries, GhError fall-through, and direct already-merged finalize completion. This refresh did not find an in-tree artifact showing either live path against GitHub: a daemon observing a red finalized row after a real merge and archiving it, or a normal `hive finalize` run seeing an out-of-band merged PR and surfacing the completed task through `hive status`/TUI/bot.
34. **Claude/tmux orphan-sweep server skip is unit-pinned but not post-fix parallel live-smoked.** Commit `024b29b0` changes `Hive::ClaudeLauncher.sweep_orphan_processes` from a blanket `pkill -f` to `pgrep` plus per-PID `TERM`, skipping matched `tmux` commands because the tmux server can retain the first session's full `new-session ... --add-dir <task.folder>` argv. `test/unit/stages/brainstorm_tmux_sentinel_test.rb` covers the observed shape: one matched tmux server line plus one matched Claude line must kill only the Claude PID and log `skipped=1`. The 2026-06-11 refreshes did not find an in-tree artifact showing two real Claude/tmux-backed Hive tasks running in parallel after the fix, one finishing, and the sibling session surviving without `tmux_session_terminated`.
35. Hivebox web-tier residuals after the Rails rewrite (ADR-037): browser-level coverage of agents/telegram/repos pages beyond the pipeline system test (the Telegram page now has source-level integration coverage for its first-run setup guide, strict numeric chat-ID validation, and blank/@handle refusals, but no browser/Docker smoke; repos has source-level coverage for the first-run questionnaire, SSH-origin normalization, and non-directory clone-target refusal, but no live GitHub/Docker smoke; task-page red recovery now has source/Rails integration coverage and commit-message live verification, and oversized diff rendering is capped by source/Rails integration coverage, but no checked-in browser-system or Docker artifact); Action Cable behavior under many tabs; diff happy-path tests; cross-round brainstorm answer-numbering semantics (see dispatcher answer_questions); hoisting the action→verb map into the gem (duplicated in Dispatcher and bot NotificationBuilders). Commits `eb971b55`, `463fff29`, `0dea8aa6`, `d7ce55a9`, `70d60980`, `24c41980`, `b47f6627`, `9d0fc9ef`, `65e90ebe`, and `c0630426` add Playwright/system or Rails integration coverage for the task log tail's follow/pause/resume behavior, node-preserving log-frame morph reloads, artifact open-state preservation across pushed morphs, status-grid scroll plus composer draft preservation across a live broadcast, project-rail filtering with URL/composer sync, `+ Add project` routing, and re-application after a live broadcast, Telegram first-timer setup guide open-state/BotFather/userinfobot/three-step rendering and strict chat-ID validation, red-task diagnostic banner plus Retry route queueing, Q&A round replacement without permanent stale forms, finalize-first artifact ordering, chronological ordering for earlier stages, Artifacts-before-Log layout, sanitized markdown rendering, non-directory repo-target refusal, plain-vs-deep health, and bounded diff output. `StatusBroadcaster` is source/model-test pinned for self-healing after a raising broadcast, and commit `65e90ebe` moves the task-page refresh signal before the fallible grid render, but this refresh did not find a focused test or live artifact proving task pages still refresh when the projects partial itself raises. Commit `c52e4e83` styles artifact summaries as filename-tab chrome and rendered markdown as a bordered document panel, but this refresh found no screenshot or visual-regression artifact proving that distinction in a browser. Commit `279a9380` adds `web/script/record_box_demo.rb` for a staged real Rails + daemon + Playwright demo recording, and commit `c0630426` adds a real-resume helper path that reruns a stranded `3-plan` stage through the product CLI before resuming filming, but this refresh only source-inspected the recorder scripts; no checked-in `box-demo` artifact or local run evidence proves the recorder currently completes with Playwright and ffmpeg. Apart from commit `9d0fc9ef`'s live-verified stuck-review recovery note, this refresh also did not find an in-tree live Docker or long-running-agent artifact proving the same behavior against a deployed hivebox while real agents are appending logs/artifacts and status updates.
36. **Root README/FAQ still mentions "why no built-in web UI".** The committed hivebox work touched packaging and OpenClaw/wiki docs, but the root README still points readers to a FAQ entry framed as "why no built-in web UI" and `docs/faq.md` still says a web UI would add another state surface before the file protocol is finished. This refresh did not edit user-facing README/FAQ content because the request was scoped to the LLM wiki.
37. **Hivebox HTTPS-origin push path is source/integration-pinned but not live-Docker-smoked.** Commit `8be458bd` added `ReposController#normalize_origin!`, a Rails integration regression proving an existing `git@github.com:` origin is rewritten to `https://github.com/...`, and a Dockerfile system credential helper for `https://github.com` via `gh auth git-credential`. This refresh did not find an in-tree artifact showing the full Dockerized path after a real Agents-page `gh` login: register/clone a repo whose `gh` config prefers SSH, open a Hive PR, and observe `5-open-pr` push succeeding over the rewritten https origin.
38. **Hivebox Advanced Drop is source/unit/integration-pinned but not live-browser/Docker-smoked.** Commit `4a09cdb9` adds `POST /tasks/:project/:slug/drop`, `TasksController#drop`, `Hive::Web::Dispatcher#drop`, the Advanced Drop card, and tests proving the card is not a primary action, successful posts delete the task folder, and stale `from` stages return 422 without deletion. Existing `Commands::Drop` tests cover agent kill, folder/log/worktree/branch cleanup, draft-PR close, JSON/error contracts, and TUI Shift+X dispatch; commit `65e90ebe` pins the in-process return payload and the clarified `pr_closed` contract (`true` for no recorded PR, `false` only when a recorded PR could not be closed) so the web notice can stay honest. Commit `279a9380` bumps the current `hive-drop` schema to v2 while preserving v1 for pinned validators; commit `c0630426` fixes the copied v1 `$id`/title in `schemas/hive-drop.v2.json` and adds a schema-identity regression covering every exported schema file. This refresh did not find an in-tree artifact showing a real browser confirmation flow against a running hivebox instance or a Dockerized web drop that exercises full cleanup of an active worktree/branch/draft PR.
39. **3-plan terminal-error healer requeue is unit/integration-pinned but not live-smoked.** Commit `5f7ba051` changes `Hive::Daemon::StaleAgentHealer` so `3-plan` `ERROR reason=tmux_session_terminated` / `reason=agent_orphaned` clears also write a dispatch request for `hive plan <slug> --project <project> --from 3-plan` (`requestor=healer`, `trigger=terminal_agent_loss`) and log `heal_requeued`. Commit `65e90ebe` adds the distinct `heal_requeue_failed` event when the marker clear succeeded but queue write failed, plus integration coverage proving a real status row feeds the healer and lands an allowlisted dispatch request in `Hive::Daemon::DispatchRequestQueue`. Commit `279a9380` broadens the `3-plan` requeue to every successful terminal `ERROR` clear, including eligible `limits_reached` markers, because they leave the same markerless empty `plan.md`; `test/unit/daemon/stale_agent_healer_test.rb` pins the limits path. Commit `c0630426` bumps the dispatch-request schema to v2 so `requestor=healer` is part of the published queue contract, and queue/schema tests track the new const rather than hard-coded v1 fixtures. This refresh did not find an in-tree live artifact showing a daemon observing such a red `3-plan` row, writing the queue file, dispatching the queued rerun, and surfacing either a recovered `WAITING`/`COMPLETE` plan, a bounded red state for non-limit failures, or a renewed hourly quota hold after another real provider wall.
40. ~~**Root `Gemfile.lock` still lists `rack-test` after the manifest removal.**~~ — closed 2026-06-12. Commit `2e307a19` relocked the root bundle after commit `b0a31edf` removed `gem "rack-test", "~> 2.2"` from the root `Gemfile`. Current root `Gemfile.lock` no longer resolves `rack-test` and no longer lists it under top-level `DEPENDENCIES`; the separate web bundle still resolves `rack-test` transitively through Rails/Capybara for upload integration tests.
41. **Telegram `/start` welcome is source/unit/E2E-harness-pinned but not live Bot API-smoked.** Commit `4353734f` adds the `:slash_start` router intent and `SlashHandlers#start` welcome reply so Telegram's automatic first-contact command gets concrete `/status`, `/idea`, and `/help` next steps. `test/unit/bot/router_test.rb` and `test/unit/bot/slash_handlers_test.rb` cover classification and copy. The secret-gated Telegram E2E driver now imports `_drive.drive_start` and calls it before the text-mode `/idea` flow, so credentials-present runs exercise the live Bot API `/start` path. This refresh did not find an in-tree run artifact showing a freshly connected real chat sending `/start` to a running bot and receiving the welcome, nor an artifact proving the same first-contact path in a Dockerized hivebox after the supervisor starts the bot.
42. **Hivebox golden-path install is workflow/diagnostics-pinned but not fully hosted/live-provider-smoked.**

Commit `54fd3455` updates current source so it no longer tries to run the
post-publish arm64 image smoke on hosted macOS/Colima;
`.github/workflows/release.yml` uses
`hivebox-smoke-arm64` on native `ubuntu-24.04-arm` Docker instead, and the
commit message records a green run against the live
`ghcr.io/ivankuznetsov/hivebox:0.3.1` arm64 image. Remaining uncertainty is
narrower but still not closed by an in-tree artifact: no checked-in evidence
proves the public `hivecli.sh/box` and `hivecli.sh/box.ps1` endpoints served
the v0.3.1 installers, the Homebrew/AUR channels updated, Windows Docker
Desktop ran the PowerShell installer end to end, or a full live hivebox path
completed real GitHub/Codex/Claude provider login plus a daemon-owned PR push.

43. **Brakeman registry-laundered task-log ignore is scanner-clean but manually justified.** Commit `83f0a800` added a false-positive ignore for `TasksController#latest_log`: project lookup resolves through registered projects before exposing `hive_state_path`, the task slug is route-constrained, and the log path also uses `File.basename(params[:slug])`. This refresh parsed `config/brakeman.ignore` as JSON and ran the CI Brakeman command successfully on 2026-06-12. Remaining uncertainty: no focused regression test exercises `GET /tasks/:project/:slug/log` with malicious project/slug shapes; current coverage verifies task-page unknown-project/traversal handling and log rendering/follow behavior, not this exact scanner finding.
44. **`hive bench submit` is unit-pinned but not live-smoked.** Commit `ef47b9c0` adds `Hive::Commands::BenchSubmit` and CLI wiring for `hive bench submit SLUG [--project NAME]`: it resolves completed `9-done` tasks, requires `worktree.yml` and `pr.md`, derives the source repo from a GitHub `origin`, runs a local secret-token preflight over task spec files, delegates extraction to hive-bench's `harness/extract.rb`, then uses `git` and `gh pr create` in the hive-bench checkout. Commit `c4e2cab5` keeps the extractor subprocess argv-only by splitting the `ruby -I` flag/path and records the remaining `gh pr create` Brakeman finding as an array-form `Open3` false positive. Commit `90aa0501` extends `test/unit/commands/bench_submit_test.rb` beyond injected-seam orchestration: it covers the default local secret scanner, JSON/text reporter, `run_git`, extractor invocation against a stub `harness/extract.rb`, and PR opener through stub `git`/`gh` binaries. This refresh did not find an in-tree artifact showing the command against a real `HIVE_BENCH_PATH` checkout, a generated corpus entry that passes hive-bench validation, a real push, or a created GitHub PR.
45. **Status stage-move race handling is unit-pinned but not live-smoked.** Commits `586b9d31`, `a274bf42`, and `52585bc7` make `Hive::Commands::Status#collect_rows` tolerate task folders that vanish mid-scan and then drop duplicate-slug rows only when one duplicate folder no longer exists, preventing transient old-stage/new-stage duplicates in `hive status --json` and the TUI during ordinary forward workflow moves. Follow-up commits `0976c9ee`, `02ebf151`, `85e76754`, `c6543d8f`, `b018341b`, and `f6f03c59` narrow the `InvalidTaskPath` skip back to `Hive::Task.new`, document the folder-level `ENOENT` re-raise premise, and add focused tests for non-finalize forward moves, surviving-folder state-file `ENOENT`, the vanish test double's `to_path` timing, and three-member duplicate groups. This refresh still found no live TUI/daemon artifact showing a real task stage transition while the dashboard polls at 1 Hz; backward moves to an already-scanned stage are source-documented as a one-poll disappearance rather than live-smoked.
46. **`bin/hive-eval` scenario selector hardening is source-tested but not live-smoked outside the checkout tests.** Commit `822a23bf` adds `SAFE_SCENARIO_BASENAME = /\A[A-Za-z0-9_-]+\z/`, keeps slash/backslash rejection before lookup, strips a trailing `_test`, joins the safe basename under `HIVE_EVAL_SCENARIO_ROOT` or the default `test/eval/scenarios`, and exits 64 before writing a report on invalid selectors. `test/eval/support/reporter_test.rb` covers traversal, Windows-style separators, dotted unsafe names, stray positional scenario args, unknown/missing option usage errors, ambient `TEST` isolation, all-scenario scenario-only filtering, successful report writes, and deliberate failing-scenario report shape. This refresh did not find an in-tree artifact showing a live patrol-triggered or other non-test `bin/hive-eval --scenario ...` invocation after the hardened selector landed.
43. **Brakeman registry-laundered task-log ignore is scanner-clean but manually justified.** Commit `83f0a800` added a false-positive ignore for `TasksController#latest_log`: project lookup resolves through registered projects before exposing `hive_state_path`, the task slug is route-constrained, and the log path also uses `File.basename(params[:slug])`. This refresh parsed `config/brakeman.ignore` as JSON and ran the CI Brakeman command successfully on 2026-06-12. Remaining uncertainty: no focused regression test exercises `GET /tasks/:project/:slug/log` with malicious project/slug shapes; current coverage verifies task-page unknown-project/traversal handling and log rendering/follow behavior, not this exact scanner finding.
44. **`hive bench submit` is unit-pinned but not live-smoked.** Commit `ef47b9c0` adds `Hive::Commands::BenchSubmit` and CLI wiring for `hive bench submit SLUG [--project NAME]`: it resolves completed `9-done` tasks, requires `worktree.yml` and `pr.md`, derives the source repo from a GitHub `origin`, runs a local secret-token preflight over task spec files, delegates extraction to hive-bench's `harness/extract.rb`, then uses `git` and `gh pr create` in the hive-bench checkout. Commit `c4e2cab5` keeps the extractor subprocess argv-only by splitting the `ruby -I` flag/path and records the remaining `gh pr create` Brakeman finding as an array-form `Open3` false positive. Commit `90aa0501` extends `test/unit/commands/bench_submit_test.rb` beyond injected-seam orchestration: it covers the default local secret scanner, JSON/text reporter, `run_git`, extractor invocation against a stub `harness/extract.rb`, and PR opener through stub `git`/`gh` binaries. This refresh did not find an in-tree artifact showing the command against a real `HIVE_BENCH_PATH` checkout, a generated corpus entry that passes hive-bench validation, a real push, or a created GitHub PR.
45. **Golden-path CI flake fixes are source-pinned but not post-fix CI-verified in-tree.** Commit `798beb74` changes `web/test/e2e/golden_path_e2e.rb` so the browser test reads the newly created task slug from one current-DOM JavaScript query instead of retaining a `.task-row` Capybara element across daemon-driven Turbo replacements. Follow-up changes wait for the daemon's `needs_input` classification and a distinct `brainstorm.md` mtime tick before submitting the answer, and fix `hive status --json` to emit subsecond `mtime` / `folder_mtime` values so daemon edit-resume baselines are compared against the same precision they store. Commit `d76b3f60` then fixes the adjacent PR #480 failure by capturing the slug while the status grid is still visible and carrying that value into `wait_for_answer_window!`, rather than calling a nonexistent `task_slug` helper after task-page navigation. This refresh inspected the committed diff, row markup, golden-path E2E source, prior wiki fragments, and testing docs; the checked-in fragment records local Rails web/e2e/rubocop verification, but this refresh did not find an in-tree artifact showing the PR #480 `hivebox web (Rails tests + system)` job passing after the `NameError` fix.
46. **`bin/hive-eval` CLI contract is source/test-pinned but not judge-smoked.** Commit `ffa51d56` hardens the checkout-only eval runner's usage surface: positional scenario names are rejected before report creation, `--scenario` is confined to safe basenames under `test/eval/scenarios/`, and path separators/traversal/dotted names exit 64. `test/eval/support/reporter_test.rb` pins those structural paths plus inherited `TEST` isolation and successful report writing; `bundle exec ruby -Itest test/eval/support/reporter_test.rb` passed locally during this refresh. Remaining uncertainty: no in-tree artifact shows a full judge-enabled `bin/hive-eval` run after the hardening; the pinned structural path can run with `--no-judge` without exercising Codex judge subprocesses.
47. **`bin/hive-eval` usage/env contract is focused-test pinned but not full judged-eval smoked.** The eval-wrapper follow-up changes the checkout-local eval wrapper's usage text so one unexpected positional argument prints `unexpected argument: ...`, multiple positional arguments print `unexpected arguments: ...`, path separators report `scenario basename must not contain path separators`, and unsafe separator-free names report a generic safe-basename error without echoing the value. Commit `ed404213` then changes environment propagation so inherited `HIVE_EVAL_NO_JUDGE=1` is cleared unless `--no-judge` is passed, preventing caller environment from silently disabling Codex judge assertions. The patrol follow-up also rejects inherited `RAKEOPT=-n`/`--dry-run`, clears `RAKEOPT` before launching Rake, and refuses a zero child exit unless the report is parseable, identifies itself as `hive-eval-report` version 1, contains at least one scenario, and includes the requested scenario when filtered. The current focused tests pin the first positional scenario argument, a trailing extra argument, the stray positional scenario argument, path separators, unsafe names, invalid options, missing option values, ambient `TEST` isolation, all-scenario filtering, successful report writes, deliberate failing-scenario report shape, the judge-enabled env-clear fixture, inherited Rake dry-run rejection, child `RAKEOPT` scrubbing, missing reports after a successful child, malformed/wrong-schema reports, empty reports, and filtered reports naming the wrong scenario. This refresh did not find an in-tree artifact from a full `bin/hive-eval` run with real Codex judge/persona calls enabled after `ed404213`; the verified surface is the local structural wrapper/test path.
46. **`hive new` capture commit serialization is pinned, but adjacent display-name commits remain best-effort.** Commit `bdd9a9fa` wraps the captured-task `Hive::GitOps#hive_commit(stage_name: "1-inbox", action: "captured")` in `Hive::Lock.with_commit_lock(hive_state)`, and `test/integration/new_test.rb` now asserts the wrapper path. The committed wiki fragment records a local direct multi-process repro, but this refresh did not find an in-tree artifact proving the original parallel hivebox Rails/system-worker failure no longer reproduces. Source inspection also shows `Hive::DisplayName::Generator#commit_name` still calls `Hive::GitOps#hive_commit` directly and swallows `Hive::GitError`; that best-effort path may recover naturally through daemon backfill, but it is not serialized by `Hive::Lock.with_commit_lock` today.
46. **`hive digest` is implemented and test-pinned, but live provider evidence remains external.** Commits `7a75ee6e`, `814cd123`, `6bc04c90`, `742d4fab`, `ab35b657`, and the digest config follow-up add the shipped-digest pipeline: local-date windows, ship-time extraction from `hive/state`, `9-done` task collection, agent categorization through `templates/digest_prompt.md.erb`, Telegram MarkdownV2 rendering, `Digest::Sender`, the public `hive digest [--date] [--dry-run] [--json]` command, `Config.load_global_digest_config`, `digest.enabled` daemon scheduling, and `DigestScheduler` catch-up. Focused tests cover collection, ship-time precedence, categorizer output mapping/fallbacks, renderer escaping/order, orchestration statuses, sender chat-id resolution, dry-run token bypass, CLI date parsing, success JSON, global config validation, daemon catch-up/DST behavior, dry-run digest completion, and fatal-log isolation when scheduler completion raises. `test/digest/e2e_test.rb` now exists for a real agent + Telegram Bot API run (including a live failed-notice send) and fails loudly when `HIVE_TELEGRAM_BOT_TOKEN` or `HIVE_DIGEST_TEST_CHAT_ID` is missing, but this refresh did not run it and did not produce an in-tree artifact showing a delivered real digest. The `hive-digest` JSON document is now registered in `Hive::Schemas::SCHEMA_VERSIONS` (v1, published under `schemas/hive-digest.v1.json`) and emits `schema_version`; a malformed invocation caught before dispatch emits the shared error envelope via `JSON_USAGE_ERROR_CONTRACTS`, while other hard failures (bad `--date`, Telegram send error) remain on the stderr + exit-code path by design.
49. **Append-only log.d fragment carries a stale `:marker` kind reference (U11).** `wiki/log.d/20260620T120000Z-task-action-review-fixes.md:7` says the `:none` inert fall-through gate "excludes `:agent`, `:marker`, and `nil`". That was accurate at its 2026-06-20 timestamp, but U11 retired the `:marker` kind: `Hive::Workflow::KNOWN_KINDS` is now `[nil, :agent, :inert, :execute, :review_council, :finalize]` (`refute_includes ..., :marker` pins the absence in `test/unit/workflow_test.rb`), and the live code comment in `lib/hive/task_action.rb` was updated to "coding runtime kinds". Per the repo's append-only `log.d` convention the fragment is NOT rewritten; this note exists so an `rg :marker` reader treats that line as historical, not current. The only authoritative kind list lives in `lib/hive/workflow.rb`. See [[modules/task_action]].

49. **Screenote live capture test-token endpoint is blocked on Screenote-side availability.** The OAuth/MCP implementation has opt-in live discovery, dynamic-registration, and preseeded auth-code exchange coverage in `test/integration/screenote_oauth_live_test.rb`. The live `create_screenshot_upload` round-trip is written in `test/integration/screenote_capture_live_test.rb`, but it skips until the Screenote non-interactive test-token endpoint URL, secret, and project id are provided. As of 2026-06-22 the upload tool's request/response contract is covered in CI by `test_call_tool_create_screenshot_upload_round_trips_through_http_seam` (`test/unit/screenote/mcp_client_test.rb`) through the FakeHttp seam; the remaining gap is narrowed to proving the *signed upload* against a real Screenote bearer, which still requires the blocked live endpoint.

50. **Recoverable-error healer routing is source/test-pinned but not live-smoked.** The daemon docs now match recoverable auto-retry audit channels: `Hive::Events::EVENT_TYPES` accepts only `auto_retry` and `auto_retry_skipped` for task-local `events.jsonl`, while `Hive::Daemon::Logger::EVENTS` accepts `auto_retry`, `auto_retry_skipped`, `auto_retry_exhausted`, and `auto_retry_failed` for `daemon.log`. Source and focused tests pin the non-allowlisted reason suppression from the task channel, exhausted retries emitting task `auto_retry_skipped`, nil-`state_file_mtime` pre-clear guard, post-clear `heal_requeue_failed` isolation, fail-closed doctor probes, fail-closed stage safety, and stable health fingerprints. This refresh did not find an in-tree artifact showing a live daemon observing a real Codex-auth or Claude-launch recoverable terminal error, clearing it after a successful probe, and surfacing the expected task/daemon audit split. The 2026-06-30 cleanup audit for `make-the-hive-daemon-automatically-260629-223d` rechecked the branch commit, current source/tests, and configured main-wiki context and found no new live-daemon evidence closing this gap.

51. **Ad-hoc PR review is source/test-pinned but not live-smoked.** `hive review --pr PR` runs through `Hive::Commands::AdhocReview`, `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, and `Hive::Worktree.materialize_pr`. Focused unit/integration tests pin PR identifier parsing, project-scoped `gh pr view` lookup via `chdir:`, synthetic `6-review/adhoc-review-pr-N` task creation/reuse/collision behavior, PR-head materialization, head-SHA verification, cleanup after partial creation, reviewer selection, and default fix-off behavior (`review.adhoc.fix: false`). This refresh did not find an in-tree artifact showing a real registered project running `hive review --pr <github-pr>`, materializing the PR head from GitHub, completing review with real reviewer agents, and surfacing the ad-hoc task through `hive status`/TUI/bot. The 2026-06-30 cleanup audit for `make-the-hive-daemon-automatically-260629-223d` rechecked the branch commit, current source/tests, and configured main-wiki context and found no new live ad-hoc PR review evidence closing this gap.

52. **Local setup/web install repair is source/test-pinned but not live-smoked.** Branch `add-local-hive-web-install-260629-f4ca` documents `hive setup`, managed web-bundle refresh/install safety, daemon/web same-binary service install, web loopback/no-auth gating, and `hive web start --detach` systemd reload behavior. Focused tests cover phase-exit semantics, AppBundle extraction/stamping, service-installer rendering/parsing, and queue allowlisting, but this refresh did not find an in-tree artifact showing a real Homebrew/AUR/install.sh local install running `hive setup --service`, repairing stale daemon/web services, downloading the release web bundle, and serving the updated local web UI after a CLI upgrade. The 2026-06-30 residual wiki refresh for this branch re-inspected the wiki-only 6-review residue commit plus current setup/web/daemon source and tests; it did not add live-install evidence that would close this gap. Later 2026-06-30 post-commit audits of the same branch residue confirmed the committed setup wiki page was narrower than the main-checkout page and found no new live-install artifact; the final residual commit for this branch also removed setup/web managed-bundle details from several committed wiki pages rather than adding runtime evidence. The 2026-07-01 pass-02 wiki cleanup audit rechecked the branch diff, `Hive::Commands::Setup`, `Hive::Web::AppBundle`, `Hive::Commands::Web`, daemon/web service installers, and focused tests; it still found source/test coverage only, not a live release-install smoke artifact. This HEAD command/API refresh rechecked the local web bundle, web service subcommands, loopback no-auth config, example service units, and focused web/setup tests; it found no new release-install smoke artifact. The 2026-07-02 `arch-review-local-web-install` refresh rechecked setup CLI wiring, `Hive::Commands::Setup`, and focused setup tests after the dead `--yes` flag was removed and the shared phase runner was introduced; it confirmed source/test coverage for the JSON envelope and phase failure shape but still found no live release-install smoke artifact.

53. **Daemon status `unreadable` drift is source/test-pinned but schema-unpinned.** Branch `arch-review-local-web-install` extracts the daemon-status envelope into `Hive::Daemon::StatusReport`; that producer now owns `BINARY_DRIFT_STATES` / `BINARY_DRIFT_ACTIONABLE`, can emit `binary_drift: "unreadable"` when an installed same-path binary cannot answer `--version`, and the hivebox `_daemon` view treats that value as actionable through `StatusReport::BINARY_DRIFT_ACTIONABLE`. Focused daemon tests cover `StatusReport#safe_payload`, `binary_state`, `binary_version`, and the `unreadable` drift branch. However, `schemas/hive-daemon-status.v1.json` still enumerates only `none`, `path`, `version`, `unparseable`, and `not_applicable`, so an actual `unreadable` payload would not validate against the published daemon-status schema. A follow-up should add `unreadable` to the schema enum/description and pin a schema validation test for that payload shape. The 2026-07-01 post-commit audit for `arch-review-local-web-install` rechecked the branch diff, `Hive::Daemon::StatusReport`, daemon CLI wiring, hivebox `_daemon` rendering, the daemon-status schema, and focused daemon tests; it found no schema update or live repair artifact closing this gap.

The focused eval-wrapper guard now recognizes bundled, abbreviated, underscored,
and shell-quoted Rake dry-run options; validates complete passing scenario
records; and isolates concurrent report generation before atomic publication.
The remaining gap is still a real judge-enabled run, not structural report
integrity.

54. **Drop's descendant cleanup still has a snapshot/concurrent-fork race.** `Hive::ProcessKill` can terminate the agent and every descendant whose parent, process group, and start-time identity agree across two successful process-tree snapshots, and it reports `process_tree_unavailable` when discovery cannot support that claim. The second snapshot closes the PID-reuse window between ancestry and identity reads, but a child created after confirmation can still escape before the captured processes are stopped. Fully closing this race requires durable OS-level containment such as a cgroup (or an equivalent cross-platform process-lifetime boundary); repeated best-effort snapshots can narrow but cannot remove the race.

## 2026-06-16/17 refresh uncertainty

The 2026-06-17 audit rechecked recent source, tests, git history, project wiki
pages, and the configured master wiki path, and did not find new in-tree live
evidence closing the following June 16 gaps.

- **Hivebox Agents-page login fixes are source/Rails-integration-pinned, not live-provider-smoked.** Commits `5c645734`, `b08703a3`, `c5cd70a9`, `c75f4039`, `70e6ff14`, and `b370e7c3` cover binary PTY output scrubbing, Codex `--device-auth`, URL sanitize behavior, operator-ward Codex/gh polling UI, Claude paste-back preservation, and favicon/icon serving. This refresh did not find an in-tree artifact from a running Docker hivebox completing real Codex and `gh` logins against providers, then using the resulting `gh` credentials for a daemon-owned push.
- **Native Codex reviewer transcript trimming is unit-pinned, not live-flow-smoked.** Commit `0d0cac16` trims `codex review` stdout so triage receives the findings block plus final Codex reply without the middle exec/thinking transcript. `test/unit/reviewers/codex_review_test.rb` covers the output shapes, but this refresh did not find a live `hive patrol` or 6-review daemon artifact proving a real large Codex transcript no longer bloats triage.
- **Tmux large-prompt settle is unit-pinned, not live-Claude-smoked.** Commit `f25896a2` makes `Hive::TmuxRunner#send_prompt` wait for a stable pane tail before sending Enter. `test/unit/tmux_runner_test.rb` covers settle/deadline/failure paths with fake tmux, but this refresh did not find a live Claude/tmux run with a large review/triage prompt proving the prompt no longer sits staged in the input box.

47. **Babysitter GH browser-flag parsing is unit-pinned but not live-agent-smoked.** Commit `1dab816a` changes `bin/hive-babysitter-stub-gh` so short `-w` is treated as a browser-launch flag only when the command-specific short-option scanner parses it as an option flag. Value-taking read options now consume attached or following values, allowing examples such as `gh pr diff 42 -eworkflow.yml`, `gh pr list -lwip`, `gh pr view 42 -qweb`, and `gh pr list --search -wip` to pass through. `test/unit/babysitter/dry_run_env_test.rb` pins those cases with a recording fake `gh`, but this refresh did not find an in-tree artifact proving a full live-agent `hive babysit --once PROJECT --dry-run` run after the GH stub parser change.

48. **Fix-prompt whole-defect-class behavior is prose/test-render pinned but not live-smoked.** Commit `ce3f7978` changes `templates/fix_prompt.md.erb` so a 6-review Phase 4 fix agent should grep for and fix every site with the same defect class named by an accepted finding, rather than patching only the cited line. The committed evidence is prompt prose plus the existing `test/integration/prompt_injection_test.rb` render coverage (nonce wrapping, trailers, answered-escalation context); no in-tree artifact yet proves a live review fix agent followed the new instruction by repairing multiple same-defect sites in one pass, named the extra sites, and avoided unrelated refactors.

49. **PR #512 coverage-gate repair is focused-test pinned but not hosted-CI verified in-tree.** Commit `03ba06b9` added regressions for the two lines that made the Ruby CI coverage gate red: `test_wall_clock_returned_from_triage_retry_yields_review_stale` proves `run_triage_with_retries` returning `:wall_clock_exceeded` becomes `REVIEW_STALE reason=wall_clock`, and `test_dry_run_digest_complete_raise_is_isolated_as_a_fatal_event` proves dry-run digest pseudo-child completion write failures log `:fatal` instead of crashing the dispatcher tick. The committed fragment records the failed job's uncovered-line evidence and [[testing]] now names both contracts, but this refresh did not find an in-tree artifact showing the hosted Ruby CI / `bundle exec rake coverage` job passing after `03ba06b9`.
49. **Status/TUI/Telegram PR URL surfacing is unit-pinned but not live-smoked.** Commits `42fd5e2b`, `5e4e1ffa`, `408192cb`, `50552435`, and `06e37a80` add `tasks[].pr_url` to the current `hive-status` task payload, preserve it through `Hive::Bot::StatusWatcher` and `Hive::Tui::Snapshot::Row`, add `Hive::Pr.number`, render fixed PR columns in text status/archive output and the TUI, render Telegram `/status`/`/queue` PR links with HTML escaping, and append a PR link to the existing `ready_for_review` push without changing its fingerprint. Focused tests cover status extraction from `pr.md`, nil behavior before `5-open-pr` / missing / malformed sidecars, quiet mid-scan `pr.md` `ENOENT` degradation, schema required-key drift, bot row parsing, snapshot preservation, PR-number formatting, invalid URI rejection for link safety, text/archive status rendering, TUI column layout, OSC 8 hyperlink sanitization, Telegram HTML PR-link escaping, queue parse-mode forwarding, ready-for-review push enrichment, and fingerprint stability. This refresh did not find an in-tree artifact showing a real task with an opened PR feeding live `hive status` text output, a live `hive tui` TTY frame whose PR number is clickable in the operator's terminal, or a real Telegram dev chat receiving `/status` plus the open-PR push with clickable links.

## Release install follow-ups

Latest refresh (2026-07-19): v0.6.2 release-prep source is synchronized in
`lib/hive.rb`, both lockfiles, README/install URLs, the changelog, and the
release-facing wiki pages. This source commit does not itself prove the public
tag, signed gem/assets, Homebrew/AUR updates, or multi-architecture hivebox
images; those remain the tag-triggered `release.yml` verification boundary.
The v0.6.2 prep packages quota-bounded ordinary/architecture patrol progress,
durable architecture reviewer evidence, and detached exact-source analysis
after their focused tests and exact-head pull-request CI gates passed. The live
post-release dogfood evidence tracked below remains intentionally open until the
published release is installed and both patrol modes complete a real run.
Historical commit `54fd3455` still provides commit-message evidence for the
native arm64 GHCR smoke against `ghcr.io/ivankuznetsov/hivebox:0.3.1`.
Dependency lock uncertainty is unchanged: the root bundle has
`concurrent-ruby` 1.3.7 and Brakeman 8.0.5, while `web/Gemfile.lock` resolves
`concurrent-ruby` 1.3.6 and Brakeman 8.0.4; v0.6.2 synchronizes only the local
`hive-cli` path-gem version in that independently resolved web bundle.

1. **Release tag creation is protected, while signed git-tag verification remains deferred.** Homebrew and AUR publishing are implemented and public install docs route macOS users to the tap and Arch users to `yay -S hive-bin` (see ADR-032 in [[decisions]], `docs/RELEASING.md`, `README.md`, and `install.md`). The live repository has an active `v*` tag ruleset restricting creation, update, deletion, and non-fast-forward changes to the configured repository-role bypass. Release automation still publishes the commit selected by an authorized tag without independently verifying a maintainer cryptographic git-tag signature.
2. **macOS x86_64 install.sh support remains unsupported.** Current `install.sh` still accepts only `darwin-arm64` on macOS and glibc Linux `x86_64`/`aarch64`; a future follow-up can add best-effort Rosetta behavior once the release smoke matrix covers it.
3. **Authenticated agent-skill activation evidence remains opt-in.** Hive now provisions enabled built-in capabilities directly from their upstream Compound Engineering, llm-wiki, and Claude PR Review Toolkit packages; the unpublished `ivankuznetsov/hive-skills` placeholder is no longer part of the install path. Offline process-level fake CLIs prove argv, config homes, resolution, consent, conflicts, and convergence. `test/smoke/live_agent_skill_resolution_smoke_test.rb` can prove provider-authored structured activation metadata for Claude/Codex/Pi with disposable homes, but requires explicit `HIVE_LIVE_AGENT_SKILLS=1`, real credentials, and possible API/network cost. No checked-in artifact yet proves all three live jobs against one release build.
4. **OpenClaw ClawHub listing is published; scan completion evidence is partial.** `openclaw/skills/hive/` is the only public OpenClaw skill source. It publishes to ClawHub as `hive-cli` at `https://clawhub.ai/ivankuznetsov/hive-cli`, installs a slash command named `/hive`, and handles all workflows as `/hive ...` arguments. `/hive setup` guides first-use Hive CLI install/verification, daemon install, and optional project init. The skill now documents `/hive wiki compile-log --check` as the read-only wiki changelog verification path, but no checked-in artifact proves that an installed OpenClaw session delegated that specific subcommand. The public `hive` slug is owned by another publisher, so Hive intentionally uses `hive-cli`; shortcut listings such as `hive-plan`, `hive-work`, or `hive-babysit` are not part of the public surface. The 2026-06-07 wiki log records `clawhub inspect hive-cli --json` reporting `latest: 0.1.1` and clean moderation fields, but also records `clawhub scan --slug hive-cli --version 0.1.1 --json` hanging without returning; no checked-in artifact independently proves a completed scan command.

## Patterns detected in code but not yet documented

1. **`Stages::Base::TemplateBindings` reflection pattern** — used as a generic kw-args → instance vars adapter. Worth a one-paragraph note in [[templates]] if the pattern appears elsewhere.
2. **Idempotency conventions** — `Init` exits with code 2 when already initialised; `New` exits with code 1 on slug collision; the `OpenPr` stage idempotent-PR path returns `:complete` without spawning. There's no centralised exit-code policy.
3. **Two patterns for marker writes** — `Markers.set` (now uses flock + tempfile-rename atomic write) vs the agent writing into the state file via `Edit`/`Write`. The orchestrator now owns the terminal marker after every stage (the reviewer template explicitly does not write `task.md`), so concurrent-write races on the state file should not arise during normal flow. The remaining unprotected case is a user editing the state file in vim/VSCode while AGENT_WORKING — documented as "don't do that" in the README.

## Open enhancements

- **Ordinary-patrol alpha weights are Hive-corpus calibrated, not yet cross-project calibrated.** The 0–100 scorer, semantic clustering, component cooldown, and proof gates are language-neutral, but the empirical audit behind the default threshold used 218 generated PRs from this repository. No checked-in evidence yet compares acceptance, duplicate rate, surface diversity, or delivered weighted alpha across unrelated Python, TypeScript, Go, Rust, JVM, infrastructure, or mixed-language projects. Persisted immutable finding/selection/outcome metadata now makes that calibration possible; a future evaluation should tune weights from several repositories without using raw patrol count as a positive signal for already-overpatrolled surfaces.

- **Ordinary-patrol exact publication recovery is locally pinned, not live-smoked.** Unit/integration coverage now fetches the explicit remote branch under a bounded transport deadline, replaces unmaterializable scan pins, binds proof/branch push/PR identity/review handoff to exact Git SHAs, uses expected-OID leases, and rechecks the live remote head/base immediately before first and retried task handoff. No disposable hosted-repository run has yet advanced the default branch during ordinary-patrol publication or failed/retried the real GitHub `6-review` handoff, so remote-provider race behavior remains proven by fake-`gh` contracts rather than a live trace.

- **Generic workflows have no dedicated stale/error resting-marker surface** — `TaskAction#generic_action`'s `else` arm classifies every non-`{complete,waiting,none}` marker as `generic_ready_to_run` / `ready_to_run` ("Ready to run") with no diagnostic, so a future non-coding workflow that invents a stale/error-style resting marker (other than `:error`/`:agent_working`, which the universal overrides already catch) would read as "ready to run" with no signal, unlike the coding path's dedicated stale/error arms. Dormant today for production workflows; a future descriptor-workflow follow-up should wire a generic error/stale surface without changing coding's bespoke action map. See [[modules/task_action]].

- **Daemon quarantine is invisible to operators** — after the transient
  backoff schedule (60/120/300s) is exhausted, `ConcurrencyController`
  quarantines the `[project, slug]` pair for the daemon's lifetime. The state
  lives only in daemon memory: `hive status` (and therefore the hivebox web
  grid) recomputes the row from filesystem markers and shows the gate label
  (e.g. "Ready to open PR") as if the task were merely waiting, while the
  daemon logs `blocked reason=quarantined` every tick. Observed live during
  the 2026-06-11 dogfood: three ssh-push failures in `5-open-pr` quarantined
  the task and nothing surfaced in the UI. There is also no operator-facing
  lift short of restarting the daemon or running the stage command manually.
  Candidate fix: persist quarantine (or at least the last `stage_exit` error
  + blocked reason) somewhere `Commands::Status` can read, render it as an
  error row, and let a manual/web dispatch clear it.

- **Review fix-phase agent loss goes undetected** — observed live 2026-06-11:
  the tmux server was killed (pre-fix sweep from a long-running old-code
  child) while two `6-review` tasks were in `phase=fix pass=02`. The reviewer
  phase stamps `tmux_session_terminated` errors promptly, but the FIX phase
  parents sat for ~1h with `Last event: agent_start — phase=fix`, no error
  marker, no live agent, and rows honestly-but-wrongly showing "Agent
  running" (live run lock → healer skips). Likely cause: with the tmux
  server itself gone, the session-liveness probe errors instead of returning
  false, and the fix-phase wait treats that as retryable. Candidate fix:
  treat "no tmux server" as session-terminated in the fix-phase sentinel,
  mirroring the reviewer-phase handling. Recovery today: TERM the `hive
  review` parent; the daemon re-dispatches and the stage resumes its pass.
  Commit `b6bba5d6` only covers returned error text that clearly indicates a
  provider usage/credit limit; it does not close this lost-tmux/liveness
  detection gap.

- **Brainstorm answers written within one daemon tick of round-end are
  swallowed** — found by the hivebox golden-path E2E. The resume watcher
  only sees state-file edits NEWER than its baseline, and the baseline is
  seeded by the first classification tick after the round's active owner is
  observed complete (legacy child exit or durable attempt terminalization).
  An operator answering inside that window (the push-updating web
  UI shows questions the moment the agent writes them, before the child
  even exits) strands the task at `needs_input` until some later edit. The
  E2E syncs on the daemon's own event log to avoid the window
  (`wait_for_answer_window!`); a product fix would be dispatching on
  first sight when `answers_pending` is already false, or seeding the
  baseline from the round's dispatch mtime instead of the current one.
  The distinct same-second precision variant is fixed: `StatusConsumer`
  now re-stats local `state_file` paths so an answer written after the
  baseline in the same wall-clock second still compares newer than the
  agent's fractional post-child mtime.

## Aggregate council resource caps (2026-07-09)

Workflow `budget_usd` and `timeout_sec` values are deliberately applied per
reviewer/retry/round/revise spawn, not to the council as a whole. A council with
multiple reviewers or rounds can therefore consume several times its stage
budget. The current docs make that multiplication explicit, but Hive has no
aggregate council cost or wall-clock cap yet. Add one only with clear semantics
for partially completed rounds, command reviewers, and profiles that cannot
natively enforce dollar budgets.

## Grok live skill and telemetry verification (2026-07-10)

The Grok profile's argv, device/API-key authentication, `GROK_AUTH_PATH` / `GROK_HOME`, and
streaming text-event contract are verified against the installed CLI and its
documentation. Two boundaries remain intentionally open:

- Grok has no `Hive::SkillCheck` verifier, so skill-backed planning/review
  stages cannot prove a configured slash command exists before spawn. The
  bundled Grok CE reviewer uses a compact self-contained prompt as a stopgap;
  a real Grok extension invocation still needs a live end-to-end smoke test.
- Current `streaming-json` terminal events expose no token counts. Hive leaves
  Grok usage unavailable rather than storing fake zeroes. Add a captured-stream
  fixture and extractor mapping if a future CLI version publishes usage.

## Daemon concurrency-limit reload live verification (2026-07-10)

The pre-fix defect was reproduced live: after changing
`max_concurrent_per_project` from 3 to 4 and running `hive daemon reload`, the
daemon logged `config_reloaded` but continued returning `project_cap` at three
live project runs. Focused tests now pin in-place refresh of all four
controller-owned limits while preserving controller identity and existing
in-flight accounting. A live daemon running a release containing the fix has
not yet repeated the same 3→4 reload and dispatched the fourth task without a
restart; capture that daemon-log sequence after deployment to close this gap.

## Architecture-patrol remote recovery is locally pinned, not live-smoked (2026-07-11)

The v2 architecture-patrol lifecycle has fake-`gh`, unit, and integration
coverage for immutable merge intake, language-neutral discovery, durable
feature checkpoints, dead-owner claim recovery, isolated fixes, issue routing,
creation intents, exact repository/branch reconciliation, mandatory `6-review`
handoff, and read-only provider enforcement. This refresh did not run a
disposable live GitHub or GitHub Enterprise repository through branch push, PR
creation, issue creation, open/closed reconciliation, crash-after-intent
recovery, and handoff creation. Until that smoke exists, the checked-in tests
prove Hive's local state machine and command contracts, not the complete hosted
provider behavior under real network ambiguity.

## Non-Claude patrol in-flight token enforcement needs live stream fixtures (2026-07-16)

Claude 2.1.179 patrol logs and focused process-group tests prove that nested
`message_start` usage plus cumulative `message_delta` output can stop a running
agent at `max_tokens_per_agent`. Codex and Pi terminal totals are parsed, while
current Grok streaming JSON exposes no counts, but representative live interim
usage streams for those three profiles have not been captured. Until they are,
Hive can mark a terminal-total run over-limit but cannot promise an early token
interrupt for that provider; launch ceilings and wall-clock timeouts remain the
provider-independent bounds. Capture real streams before adding profile-specific
interim accounting so cumulative events are not accidentally double-counted.

## Patrol provider-event ceilings remain event-granular (2026-07-16)

Live Claude patrol sampling showed that provider-owned startup context can be
charged before Hive receives its first measurable usage event. Hive now refuses
a patrol launch unless the remaining allowance covers Claude's conservative
20,000-token initial-context reserve plus one token per prompt byte, and a
three-turn/output-complete boundary prevents an unnecessary follow-up after the
artifact is written. This closes the previously observed unbounded pre-event
launch and extra-response paths, but it cannot make provider telemetry
continuous: a single usage event can still cross the configured token ceiling
before Hive can send TERM. The exact provider context/tokenization is not a
stable local API, so the reserve is deliberately conservative rather than an
exact forecast. Recalibrate from captured streams if Claude materially changes
its headless context or event cadence.

## Four incident e2e fixtures remain sibling-gated (2026-07-17)

All six production-incident sequences are synthetic and parseable. The #9771
plan-only dependency and repository-routing fixtures now execute as ordinary
green results against the merged fail-closed contracts. Four remain visible as
pending entries rather than claimed passes because the current tree does not expose the exact sibling-owned
contracts needed to activate them: #9767's durable attempt lease and adoption
reason, #9768's generation identity and reconciliation reason, #9769's
finalize lifecycle terminal reason, and #9770's retry-owner evidence and bounded
terminal reason. The harness deliberately does not infer those formats or strings.

Close this gap one fixture at a time after the corresponding sibling lands:
replace its activation guard with real CLI reconciliation and exact
state/reason assertions, remove `pending: true`, and keep the report-measured
runtime below five seconds. Full incident coverage is not complete until the
incident report contains six ordinary green results and zero pending entries.

## Areas the wiki could be expanded

- `wiki/troubleshooting.md` — currently lives only in README's Troubleshooting section. Could be lifted into a dedicated page once the project sees real-world failures.
- `wiki/security.md` — dedicated page for the trust model, prompt-injection policy, and the protected-files SHA-256 check. Currently spread across `[[architecture]]`, `[[decisions]]` ADR-008, and `[[modules/agent]]`.
- `wiki/operating.md` — expand the existing page with deeper log rotation, `.hive-state` backup strategy, recovering from a deleted feature worktree, and live daemon restart playbooks once ops practice exists.
- `wiki/roadmap.md` — Phase 2/3 work is listed in [[active-areas]]; a dedicated roadmap with status columns would be more navigable once Phase 2 work begins.

## Backlinks

- [[active-areas]]
- [[index]]
- [[e2e]]

## Resolved Bootstrap Validation

- 2026-05-14: Managed llm-wiki config, agent context, post-commit hook, and daily systemd timer were validated for `hive`.
- 2026-05-15: `qmd status` reports Vulkan GPU offload on AMD Radeon 890M Graphics (RADV STRIX1) after installing the Arch Vulkan stack.
- 2026-05-15: `qmd query "llm wiki managed bootstrap" -c hive --no-rerank -n 3` completed with local Vulkan-backed generation; sandboxed agent sessions still need qmd cache write access via `--add-dir` or host-side maintenance hooks.

## Leaked sandbox daemons from tests/recorders (2026-06-12)

Six `hive daemon start` processes (cwd: pr300-review worktree, throwaway
HIVE_HOMEs) were found running on the dev machine, leaked across the day's
web-suite/E2E/recorder runs. At least one was DETACHED (argv without
--foreground) while bound to a recorder sandbox's HIVE_HOME, fighting the
recorder's own foreground daemon over the pidfile. Open questions:
- What spawns a detached daemon with an inherited sandbox HIVE_HOME?
  (Only Hive::Web::Supervisor uses `hive daemon start` without
  --foreground in-tree.)
- Should `hive daemon start` refuse to detach when HIVE_HOME looks like a
  test sandbox, or should test helpers register an at_exit reaper?
- A daemon whose pidfile is stolen exits silently — no dispatcher_stopping
  event. It should log what it observed before exiting.

## Display-name agent emits activity labels (2026-06-12)

On a real run the display-name agent named the task "Agent Work In
Progress" — an activity description, not a name. The prompt should pin
"a short noun-phrase name for the TASK" with an example or two.

## Triage phase ~5.5-min failure cause unconfirmed (2026-06-17)

Live task `xbookmark` #1333 (`we-need-to-add-an-260616-094b`) failed at the
triage phase ~5.5 min in across two separate runs (5m42s and 5m32s) with a
legacy generic triage failure reason. The real `error_message` was discarded by
`mark_review_phase_failure` (now fixed — it surfaces a `message=` attr and
triage retries; see [[stages/review]]), so the underlying trigger was never
captured. Open questions:
- What exactly made `wait_for_expected_output` exit before its 1800s deadline?
  No 300s/5-min constant exists in `claude_launcher.rb`; the early-exit paths
  are limit-reached, `tmux_session_terminated` (single-shot
  `expected_output_session_alive?` — one `tmux has-session` `TmuxError` →
  `false`, with no streak tolerance unlike the 3-streak pane-read path), or
  3× consecutive unreadable-pane errors.
- The box had ~130 agent procs and fully-exhausted swap (no OOM-kill in the
  kernel log). Did swap thrash make a `tmux has-session` call transiently fail
  and get misread as a dead session? If so, `expected_output_session_alive?`
  should tolerate a transient `TmuxError` like the pane-read streak does.
- Or did the interactive `claude` triage agent end its turn / exit before
  writing `escalations-NN.md` (the log showed it spinning at "5m 0s" right as
  it was about to write its output files)?
Commit `e5c26edc` adds direct helper coverage for bounded `message=`
truncation and capped retry backoff. Commit `c4045dfe` then clamps the retry
loop against `review.max_wall_clock_sec` before another triage spawn and dedups
the retry/backoff/truncation helpers, but it still does not provide a live
post-fix failure sample. Next live triage failure should now carry the
`message=` attr — use it to pick between these before hardening
`expected_output_session_alive?`.
## codex-native review: prose-verdict clean-pass heuristic (2026-06-19)

`Hive::Reviewers::CodexReview` accepts a prose (non-checkbox) verdict as a
`:clean` pass only when `clean_verdict?` matches an affirmative no-findings
phrase (`CLEAN_VERDICT`) and no `CONCERN_SIGNAL`. This closed the `all_failed`
regression (genuine clean reviews failing) while preventing a prose-described
finding or an exit-0 soft-error from being laundered into a clean pass. Residual
risk: the patterns are heuristic. A finding phrased with no concern word AND a
"no … issues" hedge could still slip to `:clean`, and an unusually-worded
genuine clean verdict could fail to match and `:error`/retry (worst case
`all_failed`). The robust long-term fix is to get `codex review` to reliably
emit the strict `## High/Medium/Nit` + `No findings.` format so the prose path
is never exercised; until then, watch `reviews/errors-NN.md` tails for
clean-but-rejected verdicts and extend `CLEAN_VERDICT` as new phrasings appear.

## Execute condition shadow rollout lacks live parity volume (2026-07-17)

Generation-scoped execute conditions, deterministic replay, marker/shadow/
conditions modes, and the sanitized task-1849 golden fixture are covered in
source and tests. Authenticated replay, future-schema rejection, short-write
completion, partial-append rollback, journal/telemetry separation, and cached
snapshot attempt revalidation are fault-injection/unit pinned, but have not
been exercised against a live task
journal under real disk pressure. No production project has yet supplied the promotion bar of
at least 100 categorized live transitions across commit success, research
success, no-change, agent-loss, and operator-repair with zero unexplained
mismatches and an empty allow-list. Projects must remain on marker or shadow
authority until operators collect that evidence; Hive never auto-promotes.
The daemon's terminal/lost `AttemptObserver` path is likewise unit-pinned but
has not been live-smoked with a real detached execute worker failing after its
last boundary observation and then surfacing the updated gate through status.
Missing/empty post-handoff journals, failed-first-append retry fsync, causal
predecessor ordering under clock regression, terminal-state snapshot
invalidation, structured condition recovery actions, and durable forced-
override visibility are also unit/fault-injection pinned only. The rollout
still has no project-scoped promotion/rollback CLI or public snapshot-rebuild
command; those are operator-ergonomics follow-ups rather than authority gaps,
because marker mode remains default, status replays snapshots read-only, and
promotion is deliberately explicit/manual.

## Pi/Grok concrete-default config discovery needs live drift monitoring (2026-07-17)

Implementation ownership resolves pi from project/home `settings.json` and Grok from project/home `settings.json` or top-level `config.toml`, extracting only provider/model identifiers. Deterministic tests cover those current shapes and ensure PR opening remains unpinned, but neither CLI publishes a Hive-stable config schema. A future upstream path/key change will intentionally fail before execute capture rather than serialize `default` or route to another provider. The next verified CLI upgrade should re-check these read-only paths and update the headless matrix plus fixtures if native configuration moved.

## Patrol quota-progress fixes need post-release dogfood (2026-07-19)

A live medium ordinary-patrol run exposed that the configured 12-feature batch
could consume its three-launch cycle envelope, report the remaining features as
errors, and leave the cursor at zero. Live architecture jobs then exposed the
same exhausted shared 8-launch UTC-day ceiling as one synthetic failure for
every remaining feature and retried it every minute without starting another
provider process. Post-release v0.6.2 ordinary patrol mapped 209 features,
reviewed exactly the launch-aware three-feature batch without errors, advanced
its clean prefix, and ranked one source-anchored systemd startup defect at alpha
80. Architecture Patrol reached the isolated exact checkout and retained its
raw response, proving the dirty-checkout and ephemeral-evidence fixes, but
exposed a valid leading JSON fence followed by plain-text rationale that v0.6.2
rejected. The v0.6.3 parser accepts that canonical document shape; exact-main
dogfood then completed clean PR-scoped reviews and a full scan produced the
meaningful `invert-usage-error-contract-ownership` thesis above the configured
0.25 discovery floor. Automation correctly rejected it for unverified evidence,
multi-feature scope, and file/diff limits. Durable architecture review run
directories still have no automatic retention policy, so long-running
installations should monitor `.hive-state/refactor_patrol/runs/` growth. Retain
this gap only until the installed v0.6.4 package repeats both patrol modes
without dirty-checkout, quota-churn, or response-envelope errors.
