# Wiki Changelog

Append-only log of all wiki operations.

<!-- BEGIN GENERATED WIKI LOG FRAGMENTS -->
---
title: Residual wiki cleanup for daemon auto-retry and ad-hoc review
date: 2026-06-30
---

Refreshed main-checkout LLM wiki coverage for `make-the-hive-daemon-automatically-260629-223d` after its residual 6-review commit changed wiki pages and changelog fragments.

Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the configured main-wiki path first. `qmd search "make hive daemon automatically auto retry recoverable ad hoc review"` returned no indexed hits, so verification used direct wiki/source search and the branch diff.

Inspected the committed diff plus current source/tests: `Hive::Daemon::RecoverableErrorHealer` still emits task-local `auto_retry` / `auto_retry_skipped` while daemon logs accept `auto_retry`, `auto_retry_skipped`, `auto_retry_exhausted`, and `auto_retry_failed`; `daemon.auto_retry.enabled` remains the kill switch; and `hive review --pr` is implemented through `Hive::Commands::AdhocReview`, `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, and `Hive::Worktree.materialize_pr`.

Normalized branch-only wording in [[cli]], [[commands]], [[commands/stage_action]], [[modules/config]], [[modules/gh]], [[modules/pr]], [[modules/worktree]], [[state-model]], [[stages/review]], and [[testing]]. Carried forward [[gaps]] uncertainty for the missing live-daemon recoverable-error smoke and missing live `hive review --pr` smoke. No page was created, so [[index]] page coverage did not change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

## [2026-06-30T16:52:33Z] wiki — audit local web install residue commit

**Action:** Refreshed planning/documentation coverage after branch `add-local-hive-web-install-260629-f4ca` produced a 6-review residual wiki-only commit. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, ran `qmd search "local hive web install setup service web bundle binary drift unreadable"` (no hits), checked the configured main wiki path, inspected the committed diff with `git show`, and rechecked current setup/web/daemon source and tests for the documented local install surface.

**Coverage:** Kept the main-checkout wiki pages as canonical because they already contain the stronger current coverage for `hive setup`, managed web-bundle bootstrap, daemon/web same-binary service install, loopback no-auth gating, daemon binary-drift reporting, web service start behavior, and focused test coverage. No page/index edits were needed beyond this changelog fragment: [[gaps]] already records that this residue audit did not add live local-install smoke evidence and did not resolve the `binary_drift: unreadable` schema/test uncertainty. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
slug: claude-tmux-ready-detector-refresh
created: 2026-06-30T16:30:00Z
---

**Action:** Refreshed main-checkout wiki coverage for branch `fix-claude-tmux-ready-detector-260629-50cc` after its finalize backstop commit touched wiki files. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "claude tmux ready detector packaging detector review limit text threading"` returned no indexed hits. Inspected the committed wiki diff plus current `lib/hive/claude_launcher.rb`, `test/unit/claude_launcher_test.rb`, `hive.gemspec`, `test/unit/gemspec_test.rb`, `test/integration/gem_package_scripts_test.rb`, and existing wiki pages. Updated the shared Claude/tmux ready-prompt docs for Claude Code 2.1.179 separator/caret/footer prompt chrome, Unicode separator spaces, and the stricter bypass-permissions footer check; carried forward the local-gem live replay gap using the branch slug rather than a raw commit reference. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/agent]]
- [[stages/brainstorm]]
- [[testing]]
- [[gaps]]

## [2026-06-30T15:52:48Z] setup/web/daemon — residual wiki coverage audit

**Action:** Refreshed wiki planning/documentation coverage after branch `add-local-hive-web-install-260629-f4ca` produced a residual 6-review wiki-only commit. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, ran `qmd search "local setup web install daemon status binary drift unreadable"` (no hits), checked the configured main wiki path, inspected the committed diff and committed wiki pages via `git show`, and rechecked current source/tests for `Hive::Commands::Setup`, `Hive::Commands::Web`, `Hive::Web::AppBundle`, `Hive::Commands::Daemon`, `schemas/hive-daemon-status.v1.json`, and related unit coverage.

**Coverage:** Kept the main-checkout wiki pages as the canonical coverage because they are already more complete than the residual committed `commands/setup` page and include the current local setup, managed web-bundle, same-binary service install, loopback auth, daemon-status, and test coverage details. Updated [[gaps]] only to record that this residual refresh did not close the missing live local-install smoke evidence and did not resolve the `binary_drift: unreadable` daemon-status schema/test uncertainty. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]

---
slug: claude-tmux-packaging-detector-refresh
created: 2026-06-30T15:30:00Z
---

**Action:** Refreshed main-checkout wiki coverage for branch HEAD after it
documented the local validation path for unreleased Claude tmux launcher-script
packaging fixes. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search
"Claude tmux packaging detector ready"` returned no indexed hits, and the
configured master wiki path did not exist in this checkout. Inspected the
committed diff plus current `hive.gemspec`, `lib/hive/claude_launcher.rb`,
`lib/hive/commands/daemon.rb`,
`lib/hive/commands/daemon/service_installer.rb`,
`test/unit/gemspec_test.rb`, and
`test/integration/gem_package_scripts_test.rb`. Copied the operating guidance
into the global main wiki and recorded that source/tests prove the script
packaging contract, but no in-tree artifact proves a locally built gem replayed
the affected Claude tmux task to `WAITING` or later. Did not run `qmd update`
or `qmd embed`.

**Refreshed pages:**
- [[operating]]
- [[gaps]]

## [2026-06-30T14:54:19Z] setup/web/daemon — residual local install coverage refresh

**Action:** Refreshed command/API wiki coverage for branch `add-local-hive-web-install-260629-f4ca` after its residual 6-review commit touched `Hive::Commands::Setup`, `Hive::Commands::Web`, daemon/web service installers, `Hive::Web::AppBundle`, `Hive::Web::Loopback`, and `Hive::Daemon::DispatchRequestQueue`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], recent [[log]] entries, ran `qmd search "local hive web install service installer daemon web loopback app bundle"` (no hits), and inspected the committed diff plus current source/tests.

**Coverage:** Added missing [[commands/setup]] for the local non-Docker provisioning surface, added it to [[index]]/[[cli]]/[[commands]], and refreshed [[commands/daemon]], [[commands/web]], [[modules/daemon]], [[testing]], and [[gaps]]. Documented `--no-bootstrap` as diagnose-only, setup phase/exit semantics, QMD/web-bundle bootstrap failure reporting, managed web-bundle stale refresh and safe extraction, same-binary daemon/web service install, shared launchd rendering and daemon plist `$0` parsing, web loopback/no-auth gating, `hive web start --detach` systemd reload behavior, and the narrowed daemon queue global-maintenance allowlist. Recorded remaining uncertainty that source can emit `binary_drift: unreadable` while the inspected `hive-daemon-status.v1` schema enum still lacks that value, plus missing live smoke for `hive setup --service` against a real local release install. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/setup]]
- [[index]]
- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[commands/web]]
- [[modules/daemon]]
- [[testing]]
- [[gaps]]

## [2026-06-30T14:48:32Z] wiki — audit make-the-hive-daemon-automatically-260629-223d docs cleanup

**Action:** Refreshed the global project wiki after branch `make-the-hive-daemon-automatically-260629-223d` touched wiki pages and log fragments. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "adhoc review daemon auto retry diagnostic evidence"` returned no indexed hits, and the configured `main_wiki_path` (`/home/asterio/wikis/master/wiki`) was absent, so verification used direct source/wiki reads. Inspected the branch diff plus current `Hive::Commands::AdhocReview`, `Hive::Worktree.materialize_pr`, `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, daemon recoverable/stale healer code, `Hive::DiagnosticEvidence`, and focused tests.

The existing global wiki already preserved the ad-hoc PR review source mappings and daemon auto-retry coverage that the branch diff touched. Updated [[commands/status]] because it still described read-only `hive status --diagnose` as identical to status-row JSON; current code uses `Hive::DiagnosticEvidence` to synthesize diagnostics for non-red rows when on-disk evidence exists. Updated [[testing]] and [[gaps]] so `lib/hive/diagnostic_evidence.rb` and `test/unit/diagnostic_evidence_test.rb` are discoverable. Carried forward the live-evidence uncertainty in [[gaps]]: no new artifact was found proving a real daemon recoverable-error retry or a real registered-project ad-hoc PR review flow. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[testing]]
- [[gaps]]

---
title: Review-fix wiki cleanup for daemon auto-retry and ad-hoc review
date: 2026-06-30
---

Refreshed main-checkout LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its review-fix commit changed wiki pages and changelog fragments.

Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the configured main-wiki path first. `qmd search "make-the-hive-daemon-automatically recoverable error healer adhoc review"` returned no hits, and the configured main-wiki path had no branch-specific context.

Inspected the committed wiki diff plus current branch source/tests: `Hive::Daemon::RecoverableErrorHealer` still provides the fixed v1 dependency-outage auto-retry path with task-local `auto_retry` / `auto_retry_skipped` and broader daemon-log audit names, and `Hive::Commands::AdhocReview` still creates/reuses `6-review/adhoc-review-pr-N` tasks through PR metadata, PR-head materialization, and normal `6-review` dispatch. The same source check found no `lib/hive/commands/setup.rb` and no daemon binary-drift status payload in the branch.

Removed stale setup-command and daemon binary-drift coverage from [[index]], [[cli]], [[commands]], [[commands/daemon]], [[commands/web]], [[testing]], and [[gaps]], and deleted the stale [[commands/setup]] page from the main wiki. Carried forward [[gaps]] uncertainty for the missing live-daemon recoverable-error smoke and missing live `hive review --pr` smoke. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
title: Residual wiki refresh for daemon auto-retry and ad-hoc review
date: 2026-06-30
---

Refreshed LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its residual 6-review commit touched command/module/state/test wiki pages, gaps, index metadata, and changelog fragments.

Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and existing branch-specific log fragments first. `qmd search "make-the-hive-daemon-automatically recoverable auto retry adhoc review"` returned no indexed hits, so verification used direct wiki/source search plus the configured main-wiki path.

Verified the committed wiki diff and source/test evidence with `git show make-the-hive-daemon-automatically-260629-223d:<path>`: `Hive::Daemon::RecoverableErrorHealer` handles only the fixed dependency-outage allowlist, emits task-local `auto_retry` / `auto_retry_skipped` events while daemon logs keep `auto_retry_exhausted` / `auto_retry_failed`, observes pre-clear mtimes, and requeues `3-plan` after successful clears; `Hive::Commands::AdhocReview` creates or reuses synthetic `6-review/adhoc-review-pr-N` tasks through `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, and `Hive::Worktree.materialize_pr`, with ad-hoc fixes disabled by default through `review.adhoc.fix: false`.

Updated [[state-model]] to include the recoverable dependency-outage healer alongside existing terminal-`ERROR` auto-clear semantics, and carried forward [[gaps]] uncertainty for the missing live-daemon Codex/Claude retry smoke and missing live `hive review --pr` smoke. No page was created, so [[index]] page coverage did not change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

## [2026-06-30T11:21:02Z] babysitter - extract shared skip-log/escaping helper for the dry-run stubs

**Action:** Fixed Hive patrol finding `command-bin-hive-babysitter-stub-git-2`
(maintainability/medium): the security-critical skip-log and control-char
escaping helpers (`log_skip`, `append_skip_log`, `escaped_argv`,
`escape_control_chars`) were copy-pasted byte-for-byte across
`bin/hive-babysitter-stub-git` and `bin/hive-babysitter-stub-gh`, so a future
hardening pass on the audit-log open path or the binary-safe escaping could land
in one stub and silently diverge from the other.

Extracted the four helpers into a single `bin/hive-babysitter-skip-log.rb` that
both stubs `require_relative`. require_relative resolves from each stub's real
`bin/` dir, which survives the PATH-overlay shim handoff because
`Hive::Babysitter::DryRunEnv#prepare_overlay` execs the stub by its absolute
`bin/` path through the pinned interpreter. `log_skip` now takes the
`"git"`/`"gh"` label as its first argument so the audit line still names the
entrypoint; the only per-stub difference is removed from the duplicated body.
Added the shared file to `hive.gemspec` `spec.files` so it ships with the gem
(verified `Gem::Specification.load`).

Verified behaviorally: both stubs still skip a mutating command, write the
correct command-prefixed line to the skip log, exit 0, and the escaping path
stays binary-safe (control bytes -> `\xHH`, high bytes pass through, non-UTF-8
argv does not raise). Full minitest suite (`test/babysitter/acceptance/dry_run_test.rb`,
`test/unit/gemspec_test.rb`) runs under Hive validation; minitest is not
installed in this worktree's gem home for a local run.

**Refreshed pages:**
- [[modules/babysitter]]

---
timestamp: 2026-06-30T11:05:00Z
title: Review fix stop-hook failures are bounded auto-recoverable
---

- `StaleAgentHealer` now treats `REVIEW_ERROR phase=fix reason=fix_failed message="claude stop hook did not signal completion"` as a narrow recoverable infrastructure failure.
- Generic `fix_failed` markers remain manual; the healer includes the stop-hook `message` in the guarded marker clear so stale rows cannot clear a different fix failure.

---
title: Recoverable healer and ad-hoc review wiki refresh
date: 2026-06-29
---

Refreshed LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its residual docs commit touched command/module/state/test wiki pages and changelog fragments.

Verified the committed wiki diff against committed source and tests using `git show <branch-change>:<path>`: `Hive::Daemon::RecoverableErrorHealer` keeps task-local events to `auto_retry` / `auto_retry_skipped` while daemon logs also accept `auto_retry_exhausted` / `auto_retry_failed`; `daemon.auto_retry.enabled` is the global kill switch; and the branch also adds the `hive review --pr` ad-hoc PR review path through `Hive::Commands::AdhocReview`, `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, and `Hive::Worktree.materialize_pr`.

Updated [[cli]], [[commands]], [[commands/daemon]], [[commands/stage_action]], [[modules/config]], [[modules/gh]], [[modules/pr]], [[modules/worktree]], [[stages/review]], [[testing]], and [[gaps]]. No page was created, so [[index]] page coverage did not change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
title: Recoverable error healer routing refresh
date: 2026-06-29
---

Refreshed LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its docs-only review fix corrected recoverable auto-retry event-channel routing.

Verified the committed wiki diff against current source and tests: `Hive::Events::EVENT_TYPES` only allows task-local `auto_retry` / `auto_retry_skipped`, while `Hive::Daemon::Logger::EVENTS` allows the broader daemon-log audit set (`auto_retry`, `auto_retry_skipped`, `auto_retry_exhausted`, `auto_retry_failed`). `RecoverableErrorHealer` suppresses task events for non-allowlisted reasons, maps exhausted retries to task `auto_retry_skipped`, keeps all four names in the daemon log, guards nil `state_file_mtime` before clears, and lets `HealerSupport#requeue_plan_rerun` log `heal_requeue_failed` after a successful clear without relabeling the clear as `auto_retry_failed`.

Updated [[modules/daemon]] because the main wiki still lacked the recoverable-healer module row and tick-order placement, and added [[gaps]] uncertainty for the missing live-daemon smoke of the Codex-auth / Claude-launch recoverable auto-retry path. No page was created, so [[index]] page coverage did not change.

## [2026-06-29T12:32:47Z] setup/daemon/web — local setup and daemon binary-drift status

**Action:** Refreshed command/API wiki coverage after branch `add-local-hive-web-install-260629-f4ca` touched the local setup command, daemon status payload/schema, daemon service-installer parsing, setup diagnostics, and hivebox status rendering. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "daemon status binary drift installed_binary hive-daemon-status"` returned no indexed hits, and the configured main wiki path had no matching context. Inspected the committed diff plus committed versions of `lib/hive/commands/setup.rb`, `lib/hive/setup/diagnostics.rb`, `lib/hive/commands/daemon.rb`, `lib/hive/commands/daemon/service_installer.rb`, `schemas/hive-daemon-status.v1.json`, `web/app/controllers/status_controller.rb`, `web/app/views/status/_daemon.html.erb`, and focused tests.

**Coverage:** Added [[commands/setup]] for the local non-Docker web/daemon provisioning path and updated [[cli]], [[commands]], [[commands/daemon]], [[commands/web]], [[modules/agent_profile]], [[testing]], [[gaps]], and [[index]]. Documented the `hive-setup` phase report, setup diagnostic status/auth semantics, daemon-status binary-drift fields and enum, bounded installed-binary version probe, macOS launchd `$0` binary parsing, and hivebox's in-process daemon status payload plus actionable repair states. Recorded missing live evidence for real `hive setup` service repair and concurrent web dashboard daemon-status rendering. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/setup]]
- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[commands/web]]
- [[modules/agent_profile]]
- [[testing]]
- [[gaps]]
- [[index]]

---
timestamp: 2026-06-25T17:34:45Z
slug: release-smoke-wiki-refresh
tags: [wiki, release, hivebox, dependencies]
---

## [2026-06-25T17:34:45Z] wiki — refresh v0.3.1 release smoke and dependency coverage

**Action:** Refreshed the LLM wiki after reading `.llm-wiki/config.json`,
`AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent compiled [[log]]
entries, and current `wiki/log.d` fragments first. `qmd search "hive workflow
screenote worktree review suppression release arm64 image smoke"` surfaced
current project wiki coverage in [[gaps]], [[testing]], and [[commands/web]].
Searched the configured main wiki path `/home/asterio/wikis/master/wiki`
before changing project pages; the other default cross-project paths did not
exist in this checkout. The master wiki had general Screenote/MCP/OAuth context
but no Hive-specific release-smoke guidance for the current changes.

Inspected recent history through `54fd3455`, including the v0.3.1 release prep,
RuboCop 1.88 dependency bump, root Brakeman/concurrent-ruby lock bumps,
Screenote OAuth/MCP merge, no-fix review suppression, dependency-stacking
worktree fix, workflow-selection/custom workflow commits, and the release
workflow change from macOS/Colima to native arm64 Linux Docker. Updated
[[commands/web]] and [[testing]] so the hivebox image smoke contract names
`hivebox-smoke-arm64` on `ubuntu-24.04-arm` instead of the obsolete hosted
macOS/Colima check. Updated [[dependencies]] and [[operating]] for `0.3.1`,
root RuboCop `1.88`, root Brakeman `8.0.5`, root `concurrent-ruby` `1.3.7`, and
the fact that `web/Gemfile.lock` remains separately locked to Brakeman `8.0.4`
and `concurrent-ruby` `1.3.6`; refreshed [[active-areas]] and [[index]] for
descriptor-backed workflows and the current release surface; and recorded the
remaining release-channel/live-provider plus web-lock dependency uncertainty in
[[gaps]].

Page count stayed 84; [[index]] was updated for summary/date, not for a new
page. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[commands/web]]
- [[dependencies]]
- [[gaps]]
- [[index]]
- [[operating]]
- [[testing]]

## bot - row-action review-fix pass 2 (model unification + fail-loud)

**Action:** Stage 6-review fix pass 2 over the [[modules/bot]] row-action work.

**Type design:**
- `RowActions::Resolution` drops the redundant `suppress` boolean; it is now
  derived from `kind == :suppressed` so a contradictory `(suppress: true,
  kind: :plan_waiting)` pair is no longer representable. Construction enforces
  exactly one primary action for a non-empty resolution (the
  `find(&:primary) || actions.first` fallback is gone).
- `RowActions::Action` now also requires a non-nil `callback` and a `verb` for
  the `:rerun` role (the only role whose label/hint is verb-derived).
- The `:run` role is collapsed into `:rerun`: one role for "paused stage,
  re-run the agent", with the Run/Re-run label and next-step hint derived from
  the `verb` (`develop` → "Re-run", `finalize`/`run` → "Run"). The label and
  hint live in `NotificationBuilders.rerun_label` / `Supervisor#rerun_hint`.

**Fail-loud:**
- `NotificationBuilders#needs_input` replaces its catch-all `else
  default_needs_input` with an explicit `:generic_needs_input` arm and raises
  on any other kind.
- `Supervisor#next_step_hint` raises on an unmapped primary role instead of
  silently degrading to the laptop hint; `button_coverage_test` now sweeps
  every representative row through it.
- `PlanApproval.rewrite_to_develop` accepts an already-`hive develop ...`
  command idempotently, so the bot's stale-Approve tap on a row that raced to
  `:complete` dispatches the valid develop (the `:complete` no-op branch is now
  reachable) instead of falling to handle's generic rescue. `approve_plan`
  gains a local `ArgumentError` rescue that distinguishes corrupt plan.md /
  malformed queued command from a malformed callback.

**Robustness:** per-row isolation in `NotificationDispatcher` now wraps the
WHOLE per-row body (suppress predicates + `fingerprint`, not just the build) and
both it and `Supervisor#status_action_button` widen to `rescue StandardError`,
so a `NoMethodError`/`TypeError` on a bad attrs/workflow value drops one row
rather than aborting the tick / keyboard.

**Dependency hygiene:** `row_actions.rb` now declares its
`require "hive/bot/notification_builders"` (the two modules are mutually
recursive at runtime; neither references the other at load time, so the cycle
is safe) — requiring `row_actions` alone no longer raises `NameError` on a
recovery row.

**Cleanups:** `keyboard_for_actions` maps actions→buttons once; the dead
`result_stage` `respond_to?(:stage)` guard and the unreachable
`status_action_emoji[:findings_reject]` / `[:run]` entries are gone.

**Tests:** `button_coverage_test` derives `WORKFLOWS` and `MARKERS` (incl.
`manual_steering`) from the closed registries; the review-triage keyboard pins
its un-flattened 2-wide row structure; the parity test annotates the
tautological brainstorm cell.

**New log event:** `callback_plan_state_corrupt` (added to `Logger::EVENTS` and
`schemas/hive-bot-log.v2.json`).

**Refreshed pages:**
- [[modules/bot]]

## [2026-06-25T12:00:00Z] bot — re-arm recovery grace during a live-retry hold (A5)

**Action:** Corrected a false-recovered hazard in
`NotificationDispatcher#process_recoveries`. The live-identity hold is now
checked BEFORE the absence-grace window, and each held tick re-arms the grace
clock (`AlertStore#mark_present`, clearing `absent_since`). Previously grace was
checked first and could fully elapse *during* the hold, so the first tick the
`agent_running` identity was merely absent from the snapshot released the hold
and fired "✅ Recovered" — even when the retry had not finished. A per-project
status degrade (`commands/status.rb` keeps top-level `ok:true` while emptying a
project whose dir check fails; `status_watcher`'s `extract_rows` skips a project
with an `error`; the supervisor still calls `process_rows` because `result.ok`)
can drop a still-running row from a single tick, which is exactly the blip that
used to leak a premature Recovered. Recovered now fires only once the lock has
been gone for a full grace window after the hold genuinely lifts.

**Supersedes:** the earlier
`20260624T184142Z-telegram-live-agent-suppression` note's "`absent_since`
continuity during a hold" property — `absent_since` is now deliberately
re-armed (kept un-started) while held, not carried across the hold.

**Tests:** Replaced the absent_since-continuity test with
`test_grace_clock_is_rearmed_every_tick_while_live_retry_holds_the_row`; added
`test_mid_hold_single_tick_identity_drop_does_not_fire_premature_recovered`
(transient one-tick degrade keeps the hold, no Recovered, entry retained),
`test_clean_agent_working_retry_holds_recovery_independent_of_marker`
(marker-independent hold: `agent_running` + `agent_working`), and
`test_live_agent_for_different_project_does_not_hold_same_slug_recovery`
(project component of `recovery_identity`). The live-retry resolution tests now
advance past the post-hold settling window, and the archived / manual_steering
recovery tests pin an exact `RECOVERED_MESSAGE` body and total message count.
The builders archived-error test now asserts `:notification_skipped_live_agent`
fires with `action: "archived"`.

## [2026-06-25T11:18:56Z] bot — soft-degrade the Show-details render path

**Action:** All three sites that render `NotificationBuilders.details_reply(row)` — inline `details:` callbacks (`CallbackHandlers#show_details`), `/details` (`SlashHandlers#details`), and `Supervisor#render_details` — now wrap the render in a soft-degrade rescue. A render-time fault logs the new `details_render_failed` event and replies "Status lookup failed — try again in a moment." instead of escaping past the already-ack'd callback / poll loop and leaving the operator with no reply (preserving the "never a dead end" guarantee). The slash `resolve_status_row` degrade now logs the new `status_lookup_failed` event, and `CallbackHandlers#resolve_details_row`'s degrade logs a backtrace. Both new events are registered in `Logger::EVENTS` and the `hive-bot-log.v2` schema enum (additive, no version bump). `Diagnostic` coerces its members to strings in `initialize` so `#text` can't `NoMethodError` on a nil member.

**Refreshed pages:**
- [[modules/bot]]

## bot - row-action review-fix pass (type hardening + UX)

**Action:** Stage 6-review fix pass over the [[modules/bot]] row-action work.

**Type design:**
- `RowActions::Resolution` carries a `kind` tag (a closed `KINDS` set);
  `NotificationBuilders#needs_input` now dispatches on the kind instead of
  reverse-engineering the surface from the exact role array (which silently
  fell through to the neutral default on any reorder/extra action).
- `RowActions::Action` validates its `role` against a frozen `ROLES` set at
  construction (a typo'd/added role is now a boundary `ArgumentError`, not a
  deep `Hash#fetch` `KeyError`) and carries an explicit `verb` used by the
  status next-step hint (fixes the "tap Run to run run" copy → "run this
  stage"). `Resolution#primary` replaces the scattered
  `actions.find(&:primary) || actions.first`.
- `READY_ROLES` is gone; `ready_action?` derives from
  `NotificationBuilders.verb_for_action` as the single source of truth (every
  ready row's role is uniformly `:approve`).

**Robustness:** per-row build is isolated in `NotificationDispatcher`
(`build_notification`) and `Supervisor#status_action_button` so one malformed
row can't abort the whole tick / keyboard. `approve_plan` rescues
`SystemCallError`/`IOError` from the marker write with an actionable reply, and
documents the deliberate advance-then-resurface window. An unresolved `#`
compaction token now replies "button expired — reopen /queue" instead of "I
did not understand that".

**Cleanups:** dropped the dead `coding_stage?(row, "7-finalize")` disjunct and
the dead `waiting_input` builder / `actions: nil` fallbacks; added
`# coding-scoped:` annotations to the remaining stage literals; removed the
now-unreachable `--diagnose` slug inference; re-indented `finalize_action`.

**New log events:** `notification_build_failed`, `status_button_failed`,
`callback_marker_write_failed` (added to `Logger::EVENTS` and
`schemas/hive-bot-log.v2.json`).

**Refreshed pages:**
- [[modules/bot]]

## [2026-06-25T09:56:20Z] bot - noise category is a downstream-only convention

**Action:** Clarified that the bot log `noise` category is a **downstream-only**
convention — producers tag high-frequency, low-signal lines (benign poll-transport
failures, dedupe/backoff skips) with it, but nothing in the gem filters on it; an
external log viewer/forwarder is expected to drop `category=noise` lines. Extracted
the one load-bearing value as `Hive::Bot::Logger::CATEGORY_NOISE` so the single
significant category is greppable while the `category` field stays open-set, and
used it at the three producer sites (`Telegram`, `NotificationDispatcher` ×2).
Reworded the overclaiming `logger.rb` comment, documented the contract in the
`hive-bot-log.v3` schema `category` description, and scoped `PollHealth::Result`'s
`consecutive_failures` / `seconds_since_success` to the escalation path with a doc
comment.

**Tests:** Pinned `LEVELS.keys ⊆ EVENTS` (catches a stale/misspelled LEVELS key
silently ignored by `LEVELS.fetch`), pinned a strict bijection between the
`hive-bot-log.v3` event enum and `Logger::EVENTS` (catches schema-side drift),
pinned that `build_update` parse failures never escalate poll-health even past
`max_consecutive`, and pinned that a second backoff episode for a fingerprint that
never leaves `current` stays log-suppressed (the deliberate in-memory-Set tradeoff,
asserted `== 1`).

**Refreshed pages:**
- [[modules/bot]]

## [2026-06-25T09:49:24Z] testing - hive-eval clears the default report when --report value is junk

**Action:** Extended the [[testing]] "no stale report" contract for `bin/hive-eval`. When `--report` is followed by an option-looking or empty value (`--report --no-judge`, `--report=`, `--report=-x`), `OptionParser#parse!` overwrites `options[:report]` with that junk token before the missing-argument error is raised, so the usage-error cleanup had been deleting the junk path instead of the stale default report. The default report path is now held in a standalone `default_report` local; the rescue (and `selected_report_path`'s inline-`--report=` branch) fall back to it whenever the captured value is option-looking/empty, so a stale `tmp/hive-eval-report.json` is cleared on these usage errors too.

**Tests:** Added `test_cli_usage_error_clears_default_report_for_option_looking_value` (with a `preserve_path` helper that safely exercises the hardcoded default location) in `test/eval/support/reporter_test.rb`; verified it fails on the pre-fix binary and passes after, and ran the full `bundle exec ruby -Itest -Itest/eval test/eval/support/reporter_test.rb`.

## [2026-06-25T01:28:48Z] cli - wrapper argv encoding preflight

**Action:** Added pre-dispatch `ARGV#valid_encoding?` guards to `bin/hive` and
`bin/hive-e2e` so invalid-byte arguments route through existing usage-error
formatting instead of Thor/Ruby internal errors. `bin/hive run --json <invalid>`
now emits the command-specific `hive-run` error envelope with exit 64;
`bin/hive-e2e replay --json <invalid> ...` emits `hive-e2e-error` with
`error_kind: "usage"` and exit 64.

**Verified:** `bundle exec ruby -Itest -Ilib test/integration/cli_usage_error_json_test.rb`;
`bundle exec ruby -Itest -Ilib test/e2e/lib/hive_e2e_binary_test.rb`;
`bundle exec rubocop bin/hive bin/hive-e2e test/integration/cli_usage_error_json_test.rb test/e2e/lib/hive_e2e_binary_test.rb`.

## [2026-06-24T22:41:04Z] bot — render Show details from cached rows

**Action:** Inline `details:` callbacks, `/details <slug>`, and supervisor status-row detail rendering now share `NotificationBuilders.details_reply(row)`. The reply always includes a row summary and row-specific next-step hint, appends cached `row.diagnostic` summary/detail when present, and truncates oversized diagnostic detail to Telegram's message limit. Show details no longer spawns read-only `hive status --diagnose`, so non-red waiting rows no longer dead-end with an empty diagnostic reply; `refresh_diagnose` remains the explicit `--diagnose --write --force` path.

**Refreshed pages:**
- [[modules/bot]]
- [[commands/bot]]

## bot/task-action - canonical Telegram row actions

**Action:** Added `Hive::Bot::RowActions` as the canonical status-row to
Telegram-action resolver and moved push notifications plus `/status` buttons to
consume it. Needs-input rows now get a working action (`Answer`, plan `Approve`,
review findings triage, execute `Re-run`, finalize/generic `Run`) or are
suppressed when the row is incoherent (`marker=none` / `marker=complete`).
Details now renders the cached `Supervisor#render_details` summary with a
next-step hint instead of dead-ending through `hive status --diagnose`.

**TaskAction:** Markerless coding brainstorm/execute rows and markerless
finalize rows with an existing `pr.md` classify as `READY_TO_RUN`, not
`NEEDS_INPUT`; execute-stage `:complete` maps to `READY_TO_OPEN_PR`.

**Tests:** Added `test/unit/bot/button_coverage_test.rb` to enumerate
representative `(action, marker, stage, workflow)` rows, assert resolver and
`/status` agreement, and forbid non-terminal needs-input rows whose only action
is Details.

**Refreshed pages:**
- [[modules/bot]]
- [[modules/task_action]]

---
date: 2026-06-24
slug: bot-task-id-slash-targets
pages: [commands/bot, modules/bot]
---

`/answer`, `/approve`, `/autofix`, and `/details` now accept the numeric task id
shown in Telegram notifications and `/status` rows, with or without a leading
`#`. Numeric targets resolve against the bot's current `StatusWatcher` snapshot
to the task slug before the existing action path runs, so archived or
scrolled-out ids stay untargetable and id misses report the normalized
`#id` (leading zeros stripped, e.g. `09281` → `#9281`), not the literal
typed string.

Updated [[commands/bot]] with the `<id|slug>` typeable command surface and
[[modules/bot]] with the split between slug-based callback payloads and
id-or-slug slash-command arguments.

## [2026-06-24T18:41:42Z] bot — suppress stale recovery markers during live retries

**Action:** `NotificationBuilders.build` now treats the live `action` as the
authoritative notification gate for `agent_running` and `archived` rows. If a
task lock makes status report `agent_running` while the state file still carries
a previous recovery marker such as `ERROR`, `REVIEW_ERROR`, `REVIEW_STALE`,
`REVIEW_CI_STALE`, or `EXECUTE_STALE`, the bot returns no notification and logs
`notification_skipped_live_agent` with project, slug, stage, marker, and action.
The event was added to `Hive::Bot::Logger::EVENTS` and the additive
`hive-bot-log.v2` enum.

`NotificationDispatcher` now also reads live `agent_running` identities from the
raw status rows before building notifications. Stored recovery alerts whose
project/slug/stage is currently live are held instead of being turned into a
premature "Recovered" message; if the retry fails the original stuck alert
dedupes, and if it succeeds the normal recovered confirmation fires after the
live identity disappears.

**Tests:** Added `notification_builders_test` coverage for the #9281
`agent_running` + `error` regression fixture, the parameterized recovery
markers under `agent_running` (`review_stale`, `execute_stale`, `review_error`,
`review_ci_stale`; the `error` marker is covered by its own case), an archived
`error` row, unchanged `error` / `recover_execute` / `recover_review`
notifications, and suppression logging. Added `notification_dispatcher_test`
lifecycle coverage for live retry holds, retry failure dedupe, retry success
recovery confirmation, the cross-layer agent_running contract (builder suppress
+ dispatcher hold), identity-scoped holds (a different slug does not hold an
unrelated recovery), the archived-vs-agent_running asymmetry (archived can fire
Recovered), `absent_since` continuity during a hold, and skip-event logging
across the held retry lifecycle.

## [2026-06-24T18:14:29Z] bot - structured bot log severity and noise controls

**Action:** Bumped `Hive::Bot::Logger` to `hive-bot-log.v3` with required
`level`, optional `category`, and the new `poll_unhealthy` event while keeping
`hive-bot-log.v1` and `hive-bot-log.v2` for historical lines. Added
`Hive::Bot::PollHealth` so benign Telegram long-poll transport failures remain
visible as `poll_failure` but at `debug`/`noise`, with a single loud
`poll_unhealthy` warning when the poll loop stays unhealthy. `NotificationDispatcher`
now emits `notification_skipped_dedupe` and `notification_skipped_backoff` only
when an active fingerprint enters that skip state, when its fingerprint changes,
or after it leaves and returns.

**Tests:** Added focused logger, poll-health, Telegram polling, and notification
dispatcher coverage for severity defaults, v2 back-compat, info-stream noise
filtering, benign-vs-real poll failures, once-per-outage escalation, and
transition-only skip logging.

**Refreshed pages:**
- [[modules/bot]]
- [[commands/bot]]

---
date: 2026-06-24T17:40:08Z
slug: babysitter-gh-binary-argv
pages: [modules/babysitter, testing]
---

## babysitter - normalize gh stub argv before classification

`bin/hive-babysitter-stub-gh` now mirrors the git dry-run stub by converting
`ARGV` entries to binary strings before any regex-based classification. A
malformed external-host `gh api` operand such as an invalid/non-UTF-8 URL now
falls through the default-deny skip path, writes the dry-run audit log, and
prints the skipped command without an `ArgumentError` backtrace.

Added focused `test/unit/babysitter/dry_run_env_test.rb` coverage for the gh
invalid-argv skip path and refreshed [[modules/babysitter]] / [[testing]].

## [2026-06-24T17:28:41Z] wiki — refresh v0.3.1 release and workflow-engine coverage

**Action:** Refreshed high-level architecture, release/install, dependency, active-area, and gap coverage after commit `9efbca2a` prepared `0.3.1` and commit `9ca14ae0` updated the root dev/test bundle plus web fixture task creation. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], and recent compiled [[log]] entries first. Searched the configured exact `main_wiki_path` (`/home/asterio/wikis/master/wiki`) and checked the default cross-project wiki paths; only the configured master path existed, and the search found no Hive-specific release/workflow guidance beyond a generic debt-tracker index hit. `qmd search "hive custom workflow 0.3.1 release install changelog"` surfaced older release-wiki history, so verification used the clean working tree, recent git history, the top release-prep diff, and direct reads of `README.md`, `CHANGELOG.md`, `docs/RELEASING.md`, `install.md`, `lib/hive.rb`, `Gemfile.lock`, `web/Gemfile.lock`, `Gemfile`, and affected wiki pages.

Documented that the current checkout is `0.3.1`, both root and web lockfiles pin `hive-cli (0.3.1)`, the public installer snippets now point at `v0.3.1`, and `docs/RELEASING.md`'s release-prep summary explicitly requires syncing both lockfiles because hivebox depends on the gem through `path: ".."`. Updated the project overview language to match the README's agent workflow engine/meta-harness positioning and to foreground descriptor-backed custom workflows, `hive workflow new --template`, and `hive init --new-workflow`. Recorded the remaining uncertainty: no in-tree artifact proves `packaging/verify-release.sh --version=v0.3.1`, a published `v0.3.1` GitHub Release, Homebrew/AUR updates, or a `ghcr.io/ivankuznetsov/hivebox:0.3.1` image. Page count stayed 84, so [[index]] needed only metadata/summary refresh, not a page-list change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[index]]
- [[commands/workflow]]
- [[dependencies]]
- [[operating]]
- [[active-areas]]
- [[gaps]]

## babysitter - close relative real-binary dry-run handoff

**Action:** Hardened `Hive::Babysitter::DryRunEnv.which` to return absolute realpaths for resolved `git` / `gh` binaries, even when the matching PATH entry is relative. The shared `git` and `gh` dry-run stubs now exit 127 when `HIVE_BABYSITTER_REAL_GIT` or `HIVE_BABYSITTER_REAL_GH` is unset or non-absolute, so a handoff like `bin/git` cannot be re-resolved after the agent cwd changes to the PR worktree.

**Coverage:** Added `test_with_env_canonicalizes_relative_path_real_binaries_before_agent_cwd_changes` with parent/worktree `bin` directories and fake worktree `bin/git` / `bin/gh` executables, plus `test_stubs_refuse_relative_real_binary_paths` for direct shared-stub invocation.

**Verification:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb -n '/relative_real_binary|canonicalizes_relative_path/'`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git bin/hive-babysitter-stub-gh lib/hive/babysitter/dry_run_env.rb test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]], [[gaps]]

---
date: 2026-06-23T18:23:56Z
slug: workflow-selection-first-class
pages: [commands/init, commands/web]
---

## init/web — workflow selection is a setup step

`hive init` now renders the TTY workflow chooser as an explicit `Workflow:`
step and includes an inline `author a new workflow` entry. The author entry
prompts for an id, re-prompts on reserved, invalid, or colliding ids, and then
routes through the existing `--new-workflow` scaffold/bind path so the full
setup questionnaire still runs on fresh init.

Hivebox `/repos/new` now has a select-only Workflow control. Fresh setup lists
the built-ins (`coding`, `content`) with `coding` selected; re-run setup lists
built-ins plus project-authored workflows and preselects the project's current
`default_workflow`. The selected value is passed to
`Hive::Commands::Init.new(..., workflow:)`, leaving the `prompts:` answers hash
unchanged.

Updated [[commands/init]] and [[commands/web]]. Coverage now includes CLI
prompt selection, non-TTY skip, inline authoring/re-prompt cases, request-level
web posting, and a Capybara Playwright setup flow that writes real
`config.yml`.

## hive workflow new --template (sample workflow seeds)

`hive workflow new ID` previously always scaffolded the bare `blank`
inbox->work->done stub with a placeholder `work.md`. Generalized the scaffolder
to named templates: a template is a directory under `templates/workflows/`
carrying `descriptor.yml.erb` plus one `.md` instruction per agent stage. The
new `--template NAME` flag seeds from a sample instead of the stub — the
descriptor is rendered with the user's ID and every stage instruction is copied
verbatim (real content, not "Edit this file").

Shipped two samples: `writing` (inbox->research->draft->edit->done) and
`research` (inbox->gather->synthesize->report->done). Unknown templates are a
USAGE error listing the available names (also in the `--json` `expected`
array). The blank default, `hive init --new-workflow` (which shares the
scaffolder), and the `hive-workflow-new` JSON schema (single `instruction_path`
= the first stage's instruction) are unchanged. Multi-stage templates print
`edit: <id>/ (N stage instructions to fill in)` pointing at the directory.

Refreshed [[commands/workflow]].

## [2026-06-23T07:02:43Z] execute/status — quota walls now park on cooldown

**Action:** `4-execute` now preserves provider quota walls as
`ERROR reason=limits_reached provider=<execute-agent> message="implementer hit a usage/credit limit" retry_after=<iso8601>`
instead of collapsing them into `reason=implementer_failed`. The runner checks
the implementation result's raw `limit_text` first and then the formatted
`error_message`, writes the shared `Hive::AgentLimit.retry_after` cooldown stamp,
and leaves non-limit implementation failures on the existing
`implementer_failed` marker shape.

`Hive::AgentLimit` now owns quota-held rendering helpers used by text status,
JSON status, and the TUI. Human/TUI rows render `held: agent quota (...) —
retry after ... UTC; top up or switch execute agent`; JSON rows add
`held: {reason: quota, provider: ..., retry_after: ...}` without overloading
dependency `blocked_by`.

**Tests:** Added execute unit coverage for quota detection via `error_message`
and raw `limit_text`, plus the non-limit marker invariant. Added
`AgentLimit` held-helper coverage, status text/JSON coverage, and TUI
`ERROR` / `REVIEW_ERROR` held-label coverage. Added status-schema coverage for
the optional `held` object so `Snapshot::Row` and `hive-status.v4.json` stay
aligned. Re-ran
`test/unit/daemon/stale_agent_healer_test.rb`, whose existing terminal
`limits_reached` tests cover `4-execute` cooldown hold/retry behavior.

**Follow-ups:** The provider's literal wall-clock reset time and a
provider-level circuit breaker remain separate follow-up tasks; this change
continues using the existing fixed cooldown contract.

## [2026-06-23T04:44:31+01:00] init — harden `--new-workflow` rollback, binding durability, and YAML safety

**Action:** Review fix-pass on the `hive init --new-workflow` feature:
- The fresh path now commits `config.yml` alongside the descriptor on `hive/state`, so the `default_workflow` binding is durable against a hive-state `reset --hard`/`clean` — symmetric with the existing-project path.
- The existing-project rollback now resets the `.hive-state` index for the scaffold pathspecs after a commit failure (`Init#reset_hive_state_index`), so a half-rolled-back rebind can no longer ride the next unrelated bare `git commit`.
- `default_workflow` is now emitted quoted (`default_workflow: "ID"`) in both the template and `write_default_workflow!`, so keyword-like ids (`yes`/`on`/`null`/…) are not coerced to booleans/nil by `YAML.safe_load`.
- Human next-step hints shell-escape the project basename; the `--workflow`/`--new-workflow` mutual-exclusivity check now runs before the clean-tree check for a clearer error.
- Internal cleanups: collapsed the `WorkflowDescriptorRef` stand-in (the existing path now carries the real resolved descriptor), extracted a shared `Workflow.commit_workflow_scaffold` helper, promoted the stateless `Workflow` scaffold helpers to class methods, and added a cleanup-failure warning to `rollback_scaffold`.

**Refreshed pages:**
- [[commands/init]]

## 2026-06-23 - Workflow option help advertises project-authored workflows

- Updated the Thor `--workflow` help for `hive init` and `hive new` to list the
  built-in workflow names and explicitly state that project-authored workflows
  are also valid.
- Both commands share the same `Hive::CLI.workflow_option_desc` helper, leaving
  one future seam for any dynamic, project-aware help rendering.

## [2026-06-23T03:05:29+01:00] init — scaffold and bind custom workflows

**Action:** Added `hive init --new-workflow ID [PROJECT_PATH]` to document the single-command custom workflow bootstrap: init scaffolds the same project-authored descriptor and `work.md` instruction as [[commands/workflow]], binds `default_workflow: ID`, prints the edit paths, and leaves flag-less `hive new` routing through the custom descriptor. Documented mutual exclusivity with `--workflow`, reserved built-in id rejection, already-initialized scaffold+rebind behavior, and the optional `descriptor_path` / `instruction_path` fields on `hive-init.v1`.

**Refreshed pages:**
- [[commands/init]]
- [[commands/workflow]]

---
date: 2026-06-23
slug: init-workflow-authoring-hints
pages: [commands/init]
---

Added the `hive init` discovery surface for project-authored workflows.
Fresh coding-default projects with no descriptors now show a single human
summary tip for `hive workflow new <id>`, while `hive init --json` emits a
required `hints` array containing the same pointer. Non-coding defaults or
projects that already have descriptors suppress the tip and emit `hints: []`.

Updated [[commands/init]] with the new `hive-init.v1` payload key and the
focused integration/schema coverage that keeps the producer and schema in
lockstep.

## workflow - bare subcommand usage errors

**Action:** Routed bare `hive workflow` through the command body instead of
Thor's required-argument check. The command now emits
`hive workflow: missing SUBCOMMAND (expected: new)` in human mode and a
`hive-workflow-new` usage envelope with `expected: ["new"]` in JSON mode; the
unknown-subcommand envelope keeps `value` and also reports `expected`.

**Tests:** Added focused command coverage and wrapper integration coverage for
bare human/JSON usage errors, unknown JSON extras, and published schema
validation for the new `expected` field.

**Pages:** [[commands/workflow]]

---
timestamp: 2026-06-23T12:00:00Z
slug: web-create-task-collision-retry
tags: [testing, web, ci]
---

Documented the web test helper's retry behavior for rare generated task slug
collisions and the before/after child comparison used to identify newly created
fixture tasks.

---
date: 2026-06-22
slug: drop-numeric-id
pages: [commands/drop, modules/task_resolver]
---

`hive drop` now treats an all-digits target as a task id and routes it through
`Hive::TaskResolver`, matching the existing `run`/`approve`/`findings` target
semantics. The command still uses its bespoke slug context for bare slugs so the
lock-held active/archive snapshot and cleanup context stay unchanged.

Added integration coverage for successful `drop <id>`, unknown-id JSON errors
using the resolver's `"no task folder for id <id>"` message, and duplicate-id
ambiguity across projects with `--project` disambiguating the selected task.

---
date: 2026-06-22
slug: kind-routed-task-action
pages: [modules/task_action, modules/workflows]
---

Retired the production `TaskAction` coding stage-name case. Coding status
classification now routes through descriptor `kind:` values: execute,
review_council, and finalize use their runtime helpers directly, while coding
agent/inert stages read `Hive::Workflows::Coding::ACTION_DISPATCH` for the
stage-specific user-facing action keys that generic workflows do not share.

Relabeled the coding descriptor's execute, open-pr, review, artifacts, and
finalize stages away from the legacy `:marker` kind and removed `:marker` from
`Hive::Workflow::KNOWN_KINDS`. A test-only parity harness keeps comparing the
retired case table against the production kind path across coding markers,
diagnostics, and command strings.

---
date: 2026-06-22
slug: new-wrapper-option-lift
pages: [cli, commands/new, testing]
---

Fixed the `bin/hive` wrapper path for `hive new` so standalone allow-listed
options are lifted out of the task text no matter where they appear in argv.
The canonical workflow-authoring command now works as printed:
`hive new PROJECT --workflow ID "<your idea>"` pins the task workflow instead
of capturing `--workflow ID` into `idea.md`.

The allow-list is intentionally closed: `--workflow`, `--depends-on`, and JSON
booleans are lifted, including `--name=value` forms for the value-taking
options. Remaining positionals are rebuilt as `PROJECT -- TEXT...`, preserving
literal `--help`, unsupported `--json=...`, unrecognized `--foo`, explicit `--`
tails, and quoted strings that merely contain `--workflow`.

Added `test/integration/new_wrapper_argv_test.rb`, which drives the real
`bin/hive` subprocess against on-disk project workflows, plus refreshed the
older wrapper test that previously asserted the swallowed-`--workflow` bug.
Updated [[cli]], [[commands/new]], and [[testing]] to describe the new wrapper
contract.

Review follow-up: hardened the value-option branch so a trailing or value-less
`--workflow`/`--depends-on` no longer consumes the next token. The value is only
lifted when it exists and is not option-like; otherwise the bare option drops to
the literal-text tail, fixing the regression where `hive new proj idea --depends-on`
mis-bound PROJECT to the idea text. Added coverage for the trailing value-less
case, the `--depends-on=42` equals form, and a literal `--` tail, and refreshed
gap #29 in [[gaps]] to point at the lift-and-rebuild contract.

---
date: 2026-06-22
slug: worktree-placeholder-either-ref
pages: [modules/worktree, testing]
---

Review-fix pass 02 on the dependency-stacking branch, two findings.

`empty_placeholder?` no longer picks a single base ref (origin-when-present,
else local). Pass 01's origin-first basis fixed the origin-ahead-of-local case
but left the inverse open: a placeholder created by `freshest_base`'s
fetch-failure fallback from a *local* default that runs ahead of a *stale*
origin sits ahead of `origin/<default>`, so the origin-only measurement counted
the local-ahead commit and misread the empty placeholder as carrying work —
collapsing stacking again. The check now measures against **both**
`origin/<default>` (when its tracking ref exists) and local `<default>`, and
treats the branch as empty when it carries no unique commits beyond **either**
ref (brainstorm A1: "no unique commits vs EITHER"). The real-work and
fail-closed guarantees hold: a branch is deleted only on positive proof of
emptiness (some ref measures zero); a git error skips that ref rather than
counting as proof, and if no default ref is measurable the branch is preserved
and warned. Candidate refs are gathered in a new `default_base_refs` helper.

`override_local_or_default` now returns `refs/heads/<branch>` for the local
stacked start-point instead of the bare branch name, so a same-named tag
(`refs/tags/<branch>`) can no longer shadow the branch through gitrevisions
precedence. The local ref is already verified to exist by
`local_branch_ref_exists?`, so the fully-qualified form is unambiguous with no
downside; the human-readable warning still names the bare branch.

New regression in [[testing]]: `test_repoints_empty_placeholder_when_local_ahead_of_origin`
(inverse of the pass-01 origin-ahead test) — a placeholder at local master with
a lagging origin is re-pointed onto `origin/<prereq>` instead of preserved.
Verified to fail against pre-fix code. Refreshed [[modules/worktree]] for the
either-ref measurement basis.

Verification on this branch:

- `ruby -Itest -Ilib test/unit/worktree_test.rb` (29 runs, 0 failures)
- `bundle exec rubocop lib/hive/worktree.rb test/unit/worktree_test.rb`

---
date: 2026-06-22
slug: worktree-placeholder-origin-measure
pages: [modules/worktree, modules/task_dependencies, testing]
---

Review-fix pass on the dependency-stacking branch. The empty-placeholder check
(`empty_placeholder?`) previously measured `git rev-list --count
<local-default>..<branch>`, which silently defeated the re-point fix: a
placeholder created by a prior run from `origin/<default>` (via
`freshest_base`) sits ahead of a lagging local default, so the local-ref
measurement counted the origin-ahead commits, misread the empty placeholder as
carrying real work, and collapsed stacking onto the stale base. The check now
measures against `origin/<default>` when its tracking ref exists, falling back
to local `<default>` only when absent. A rev-list error is now fail-closed
*and* warned (it used to fold into "not a placeholder" silently), and
`override_local_or_default` now carries the distinguishing reason (no origin /
fetch failed / ref missing) into its warning instead of always claiming
`origin/<branch> unavailable`, with the shared default-fallback tail moved into
the helper. `delete_local_branch!` appends a checked-out-elsewhere remediation
hint.

New regressions in [[testing]]: origin-ahead-of-local placeholder re-point
(locks in the measurement-basis fix), fail-closed preservation when the
emptiness check errors, and the `local_branch_ref_exists?` blank-name guard;
the delete-failure test now also asserts git's underlying reason survives in
the message. Refreshed [[modules/worktree]] and [[modules/task_dependencies]]
for the origin-first measurement basis (framed as a heuristic distinct from the
origin→local→default recreate base).

Verification on this branch:

- `bundle exec ruby -Itest test/unit/worktree_test.rb`
- `bundle exec rubocop lib/hive/worktree.rb test/unit/worktree_test.rb`

## Screenote connect/MCP hardening (review pass 02) — 2026-06-22

Applied the 6-review pass-02 findings on the Screenote OAuth/MCP integration:

- **MCP tool-channel errors surface.** `McpClient#call_tool` now raises a typed
  `Hive::Error` (joined `content` text) on a 2xx whose `result` is
  `{"isError":true,…}`, instead of letting `list_projects` fall through to `[]`
  (and `connect` raise the wrong "create a project" remedy) or a failed upload
  read as success. `extract_projects` guards a non-Hash `result` (no more
  untyped `TypeError`).
- **SSE replies parse.** `call_tool` de-frames a `text/event-stream` body
  (`data:` lines) so a spec-compliant Streamable-HTTP server no longer breaks
  with "unparseable response". JSON-object parsing is shared via
  `Hive::Screenote::Http.parse_json_object` (OAuth keeps the empty-body→`{}`
  guard).
- **`connect` no longer abandons a live token.** Any post-`exchange_code`
  failure (project listing/selection/payload/`save`) best-effort revokes the
  fresh bearer before re-raising; an OS-level `save` failure maps to a typed
  error with the path; the loopback socket closes on an early raise.
- **`--json` is machine-usable.** `connect`/`disconnect` emit a structured
  `{ "ok": false, … }` error envelope on failure; under `--json`, `connect`
  auto-selects a lone project and emits a `needs_project_selection` envelope for
  several (no human prose on the JSON stream, no silent default).
- **Artifacts fail-soft is visible.** `screenote_context` skips now `warn` why
  no upload happened; the MCP-config write rescue covers `Hive::ConfigError`
  too; ephemeral-config cleanup failures warn.
- Doc/comment fixes: `disconnect` `reason` no longer claims an "already-revoked"
  case RFC 7009 can't emit; `config.rb` names the real `load_global_screenote`
  owner.

## [2026-06-22T12:05:21Z] commands/screenote — OAuth 2.1 + MCP artifact uploads

Replaced Screenote API-key REST uploads with OAuth 2.1 and MCP-backed artifact
uploads. `hive connect screenote` now handles auth-code + PKCE setup, dynamic
client registration, MCP project selection, and mode-0600 credential storage in
`screenote.json`; `hive disconnect screenote` revokes and clears the stored
token. `screenote.api_token` and `HIVE_SCREENOTE_API_TOKEN` are obsolete and
user configs that still set the YAML key get a migration error.

The `7-artifacts` stage no longer mutates `media/manifest.json` after the agent
exits. Claude-backed runs with a valid Screenote credential receive a strict
ephemeral MCP config and allowed Screenote MCP tools; disconnected/expired
credentials remain fail-soft and ask the agent to write local media plus
`screenote_skipped_reason`.

Updated [[commands/screenote]], [[stages/artifacts]], [[modules/config]],
[[dependencies]], [[testing]], and [[gaps]]. The live Screenote capture test is
still gated on the Screenote non-interactive test-token endpoint becoming
available.

## [2026-06-22T12:00:00Z] review — harden no-fix suppression fingerprint + protection

**Action:** Review-pass fixes to `Hive::Stages::Review::Suppression` and its wiring. The fingerprint now extracts/strips file refs **before** the title/justification `": "` split, so a reviewer line shaped `file:line: description` no longer collapses to just the filename — distinct findings on the same file keep distinct keys (the plan's "different-title re-loops" guarantee held only by accident before). Other hardening: `reviews/suppressed.md` is now SHA-protected during the **triage** spawn too (triage-local `TRIAGE_PROTECTED_FILES`, not a mutation of the shared `ORCHESTRATOR_OWNED`), closing U3/A4; a present-but-unreadable suppressed doc makes mutation paths warn-and-skip instead of clobbering operator-edited tombstones (ENOENT stays the silent first-run case); an unreadable reviewer file warns-and-skips rather than aborting the pass; `clean_finding_text` strips **all** HTML comments globally (a mid-text comment no longer swallows the visible text between two comments); the severity enum is unified onto one canonical `SEVERITY_ORDER` (labels/titles derived, `parse_section` recognizes the rendered `## Unknown`, `normalize_severity` clamps out-of-enum severities, `split_entry_severity` only treats known severities as inline); and the degraded HEAD-fallback compare base is surfaced as an explicit per-pass warning (`reviewer_compare_base_sha` now returns `ReviewerCompareBase{sha, degraded}`).

**Tests:** Added unit coverage for the `file:line: description` non-collision (M1 regression), seed↔strip cross-shape key identity at drifted lines, `## Unknown` heading recognition, fenced-code-block fence-skip in seed and strip, first-pass provenance surviving a later-pass strip, out-of-enum inline severity surviving a rewrite, append-skips-on-unreadable, and the `reviewer_compare_base_sha` resolve / HEAD-fallback / unresolved-token contract. Strengthened the High-escalation integration test to assert the finding reached triage unstripped, and the different-title test to assert the prior seed is still live at pass 2.

**Docs:** Updated [[state-model]] and [[modules/protected_files]].

---
date: 2026-06-22
slug: worktree-dependency-stacking
pages: [modules/worktree, modules/task_dependencies, testing, gaps]
---

Fixed and documented dependency-stacked worktree creation when a dependent task
already has an empty placeholder branch. `Hive::Worktree#create!` now preserves
existing branches with real commits, but deletes a zero-commit placeholder
measured against the default branch when a non-empty stacked override is
present, then recreates the task branch through the normal base-resolution path.
`freshest_override_base` now resolves stacked bases as `origin/<prereq>` then
local `refs/heads/<prereq>` before falling back to the default branch.

Refreshed [[modules/worktree]] and [[modules/task_dependencies]] for the new
origin/local/default base order and placeholder handling, and refreshed
[[testing]] for the focused worktree regressions. Updated [[gaps]] with the
branch-creator investigation: no separate in-`lib/` normal task-branch
pre-creator was found; the leading cause is a stale placeholder branch left by
a prior collapsed execute attempt.

Verification on this branch:

- `bundle exec ruby -Itest test/unit/worktree_test.rb`
- `bundle exec rake test`
- `bundle exec rake coverage`
- `bundle exec rubocop lib/hive/worktree.rb test/unit/worktree_test.rb`

## [2026-06-22T09:19:22Z] review — suppress re-emitted triage no-fix findings

**Action:** Added `Hive::Stages::Review::Suppression`, a base-SHA-bound `reviews/suppressed.md` artifact, and review-loop wiring that strips active suppressions before triage and seeds new suppressions from checked `RESOLVED/NO-FIX:` triage lines. The fingerprint is intentionally loose (`severity + normalized file refs + normalized title`, with line numbers and body/justification excluded) so a no-fix finding re-emitted on the next pass does not re-enter triage. `suppressed.md` is operator-visible, hand-editable, classified as orchestrator-owned, and included in the fix protected-file snapshot.

**Tests:** Added unit coverage for fingerprint normalization, base reset, active-key parsing, deduped append, strip, and seed behavior; added review-loop integration coverage for post-fix convergence by pass 2, High escalation staying unsuppressed, different-title non-suppression, and fix-agent tampering of `reviews/suppressed.md`.

**Docs:** Updated [[stages/review]], [[state-model]], [[modules/protected_files]], and [[testing]].

## permissions - review-pass fixes for per-stage scopes

**Action:** Hardened the per-stage `permissions:` feature after code review.

- **`scoped` no longer denies the tools it grants.** `PermissionScope.scoped_scope`
  derived its deny list as the full `READ_ONLY_DISALLOWED` set regardless of the
  granted `tools:`/`bash:`, so a `scoped tools: [Read, Write, Edit]` (or
  `bash: true`) put the granted tool in BOTH `--allowedTools` and
  `--disallowedTools`; Claude's deny rules win, silently revoking the grant. Now
  `disallowed = READ_ONLY_DISALLOWED - allowed`, so the lists never overlap.
- **A8 runner-gate failures attribute an `:error` marker.** The runner-support
  gate fires inside `PermissionScope.resolve` — a non-yolo scope on a non-claude
  runner (codex/pi) raises `Hive::ConfigError` there. Every single-agent stage
  now resolves its scope through `Stages::Base.stage_permission_scope_or_mark!`,
  which stamps `:error reason=permission_config_error` on the stage's own task
  before re-raising — mirroring `Review.run!`'s ConfigError rescue. Previously a
  non-yolo scope on codex/pi escaped uncaught and left a stale `AGENT_WORKING`.
- **`review.permissions` is rejected at load.** A bare `review:` permissions key
  was validated then silently ignored (every review sub-stage fell back to the
  project default) — a fail-OPEN downgrade. `permission_entries` shape-validates
  a superset of the resolved locations (it cannot enumerate exactly the resolved
  set — generic stage names aren't known at load) and
  `reject_unsupported_review_permissions!` fails closed.
- **`tool_csv` dedups** (first-occurrence order) so repeated `tools:` entries
  can't reach Claude's argv twice.
- Removed dead `BrainstormTmux.wrapper_command` and the dead re-validation in
  `resolve_dirs`; co-located `permission_spec` with `permission_at` /
  `MISSING_PERMISSION`; extracted the `YOLO` preset constant.

**Verification:** Unit tests now pin the scoped allow∩deny disjointness invariant,
the codex/pi attributed-marker path (helper + `Execute.spawn_implementation` e2e),
the reviewer `permissions:` resolution-into-spawn path, a per-stage/per-mode yolo
argv golden, and the `review.permissions` load rejection. The live smoke
`test/smoke/permission_scope_headless_smoke_test.rb` now also proves a `scoped`
agent with `Write` granted actually creates the file.

**Pages:** [[modules/config]], [[modules/agent]], [[stages/index]]

## [2026-06-21T12:15:41Z] babysitter — skip PRs owned by an active pipeline task

**Action:** Closed the babysitter-vs-pipeline rebase race that left patrol
finalize tasks looping on `:error reason=unpushed_commits`.

Root cause: a patrol PR is opened as a draft (so the babysitter's `isDraft`
skip protects it through review), but `8-finalize` runs `gh pr ready` to
un-draft it before merge (the merge is external — `PrMergeWatcher` only watches
for `MERGED`). Once ready, the babysitter's `select_prs` — which filtered only
on `isDraft`, labels, and inflight — treated it as a normal open PR and rebased
+ force-pushed its branch onto the advanced `main`, while the patrol task's own
worktree stayed pinned to its old base. Finalize's push gate then saw genuine
bidirectional divergence (remote has a main commit not in HEAD; HEAD has local
fix commits not on the remote), refused to force-push, and looped on
`unpushed_commits`.

Fix: `Hive::Babysitter::ProjectTick` now consults hive-state (the `hive/state`
branch — the git source of truth for ownership) instead of relying on the
GitHub draft flag. `pipeline_owned_branches` collects the `worktree.yml`
`branch` of every task in a non-terminal stage (`Hive::Stages::DIRS` filtered by
`Hive::Workflows.verb_advancing_from`, so the done stage is excluded and no
stage literal is hardcoded — respects the stage-literal guard). `select_prs`
skips any PR whose `headRefName` is in that set, ahead of the draft check,
emitting the new `Events` outcome `pipeline_owned`. A missing/malformed
`worktree.yml` is skipped so one bad task never aborts the scan, and a
done-stage task no longer shields its branch.

Tests: `test/unit/babysitter/project_tick_test.rb` — owned-active-task skip
(non-draft, with a pre-execute task that contributes no branch), done-stage task
not protected, and malformed pointer doesn't crash the scan. Full babysitter
suite (97) + rubocop green; new lib lines fully covered.

**Refreshed pages:**
- [[modules/babysitter]]

## [2026-06-21T12:00:00Z] e2e - classify dangling symlink replay repro as unusable

**Action:** Fixed `bin/hive-e2e replay` so a dangling `repro.sh` symlink falls through to the `lstat`-based check and reports `error_kind: "unusable_repro"` (exit `78`) instead of `missing_repro`. The `missing_repro` guard now also short-circuits on `File.symlink?`, since `File.exist?` follows the link and would otherwise misreport a present-but-broken artifact as missing. Added a dangling-symlink replay regression in `test/e2e/lib/hive_e2e_binary_test.rb` and refreshed [[e2e]] contract wording. Did not run `qmd update` or `qmd embed`.

## [2026-06-21T10:22:39Z] testing - hive-eval clears stale reports on usage errors

**Action:** Updated [[testing]] after fixing `bin/hive-eval` report lifecycle handling. Usage-error exits now remove the selected report path before returning `64`, including validation failures after `--report` has been parsed, so downstream readers cannot mistake a previous `hive-eval-report` JSON document for the failed invocation's output.

**Tests:** Added `test_cli_usage_error_removes_existing_selected_report` in `test/eval/support/reporter_test.rb` and verified `bundle exec ruby -Itest test/eval/support/reporter_test.rb`.

## [2026-06-21T10:11:17Z] e2e - reject symlinked replay repro artifacts

**Action:** Hardened `bin/hive-e2e replay` so `repro.sh` must be a regular executable directory entry before the no-shell `exec`; symlinks now report `error_kind: "unusable_repro"` with exit `78` instead of following the target. Added focused coverage in `test/e2e/lib/hive_e2e_binary_test.rb` for an executable symlinked repro and refreshed [[e2e]] / [[testing]] contract wording. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-21
slug: project-workflow-authoring
pages: [modules/workflows, commands/workflow, cli, testing]
---

Added project-authored workflow discovery and authoring. User descriptors now
live under `<hive_state_path>/workflows/*.yml`, parse through
`Hive::Workflows::DescriptorParser`, and register through a project overlay in
`Hive::Workflows::Registry` so `hive new --workflow`, `hive init --workflow`,
status scans, `hive run`, `hive approve`, and daemon-dispatched commands see
the active project's workflows.

Agent stages may carry either `skill:` or an owner-authored `instruction:`
file, and may include descriptor-level `permissions:` validated with
`Hive::PermissionScope`. Added `hive workflow new ID` to scaffold a blank
`inbox -> work -> done` workflow plus placeholder `work.md` instruction under
the state tree.

Updated [[modules/workflows]], [[commands/workflow]], [[cli]], and
[[testing]] with the new descriptor, command, and acceptance-test coverage.

## permissions - per-stage Claude tool scopes

**Action:** Added opt-in project and per-stage `permissions:` specs for Claude
spawns. `yolo` remains the default and preserves historical per-mode behavior;
`read-only` and `scoped` resolve through `Hive::PermissionScope` and feed
Claude `--allowedTools`, `--disallowedTools`, `--permission-mode default`, and
extra task-relative add-dirs.

**Implementation notes:** `Config.permission_spec` returns a full-replacement
stage spec or the project default. `Stages::Base.stage_permission_scope` is the
shared wiring point for bespoke coding stages, generic descriptor-backed agent
stages, and review helper/reviewer spawns. Non-yolo scopes fail closed on
non-Claude runners.

**Verification:** Unit tests cover resolver/config validation, headless/tmux
argv plumbing, stage-scope default preservation, and review spawn paths. The
live smoke `test/smoke/permission_scope_headless_smoke_test.rb` proves a
read-only headless write attempt completes without writing, while yolo writes.

**Pages:** [[modules/config]], [[modules/agent]], [[stages/index]]

## workflows - built-in content research workflow

**Action:** Added the built-in `:content` non-coding workflow descriptor and
registered it beside `:coding`. The descriptor uses an inert `inbox` stage for
`idea.md`, generic agent stages for research, outline, draft, critique, and a
terminal `done` agent that writes `article.md`.

**Tests:** Added descriptor-shape, per-stage generic-agent, and full daemon e2e
coverage for the content workflow. Updated registry and init prompt expectations
now that `content` is a built-in workflow choice.

**Docs:** Refreshed [[modules/workflows]] and [[testing]] to distinguish the
built-in `:content` workflow from the test-only `:content_fixture`.

## 2026-06-20 - U7 workflow selection write paths

- Added CLI-facing workflow selection documentation for `hive init --workflow` and `hive new --workflow`.
- Documented the test-only `content_fixture` workflow and deterministic agent helper used to prove generic surface rendering and daemon advancement.
- Updated testing coverage notes for init/new workflow pinning, mixed render proof, and the content daemon E2E.

## task-action - U4 review-pass 3 coverage + doc-formatting fixes

**Action:** Closed review-pass-3 test-coverage gaps and one doc-rendering bug for
the descriptor-generic classifier; no production behavior changed:
- Pinned the daemon-decision outcome of the markerless **inert entry** `:none` ->
  `ready_to_advance` row (`test_generic_inert_entry_none_dispatches_at_policy_decision_level`).
  This is the only generic path that auto-advances a stage with zero prior
  execution; the matrix test asserted its classification key but never ran a
  `policy_decision` on it, so a regression dropping `ready_to_advance` from
  `ADVANCE_ACTIONS` or widening the `:none` guard to non-entry stages would have
  stayed green.
- Pinned the generic stale-agent **orphaned-placeholder** branch
  (`test_generic_stale_agent_orphaned_placeholder_classifies_as_error`): a no-pid
  `AGENT_WORKING` marker past the grace window classifies as `:agent_orphaned` ->
  error, completing plan IU-4's "stale ⇒ error" coverage (the matrix test only
  covered the `pid_alive:false` / agent_died half).
- Pinned `ACTION_LABEL_ORDER` generic-label placement
  (`test_action_labels_sorts_generic_labels_above_error`): both "Ready to run" and
  "Ready to advance" must sort above "Error" via the live `action_labels` sorter,
  so dropping either entry can no longer silently sink generic rows below "Error".
- Fixed the `[[modules/task_action]]` action-map table: the `generic_ready_to_run`
  wire-format prose had been inserted mid-table, breaking the `agent_running` /
  `done` / `error` rows; moved it below the `error` row so the whole table renders.
- Flagged a forward-looking U5 gap in [[gaps]]: generic workflows have no
  dedicated stale/error resting-marker surface (the `generic_action` `else` arm
  classifies any unknown resting marker as "Ready to run" with no diagnostic).

**Verification:** `bundle exec ruby -Itest test/unit/task_action_generic_test.rb`
(15 runs), `test/unit/commands/status_test.rb`, `test/unit/daemon/policy_test.rb`,
`test/unit/schema_files_test.rb`, plus the TUI snapshot/tasks-pane suites that
consume `ACTION_LABEL_ORDER`; rubocop clean on the edited test files. The
requested Ruby↔JSON enum-parity test was already present
(`test_hive_status_task_enums_match_closed_sets` and
`test_hive_stage_action_next_action_key_enum_matches_task_action_kind` in
`schema_files_test.rb`), so no duplicate was added.

**Pages:** [[modules/task_action]], [[commands/status]], [[gaps]]

---
date: 2026-06-20
slug: u6-review-fixes
pages: [modules/stages, modules/workflows, modules/task, modules/task_action, stages/agent]
---

U6 review-pass fixes. Routed the daemon's post-advance state-file lookup
(`Dispatcher#find_post_advance_state_file`) and `stage_rank` through the runtime
union `Hive::Workflows.all_stage_dirs` instead of the coding-only
`Stages::DIRS`, so a generic `hive approve` into a non-coding dir (e.g.
`2-gather`) no longer strands the moved task's mtime baseline (the High #1 stall
surface). The generic `Stages::Agent` runner now consumes `spawn_agent`'s
`{status: :error}` preflight envelope and stamps an attributed `:error` marker
(NO-SILENT-CAPS) rather than re-classifying as `ready_to_run` forever.

Relaxed the published `hive-approve.v2` / `hive-run.v2` stage-name, stage-dir,
and stage-index fields from the closed coding enums to patterns (mirroring the
`hive-status.v4` precedent) so generic descriptor stages validate; no version
bump (backward-compatible widening).

Extracted `Hive::Workflows.resolve_stage_ref_across_workflows` (shared by
`TaskResolver` and `Drop`) and folded the three `hive <verb> <slug>` command
builders in `TaskAction` onto one `command_prefix` helper.

Corrected wiki drift: `Stages::Agent` resolves the stage via
`task.workflow.stage_named` (not `Registry.default`); `Stages`/`Workflows`
module headers and the `Status` legacy-dir detector now name the
`task.workflow` / `all_stage_dirs` seam; `TaskMeta.write` documents its
`workflow:` kwarg; the generic WAITING action is `generic_needs_input`.

## task-action - U4 review-pass accuracy/clarity fixes

**Action:** Tightened the descriptor-generic classifier docs and guards after
review pass 2:
- Reworded the `:none` entry fall-through (code comment + `[[modules/task_action]]`)
  from the `:agent`-only understatement to "any non-inert entry kind" — the gate
  is `stage.kind == :inert`, which excludes `:agent`, `:marker`, and `nil`.
- Documented the deliberate lossy merge: `generic_ready_to_run` and
  `generic_needs_input` share the `NEEDS_INPUT` key + `run` command, so the
  run-vs-input distinction survives only in the label, not on the JSON wire
  (intended per plan R3/Q2; daemon routing uses the mtime baseline, not the key).
- Recorded the U5-deferred behavior in code: a markerless generic stage stays at
  `:record_baseline` until a human edits the state file (no auto-dispatch yet).
- Added `"Ready to run"` and `"Ready to advance"` to `ACTION_LABEL_ORDER` in
  `Hive::Commands::Status` so generic rows sort with the actionable rows instead
  of below `"Error"`.

**Verification:** `bundle exec ruby -Itest test/unit/task_action_generic_test.rb`
plus the new `agent_entry_workflow` fixture that discriminates the `entry` and
`stage.kind == :inert` conjuncts of the `:none` advance guard in isolation.

**Pages:** [[modules/task_action]], [[commands/status]]

---
title: Task meta updates preserve workflow
date: 2026-06-20T11:15:28Z
area: task
---

## Task meta updates preserve workflow

`Hive::TaskMeta.write` now accepts an optional `workflow:` selector, and both
`update_display_name` and `update_id` preserve the existing selector when they
rewrite `meta.yml`. This prevents display-name generation or daemon id backfill
from silently dropping a task-level workflow override.

Updated [[modules/task]] and pinned the behavior in `test/unit/task_meta_test.rb`.

## workflow - U6 descriptor-routed stage literal consumers

**Action:** Routed the generic workflow daemon path and hardcoded stage-literal
consumers through descriptor-aware seams, while keeping coding-only behavior
explicit:
- Added `Hive::Workflow#has_stage?`, live `Hive::Workflows::Registry.all` /
  `.ids`, and `Hive::Workflows.all_stage_dirs` / `.all_stage_names` for
  descriptor-aware scans without changing coding's load-time constants.
- Added `workflow` to `hive status --json` task rows and preserved that field
  through daemon, bot, and TUI row mirrors so row-based consumers can guard
  coding-specific plan/brainstorm/review/finalize behavior.
- Relaxed CLI stage-ref parsing for `run` / `approve` to validate against the
  resolved task workflow, taught status and `TaskResolver` to scan the live
  descriptor stage-dir union, and gated bespoke runner name precedence to
  `descriptor.id == :coding` so non-coding name collisions route by descriptor
  kind.
- Split generic first-run action wiring so markerless generic agent stages emit
  `ready_to_run` and daemon policy can dispatch `hive run <slug>`, while
  generic `WAITING` markers still go through the edit/mtime debounce path.
- Added `test/unit/stage_literal_guard_test.rb`; every surviving hardcoded live
  stage literal under `lib/` must now be migrated or carry a same-line
  `# coding-scoped:` / `# not-a-stage-ref:` annotation with a reason.

**Literal triage summary:**

| Area | Mode | Result | Reason |
|------|------|--------|--------|
| Bot notification/status watcher/supervisor surfaces | stage identity/path | Guarded coding-scope plus `workflow` row field | Brainstorm answer buttons and plan-pause notifications are coding-only; generic waiting rows now get neutral details. |
| Daemon policy/healer | stage identity/argv | Guarded coding-scope plus descriptor dispatch | Plan auto-approval, review exclusion, finalize unpushed-commit retry, and coding plan rerun are coding-specific; generic `ready_to_run` / `ready_to_advance` dispatch through descriptor commands. |
| Status, task resolver, and CLI stage-ref gates | path/validation | Migrated | They scan `Hive::Workflows.all_stage_dirs` and validate stage refs against the resolved workflow or live registry. |
| Stages resolver and generic agent runner | runner dispatch | Migrated | Non-coding stage-name collisions route by descriptor kind and `Stages::Agent` resolves stage metadata from `task.workflow`. |
| Title formatter, TUI affordances, doctor/new/bench/patrol/reviewer/digest/core coding constants | labels/path/fixtures | Annotated coding-scoped | These are coding UI, diagnostics, task creation, review/PR, archive, or dependency-gate concepts. |
| Migration/recovery legacy maps and comments | legacy/docs | Annotated not-a-stage-ref | Historical remaps and examples are not live descriptor references. |

**Verification:** Characterization tests were added before the refactor, the
literal guard is green, and the new
`test/integration/generic_workflow_daemon_e2e_test.rb` drives a registered
generic workflow through status -> daemon policy -> `hive run` -> `hive approve`
for two stage hops while a coding task in the same project keeps its coding
dispatch path.

**Pages:** [[modules/workflows]], [[modules/task_action]], [[modules/daemon]],
[[commands/status]], [[gaps]]

## [2026-06-20T10:07:48Z] daemon — assign ids to tasks created outside `hive new`

**Action:** Added `Hive::Daemon::TaskIdBackfiller`
(`lib/hive/daemon/task_id_backfiller.rb`), a tick-time self-healer that assigns
a task id to any task whose `meta.yml` has none. `hive new` allocates ids from
`Hive::TaskCounter`, but a task created by hand (`mkdir` + `idea.md`, or one
`mv`-ed into a stage folder) never goes through that path and shows a blank id
in the TUI, `hive status`, the digest, and dependency references.

On each tick the dispatcher now runs the new backfiller right after the
display-name backfiller: for any status row whose `Hive::TaskMeta` `id` is nil
it allocates `TaskCounter.next!`, writes it via the new
`Hive::TaskMeta.update_id` (preserving slug / display_name / depends_on), and
commits the meta on `hive/state` **under the per-project commit lock**
(`Hive::Lock.with_commit_lock`, as every durable `hive_commit` caller does, so
the commit can't interleave with a dispatched child's and cross-contaminate the
audit history or collide on `index.lock`). It is synchronous (id assignment is
instant, so no spawn/inflight tracking), bounded by `max_per_tick` (default 5),
and an assigned id is a natural fixed point — no churn once set. The
`task_id_backfill` event carries `committed:` so a swallowed commit (lock
timeout / git error) is visible rather than masquerading as fully durable.

Critical guard: `id_missing?` returns false unless `File.directory?(folder)`.
A status row can outlive its folder (`hive drop` between snapshot and tick);
since `TaskMeta.write` `mkdir_p`s the path, assigning an id to a vanished folder
would RESURRECT the dropped task (and, because the backfiller runs before
per-row dispatch, defeat the dispatcher's vanished-folder spawn guard). The
existence check skips it. Every per-row step is rescued and `#backfill` never
raises out of the tick. Built at startup and rebuilt on SIGHUP reload alongside
the other backfillers.

Added `test/unit/daemon/task_id_backfiller_test.rb` (assignment, field
preservation, already-has-id skip, dry_run, `max_per_tick`, nil allocation,
vanished-folder no-resurrection, no-raise-on-bad-row) and a `TaskMeta.update_id`
path. Full daemon suite (547 runs) + rubocop green.

**Refreshed pages:**
- [[modules/daemon]]

## [2026-06-20T09:49:58Z] babysitter — pin dry-run fixture Ruby shebangs

**Action:** Fixed the CI-only `rake coverage` failures in `test/unit/babysitter/dry_run_env_test.rb` after the git dry-run stub began pinning `PATH=/usr/bin:/bin` before passthrough. The generated fake `git` binaries used `#!/usr/bin/env ruby`, so on GitHub's Ubuntu runner they re-entered system Ruby 3.2.3 and inherited Bundler state for the Ruby 3.4 test process, producing `Bundler::RubyVersionMismatch` before the fixtures could record passthrough. The fixture generators now write `#!#{RbConfig.ruby}` so they keep using the test runner's Ruby even after the production stub pins PATH for helper safety.

**Coverage:** Updated [[testing]] to record that the dry-run fake binaries are pinned to the current test runner Ruby. This is test-harness isolation only; the production stub still pins PATH before execing the configured real git.

**Verification:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rake coverage`.

**Links:** [[testing]], [[modules/babysitter]]

## [2026-06-20T07:28:12Z] reviewers — normalize codex native `[Pn]` review output

**Action:** Fixed a recurring patrol `6-review` `reviewers/all_failed` regression
where `codex-native-review` rejected real findings because codex-cli (0.141.0)
ignored the prompt's `## High/Medium/Nit` GFM coercion and emitted its native
`codex review` format instead — a "No plan was found" preamble plus `[P1]/[P2]`
priority bullets. The parser's `SEVERITY_HEADER` check found no headers, failed,
and retried the same deterministic failure until the stage exited `all_failed`;
because patrol's only reviewer is `codex-native-review`, every patrol PR looped
on a full xhigh review (~7–10 min/pass) without ever advancing.

`lib/hive/reviewers/codex_review.rb` now classifies an answer carrying ≥1 native
`[Pn]` bullet (and no `## High/Medium/Nit` header) as `:findings`, and
`findings_markdown` normalizes it via `normalize_native_findings`: each
`- [P1] …` bullet becomes a `## High/Medium/Nit` checkbox (P1→High, P2→Medium,
P3+→Nit, per `NATIVE_SEVERITY`), the finding's indented justification is folded
onto its single line, repeated echoes are de-duplicated, and empty severities
still print their header + `No findings.` so triage's `- [ ]` parser consumes
the result. The GFM-findings, clean-verdict, template-echo, and error paths are
unchanged; a prose-described finding with no `[Pn]` tag still fails (not laundered
into a clean pass).

Distinct from the #512 fix (review timeouts/caps + the prompt-echo `all_failed`):
this is a codex-CLI output-format drift that retries could never resolve. Added
`test_native_priority_findings_are_normalized_to_gfm` and
`test_native_findings_are_deduplicated`.

**Refreshed pages:**
- [[modules/reviewers]]

## [2026-06-20T06:11:35Z] workflows - descriptor-aware generic advance routing

**Action:** U5 moved generic advance resolution into descriptor-aware command
paths: `Hive::Commands::Approve` now resolves `--to`, `--from`, forward
destinations, validation, payload stage fields, and text next-hints through
`task.workflow`; `Hive::Commands::Run#next_stage_dir` now emits approve actions
for the task workflow's actual next stage. Coding verb constants remain derived
from the default descriptor for legacy consumers.

**Docs:** Updated [[modules/task_action]] to distinguish post-U5 generic
advance routing from the still-deferred first-run generic auto-dispatch gap, and
retargeted the generic stale/error resting-marker gap as future descriptor
workflow work rather than U5 scope.

## task-action - descriptor-generic status classification

**Action:** Generalized `Hive::TaskAction` for descriptor-resolved non-coding
workflows while keeping the coding workflow on its existing stage-name case.
Added the `ready_to_advance` action kind and current schema enum entries,
emitting `hive approve <slug> --from <descriptor-stage-dir>` for generic
non-terminal `COMPLETE` rows and for a markerless (`:none`) inert entry stage
that is not also terminal. `Hive::Daemon::Policy` now treats
`ready_to_advance` as an advance action so generic COMPLETE rows reach
`:dispatch` at the decision layer. Added descriptor-generic tests plus a
coding action golden matrix.

**Verification:** Focused tests run locally:
`bundle exec ruby -Itest test/unit/task_action_test.rb`,
`bundle exec ruby -Itest test/unit/task_action_generic_test.rb`,
`bundle exec ruby -Itest test/unit/daemon/policy_test.rb`,
`bundle exec ruby -Itest test/unit/exit_codes_test.rb`, and
`bundle exec ruby -Itest test/unit/schema_files_test.rb`.

**Pages:** [[modules/task_action]], [[modules/daemon]], [[testing]]

## [2026-06-20T02:00:00Z] babysitter — resolve a bare real-git before pinning PATH

**Action:** Followed up the `PATH = "/usr/bin:/bin"` pin in `bin/hive-babysitter-stub-git` (see [[babysitter]]) so it does not break a command-name `HIVE_BABYSITTER_REAL_GIT`. The pin lands before `exec real`; when `real` is a bare name (the `real_git_env` test helper sets it to `"git"`) `exec` resolved it against the pinned `/usr/bin:/bin`, so on Nix/custom installs where git lives outside those dirs every allowlisted dry-run read failed. The stub now calls `resolve_real_git(real, ENV["PATH"])` to resolve a bare name against the *inherited* PATH before pinning, then execs the absolute path. A path-qualified value (contains `/`) is execed verbatim, and an unresolvable bare name falls through unchanged so the existing exec-failure handler still emits the exit-127 diagnostic. No security cost: the real-git binary is chosen by the trusted env var (not PATH), and the pin still guards git's own internal PATH-based helper resolution (`gpg.program=false`, etc.). Production is unaffected — `dry_run_env.rb`'s `which("git")` already passes a parent-resolved absolute path.

**Verification:** `ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (27 runs, 0 failures); `bundle exec rubocop bin/hive-babysitter-stub-git` (no offenses). Manually confirmed a bare `HIVE_BABYSITTER_REAL_GIT="git"` resolves to a custom-PATH git ahead of `/usr/bin:/bin`, and an unresolvable name still exits 127.

## [2026-06-20T01:00:00Z] babysitter — pin PATH so the gpg `false` no-op can't be hijacked

**Action:** Closed a PATH-resolution gap in `bin/hive-babysitter-stub-git`'s dry-run hardening. The `-c gpg.program=false` overrides (plus the `gpg.openpgp.program` / `gpg.x509.program` / `gpg.ssh.program` siblings) neutralize `%G*` signature verification only if git resolves the bare `false` from a trusted location — and git looks `false` up through `PATH`, which the pre-exec env scrub never sanitized. An agent invoking the overlay stub with a `PATH` whose leading directory holds its own `false` could turn the supposed no-op back into an exec seam whenever a config-resolved `%G` placeholder reached real git. The stub now pins `ENV["PATH"] = "/usr/bin:/bin"` alongside the other hermetic env controls before `exec`, so every `PATH` lookup git makes (the `false` no-op and any other helper) resolves from root-owned system dirs an unprivileged agent cannot write. `/usr/local/bin` is intentionally excluded — it is user-writable under Homebrew, which would reopen the same vector. Production is unaffected: `HIVE_BABYSITTER_REAL_GIT` is already a parent-resolved absolute path, so pinning `PATH` does not change how real git is located.

**Coverage:** Added `test_git_stub_pins_path_so_gpg_no_op_cannot_be_hijacked` to `test/unit/babysitter/dry_run_env_test.rb` — it configures `pretty.pwn=format:%G?` + `format.pretty=pwn` on the synthetic signed repo, plants a marker-writing `false` in a `PATH`-leading poison dir, and proves that poisoned `false` never runs for `log -1` and `show --pretty=pwn HEAD`. Confirmed the test fails (the poisoned `false` runs) when the `ENV["PATH"]` pin is stripped.

**Verification:** `ruby -Itest -Ilib test/unit/babysitter/dry_run_env_test.rb` (27 runs, 0 failures); `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb` (no offenses).

## [2026-06-20T00:00:00Z] babysitter — neutralize config-resolved `%G` signature exec seam

**Action:** Closed a residual gap in `bin/hive-babysitter-stub-git`'s dry-run signature hardening. The argv scan only blocks literal `%G` in argv, and `-c log.showSignature=false` only suppresses the implicit `--show-signature` — neither stops `%G*` pretty placeholders from running the configured gpg helper when the `%G` format arrives via repo config (a worktree-local `pretty.<name>=format:%G?` alias selected by `format.pretty=<name>` resolves to `%G?` even for a bare `git log` / `git log --pretty=<name>` / `git show --pretty=<name>`). The hermetic passthrough now also pins `gpg.program`, `gpg.openpgp.program`, `gpg.x509.program`, and `gpg.ssh.program` to `false`, so no attacker-configured helper runs no matter how the placeholder is reached. These `-c` overrides outrank the worktree's local config.

**Coverage:** Added `test_git_stub_disables_config_resolved_signature_format_before_passthrough` to `test/unit/babysitter/dry_run_env_test.rb` — it configures `pretty.pwn=format:%G?` + `format.pretty=pwn` on the synthetic signed repo and proves the configured `gpg.program` marker is never written for `log -1`, `log --pretty=pwn -1`, and `show --pretty=pwn HEAD`. Updated `expected_real_invocation` and the pinned-passthrough assertion to expect the new gpg-program `-c` keys. Confirmed the new test fails when the overrides are stripped.

**Verification:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (26 runs, 0 failures); `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb` (no offenses).

## [2026-06-19T23:17:59Z] task — workflow descriptor resolution

**Action:** Implemented U3 of the workflow-as-data inversion. `Hive::Workflow`
now exposes stage lookup helpers, `TaskMeta.read` surfaces a read-only
`workflow:` selector, and `Config::DEFAULTS` includes
`default_workflow: "coding"`. `Hive::Task` resolves a descriptor through
task selector -> project default -> coding, validates both stage name and
numeric prefix against that descriptor, and derives `state_file` from the
selected workflow. `Hive::Commands::Run#pick_runner` now passes
`task.workflow` to `Hive::Stages::Resolver`, so non-coding agent stages dispatch
through their own descriptor while field-less coding tasks keep historical
state-file paths and runners.

**Tests:** Added focused unit coverage for workflow lookups, meta selector
reads, default workflow config, descriptor-driven task validation/fallbacks,
unknown workflow reclassification as `InvalidTaskPath`, and run-path dispatch
using a throwaway research descriptor. Updated [[modules/task]],
[[state-model]], [[modules/config]], [[modules/workflows]], [[commands/run]],
and [[testing]].

---
date: 2026-06-19
slug: babysitter-gh-api-preview-host-gate
pages: [modules/babysitter, testing]
---

`bin/hive-babysitter-stub-gh`: `gh api -p <preview> https://host` bypassed the
new endpoint host check. `api_endpoint_host_override?` consumed the long
`--preview` value (it is in `API_ENDPOINT_VALUE_OPTIONS`) but the short `-p`
form was not in the value-taking short list `-H -X -F -f -q -t`. The scanner
treated `-p` as a no-value flag, stopped on the preview name, found it was not a
URL, and returned `false` — never inspecting the trailing external URL, so the
call reached real gh against an agent-chosen host.

Fix: added `p` to the short-option regex (`/\A-[HXFfqtp]/`) and to the
separate-value list (`-H -X -F -f -q -t -p`), matching how the other
value-taking shorts are consumed. The short list now covers every long
value-taking option that has a short equivalent
(`--field/-F`, `--header/-H`, `--jq/-q`, `--method/-X`, `--preview/-p`,
`--raw-field/-f`, `--template/-t`).

Whole-class check: the sibling scanners do not share this defect.
`api_read_only?`'s `else` branch only ever over-blocks when an unconsumed value
happens to match a payload flag (fail-safe), and `target_operands` serves
`repo view` / `pr view`, which have no `-p`. `api_endpoint_host_override?` was
the only under-blocking site.

Regression coverage in `test/unit/babysitter/dry_run_env_test.rb`: separate
short, glued short, and long preview forms in front of `https://evil.example.com`
must skip; the same forms against a default-host endpoint
(`repos/owner/repo`) must still reach real gh.

## [2026-06-19T22:21:14Z] babysitter - force no-pager for dry-run git passthrough

**Action:** Hardened `bin/hive-babysitter-stub-git` so allowlisted real-git passthrough always includes `--no-pager` and deletes plain `PAGER` alongside `GIT_PAGER`. Pager env/config remains non-fatal at the skip gate, but allowed reads no longer let TTY stdout trigger a caller- or repo-controlled pager.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with pager env scrubbing assertions and a PTY-backed `git log` regression where `PAGER`, `GIT_PAGER`, and repo-local `core.pager` point at a marker-writing helper. The helper must not run.

**Verified:** `ruby -c bin/hive-babysitter-stub-git`; `env -u GIT_EXEC_PATH -u GIT_EXTERNAL_DIFF -u GIT_SSH_COMMAND -u GIT_SSH -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_PROXY_COMMAND -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]]

## [2026-06-19T21:15:58Z] babysitter — block git signature helpers in dry-run stub

**Action:** Hardened `bin/hive-babysitter-stub-git` so dry-run allowlisted reads no longer execute configured GPG helpers through commit-signature display. The stub now skips `git log` / `git show` `--show-signature`, skips `log` / `show` / `rev-list` `--format` or `--pretty` values containing `%G`, and forces `log.showSignature=false` in the hermetic passthrough config before allowed reads reach real git.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with a synthetic signed commit and fake `gpg.program` marker. The tests prove signature argv is skipped before real git runs and that a repo-local `log.showSignature=true` config is neutralized during plain `git log` passthrough.

**Verification:** `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb -n '/signature/'`; `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.

---
date: 2026-06-19
slug: runner-resolver
pages: [commands/run, modules/workflows, stages/agent, testing]
---

Wired `hive run` stage dispatch through `Hive::Stages::Resolver`. The resolver
keeps coding stage names authoritative and lazy-requires their bespoke runners,
then falls back to the generic [[stages/agent]] runner for descriptor stages with
`kind: :agent`. Unknown stages retain the existing `Hive::StageError` message.

Updated [[commands/run]] and [[modules/workflows]] to document name-first coding
precedence and descriptor fallback dispatch, refreshed [[stages/agent]], and added
the new runner tests to [[testing]].

---
date: 2026-06-19
slug: generic-agent-runner
pages: [stages/agent, stages/index, index]
---

Added the generic descriptor-backed `Hive::Stages::Agent` runner and shared
`templates/agent_prompt.md.erb`. The runner resolves the current stage per-task
via `task.workflow.stage_named(task.stage_name)` (not the coding-pinned workflow
registry), reads prior markdown artifacts with a per-spawn nonce wrapper,
spawns one headless folder-isolated agent with `status_mode: :state_file_marker`,
and maps terminal markers to brainstorm-style commit actions.

Created [[stages/agent]], cataloged it in [[index]], and linked it from
[[stages/index]]. Coding's existing stage names remain handled by their bespoke
runners in the follow-up resolver unit.

---
date: 2026-06-19
slug: codex-review-clean-pass
pages: [modules/reviewers]
---

Fixed a `reviewer all_failed` regression in the patrol-default
`codex-native-review` reviewer. Two patrol PRs sat in `6-review` with
`all_failed`, retried every pass, because the sole reviewer reported "codex
review echoed the prompt template instead of producing findings" — even though
the captured transcript showed codex genuinely reviewing (running the test
suite, inspecting the diff) and concluding "no regressions."

Root cause: `#523` (2026-06-18) added a `TEMPLATE_ECHO` guard that ran against
codex's **raw stdout**. But `codex review` always echoes the prompt at the top
of its session, and the prompt template carries both the `## High/Medium/Nit`
headers and the literal `- [ ] <finding>: <one-line justification>` placeholder.
So a genuine **clean** review (codex concludes in prose with no structured
findings) tripped the placeholder check via the echoed prompt → `:error` →
`all_failed`. Before #523 the same output passed `valid_findings?` on the
echoed `## High` and recorded a hollow clean pass; #523 stopped the hollow pass
but also broke real clean reviews.

Fix (`lib/hive/reviewers/codex_review.rb`): decisions now run on codex's REAL
answer via `review_body`, which strips the echoed prompt (a leading block whose
only content is the placeholder is dropped) and the tool transcript, keeping a
real leading findings block plus codex's final message. New `review_status`
classifies `:findings` / `:clean` / `:template_echo` / `:error`. A prose verdict
is recorded as a `:clean` pass (canonical `No findings.` via `CLEAN_FINDINGS`)
ONLY when it AFFIRMATIVELY reports nothing found — `clean_verdict?` requires a
`CLEAN_VERDICT` match ("did not find", "found no/nothing", "no … regressions",
"the diff is/looks clean") and the absence of any `CONCERN_SIGNAL`. This is
deliberately stricter than "any non-empty reply": it stops a finding codex
describes in prose (no checkbox), or an exit-0 soft-error like "stream error,
unable to complete the review", from being silently laundered into a clean pass
(flagged in PR review). The `:template_echo` guard still fires when codex's own
answer is the unfilled template. Added regression tests for the real transcript
shape, prose-finding → `:error`, soft-error → `:error`, header-less clean
verdict, multiple `codex` markers, and the audit-comment sanitization. Refreshed
[[modules/reviewers]]; the heuristic's residual risk is noted in [[gaps]].

Note: these are **patrol** tasks, so codex's "No plan was found" line is
expected, not an error — patrol skips the brainstorm/plan stages, so
`Reviewers::PlanContext` injects its absent-note telling the reviewer to
proceed without plan grounding and say so.

## [2026-06-19T11:10:11Z] testing — close visual artifact coverage gaps

**Action:** Closed the Ruby CI coverage failure on PR #515. The branch's test assertions were already green, but `bundle exec rake coverage` failed the 100% line gate on unexercised visual-artifact/Screenote branches.

**Tests:** Added focused unit coverage for:

- `Hive::ScreenoteUploader` invalid JSON success bodies and default Net::HTTP timeout forwarding.
- `Hive::Stages::Artifacts` unexpected upload exceptions and missing `media/` directory skips.
- `Hive::Config` non-string `screenote.api_token` validation.
- `Hive::Daemon::Dispatcher` dry-run digest completion errors while still reaping the pseudo-child.

**Verification:** `bundle exec rake coverage` now passes locally with `100.00% (24410/24410)` line coverage and `5498 runs, 21734 assertions, 0 failures, 0 errors`.

**Docs:** Updated [[testing]] so the visual-artifact/Screenote coverage contract is explicit.

## [2026-06-19T10:21:08Z] maintenance — rebase PR #491 onto current main

**Action:** Rebasing PR #491 onto `origin/main` required combining the PR URL
status/TUI surface with the newer `hive-status` v4 dependency schema. Updated
`schemas/hive-status.v4.json` so the current task contract requires and
describes `pr_url` alongside the v4 dependency fields, while preserving v3 as
the pre-dependency compatibility schema. Also adjusted the TUI task-pane layout
minimum name width so the 69-column single-pane fallback keeps readable task
identity after the fixed PR column is present.

Focused schema, status, bot, TUI, daemon, and changed integration tests were
run after the rebase resolution; the default suite was used to catch and fix
the narrow TUI boundary regression.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[modules/pr]]
- [[testing]]
- [[log]]

---
date: 2026-06-19
slug: workflow-descriptor
pages: [modules/workflows, modules/stages, modules/task]
---

Introduced the coding workflow descriptor as the source of truth behind the
legacy stage and verb constants. `Hive::Workflow` now models immutable
workflow, stage, and advance-verb values; `Hive::Workflows::Coding::DESCRIPTOR`
declares the current nine-stage coding pipeline; and
`Hive::Workflows::Registry.default` resolves the implicit coding workflow.

`Hive::Stages::DIRS`, `Hive::Task::STAGE_NAMES`,
`Hive::Task::STATE_FILES`, and `Hive::Workflows::VERBS` are now derived from
that descriptor at load time while retaining the exact previous values,
ordering, frozen-ness, and `VERBS` hash shapes. Updated [[modules/workflows]],
[[modules/stages]], and [[modules/task]] to document the descriptor-backed
constant source.

Verified with `bundle exec rake test`, `bundle exec rake coverage` (100.00%
line coverage), and `bundle exec rubocop`.

---
ts: 2026-06-19T09:07:22Z
slug: babysitter-skip-log-path-pin
tags: [babysitter, dry-run, security, wiki]
---

## Babysitter: pin dry-run skip-log path in wrapper launchers

**Action:** Refreshed babysitter dry-run wiki coverage after PR #525 rebased
onto `origin/main`. The merged implementation keeps the newer dry-run
hardening from main and adds the PR's launcher-level
`HIVE_BABYSITTER_DRY_RUN_LOG` pin, so command-local log overrides cannot
redirect skipped-command audit writes outside the worktree-root
`.babysitter-dry-run-skipped.log`.

**Coverage:** Updated [[modules/babysitter]], [[commands/babysit]],
[[testing]], and [[gaps]] to mention skip-log override resistance alongside
the existing real-binary override, gh tempdir config isolation, host-selector
blocking, FIFO/symlink skip-log refusal, and control-character escaping
contracts. Page coverage stayed within existing pages, so [[index]] did not
need a catalog update. Did not edit compiled [[log]].

**Verification:** On the rebased PR branch, `bundle exec ruby -Itest
test/unit/babysitter/dry_run_env_test.rb`, `HIVE_COVERAGE_MIN_LINE=100 bundle
exec rake coverage`, and `bundle exec rubocop --parallel` passed.

---
date: 2026-06-19
slug: digest-redesign
pages: [commands/digest, modules/digest, modules/gh]
---

Redesigned the daily shipped digest layout (operator request). The message now
leads with a brand header `*Hive* #Digest` and a human date (`Fri, 19 June
2026`), an italic `_Summary_` block, **per-project** sections (`*Hive*`,
`*Screenote*`, …) each with `Features`/`Fixes`/`Patrol` subsections, and a
global footer under a divider: `Lines +A/-D · PRs P · Commits C`.

Changes:

- `Hive::Digest::Categories` labels are now `Features`/`Fixes`/`Patrol` (were
  `New features`/`Fixes`/`Patrol tasks`).
- `templates/digest_prompt.md.erb` now asks the model for a top-level one-line
  `summary` alongside the per-item rows; the JSON shape is
  `{"summary": "...", "items": [...]}`. `Digest::Categorizer#categorize` returns
  a new `Digest::Output(by_project:, summary:)` (items mapping kept its old
  `{project => [CategorizedItem]}` shape via `map_output_file`/`map_document`);
  a missing/blank summary falls back to a neutral count.
- New `Hive::Digest::Stats#for_items` aggregates per-PR additions/deletions/
  commits into `Totals`, fetched via the new `Hive::Gh.pr_stats(pr_url)` (keyed
  off the PR URL, so no worktree/chdir is needed). A per-PR `gh` failure is
  logged and skipped, and the renderer omits Lines/Commits when nothing could
  be measured — the digest never fails for want of footer numbers.
- `Digest::Renderer.render` takes `(by_project, date:, summary:, totals:)`;
  project headers are first-letter capitalized for display. All dynamic text
  stays MarkdownV2-escaped (the hashtag's `#` is escaped but left outside the
  bold span so Telegram still tags it).

Verified with a real `hive digest --dry-run --date 2026-06-18`: header, date,
LLM summary, the `*Hive*` / `_Patrol_` section, and a live-`gh` footer
(`Lines +355/-64 · PRs 4 · Commits 11`) all rendered correctly. Refreshed
[[commands/digest]] and [[modules/digest]]; `Hive::Gh.pr_stats` noted in
[[modules/gh]].

# babysitter dry-run skip-log path pinning

Hardened `Hive::Babysitter::DryRunEnv` so the generated `git` / `gh`
dry-run launchers reset `HIVE_BABYSITTER_DRY_RUN_LOG` to the worktree-root
`.babysitter-dry-run-skipped.log` before invoking the shared stubs. This
matches the existing real-binary handoff pattern and prevents a command-local
log-path override from redirecting skipped-command audit records to an
agent-chosen user-owned file.

Added `test_with_env_pins_skip_log_against_command_local_overrides` to
`test/unit/babysitter/dry_run_env_test.rb`; it proves both skipped `git` and
`gh` commands still log to the worktree skip log while the override file remains
unchanged.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-19
slug: digest-loads-env-file
pages: [commands/digest, modules/digest]
---

A daemon-scheduled daily digest was never delivered on an operator box even
though the daemon was running: the `DigestScheduler` dispatched
`hive digest --date <day> --json` every tick, but each child exited 78
(`HIVE_TELEGRAM_BOT_TOKEN must be set`) and the scheduler hot-looped on its
failure backoff. Root cause: the daemon runs as a systemd/detached process
whose environment carries no `HIVE_TELEGRAM_BOT_TOKEN`, and only
`hive bot start` loaded `~/.config/hive/.env` (via `Hive::EnvFile.load!`) —
`hive digest` and `hive daemon` never did, so a manual `hive digest` failed the
same way unless the token was already exported in the shell.

Fix: `Hive::Digest.run` now calls `Hive::EnvFile.load!` for a real send (after
resolving `cfg`, before `Sender#preflight!`). A dry-run never sends, so it
skips the load — matching the dry-run "no token/chat lookup" contract — and an
already-exported env var still wins over the file. Because `~/.local/bin/hive`
is a symlink into the source checkout the daemon runs, the dispatched
`hive digest` child picks this up with no daemon restart. Added
`test/unit/digest/run_test.rb` coverage asserting the env file is loaded once on
a real run and not at all on a dry-run (singleton override; minitest/mock is not
bundled). Refreshed [[commands/digest]] and [[modules/digest]].

---
date: 2026-06-19
slug: media-brakeman-ignore
pages: [testing, gaps]
---

During PR #515 babysitting, the rebased branch cleared Git conflicts and then
CI exposed a Brakeman weak `SendFile` warning for
`TasksController#media`. The route and controller already constrain the
filesystem boundary: `:filename` is route-limited to PNG/JPEG/GIF names,
`resolved_media_path` applies `File.basename`, repeats the extension check,
resolves the real task folder and `media/` directory, refuses a symlinked media
root, and only streams files whose realpath remains below that media root.

Added the current Brakeman fingerprint to `config/brakeman.ignore` with that
rationale, added an integration regression for a symlinked `media/` directory,
and refreshed [[testing]] / [[gaps]] to include the media-route false-positive
policy. Verified:

```bash
bundle exec brakeman --force --no-pager --quiet --format github --ignore-config config/brakeman.ignore
```

---
date: 2026-06-18
slug: task-dependencies-review-03
pages: [modules/daemon]
---

Review pass 03 hardening for same-project task dependencies.

Behavior-observable change: the daemon's once-per-tick status advisory is now
logged under the neutral event `:status_warning` (renamed from
`:status_schema_skew`). That channel carries both a tolerated forward
schema-version skew AND status-command stderr breadcrumbs (fail-open
dependency gate, dropped `depends_on`), so the schema-specific name was
misleading — an operator grepping daemon.log for dependency-gate degradation
never found it. Renamed in `Hive::Daemon::Logger::EVENTS` and refreshed
[[modules/daemon]].

Correctness/observability fixes: `Worktree.fetch_origin_branch` now writes the
`refs/remotes/origin/<branch>` tracking ref via an explicit colon-refspec so
dependency stacking no longer collapses onto the default base on
single-branch/narrow-refspec clones; `Commands::Status#dependency_gate_stage_for`
warns the gate-loosen direction on a config-load failure; the
`Dependencies.task_id` breadcrumb comment was corrected (corrupt id fails to
resolve, not mis-resolves).

Added regression coverage: real-git `origin_branch_exists?` (incl. narrow
refspec), the `TaskMeta.read` two-arm rescue (warn vs silent), the per-row
dependency fail-open, the blocked single-source-of-truth invariant, and
absence checks that an unblocked dependent omits the held indicator.

---
date: 2026-06-18
slug: daemon-start-config-hermeticity
pages: [testing]
---

During PR #506 babysitting, the broad `bundle exec rake test` pass failed only
in `test/unit/commands/daemon_test.rb` on a developer machine whose global
Hive config had Telegram bot delivery configured. The daemon start test already
stubbed `Hive::Config.load_global_daemon` and `load_global_update`, but
`Hive::Commands::Daemon#start_daemon` also calls
`Hive::Config.load_global_digest_block`; after the digest default-on behavior,
that unstubbed read made the expected dispatcher config depend on the
operator's real `~/.config/hive/config.yml`.

Added daemon-test helpers that stub daemon, update, and digest global config
together for start-path tests, keeping the unit focused on startup wiring and
PID cleanup rather than local operator configuration. Refreshed [[testing]] to
record that `commands/daemon_test.rb` pins the config wiring hermetically.

## reviewers — diagnose codex-native-review failures + reject prompt-template echo

**Action:** Closed the observability gap behind `reviewer all_failed` and stopped
hollow codex reviews from passing as clean.

**Problem:** When `codex review` failed, `CodexReview` recorded only the terse
`codex review exited with status=1` in `reviews/errors-NN.md` — codex's captured
combined stdout+stderr (where the actual cause lives) was discarded. A flaky
codex exit-1 was therefore undiagnosable (the #1378 case). Separately, codex
sometimes echoes the prompt's own example block (`- [ ] <finding>:
<one-line justification>` under each header); that passed the severity-header
check and was recorded as a hollow clean pass.

**Fix (`lib/hive/reviewers/codex_review.rb`):**
- On any reviewer failure, append the last `FAILURE_TAIL_BYTES = 2000` of the
  captured codex transcript to the `:error` message (scrubbed, indented under a
  labeled fence), so it lands in `errors-NN.md`. Bonus: because
  `Hive::AgentLimit.limit_reached?` only inspects the error message, a codex
  usage-limit that exits non-zero is now detectable and routes the phase to the
  cooldown `limits_reached` path instead of a generic `all_failed`.
- New `TEMPLATE_ECHO` guard: output carrying the literal
  `- [ ] <finding>: <one-line justification>` placeholder is rejected as a
  failure (retries) rather than recorded as a clean pass. A genuine
  `No findings.` review is unaffected. Validity now flows through a single
  `usable_review?` predicate; `failure_message` split into a terse `base_reason`
  + `captured_tail`, threaded through `error_result(detail:)`.

**Tests:** failure message carries the codex output tail; a usage-limit failure
is `AgentLimit.limit_reached?`-detectable; a template echo is rejected with
`echoed the prompt template`; a real `No findings.` review still passes. Updated
the transcript-dropping fixture to use a real finding instead of the placeholder
(it was incidental to that test's intent).

**Not fixed:** the codex-side *cause* of an intermittent exit-1 is still
codex's own — but it is now captured for diagnosis the next time it happens.

---
timestamp: 2026-06-18T20:57:41Z
area: babysitter
---

Updated [[commands/babysit]], [[modules/babysitter]], and [[testing]] after the
dry-run `gh` host-override rebase. The pages now describe argv-wide and
positional host rejection, `GH_HOST` / `GH_REPO` / enterprise-token scrubbing,
and the current `gh auth status` host-selector skip behavior.

## daemon — self-heal non-token error classes + close the web/ auto-commit scope gap

**Action:** Broadened the daemon's `StaleAgentHealer` so red tasks whose error
is operational (not a usage/credit limit) auto-retry and advance instead of
parking for a human, and fixed the hive-code bug that made web-UI tasks brick.

**Healer (`lib/hive/daemon/stale_agent_healer.rb`):** under the existing
bounded per-process retry budget (default 3, then park), now auto-recoverable:
- `ERROR reason=ensure_clean_on_exit_failed` (any worktree-owning stage). The
  rerun re-runs CleanExit, which re-adds and re-scope-checks the residue — it
  never bypasses the check, so genuinely out-of-scope residue re-fails and
  parks. Root cause of the common trigger (dry-run skip-log residue) was fixed
  in PR #519; this stops the immediate manual park.
- `REVIEW_ERROR phase=reviewers reason=all_failed` (every reviewer crashed for
  a non-limit reason, e.g. a native reviewer exited non-zero).
- `REVIEW_ERROR phase=fix` auto-commit failures: `fix_auto_commit_scope_failed`,
  `fix_auto_commit_sign_policy_failed`, `fix_auto_commit_signing_failed`.

Token/budget carve-out preserved: a total reviewer usage-limit still sets
`reason=limits_reached` (not `all_failed`) and stays on the `retry_after`
cooldown path. Integrity/operator reasons stay manual: `fix_status_check_failed`,
`fix_tampered`, `dirty_worktree`, `execute_stale`.

**Config (`lib/hive/config.rb`):** added nested `web/` source globs
(`web/app/**`, `web/lib/**`, `web/src/**`, `web/test/**`, `web/tests/**`,
`web/spec/**`, `web/docs/**`) to the auto-commit `allowed_paths` DEFAULTS, so a
fix touching a monorepo Rails/JS app under `web/` auto-commits. Sensitive nested
dirs (`web/config`, `web/bin`, `web/db`) are intentionally NOT allowlisted, so
they stay out of scope exactly like their top-level counterparts (denied wins
over allowed). This unbricks the `web/app/**` / `web/test/**` scope violations
(task #1361 class).

**Bot/TUI:** unchanged — `ensure_clean_on_exit_failed` stays in
`ERROR_MANUAL_ONLY_REASONS` as the post-exhaustion "inspect manually" backstop;
the daemon retries first, a human sees it only after the budget is spent.

**Tests:** healer auto-recovers all three new classes (incl. bounded-then-park);
`dirty_worktree` / `fix_status_check_failed` stay manual; CleanExit auto-commits
`web/app`+`web/test` residue but flags `web/config` as a scope violation.

This is project-agnostic (healer) and global-default (config), so it applies to
every daemon-managed project, not just hive.

---
date: 2026-06-18
slug: patrol-json-coverage-followup
pages: [commands/patrol, gaps]
---

Post-commit wiki refresh after commit `239b93c6` updated patrol JSON wiki
coverage and recorded a schema/test uncertainty. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "patrol JSON usage error
similar_to_existing skipped_findings hive-patrol"` returned no indexed
matches, and the configured master wiki path had no matching patrol/schema
guidance.

Inspected the committed diff plus current `bin/hive`,
`lib/hive/commands/patrol.rb`, `lib/hive/patrol/fingerprint.rb`,
`schemas/hive-patrol.v1.json`, `test/integration/cli_usage_error_json_test.rb`,
`test/integration/patrol_command_test.rb`, `test/unit/schema_files_test.rb`,
[[commands/patrol]], [[modules/patrol]], [[cli]], [[testing]], and [[gaps]].
Confirmed the pre-dispatch `hive patrol --json` missing-`PROJECT` envelope is
covered in source/tests/wiki, and confirmed the remaining schema/test gap is
real: source can emit `skipped_findings[].reason = "similar_to_existing"`,
while the v1 schema enum and focused schema payload test do not cover that
reason.

Refreshed [[commands/patrol]] so the step list and JSON reason text mention the
similar-known skip explicitly, and refreshed [[gaps]] with the 2026-06-18
recheck. Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

## [2026-06-18T20:05:00Z] digest — default ON when Telegram bot is configured; drop `bot.digest_chat_id`

**Action:** Made the daily shipped digest opt-out instead of opt-in, and removed
the separate `bot.digest_chat_id` setting.

- `Hive::Config.load_global_digest_block` now derives `digest.enabled` from the
  bot config when the operator has not pinned it: `true` when `bot.enabled ==
  true` and `bot.chat_id_allowlist` has at least one integer chat, else `false`.
  An explicit `digest.enabled` (true or false) is always honored — only the
  unset case is derived (`override.key?("enabled")` gate). New private predicate
  `Config.telegram_digest_default?(data)`. Both scheduler-config callers
  (`Commands::Daemon#start_daemon`, dispatcher SIGHUP reconfigure) load through
  this method, so no second code path.
- Removed `bot.digest_chat_id`: gone from `DEFAULTS["bot"]`, validator
  `validate_bot_digest_chat_id!` deleted, removed from `templates/hive_config.yml.erb`
  and the `schemas/hive-digest.v1.json` description. `Digest::Sender.resolve_chat_id`
  now resolves to `bot.chat_id_allowlist[0]` only and raises
  `"bot.chat_id_allowlist[0] must be configured before sending digest"` when absent.
- Tests: new `load_global_digest_block` cases for auto-enable derivation
  (bot-configured → on; explicit false honored; no chat / disabled bot → off);
  `digest/sender_test` resolves via the allowlist; removed the
  `digest_chat_id` validation test; updated the digest e2e fixture.

Documented as [[decisions]] ADR-030. Refreshed [[commands/digest]],
[[modules/digest]], [[modules/config]], [[commands/bot]], and [[commands/daemon]].

**Refreshed pages:**
- [[decisions]]
- [[commands/digest]]
- [[modules/digest]]
- [[modules/config]]
- [[commands/bot]]
- [[commands/daemon]]

---
date: 2026-06-18
slug: task-dependencies
pages: [modules/task_dependencies, modules/task, commands/status, modules/worktree, index]
---

Added same-project task dependency support around `depends_on` metadata,
central `Hive::Dependencies` resolution, status JSON/text surfacing, daemon
dispatch gating, and stacked worktree/PR base selection.

Documented the feature in [[modules/task_dependencies]], refreshed
[[modules/task]] for the `depends_on` sidecar field, refreshed
[[commands/status]] for `hive-status` v4 dependency fields and blocked
indicators, and refreshed [[modules/worktree]] for dependency branch base
overrides. Updated [[index]] because the task-dependencies page is new.

Verified the implementation with focused unit/integration groups covering
task metadata, dependency resolution/config, status/TUI/daemon gating, and
stacked branch/PR behavior.

---
date: 2026-06-18
slug: gif-tooling-doc-correction
pages: [commands/web, dependencies]
---

Corrected a factually-wrong claim that the hivebox Docker image could produce
terminal GIFs. The image ships `asciinema` (records a `.cast`) and `ffmpeg`,
but no terminal-GIF encoder: `ffmpeg` cannot read an asciinema `.cast`, and
`agg`/`vhs` (the actual encoders — `agg` renders a `.cast`, `vhs` records
straight to GIF) are not installed. So an in-box TUI/CLI demo records a `.cast`
and then degrades to a `failed` capture unless the agent installs `agg`/`vhs`.
This degrades safely (artifacts U6 is plan-deferred/optional), so the fix was
documentation accuracy, not adding the encoders to the image.

Updated [[commands/web]] and [[dependencies]] plus `docs/visual-artifacts.md`
and `packaging/docker/README.md` to name the missing encoder; did not edit
compiled [[log]].

## babysitter — gitignore dry-run worktree artifacts so CleanExit stays clean

**Action:** Fixed the recurring red-task cluster where patrol/babysit dry-run
runs left `.babysitter-dry-run-skipped.log` (and the `.hive-babysitter-dry-run-bin/`
overlay shims) at the worktree root. `Hive::Stages::CleanExit.run!` on stage exit
runs `git add -A` and the `review.fix.auto_commit.scope_check` rejected those
untracked artifacts as out-of-scope residue, landing tasks as
`:error reason=ensure_clean_on_exit_failed` (and `review_error
reason=fix_auto_commit_scope_failed`).

**Fix:**
- `.gitignore`: ignore `.babysitter-dry-run-skipped.log`,
  `.babysitter-dry-run-plan.md`, and `.hive-babysitter-dry-run-bin/` — these are
  transient dry-run artifacts that must never be committed, so `git add -A` /
  `git status --porcelain` skip them and CleanExit exits `:clean`.
- `lib/hive/babysitter/dry_run_env.rb`: extracted `OVERLAY_DIRNAME` /
  `SKIP_LOG_BASENAME` constants and `rm_rf`'d the overlay-bin dir in the
  `with_env` `ensure` block (pure tooling, nobody reads it after the block). The
  skip log is deliberately kept — it is the dry-run diagnostic record that
  callers/tests read after `with_env` returns.

**Tests:**
- `test/unit/stages/clean_exit_test.rb`: gitignored dry-run residue exits `:clean`.
- `test/unit/babysitter/dry_run_env_test.rb`: `with_env` removes the overlay dir
  on exit while keeping the skip log; real repo `.gitignore` ignores all three
  artifacts (`git check-ignore`).

Not addressed (separate causes seen in the same red sweep): `web/app/**` /
`web/test/**` falling outside the auto-commit `allowed_paths` (#1361),
reviewers `all_failed` (#1378), and review `wall_clock` timeouts (writero #1).

## [2026-06-18T18:25:00Z] babysitter - point gh dry-run HOME at an empty tmpdir, not /dev/null

**Action:** Fixed a regression in `bin/hive-babysitter-stub-gh`: before exec it set `HOME=/dev/null`. Unlike git (which honors `GIT_CONFIG_GLOBAL=/dev/null` / `GIT_CONFIG_NOSYSTEM` as an explicit "no config" sentinel), gh has no such escape hatch — it resolves its config dir as `GH_CONFIG_DIR` -> `XDG_CONFIG_HOME/gh` -> `$HOME/.config/gh` and then reads/creates files under it, so `HOME=/dev/null` left gh resolving `/dev/null/.config/gh` and failing with `ENOTDIR`. The stub now points both `HOME` and `GH_CONFIG_DIR` at a fresh empty `Dir.mktmpdir` directory: gh finds no attacker-controlled config to honor (the real `~/.config/gh` is out of reach) yet still has a writable location for its own state. The dir is intentionally not cleaned up (passthrough execs over the stub, which never regains control); it is empty and swept by the OS tmp reaper.

**Coverage:** Reworked the gh env-scrub regression in `test/unit/babysitter/dry_run_env_test.rb` to assert every other exec-influencing var is `<unset>` while `HOME` and `GH_CONFIG_DIR` are real, fresh, empty directories distinct from the caller-supplied `evil-home` / `evil-gh-config` and never `/dev/null`.

**Verified:** `ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (16 runs, 0 failures); `rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb` clean.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]]

## [2026-06-18T18:10:00Z] wiki - audit gh dry-run tmpdir follow-up coverage

**Action:** Refreshed wiki planning/documentation coverage after `6f3e66ce` committed review-pass wiki residue on top of `fe222022`, which changed the gh dry-run passthrough environment from `HOME=/dev/null` to a fresh empty `Dir.mktmpdir` used for both `HOME` and `GH_CONFIG_DIR`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host selector dry-run stubs testing gaps"` surfaced existing babysitter/gaps context, and the configured master wiki path had no matching context. Inspected `6f3e66ce`, `fe222022`, the earlier host-selector source commit `44768970`, and current `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed [[commands/babysit]] and [[modules/babysitter]] already describe the gh tmpdir behavior after `fe222022`; refreshed [[testing]] so its unit-test map names the fresh empty `HOME`/`GH_CONFIG_DIR` assertion, and refreshed [[gaps]] so the live-smoke uncertainty reflects the current host-selector plus temp-home dry-run boundary. Page coverage did not change, so [[index]] did not need a catalog update.

**Verified:** `git diff --check -- wiki/commands/babysit.md wiki/modules/babysitter.md wiki/testing.md wiki/gaps.md wiki/log.d/20260618T180046Z-babysitter-gh-host-selector-residual-audit.md wiki/log.d/20260618T181000Z-babysitter-gh-home-tmpdir-audit.md`; `bundle exec ruby -Itest test/unit/wiki_log_test.rb`; `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`. Did not run `qmd update` or `qmd embed`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]]

## [2026-06-18T18:00:46Z] wiki - audit residual gh dry-run host-selector docs

**Action:** Refreshed wiki planning/documentation coverage after `bfaa8ee7` committed residual wiki changes from the `44768970` gh dry-run host-selector hardening. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host selector dry-run stubs testing gaps"` surfaced existing babysitter/gaps context, and the configured master wiki path had no matching context. Inspected the committed diffs plus current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the gh host-selector boundary from `44768970` is covered in existing babysitter command/module/testing pages. Refreshed [[commands/babysit]] and [[modules/babysitter]] to include the current `git` dry-run env seams that were already present in source/tests/gaps (`GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS`) but stale in those page summaries. Also aligned [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]] with current gh passthrough config handling: caller `HOME`/`GH_CONFIG_DIR` are replaced with a fresh empty temp directory rather than `HOME=/dev/null`. Carried the existing uncertainty in [[gaps]]: no checked-in artifact proves a full live-agent `hive babysit --once PROJECT --dry-run` run after the current dry-run stub hardening. Page coverage did not change, so [[index]] did not need a catalog update.

**Verified:** `git diff --check -- wiki/commands/babysit.md wiki/modules/babysitter.md wiki/testing.md wiki/gaps.md wiki/log.d/20260618T180046Z-babysitter-gh-host-selector-residual-audit.md`; `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`. Did not run `qmd update` or `qmd embed`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]]

## [2026-06-18T17:49:45Z] wiki - audit gh dry-run host-selector coverage

**Action:** Audited commit `44768970` after it touched `bin/hive-babysitter-stub-gh`, dry-run tests, and babysitter wiki coverage. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host selector dry-run audit"` surfaced existing babysitter/gaps context, and the configured master wiki path had no matching context. Verified the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, and `test/unit/babysitter/dry_run_env_test.rb`.

**Coverage:** Confirmed [[commands/babysit]], [[modules/babysitter]], and [[testing]] describe the new `gh` dry-run host-selector boundary: `--hostname`, host-qualified `-R` / `--repo`, host-qualified repo/PR operands, full URL `api` operands, `auth status` `-h` forms, and host/config environment scrubbing. Refreshed [[testing]] metadata and consolidated [[gaps]] so the older 2026-06-15 dry-run-stub live-smoke gap no longer duplicates the current 2026-06-18 uncertainty. Page coverage did not change, so [[index]] did not need a catalog update.

**Verified:** `git diff --check -- wiki/gaps.md wiki/testing.md wiki/log.d/20260618T174945Z-babysitter-gh-host-selector-audit.md`; `bundle exec ruby -Itest test/unit/wiki_log_test.rb`; `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`. Did not run `qmd update` or `qmd embed`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]]

## [2026-06-18T17:36:32Z] babysitter - block gh dry-run host selectors

**Action:** Hardened `bin/hive-babysitter-stub-gh` so allowlisted dry-run reads skip host-redirection selectors before passthrough: `--hostname`, host-qualified `-R` / `--repo` values including glued `-R...`, host-qualified `repo view` operands, PR URL operands, full URL `api` operands, and `auth status` `-h` forms. Allowed `gh` reads now also scrub `GH_HOST`, `GH_REPO`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN`, gh config selector env, pager/browser/editor env, and neutralize `HOME` before exec.

**Coverage:** Added focused `test/unit/babysitter/dry_run_env_test.rb` regressions proving those host selectors skip without reaching the fake real `gh`, while non-host `--repo=owner/repo` reads still pass. Extended the gh env-scrub test to record the new host/config env behavior. Refreshed [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]; no new wiki page was needed.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]], [[gaps]]

## [2026-06-18T17:30:21Z] babysitter - refresh FIFO skip-log executable-stub coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after
commit `3e461d76` changed `bin/hive-babysitter-stub-git`,
`bin/hive-babysitter-stub-gh`, and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first. `qmd search "command API surface routes
handlers commands executable entrypoints README"` surfaced prior wrapper and
babysitter refresh patterns; the configured master wiki had only generic
route/API coverage guidance.

Inspected the committed diff plus the current dry-run stubs and focused unit
tests. Documented that skipped-command audit logging now preflights an existing
log path with `File.lstat`, rejects non-regular or non-current-uid targets
before open, uses `File::NOFOLLOW | File::NONBLOCK`, creates missing logs as
mode `0600`, and re-checks the opened file. This keeps dry-run default-deny
when the audit sink is unsafe and prevents a FIFO `HIVE_BABYSITTER_DRY_RUN_LOG`
override from hanging the stub while waiting for a reader.

The focused test suite now covers both `git` and `gh` stubs against a FIFO log
path through a timeout-bounded capture helper. No new wiki page was needed, so
[[index]] did not need a catalog update. The live uncertainty remains recorded
in [[gaps]]: no checked-in artifact proves a full
`hive babysit --once PROJECT --dry-run` live-agent run after these stub changes.
Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-18
slug: review-coverage-gate-audit
pages: [stages/review, modules/daemon, gaps]
---

Post-commit wiki coverage audit for `03ba06b9`
(`test(review): cover review coverage gate branches`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent
[[log]] entries, and the committed source-change fragment first.
`qmd search "review coverage gate"` surfaced existing [[testing]] coverage
context; the configured master wiki path had no relevant Hive-specific hit.

Inspected the committed diff plus current `lib/hive/stages/review.rb`,
`lib/hive/daemon/dispatcher.rb`, `test/integration/run_review_test.rb`,
`test/unit/daemon/dispatcher_test.rb`, [[testing]], [[stages/review]],
[[modules/daemon]], and [[modules/digest]]. Confirmed the existing
[[testing]] update already names the two focused coverage contracts, then
refreshed [[stages/review]] so the review-stage test map mentions the
triage-retry wall-clock handoff to `REVIEW_STALE`, and refreshed
[[modules/daemon]] so the dispatcher/digest scheduling notes mention dry-run
digest pseudo-child completion error isolation. Added [[gaps]] uncertainty for
the missing checked-in hosted Ruby CI / `bundle exec rake coverage` pass after
the fix. Page coverage did not change, so [[index]] did not need a catalog
edit. Did not edit compiled [[log]] and did not run `qmd update` or
`qmd embed`.

---
date: 2026-06-18
slug: review-coverage-gate-fix
pages: [testing]
---

Fixed the PR #512 Ruby CI red caused by the 100% line-coverage gate, not by
test assertions. The failing GitHub job had 5,436 passing runs but reported two
uncovered lines: `lib/hive/stages/review.rb:392` (the caller path that converts
`:wall_clock_exceeded` from `run_triage_with_retries` into
`REVIEW_STALE reason=wall_clock`) and `lib/hive/daemon/dispatcher.rb:710` (the
dry-run digest pseudo-child rescue that logs `digest_scheduler.complete` write
failures as `:fatal`).

Added focused regressions in `test/integration/run_review_test.rb` and
`test/unit/daemon/dispatcher_test.rb` for those branches. Updated [[testing]]
to name the new coverage contracts. Page count stayed 80, so [[index]] did not
need a catalog update. Did not edit compiled [[log]] and did not run `qmd update`
or `qmd embed`.

---
date: 2026-06-18
slug: review-p3-polish-audit
pages: [modules/reviewers, testing, gaps]
---

Refreshed wiki planning/documentation coverage after commit `c4045dfe`
cleared the deferred PR #512 review polish items. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "review triage wall clock backoff
truncation reviewers"` surfaced the existing [[stages/review]] coverage; no
relevant configured master-wiki match was found.

Inspected the committed diff plus current `lib/hive/reviewers.rb`,
`lib/hive/reviewers/agent.rb`, `lib/hive/reviewers/codex_review.rb`,
`lib/hive/stages/review.rb`,
`test/unit/stages/review/phase_failure_helpers_test.rb`,
`test/unit/stages/review/run_reviewers_test.rb`, and reviewer tests. The
committed [[stages/review]] update already documents that transient triage
retry now honors `review.max_wall_clock_sec` before starting another spawn.
Updated [[modules/reviewers]] for the shared `Hive::Reviewers.backoff_seconds_for`
formula used by Agent, CodexReview, and triage retry wrappers; updated
[[testing]] for the new wall-clock-bail helper coverage; and amended [[gaps]]
to keep the live triage-failure uncertainty open while noting that `c4045dfe`
only source/test-pins the retry clamp. Page count stayed 80, so [[index]] did
not need a catalog update. Did not edit compiled [[log]] and did not run
`qmd update` or `qmd embed`.

---
date: 2026-06-18
slug: ce-review-p3-polish
pages: [stages/review, modules/reviewers]
---

Cleared the three deferred P3 findings from the /ce-code-review of PR #512.

- **Wall-clock clamp on the triage retry.** `run_triage_with_retries` now takes
  `started_at:`/`max_wall_clock_sec:` and bails to `:wall_clock_exceeded` before
  starting another spawn when the review budget is spent; the caller turns that
  into `REVIEW_STALE reason=wall_clock`, mirroring `run_reviewers`. Prevents a
  high `review.triage.max_attempts` × 1800s triage timeout from overrunning
  `review.max_wall_clock_sec`.
- **Single backoff formula.** Added `Hive::Reviewers.backoff_seconds_for`; the
  reviewer adapters (`Agent`, `CodexReview`) and `triage_retry_backoff` now
  delegate to it instead of each carrying its own
  `[2**(n-1), REVIEWER_BACKOFF_CAP_SEC].min` copy. Each keeps a thin wrapper as
  a test-stub seam.
- **One truncation primitive.** `truncate_marker_message` gained `max:`/`ellipsis:`
  params; `review_phase_error_summary` reuses it (300-char cap, single-char
  ellipsis) instead of duplicating the truncate-with-ellipsis logic. Output is
  byte-for-byte identical to before for both callers.

Unit coverage: added a wall-clock-bail test for `run_triage_with_retries`.
`run_review_test.rb` (50), `run_reviewers_test.rb` (69), and the phase-failure
helper unit tests (10) all green; rubocop clean.

---
date: 2026-06-18
slug: fix-agent-defect-class-sha-audit
pages: [templates, gaps, log]
---

Audited the latest wiki refresh commit `27cfaff6` after it touched
[[templates]], [[gaps]], and a `wiki/log.d/` fragment for the 6-review
whole-defect-class fix-prompt change. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "fix prompt whole defect class accepted
finding"` returned no exact project hit, and `rg` found no matching
review/fix-prompt context in the configured master wiki path.

Inspected the committed wiki diff, the current `templates/fix_prompt.md.erb`,
the branch-resident source commit `ce3f7978`, the old referenced commit object
`ba495dc0`, [[stages/review]], and `test/integration/prompt_injection_test.rb`.
The source patch contents are identical, but `ba495dc0` is not contained by the
current branch after rebasing; normalized [[templates]], [[gaps]], and the prior
audit fragment to cite `ce3f7978` instead. The existing uncertainty remains:
the prompt prose and render tests are pinned, but no in-tree artifact proves a
live fix agent generalized one accepted finding across multiple same-defect
sites. No page-list coverage changed, so [[index]] did not need an update. Did
not run `qmd update` or `qmd embed`.

---
date: 2026-06-18
slug: ce-review-triage-config-hardening
pages: [stages/review, state-model]
---

Addressed /ce-code-review findings on the triage-retry / error-surfacing
change (PR #512) before merge.

P2 (cross-reviewer, 4 personas): the new `review.triage.max_attempts` knob had
neither load-time validation nor a runtime rescue, unlike every sibling
`max_attempts`. A non-integer value reached a bare `Integer(value)` in
`triage_max_attempts` and crashed the whole 6-review run as an opaque
`runner_exception`; `0`/negative silently ran triage once. Fixed by adding
`review.triage.max_attempts` to `Hive::Config::POSITIVE_INTEGER_KEYS` (rejected
at load with a typed ConfigError like `review.ci.max_attempts`) and giving
`triage_max_attempts` a clamp (`[Integer(value), 1].max`) plus an
`ArgumentError`/`TypeError` rescue that warns and falls back to the default —
defense-in-depth for programmatic/test configs that bypass validation, mirroring
`Hive::Reviewers::Agent#max_attempts_from_spec`.

P2 (project-standards): doc/comment claimed the `message=` attr is written for
"triage / fix / ci". The CI phase does not route through
`mark_review_phase_failure` — a CI failure writes `REVIEW_ERROR phase=ci
reason=ci_unrunnable` directly and carries no `message=`. Corrected the
`review.rb` helper comment (`fix_error` → `fix_failed`), [[stages/review]], and
[[state-model]] to say triage/fix only.

Added unit coverage in `test/unit/stages/review/phase_failure_helpers_test.rb`:
`review_phase_error_summary` exact-limit/blank/whitespace-collapse branches, and
`triage_max_attempts` default/explicit/clamp/non-integer-fallback. Lower-priority
findings deferred (no wall-clock clamp on the triage retry — default-safe at
max_attempts=2; the third copy of the backoff formula; the
`review_phase_error_summary` vs `truncate_marker_message` overlap). rubocop
clean; `run_review_test.rb` (50) green.

---
date: 2026-06-18
slug: babysitter-dry-run-gitignore
pages: [commands/babysit, stages/review]
---

Fixed a recurring `6-review` failure on patrol command-review tasks that
exercise the babysitter stubs (`patrol-command-bin-hive-babysitter-stub-gh-*`).
`Hive::Babysitter::DryRunEnv#with_env` points `HIVE_BABYSITTER_DRY_RUN_LOG` at
`<worktree>/.babysitter-dry-run-skipped.log` and `prepare_overlay` writes a
`<worktree>/.hive-babysitter-dry-run-bin/` PATH overlay of git/gh stub
wrappers. Neither artifact was gitignored, so after the dry-run the review
worktree carried untracked residue; the stage-exit clean-exit auto-commit
scope-check rejected `.babysitter-dry-run-skipped.log` as outside
`review.fix.auto_commit.scope_check.allowed_paths` and the task died with
`ERROR reason=ensure_clean_on_exit_failed` (observed on task id 1367).

Added both paths to `.gitignore` so git (and therefore clean-exit's residue
detection) ignores them — they are ephemeral run scaffolding that must never be
committed. Verified with `git check-ignore` and a clean `git status`. No
behavior change to the dry-run itself. Separate from the 6-review
error-surfacing / triage-retry work in PR #512.

---
date: 2026-06-18
slug: visual-artifacts
pages: [stages/artifacts, commands/web, modules/config, dependencies, testing]
---

Added visual artifact capture/display coverage for the artifacts-to-finalize
handoff. `templates/artifacts_prompt.md.erb` now asks the artifacts agent to
write `media/manifest.json` plus committed PNG/GIF evidence when a task has an
observable UI/TUI/CLI surface, or a skipped/failed manifest when it does not.
`Hive::ScreenoteUploader` uses stdlib `Net::HTTP` and global/env screenote
config to upload PNG/JPEG stills after the agent completes, keeping the token
out of prompts. hivebox now streams committed task media through a constrained
task media route and renders captured media or failed-capture warnings on the
task page. Finalize prompts instruct the agent to include screenote Demo links
in PR bodies when enriched URLs exist.

Updated [[stages/artifacts]], [[commands/web]], [[modules/config]],
[[dependencies]], and [[testing]] with the manifest contract, media route
safety boundary, screenote config/env overrides, optional capture tools, Docker
terminal-capture additions, and new test coverage. Added
`docs/visual-artifacts.md`; did not edit compiled [[log]].

---
date: 2026-06-18
slug: fix-agent-defect-class-audit
pages: [templates, gaps]
---

Audited post-commit wiki coverage after branch commit `ce3f7978` changed
`templates/fix_prompt.md.erb` and already added
`wiki/log.d/20260618T120406Z-fix-agent-generalize-defect-class.md` plus a
[[stages/review]] Phase 4 update. Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent [[log]] entries first.
`qmd search "fix agent recurring defect class review prompt"` returned no
indexed hits, and the configured master wiki path had no matching context.

Inspected the committed diff, current `templates/fix_prompt.md.erb`,
`lib/hive/stages/review.rb`, `test/integration/prompt_injection_test.rb`, and
adjacent wiki pages. Refreshed [[templates]] so the template catalog documents
the bounded whole-defect-class exception to the otherwise strict scoped-edit
rule, updated [[gaps]] with the remaining uncertainty that this is
prompt/test-render pinned but not live-smoked through a real fix-agent run, and
confirmed [[index]] already had the current 80-page catalog metadata so no page
list edit was needed. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-18
slug: fix-agent-generalize-defect-class
pages: [stages/review]
---

Nudged the 6-review fix agent to fix the whole defect class, not just the cited
line. `templates/fix_prompt.md.erb` previously said "do NOT refactor adjacent
code" full stop, so the fix agent patched only the one site a finding cited;
the next reviewer pass then re-found the identical bug at the next site,
burning a full extra pass per site. Real case that motivated this: an
xhigh-effort review of an xbookmark browser-source PR found the same
silent-truncation / session-expiry-swallowed class across `walk_timeline`,
`get_tweet`, capture, and resync over five separate passes, one site per pass.

Added a bounded carve-out (new step 3 in the fix prompt's "What to do"): when a
finding's root cause is an instance of a recurring pattern, grep the worktree
for the other sites with the SAME defect and apply the identical remedy to all
of them in this pass, naming the extra sites in the final message. Explicitly
scoped: it is the one exception to scoped-edits and is NOT license for unrelated
refactors/renames/improvements. ERB renders unchanged (prose-only, no new
binding); `prompt_injection_test.rb` (13) still green. Updated [[stages/review]]
Phase 4. Shipped on the same branch as the triage-retry / error-surfacing work
(PR #512).

# babysitter FIFO skip-log guard

**Action:** Hardened the dry-run `git` / `gh` stub skip-log path after a patrol finding showed that opening a FIFO `HIVE_BABYSITTER_DRY_RUN_LOG` for write could block before the existing post-open regular-file check ran. Read `.llm-wiki/config.json`, searched QMD and the configured master wiki path, then checked [[commands/babysit]], [[modules/babysitter]], [[testing]], and the previous skip-log hardening fragment before changing code.

**Result:** `bin/hive-babysitter-stub-git` and `bin/hive-babysitter-stub-gh` now preflight existing skip-log targets with `File.lstat`, require regular files owned by the current uid before open, open with `File::NOFOLLOW | File::NONBLOCK`, and keep the post-open `fstat` guard for races. FIFO, symlink, device, and ownership failures still warn while the command remains skipped.

**Coverage:** Added `test_stubs_refuse_fifo_skip_log_without_hanging` in `test/unit/babysitter/dry_run_env_test.rb`; it uses a FIFO log path for both stubs and asserts they exit successfully with warning/skip stderr instead of hanging. Refreshed [[commands/babysit]], [[modules/babysitter]], and [[testing]]. No new wiki page was needed, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-18
slug: review-phase-helper-coverage-audit
pages: [testing, gaps, index]
---

Refreshed wiki planning/documentation coverage after commit `e5c26edc`
added `test/unit/stages/review/phase_failure_helpers_test.rb` and amended
the existing triage retry/error-surfacing log fragment. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first; `qmd search "triage retry error surfacing review phase failure helpers"` found the current [[stages/review]] coverage and no relevant configured master-wiki hit was found.

Inspected the committed diff plus current `lib/hive/stages/review.rb`,
`test/unit/stages/review/phase_failure_helpers_test.rb`,
`test/integration/run_review_test.rb`, [[stages/review]], [[testing]], and
[[gaps]]. [[stages/review]] was already source-synced for
`run_triage_with_retries`, `review.triage.max_attempts`, capped backoff, and
bounded terminal `message=` surfacing. Updated [[testing]] to list the new
unit helper suite and to describe the integration coverage for transient
triage retry recovery plus terminal triage `message=` surfacing. Updated
[[gaps]] to carry forward that the helper tests do not close the live
~5.5-minute triage failure uncertainty; the next live failure still needs the
new `message=` attr to identify the underlying trigger. Page count stayed 80;
[[index]] freshness metadata was bumped only because coverage metadata changed.
Did not edit compiled [[log]] and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-18
slug: babysitter-gh-short-w-value-options
pages: [commands/babysit, modules/babysitter, testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`1dab816a` changed `bin/hive-babysitter-stub-gh` and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "babysitter dry-run"`
surfaced prior babysitter fragments; `qmd search "babysitter gh stub short -w
workflow dry-run"` had no exact hit. The configured master wiki path had no
Hive-specific guidance. The compiled [[log]] is stale relative to newer
`wiki/log.d/` fragments, so recent babysitter fragments were checked directly
without editing [[log]].

Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`,
`test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]],
[[modules/babysitter]], [[testing]], and [[gaps]]. The GH dry-run stub still
skips browser-launch forms such as `--web`, bare `-w`, and short clusters where
`w` is parsed as an option flag. It now keeps command-specific value-taking
options from misclassifying `w` inside their values: examples pinned by tests
include `gh pr diff 42 -eworkflow.yml`, `gh pr list -lwip`, `gh pr view 42
-qweb`, and `gh pr list --search -wip`. Updated command/module/testing coverage
and recorded the remaining uncertainty that no checked-in artifact proves a full
live-agent `hive babysit --once PROJECT --dry-run` run after this GH stub parser
change. Page coverage stayed within existing pages, so [[index]] did not need a
catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-18
slug: review-triage-doc-coverage-audit
pages: [state-model, modules/markers, testing, stages/review]
---

Audited the post-commit wiki coverage for commit `094dbb25`
(`fix(review): retry transient triage failures and surface the real error`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], recent [[log]] entries, and the committed triage refresh fragment
first. Per project protocol, ran read-only
`qmd search "triage retry review phase error message REVIEW_ERROR"`; the index
still reflected pre-refresh text, so verification used the committed diff plus
direct source/wiki reads and the configured master wiki path, which had no
matching prior context.

Confirmed [[stages/review]] and [[gaps]] already captured the main behavior:
`run_triage_with_retries` mirrors reviewer retry budgets for transient triage
errors, `review.triage.max_attempts` defaults to
`Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS`, tamper and provider-limit
outcomes short-circuit, and non-limit phase failures now stamp a capped
`message=` attr. Refreshed adjacent marker/testing coverage so
[[modules/markers]] and [[state-model]] document the optional `message=` attr
on `REVIEW_ERROR`, and [[testing]] plus [[stages/review]] mention the new
transient triage retry and message-surfacing assertions in
`test/integration/run_review_test.rb`.

No new page was added, so [[index]] page coverage did not change. The live
root cause of the original ~5.5-minute triage failure remains uncertain and is
still recorded in [[gaps]]; the next live failure should now expose the cause
through the marker `message=` attr. Did not edit compiled [[log]] and did not
run `qmd update` or `qmd embed`.

---
date: 2026-06-17
slug: triage-retry-and-error-surfacing
pages: [stages/review, gaps, testing]
---

Diagnosed a real stuck task (`xbookmark` #1333 "Add an X bookmarks feature",
slug `we-need-to-add-an-260616-094b`) parked in `6-review`. Root sequence:
codex reviewer hit a ChatGPT usage limit in the morning (resolved on reset),
but every full run then failed at the **triage** phase ~5.5 min in
(`REVIEW_ERROR phase=triage reason=triage_failed`, no `retry_after`, so the
daemon never auto-retried). Two failures couldn't be diagnosed because
`mark_review_phase_failure` only used `triage_result.error_message` to test for
a provider limit and then **discarded** it — the terminal marker recorded only
a bare `reason=triage_failed`, which `marker_summary` (web `diagnostic.summary`
+ `status.md`) and the bot surfaced as a contentless "the review agent
crashed."

Two changes in `lib/hive/stages/review.rb`:

1. **Surface the cause.** `mark_review_phase_failure` now stamps
   `message="<condensed error>"` (new `REVIEW_PHASE_ERROR_SUMMARY_MAX = 300`
   cap, whitespace-collapsed, ellipsised) on the non-limit `:review_error`
   marker via new helper `review_phase_error_summary`. Applies to every caller
   (triage / fix / ci). `Hive::Markers.format_attr` already sanitizes quotes,
   newlines, and `<!--`/`-->`; nil/blank collapses to no attr.

2. **Retry transient triage.** Triage previously ran exactly once (reviewers
   already retry). New `run_triage_with_retries` mirrors the per-reviewer
   budget: retries a transient `:error` up to `review.triage.max_attempts`
   (default `Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS = 2`) with the same
   exponential backoff capped at `REVIEWER_BACKOFF_CAP_SEC = 8`
   (`triage_retry_backoff`, extracted as a stubbable seam). `:ok`, `:tampered`,
   and provider-limit outcomes short-circuit (a retry would repeat a tamper;
   a limit self-heals via `retry_after`).

Tests (`test/integration/run_review_test.rb`): updated
`test_triage_non_limit_error_stays_terminal_triage_failed` and
`test_triage_tampered_and_error_statuses_yield_review_error` to stub
`triage_retry_backoff` (keeps them sleepless) and assert the new `message`
attr; added `test_triage_transient_error_is_retried_then_recovers` (error
once → `:ok`, asserts two triage calls and recovery to `review_waiting`).
Added `test/unit/stages/review/phase_failure_helpers_test.rb` so the 100%
coverage gate also covers long-message truncation and the real capped backoff
helper without sleeping.
Full `run_review_test.rb` (50) + markers/task_action/status/web-dispatcher/
notification-builders/run_reviewers unit suites green; rubocop clean.

Updated [[stages/review]] (triage retry + `message=` surfacing). Recorded in
[[gaps]] that the underlying ~5.5-min triage failure cause on the live box is
still unconfirmed — the surfacing fix is what will reveal it on the next run;
leading hypotheses are a transient `tmux has-session` failure under swap
exhaustion (no OOM-kill in the kernel log; the box had 130 agent procs and
full swap) misread as `tmux_session_terminated`, or the interactive `claude`
agent ending its turn before writing `escalations-NN.md`. Did not edit
compiled [[log]]; page coverage unchanged so [[index]] not edited.

## [2026-06-17T22:23:12Z] wiki — audit current LLM wiki refresh coverage

**Action:** Refreshed the LLM wiki state by auditing the existing local wiki
edits and recent `main` history through `0d0cac16`. Read
`.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent
compiled [[log]] headings, and the latest `wiki/log.d` fragments first.
`qmd search "AgentLimit finalize merged PR triage timeout budget digest patrol
dry-run GIT_EXEC_PATH web agents auth codex device flow reviewer findings
transcript tmux paste"` surfaced the local refresh fragment and updated project
pages. Searched the configured main wiki path `/home/asterio/wikis/master/wiki`
and checked the default cross-project paths; only the configured master path
existed, and it had no relevant Hive-specific guidance for the current source
changes.

Inspected recent git history and the changed source/test files for the June 16
changes: `lib/hive/web/agents_auth.rb`,
`web/app/controllers/agents_controller.rb`,
`web/app/views/agents/index.html.erb`,
`lib/hive/reviewers/codex_review.rb`, `lib/hive/tmux_runner.rb`,
`lib/hive/stages/finalize.rb`, `lib/hive/agent_limit.rb`,
`lib/hive/stages/review/triage.rb`, plus focused tests under
`test/unit/web/`, `web/test/integration/`, `test/unit/reviewers/`, and
`test/unit/agent_limit_test.rb`. Verified the current local wiki edits cover
Codex `--device-auth`, operator-ward Agents-page polling, PTY output scrubbing,
URL sanitization, favicon assets, native Codex review transcript trimming,
tmux prompt-settle polling before Enter, finalize already-merged short-circuit,
stale rebase-duplicate resync, triage fallback defaults, and the AgentLimit
false-positive test discovery caveat.

No page coverage changed during this audit, so [[index]] did not need a
page-list update. [[gaps]] already records the remaining uncertainty for live
provider/Docker Agents-page login, live native Codex-review transcript trimming,
live Claude/tmux large-prompt settle, and private non-runnable AgentLimit
assertions. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[commands/web]]
- [[decisions]]
- [[gaps]]
- [[modules/agent]]
- [[modules/reviewers]]
- [[stages/brainstorm]]
- [[stages/finalize]]
- [[stages/review]]
- [[testing]]

## [2026-06-17T01:30:55Z] wiki - audit unusable e2e replay coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `6ce31190` changed `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, and existing e2e wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "routes handlers commands executable entrypoints README command API surface"` surfaced prior wrapper/e2e refreshes, and the configured master wiki path only had general route/API coverage guidance. Inspected the committed diff plus current `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[e2e]], [[testing]], and [[gaps]]. Updated [[e2e]] so the replay JSON contract explicitly distinguishes `missing_repro` from `unusable_repro`, updated [[testing]] to name missing and non-executable replay artifact validation, and carried the remaining uncertainty forward in [[gaps]]: no checked-in artifact proves a real retained failure bundle lost executable mode before replay, and no live patrol/babysitter wrapper consumption of the e2e JSON surface was found. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[e2e]]
- [[testing]]
- [[gaps]]

## [2026-06-17T01:21:43Z] e2e - classify non-executable replay repro artifacts

**Action:** Fixed `bin/hive-e2e replay` so a stored `repro.sh` that exists but is not executable is reported as a deterministic replay artifact config failure instead of falling through to the generic outer error rescue. JSON callers now receive `error_kind: "unusable_repro"` with exit `78`. Added focused coverage in `test/e2e/lib/hive_e2e_binary_test.rb` and refreshed [[e2e]] / [[testing]] contract wording. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-17
slug: hive-eval-no-judge-env
pages: [testing, gaps]
---

Refreshed command/API and executable-entrypoint wiki coverage after commit
`ed404213` changed the checkout-local `bin/hive-eval` runner. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. Read-only
`qmd search "bin hive-eval inherited env judge"` surfaced the existing
[[testing]] eval-runner coverage and prior gap/log context; the configured
master wiki path had no matching Hive-specific entries.

Inspected the committed diff plus current `bin/hive-eval`,
`test/eval/support/reporter_test.rb`, the relevant eval support/scenario files,
[[testing]], and [[gaps]]. Documented that `bin/hive-eval` now owns
`HIVE_EVAL_NO_JUDGE`: it passes `1` only when `--no-judge` is present and
otherwise clears an inherited value before invoking `bundle exec rake
test:eval`, so a caller's environment cannot silently downgrade a judged eval
run into structural-only mode. Updated [[gaps]] to record the focused
env-clearing fixture and carry forward the remaining uncertainty: no in-tree
artifact was found for a full `bin/hive-eval` run with real Codex judge/persona
calls enabled after `ed404213`. No page was added, so [[index]] did not need a
catalog update. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

## [2026-06-16T22:30:44Z] wiki — refresh web login, native Codex review, tmux submit, and finalize coverage

**Action:** Refreshed LLM wiki coverage after inspecting recent `main` history
through `0d0cac16`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`,
[[index]], [[gaps]], recent [[log]] entries, and `wiki/log.d` entries first.
`qmd search "AgentLimit finalize merged PR triage timeout budget digest patrol
dry-run GIT_EXEC_PATH web agents auth codex device flow reviewer findings
transcript tmux paste"` returned no results. Searched the configured main wiki
path `/home/asterio/wikis/master/wiki` and the default cross-project wiki paths
that exist; only the configured master path existed, and it had no relevant
Hive-specific guidance.

Started from existing local wiki edits and
`wiki/log.d/20260615T222240Z-agent-finalize-review-refresh.md`, which already
covered `118ed2fd` / `7f088c48` AgentLimit, finalize already-merged PR, and
review-triage default fallback behavior. Extended the refresh across the newer
June 16 changes:

- `5c645734`, `b08703a3`, `c5cd70a9`, `c75f4039`, `70e6ff14`, and `b370e7c3`
  in `lib/hive/web/agents_auth.rb`, `web/app/controllers/agents_controller.rb`,
  `web/app/views/agents/index.html.erb`, `web/app/views/layouts/application.html.erb`,
  and focused web/unit tests. Updated [[decisions]] ADR-035 and [[commands/web]]
  for Codex `--device-auth`, operator-ward Codex/gh polling, Claude paste-back,
  PTY output scrubbing, URL sanitization that splits adjacent URLs, and
  favicon/icon assets.
- `0d0cac16` in `lib/hive/reviewers/codex_review.rb` and
  `test/unit/reviewers/codex_review_test.rb`. Updated [[modules/reviewers]] and
  [[stages/review]] so the native Codex reviewer documents dropping the middle
  exec/thinking/codex transcript before triage.
- `f25896a2` in `lib/hive/tmux_runner.rb` and `test/unit/tmux_runner_test.rb`.
  Updated [[stages/brainstorm]] and [[testing]] so tmux prompt submit is
  documented as pane-tail settle polling before Enter, not a fixed delay.
- `7b17bfd6` in `lib/hive/stages/finalize.rb` and
  `test/integration/run_finalize_test.rb`. Updated [[stages/finalize]] for the
  patch-identical stale rebase duplicate resync path and the guardrail that
  genuine local-only commits still become `ERROR reason=unpushed_commits`.

Refreshed [[active-areas]] with the latest inspected commits. Updated [[gaps]]
with dated uncertainty for live-provider/Docker Agents-page login, live native
Codex review transcript trimming, and live Claude/tmux large-prompt settle
evidence. Page count stayed 80, so [[index]] did not need a catalog update.
Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[commands/web]]
- [[decisions]]
- [[gaps]]
- [[modules/reviewers]]
- [[stages/brainstorm]]
- [[stages/finalize]]
- [[stages/review]]
- [[testing]]

---
date: 2026-06-16
slug: clipboard-capture-coverage-audit
pages: [testing, gaps]
---

Audited post-commit wiki coverage after commit `5389920e`
(`test(tui): stabilize clipboard capture coverage`) changed
`test/unit/tui/clipboard_test.rb`, [[testing]], and a prior wiki log fragment.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], and recent [[log]] entries first. `qmd search "clipboard capture TUI
coverage fixture"` only surfaced older TUI image-input history, and the
configured master wiki path had only a general array-form subprocess lesson, so
verification used the committed diff plus direct reads of
`lib/hive/tui/clipboard.rb`, `test/unit/tui/clipboard_test.rb`,
[[commands/tui]], [[testing]], and [[gaps]].

Confirmed the production `Hive::Tui::Clipboard::DefaultShim.capture3` did not
change; only the unit test's generic stdout/stderr and timeout subprocess
fixture moved from nested `RbConfig.ruby` to temporary executable shell scripts
so coverage-injected `RUBYOPT` cannot dominate unrelated timeout assertions.
Updated [[testing]] to add explicit `tui/clipboard_test.rb` unit-suite coverage,
and recorded in [[gaps]] that no checked-in artifact proves the hosted Ruby
3.4.9 coverage job passed after `5389920e` or that the real OS clipboard probes
were live-smoked after this test-only fixture change. Page count stayed 80, so
[[index]] did not need a page-list update. Did not run `qmd update` or
`qmd embed`.

---
date: 2026-06-16
slug: clipboard-capture-coverage-fixture
pages: [testing]
---

Stabilized `Hive::Tui::Clipboard::DefaultShim.capture3` coverage after the
hosted Ruby 3.4.9 CI job showed
`HiveTuiClipboardTest#test_default_shim_capture3_success_and_timeout_paths`
timing out before the success-path child wrote stdout. The production shim did
not change. The test now uses temporary executable shell fixtures for the
generic stdout/stderr and timeout paths instead of spawning `RbConfig.ruby`,
because coverage prepends `RUBYOPT=-Itest -rhive_coverage_boot` and nested Ruby
startup latency can leak into unrelated timeout assertions.

Updated [[testing]] with the fixture guideline. No page-list update was needed.

---
date: 2026-06-16
slug: hive-e2e-replay-unusable-repro
pages: [commands, e2e, testing, gaps]
---

Refreshed command/API and executable-entrypoint wiki coverage after commit
`cb986b33` changed `bin/hive-e2e` and
`test/e2e/lib/hive_e2e_binary_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hive-e2e replay
unusable_repro non executable repro"` returned no indexed hits, and the
configured master wiki path had no matching `hive-e2e` / `repro.sh` context, so
verification used the committed diff plus direct source and wiki reads.

Documented that `bin/hive-e2e replay RUN_ID SCENARIO` now validates the stored
`repro.sh` as a regular executable file before the no-shell `exec`. Missing
repro scripts still report `missing_repro`; existing but non-executable or
otherwise non-regular scripts report `unusable_repro`; both are config failures
with exit `78` and `hive-e2e-error` JSON envelopes when `--json` is requested.
Refreshed [[commands]], [[e2e]], and [[testing]], and carried forward the
uncertainty in [[gaps]]: the new path is focused-test pinned, but no in-tree
artifact shows a live patrol/babysitter wrapper consuming the
`unusable_repro` replay error. Page coverage did not change, so [[index]] did
not need a catalog update. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-16
slug: codex-device-auth-url-sanitize
pages: [decisions, gaps]
---

Decisions captured for the hivebox web agent-login relay
(`lib/hive/web/agents_auth.rb`, the PTY OAuth relay from ADR-035).

**codex login uses the headless device-flow.** `AGENT_COMMANDS["codex"]`
changed from `codex login` to `codex login --device-auth` (#502). Plain
`codex login` is a localhost-callback OAuth: it starts a server on the
*container's* `localhost:1455` and prints that as the first URL, which the
operator's host browser can never reach across the container boundary, and
which `URL_RE` would surface ahead of the real provider URL. `--device-auth`
is the RFC-8628 device-flow (one authorize URL + a one-time code entered at
the provider) — codex itself recommends it "on a remote or headless machine".

**Surfaced URLs are sanitized before becoming an href.** Agents print the
device link wrapped in terminal control sequences (codex: `\e[94m<url>\e[0m`).
`URL_RE` only stops at whitespace, so the raw match carries those bytes.
`sanitize_url` now replaces each `TERMINAL_CONTROL_RE` run with a **space**
(not a deletion — deleting would splice two back-to-back URLs into one href,
`…/device\e[0mhttps://evil` → `…/devicehttps://evil`) and re-extracts the
first whitespace-terminated URL via `URL_RE`. This drops the trailing color
reset, OSC-8 wrapper residue, and any trailing second URL.

**Known gap (see [[gaps]]):** codex `--device-auth` (and `gh`) are
*operator-ward* device flows — the one-time code is entered at the provider
and the CLI polls in the background; nothing is pasted back. The relay's
login-status view still shows a `required` paste-code form and stops polling
once the URL is captured, so the token saves but the UI does not auto-reflect
completion. A follow-up reworks the view/controller to keep polling until
`session.done` and suppress the paste form for poll-type agents.

## [2026-06-16T05:18:10Z] wiki - audit residual babysitter gh positional host refresh

**Action:** Audited residual wiki commit `240cba0a`, which committed the previous babysitter dry-run documentation refresh after source commit `815bab46`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first. `qmd search "babysitter dry-run gh scp positional host override"` returned no hits, and the configured master wiki path had no matching context, so verification used the committed diff plus direct source/wiki reads.

**Findings:** Verified `240cba0a` against `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], and [[gaps]]. The command, module, and gap pages already documented scp-style `git@host:owner/repo` repo selectors, positional `gh repo view` / `gh pr {view,diff,checks}` host targets, safe bare slug/numeric/branch passthrough, and the still-open live-agent `hive babysit --once PROJECT --dry-run` smoke gap. Refreshed [[testing]] because its `dry_run_env_test.rb` coverage row still described only the older `HOST/OWNER/REPO`/URL host-selector cases and omitted the new scp-form, positional-host, and safe passthrough assertions. Page coverage stayed within existing pages, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]

## [2026-06-16T05:13:19Z] wiki - refresh babysitter dry-run gh positional host coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `815bab46` changed `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, and [[modules/babysitter]]. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first. `qmd search "babysitter dry-run gh scp positional host override"` and the configured master wiki path had no matching context, so verification used the committed diff plus direct source/wiki reads.

**Findings:** [[modules/babysitter]] already carried the source-level update from the fix commit. Refreshed [[commands/babysit]] so the user-facing dry-run command contract documents scp-style `git@host:owner/repo` repo selectors, positional `gh repo view` / `gh pr {view,diff,checks}` host targets, and the safe bare slug/numeric/branch forms that still pass. Refreshed [[gaps]] to make `815bab46` the latest dry-run host-override checkpoint and keep the live-agent `hive babysit --once PROJECT --dry-run` smoke gap explicit.

**Refreshed pages:**
- [[commands/babysit]]
- [[gaps]]

## [2026-06-16T05:10:56Z] fix - reject scp-form and positional host overrides in dry-run gh stub

**Action:** 6-review pass 03 fix for `bin/hive-babysitter-stub-gh`. Closed two host-override bypasses the argv flag gate missed:

1. **scp-style `--repo`/`-R` value** — `repo_value_selects_host?` keyed on `://` or a non-`1` slash count, so `git@host:owner/repo` (one slash, no scheme) was waved through as a bare slug and reached real gh against an agent-chosen host. Now any colon disqualifies the value (covers both `scheme://` URLs and scp `host:owner/repo`).
2. **Positional host-qualified targets** — `host_override?` only inspects `-R`/`--repo`/`--hostname` flags, so `gh repo view HOST/owner/repo` and `gh pr {view,checks,diff} https://host/owner/repo/pull/N` carried the host as a positional operand. Added `positional_host_override?(rest)` (wired into the gate): it rejects `repo view` operands with a colon or a second slash, and `pr view/checks/diff` operands containing `://`. The multi-slash slug rule is scoped to `repo view` because `gh api repos/owner/repo` endpoints and `gh pr view feature/branch` refs legitimately carry slashes. A `target_operands` helper skips gh's value-taking read flags (`--repo`/`-R`, `--branch`/`-b`, `--json`, `--jq`/`-q`, `--template`/`-t`) so a `--branch feature/x/y` or `--json a,b` value is not mistaken for a host.

**Tests:** Extended `test/unit/babysitter/dry_run_env_test.rb` — skips for `gh -R git@host:owner/repo …`, `gh repo view <HOST/slug|url|scp>`, and `gh pr {view,diff,checks} <url>`; passes for `gh repo view owner/repo`, `gh pr view 42`, and `gh pr view feature/topic/branch` (and the pre-existing `gh api repos/owner/repo` guard confirms the slug rule stays off api).

**Verified:** `ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (17 runs, 1203 assertions, 0 failures) and `ruby -Itest test/babysitter/acceptance/dry_run_test.rb` (1 run, 11 assertions). Rubocop clean on both edited files; `ruby -c` clean on the stub.

**Refreshed pages:**
- [[modules/babysitter]]

## [2026-06-16T04:54:27Z] wiki - audit babysitter gh host env dry-run coverage

**Action:** Refreshed LLM wiki command/API and executable-entrypoint coverage after commit `5668015c` changed `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, and existing babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first. `qmd search "babysitter gh host override dry-run env glued -R"` returned no hits, so direct `rg` searches across this wiki and the configured master wiki path were used; they found the existing babysitter/gaps/testing/log coverage and no Hive-specific master guidance. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the existing command/module/testing pages already describe the current dry-run `gh` boundary: host overrides are rejected across argv, glued host-qualified `-R<value>` / `-R=<value>` selectors skip, safe glued bare `-Rowner/repo` remains allowed for read-only calls, and allowed `gh` passthrough scrubs `GH_HOST`, `GH_REPO`, `GH_ENTERPRISE_TOKEN`, and `GITHUB_ENTERPRISE_TOKEN`. Updated [[gaps]] so the latest uncertainty and open live-smoke gap name HEAD commit `5668015c` instead of only the preceding wiki/source commits. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Verified:** `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` passed (17 runs, 1139 assertions). This shell exports `GIT_EXEC_PATH=/usr/lib/git-core`; the focused command intentionally unsets it because the git dry-run stub treats that env seam as unsafe before allowed git reads reach the fake binary.

**Refreshed pages:**
- [[gaps]]

## [2026-06-16T04:42:58Z] wiki - refresh babysitter gh host override residual commit

**Action:** Refreshed LLM wiki planning/documentation coverage after commit `04631bcf` committed residual wiki edits for the babysitter dry-run `gh` host-override audit. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host override dry-run wiki refresh"` surfaced existing Hive babysitter/gaps/testing/log context, and the configured master wiki path had no Hive-specific guidance. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. While inspecting, current worktree source/test edits expanded the same boundary to cover glued short `-R` repo selectors and `GH_HOST` / `GH_REPO` enterprise env scrubbing; the safe glued `-Rowner/repo` expectation initially failed because the classifier did not strip glued safe `-R` before read-only classification, so this refresh added that source fix before documenting the behavior.

**Coverage:** Confirmed the latest residual commit refined existing babysitter wiki/gap wording, then synced the command/module/testing docs to the current source-level dry-run boundary: `gh` host overrides are rejected anywhere in argv, host-qualified `--repo` / `-R` values skip, glued host-qualified `-R<value>` / `-R=<value>` skips, bare `OWNER/REPO` selectors remain allowed, `gh auth status` token/host selectors skip, and allowed `gh` passthrough scrubs host/repo/enterprise env selectors. Updated [[gaps]] to tie the remaining live-smoke uncertainty to the latest wiki-only commit, source commits inspected, and current worktree source/test coverage. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

## [2026-06-16T04:33:59Z] wiki - audit babysitter gh host override hardening

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `5c38a526` expanded the babysitter dry-run `gh` host hardening, and after HEAD commit `b30484b4` added a residual gap note. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host override dry-run wiki refresh"` surfaced existing Hive babysitter, gaps, testing, and log context, while the configured master wiki path had no matching Hive-specific guidance. Inspected `git show` for `HEAD`, `5c38a526`, and `a86ca033`, plus current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the current docs mostly matched source: dry-run `gh` now skips host overrides anywhere in argv, not only leading globals; only bare `OWNER/REPO` repo selectors remain allowed; host-qualified `--repo`/`-R`, command-position `--hostname`, and `gh auth status` `-h` / `-h<host>` / `-ah` all skip and log. Tightened [[commands/babysit]] test coverage wording, updated [[gaps]] so the open live-smoke uncertainty names source commit `5c38a526` and the expanded host-selector cases, and left [[index]] unchanged because page coverage did not change. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[gaps]]

## [2026-06-16T04:28:23Z] babysitter - default-deny every dry-run gh host override

**Action:** Closed the residual host-selector bypasses in `bin/hive-babysitter-stub-gh`. The gate classifies the *stripped* argv but `exec`s the *original*, so the prior fix (rejecting only leading `--hostname` globals) still let host overrides through: a host-qualified `--repo`/`-R`/`--repo=` value (`HOST/OWNER/REPO` or a URL) and a command-position `--hostname`/`--hostname=` on `gh api` / `gh auth status` both reached the real gh against an agent-chosen host. Added a `host_override?(argv)` check that scans the whole argv (so leading *and* trailing forms are caught) and a `repo_value_selects_host?` helper that allows only the bare `OWNER/REPO` slug (exactly one slash, no scheme). Extended `auth_status_read_only?` with `auth_status_selects_host?` so the short `-h <host>` / `-h<host>` and clustered `-ah` hostname selectors are skipped too — `-h` stays scoped to `auth status` because it means `--help` on other gh subcommands.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with skip+log regressions for `gh auth status -h/--hostname/-ah`, host-qualified `--repo`/`-R` leading and trailing the subcommand (including the URL form), and command-position `gh api ... --hostname`. The previously passing `gh auth status -h github.com` / `-hgithub.com` cases now assert skipped.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (16 runs, 1110 assertions, 0 failures); `bundle exec rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb` (no offenses).

**Links:** [[modules/babysitter]], [[testing]]

## [2026-06-16T04:23:15Z] wiki - audit residual babysitter gh-hostname wiki commit

**Action:** Refreshed LLM wiki coverage after commit `ede81ac7` committed residual wiki changes for the babysitter gh-hostname dry-run audit. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh hostname dry-run audit"` returned the current babysitter module page, and the configured master wiki path had no additional Hive-specific guidance. Inspected the committed diff plus the source commit `a86ca033`, current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the documented `gh --hostname` boundary matches source: only repo selectors are stripped before classification, leading hostname overrides fail closed and are logged/skipped, and subcommand-local non-token `gh auth status -h github.com` remains allowed. Added source-synced notes for the git dry-run env seams that were still under-described in command/module docs (`GIT_EXEC_PATH`, `GIT_ASKPASS`, `SSH_ASKPASS`) and carried forward the existing uncertainty that no checked-in live-agent dry-run smoke artifact exists after the gh-hostname hardening. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[gaps]]

## [2026-06-16T04:14:15Z] wiki - audit babysitter gh hostname dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `a86ca033` changed `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[modules/babysitter]], [[testing]], and a prior implementation log fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "dry-run gh arbitrary host patrol host allowlist"` surfaced existing patrol/babysitter dry-run history, and direct wiki/source search found the current module/testing coverage. Inspected the committed diff plus the current gh stub, focused dry-run tests, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

Confirmed the executable boundary: dry-run `gh` now strips only repo selectors (`-R`, `--repo`, `--repo=...`) before read-only classification. Leading `--hostname <host>` and `--hostname=<host>` remain in argv, fail the allowlist, are logged as skipped, and do not exec the real `gh`, while subcommand-local non-token `gh auth status -h github.com` remains an allowed read. Updated [[commands/babysit]] and [[gaps]] to name that boundary and the remaining uncertainty. Page coverage stayed within existing command/module/testing/gap pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

## [2026-06-16T04:03:26Z] babysitter - block dry-run gh hostname overrides

**Action:** Hardened `bin/hive-babysitter-stub-gh` so the dry-run `gh` stub strips only known-safe leading repo selectors before allowlist classification. Other leading globals now fail closed, including `--hostname <host>` and `--hostname=<host>`, so an otherwise read-only `gh api` or `gh auth status` call cannot redirect authenticated traffic to an agent-chosen host.

**Coverage:** Added `test_gh_stub_skips_leading_hostname_overrides` to `test/unit/babysitter/dry_run_env_test.rb`, proving both separate and glued hostname forms are skipped, logged, and do not reach the fake real `gh` binary.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[testing]]

## [2026-06-16T01:36:21Z] wiki — refresh PR URL coverage-gate documentation

**Action:** Refreshed wiki planning/documentation coverage after commit
`03af0d71` (`test: cover PR URL defensive branches`) added focused tests for
three previously uncovered defensive paths and touched [[testing]] plus a wiki
log fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "PR URL
defensive branches status dispatcher pr_url"` found existing state-model/log
context, and the configured master wiki path had no matching PR URL or digest
scheduler entries.

Inspected the committed diff plus current `lib/hive/pr.rb`,
`lib/hive/commands/status.rb`, `lib/hive/daemon/dispatcher.rb`,
`test/unit/pr_test.rb`, `test/unit/commands/status_test.rb`,
`test/unit/daemon/dispatcher_test.rb`, [[modules/pr]], [[commands/status]],
[[modules/daemon]], [[modules/digest]], and [[testing]]. Updated [[modules/pr]]
so its API/test coverage includes the shared `valid_http_url?` link-safety
predicate and invalid-URI rejection; updated [[modules/daemon]] and
[[modules/digest]] to document digest scheduler `tick` / `complete` fatal-log
isolation and dry-run pseudo-child completion; and carried the new focused-test
coverage into [[gaps]] while preserving the missing live digest, TTY, status,
and Telegram smoke uncertainties. Page coverage did not change, so [[index]]
did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/pr]]
- [[modules/daemon]]
- [[modules/digest]]
- [[gaps]]
- [[log]]

## [2026-06-16T01:31:37Z] tests — close PR URL coverage gate gaps

**Action:** Fixed the local `bundle exec rake coverage` failure on PR #491
after the assertion suite passed but the 100% line gate reported three
uncovered defensive branches. Added focused unit coverage for
`Hive::Pr.valid_http_url?` invalid-URI rejection, `Status#pr_url_for`'s quiet
`Errno::ENOENT` degradation when `pr.md` vanishes mid-scan, and
`Dispatcher#reap_dry_run` fatal-log isolation when digest scheduler completion
raises. Verified `bundle exec rake coverage` now reports 100.00% line coverage
with 5450 runs, 21267 assertions, 0 failures, and 0 errors. Did not rebase the
branch because the failure reproduced on the current PR head and was unrelated
to the 4 commits behind `origin/main`.

**Refreshed pages:**
- [[testing]]

## [2026-06-15T23:09:55Z] wiki - audit residual babysitter dry-run HEAD docs

**Action:** Refreshed wiki planning/documentation coverage after HEAD commit `5e8723fa`, a residual wiki commit that updated [[testing]], [[gaps]], and added the `20260615T225615Z-babysitter-dry-run-residual-audit` fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent compiled [[log]] entries, and the latest babysitter fragments first. `qmd search "wiki refresh committed diff documentation coverage babysitter stub gh"` surfaced existing babysitter residual-audit context, and the configured master wiki path had no separate matching cross-project pattern.

**Refresh:** Inspected HEAD commit `5e8723fa`, residual commits `2d15e9ee` and `6a6cf990`, and source commit `f12c46c7` against current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, and `test/unit/babysitter/dry_run_env_test.rb`. Confirmed the current source/test contract still matches the babysitter dry-run docs: wrapper launchers pin parent-resolved real binaries, the `gh` launcher passes only the parent-resolved config directory through `HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR`, the `gh` stub clears command-local config/home env before restoring that trusted path with `HOME=File::NULL`, and the `git` stub fail-closes on the current exec-capable env seams. Refreshed [[commands/babysit]] so its dry-run test summary names the private trusted-config override regression, and consolidated the repeated residual-audit live-smoke uncertainty in [[gaps]]. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[gaps]]

## [2026-06-15T22:56:15Z] wiki - audit residual babysitter dry-run docs

**Action:** Refreshed wiki planning/documentation coverage after commit `2d15e9ee`, a residual wiki commit that updated [[commands/babysit]], [[modules/babysitter]], [[gaps]], and added the `20260615T222502Z-babysitter-gh-config-home-residual-audit` fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and both top/tail recent compiled [[log]] entries first. `qmd search "babysitter gh config home dry-run residual audit trusted GH_CONFIG_DIR"` returned no indexed hits in this checkout, so verification fell back to `rg`, the committed diff, the configured master wiki path, and direct source/wiki reads.

**Refresh:** Inspected residual commit `2d15e9ee`, prior residual commit `6a6cf990`, and source commit `f12c46c7` against current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, and `test/unit/babysitter/dry_run_env_test.rb`. Confirmed the existing command/module coverage matches the code: the dry-run `gh` wrapper captures the parent GitHub config directory before command-local env can redirect it, the `gh` stub restores only that trusted path while setting `HOME` to `File::NULL`, and the `git` stub fail-closes on `GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS`. Refreshed [[testing]] so the dry-run test map names those same regression seams and the private trusted-config handoff, and carried the unchanged live-smoke uncertainty forward in [[gaps]]. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[gaps]]

## [2026-06-15T22:25:02Z] wiki - audit residual babysitter gh config-home docs

**Action:** Audited residual wiki commit `6a6cf990`, which committed the previous babysitter dry-run documentation refresh for source commit `f12c46c7`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent compiled [[log]] entries, and the latest 2026-06-15 babysitter log fragments first; `qmd search "babysitter gh config home dry run trusted gh config dir"` surfaced the current babysitter command/module/testing/gap coverage, and the configured master wiki path had no matching project-specific context. Inspected the residual diff plus current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Refresh:** Confirmed the committed `gh` config-home coverage matches the code: the dry-run wrapper captures the parent GitHub config directory before command-local env can alter it, and the shared `gh` stub re-exposes only that trusted path while setting `HOME` to `File::NULL`. While auditing the same touched pages, corrected stale git dry-run env-seam prose in [[commands/babysit]] and [[modules/babysitter]] so it includes the current `GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS` guards already present in source, tests, and [[gaps]]. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. The uncertainty remains unchanged: no checked-in artifact proves a full live `hive babysit --once PROJECT --dry-run` agent run after the latest dry-run stub/env hardening. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[gaps]]

## [2026-06-15T22:22:40Z] wiki — refresh agent-limit, finalize, and review triage coverage

**Action:** Refreshed LLM wiki coverage after inspecting recent `main` history through
`7f088c48` and the current source files changed by commits `118ed2fd` and
`7f088c48`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`,
[[index]], [[gaps]], and recent [[log]] / `wiki/log.d` entries first. Ran
`qmd search "AgentLimit finalize merged PR triage timeout budget digest patrol
dry-run GIT_EXEC_PATH"` and searched the configured main wiki path
`/home/asterio/wikis/master/wiki` plus the default cross-project wiki paths
that exist; no Hive-specific cross-project guidance matched the new
AgentLimit/finalize/triage changes.

Verified `lib/hive/agent_limit.rb`, `lib/hive/agent.rb`,
`lib/hive/stages/finalize.rb`, `lib/hive/stages/review/triage.rb`, and the
focused tests in `test/unit/agent_limit_test.rb`,
`test/integration/run_finalize_test.rb`, and
`test/unit/stages/review/triage_test.rb`. Updated [[modules/agent]] so
provider-limit classification documents raw-stream limit capture and the
usage-qualified limit pattern that avoids UI-feature false positives. While
checking test discovery, found the new AgentLimit UI-feature/time-window
assertions below a `private` marker; a standalone Minitest check showed private
`test_*` methods are not runnable, so [[testing]] and [[gaps]] record that as a
coverage gap rather than confirmed runnable coverage. Updated
[[stages/finalize]] for the direct already-merged PR short-circuit
(`COMPLETE merged=true`, no body-refresh agent, no `summary.md`). Updated
[[stages/review]] for the `review_triage` fallback budget/timeout values
matching `Config::DEFAULTS` (75 / 1800), refreshed [[testing]] coverage rows,
carried the remaining live-smoke uncertainty into [[gaps]], and refreshed
[[active-areas]] with the latest inspected commits.

No page coverage changed, so [[index]] did not need a page-list update. Did not
edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/agent]]
- [[stages/finalize]]
- [[stages/review]]
- [[testing]]
- [[gaps]]
- [[active-areas]]

## [2026-06-15T21:59:17Z] wiki — audit babysitter gh config-home dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `f12c46c7` changed `bin/hive-babysitter-stub-gh`, `Hive::Babysitter::DryRunEnv`, and dry-run tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], recent [[log]] entries, and relevant 2026-06-15 babysitter log fragments first; `qmd search "babysitter gh HOME redirects config dry-run stub env"` surfaced existing babysitter command/test/gap coverage, while the configured master wiki path had no matching project-specific context. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Refresh:** Documented that the dry-run `gh` wrapper captures the parent GitHub config directory (`GH_CONFIG_DIR`, else `XDG_CONFIG_HOME/gh`, else `HOME/.config/gh`) in `HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR`; the shared `gh` stub deletes command-local `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`, `HOME`, and the private handoff env, then restores only the trusted path as `GH_CONFIG_DIR` and sets `HOME` to `File::NULL` before allowlisted passthrough. Updated command/module/testing coverage and consolidated the duplicate babysitter dry-run gap entry while carrying the remaining uncertainty forward: no checked-in artifact proves a full live `hive babysit --once PROJECT --dry-run` agent run after the dry-run stub/env hardening. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Verified:** `env -u GIT_EXEC_PATH -u GIT_EXTERNAL_DIFF -u GIT_SSH_COMMAND -u GIT_SSH -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_PROXY_COMMAND -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (16 runs, 1006 assertions). The unsanitized post-commit shell inherited `GIT_EXEC_PATH=/usr/lib/git-core`, which intentionally trips the git dry-run stub's env-seam guard and makes older git passthrough assertions fail even though the sanitized source behavior is green.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-15
slug: patrol-json-coverage-audit
pages: [commands/patrol, gaps]
---

Post-commit wiki coverage audit after commit `77579ae1` committed residual
wiki changes for the `25082ee4` patrol JSON usage-error fix. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "patrol JSON usage error required argument
hive-patrol"` found the current wrapper-contract coverage in [[testing]],
[[cli]], [[gaps]], and [[log]]; the configured master wiki path had no
Hive-specific patrol usage-error guidance.

Inspected the committed diff, source commit `25082ee4`, current `bin/hive`,
`lib/hive/cli.rb`, `lib/hive/commands/patrol.rb`,
`test/integration/cli_usage_error_json_test.rb`,
`test/integration/patrol_command_test.rb`, `test/unit/schema_files_test.rb`,
`schemas/hive-patrol.v1.json`, [[cli]], [[commands]], [[commands/patrol]],
[[testing]], and [[gaps]]. Confirmed the committed [[testing]] and [[gaps]]
refresh describes the `hive patrol --json` missing-`PROJECT` pre-dispatch
envelope. Refreshed [[commands/patrol]] to document that pre-dispatch
`hive-patrol` error payload and to name the current skipped-finding reason
surface.

Recorded a remaining schema/test uncertainty in [[gaps]]: patrol source can
emit `skipped_findings[].reason = "similar_to_existing"`, but
`schemas/hive-patrol.v1.json` and the focused schema validation test do not
cover that reason yet. Page coverage did not change, so [[index]] was not
edited. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

---
date: 2026-06-15
slug: patrol-json-usage-error
pages: [testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`25082ee4` changed `bin/hive` and
`test/integration/cli_usage_error_json_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first. `qmd search "patrol json missing argument
errors prose only required argument command usage"` surfaced the existing
wrapper-contract coverage in [[cli]], [[testing]], and [[gaps]]; the configured
master wiki path had no Hive-specific patrol usage-error guidance.

Inspected the committed diff plus current `bin/hive`,
`test/integration/cli_usage_error_json_test.rb`, [[cli]], [[commands]],
[[commands/patrol]], [[testing]], and [[gaps]]. Confirmed `bin/hive` now
includes `patrol` in `JSON_USAGE_ERROR_CONTRACTS`, so `hive patrol --json`
with no `PROJECT` exits 64 and emits a `hive-patrol` error envelope with
`error_kind: "error"` instead of only prose stderr. The focused integration
test now pins that schema, schema version, `InvalidTaskPath` class, and usage
exit code.

Updated [[testing]] to name the patrol-specific wrapper regression and
refreshed [[gaps]] to cite the current split between the broad
`36f7499a` wrapper mapping and the `25082ee4` patrol fix while preserving the
remaining release-install uncertainty. Page coverage did not change, so
[[index]] was not edited. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

## [2026-06-15T19:28:58Z] status/tui/bot — surface PR URLs from task sidecars

**Action:** Refreshed command/API and TUI surface coverage after commits
`42fd5e2b` (`feat(status): U1 surface PR URLs from task frontmatter`) and
`5e4e1ffa` (`feat(tui): U2 show PR column in tasks pane`), plus follow-up
`408192cb` (`feat(status): U3 show PR column in text output`), `50552435`
(`feat(bot): U4 show PR links in status queue`), and `06e37a80`
(`feat(bot): U5 include PR link in review notification`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] / `wiki/log.d` entries first; `qmd search "status pr_url task
frontmatter hive-status schema"` found existing status/frontmatter coverage, so
verification used the committed diffs plus direct source reads.

Inspected `lib/hive/commands/status.rb`, `lib/hive/pr.rb`,
`lib/hive/bot/status_watcher.rb`, `lib/hive/bot/format.rb`,
`lib/hive/bot/supervisor.rb`, `lib/hive/bot/notification_builders.rb`,
`lib/hive/bot/notification_dispatcher.rb`, `lib/hive/tui/snapshot.rb`,
`lib/hive/tui/views/tasks_pane.rb`, `lib/hive/tui/views/hyperlink.rb`,
`schemas/hive-status.v3.json`, and the focused status/bot/TUI/schema tests.
Documented that `hive-status` v3 task rows now always carry `pr_url`, populated
from `pr.md` frontmatter only at `5-open-pr` and later and `null` on early,
missing, blank, or malformed sidecars; the bot and TUI snapshot preserve that
field; text status/archive output and the TUI render fixed PR columns as
`#<number>` through [[modules/pr]] and wrap valid http(s) links in OSC 8 only on
a TTY; Telegram `/status` and `/queue` render `#<number>` as an HTML link with
dash fallback; and the existing ready-for-review push appends the same PR link
without changing its de-dup fingerprint. Added [[modules/pr]] for the new
formatter helper, updated [[index]] for the new page, and recorded the remaining
missing live TTY/Telegram/open-PR smoke evidence in [[gaps]]. Did not run
`qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[state-model]]
- [[modules/bot]]
- [[modules/pr]]
- [[testing]]
- [[gaps]]
- [[index]]

### 2026-06-15 — Daily digest review fix pass 3

Applied the accepted findings from stage 6-review pass 3:

- **Wedge fix**: the `digest` verb now ships a non-zero default
  `daemon.child_verb_timeouts` (3600s). A wedged `hive digest` child holds the
  single global digest slot (`can_dispatch_digest?`); without a cap a hung
  `ship_times` `git log` or a black-holed Telegram socket would pin the slot
  forever and disable all future digests. User overrides deep-merge, so the
  backstop survives; `{digest: 0}` disables it.
- `Dispatcher#reap_dry_run` now mirrors `reap_completed`'s digest completion
  hook, so a dry-run daemon clears `DigestScheduler`'s `@pending` marker and no
  longer wedges after one digest.
- `ConcurrencyController#record_dispatch` skips the `@daily_counts` increment
  for `kind: :digest` (the early-return in `record_completion` never refunded
  it → one leaked `[project, date]` entry per day).
- Categorizer now converts agent spawn/run `SystemCallError`s (e.g. a missing
  `digest.agent` binary → `Errno::ENOENT` from `Process.spawn`) to
  `ModelError`, so the existing failed-notice path fires instead of failing
  silently.
- Prompt hardening: `templates/digest_prompt.md.erb` fences every per-item
  field (project, display name, title, body) in the per-spawn nonce tag and
  drops the unused, attacker-influenceable PR URL line.
- Renderer caps the display label (`MAX_LABEL_LENGTH`) before escaping, so an
  overlong label can't push a MarkdownV2 link line past Telegram's chunk
  boundary.
- `hive digest --json` emits the `hive-digest` `ErrorPayload` on a bad `--date`
  (`error_kind: config`, exit 78) and now carries the resolved `chat_id`
  (optional, back-compatible) in the success envelope; CLI `long_desc` gains an
  exit-code table and examples.
- Config validates `budget_usd.digest` / `timeout_sec.digest` as positive
  numbers.
- Type/comment polish: symmetric `SendResult` dry_run/chat_id invariant,
  `Sender.blank?` made `private_class_method`, dead `VALID_CATEGORIES` alias
  removed, strip-based `ShippedItem#display_label` blank check, and corrected
  at-least-once / chunker / `RUN_DIR_RETENTION` comments.
- Strengthened the live e2e to inspect the categorizer's `items.json` (every
  fixture id covered, valid category + non-empty summary, at least one
  non-fallback summary) so it can't pass on an empty model response.

**Refreshed pages:**
- [[commands/digest]]
- [[commands/daemon]]

## [2026-06-15T14:57:28Z] wiki — audit babysitter dry-run real-binary handoff coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `c8392dfa` touched `Hive::Babysitter::DryRunEnv`, dry-run tests, and babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the committed source-change fragment first. `qmd search "babysitter HIVE_BABYSITTER_REAL override dry-run"` surfaced older babysitter dry-run context, while the configured master wiki path had no relevant cross-project hit. Inspected the committed diff plus current `lib/hive/babysitter/dry_run_env.rb`, `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], and [[testing]].

**Refresh:** Confirmed the command/module/testing pages already document the wrapper-launcher handoff: the PATH overlay now generates `git` / `gh` launchers that reset `HIVE_BABYSITTER_REAL_GIT` / `HIVE_BABYSITTER_REAL_GH` to parent-resolved paths before execing the shared stubs, preventing command-local overrides from redirecting allowlisted passthrough. Updated [[gaps]] to remove the stale duplicate dry-run entry and carry the current missing-evidence statement forward: no checked-in artifact proves a full live `hive babysit --once PROJECT --dry-run` agent run after the stub and wrapper-launcher hardening. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]

## [2026-06-15T14:49:42Z] wiki — audit babysitter dry-run real-binary handoff

**Action:** Refreshed wiki planning/documentation coverage after commit `f9d2dcf0` changed `Hive::Babysitter::DryRunEnv`, `test/unit/babysitter/dry_run_env_test.rb`, and the babysitter/testing wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run real binary handoff HIVE_BABYSITTER_REAL_GIT HIVE_BABYSITTER_REAL_GH"` returned no indexed hits, so verification used direct source/wiki search plus the configured master wiki path, which had no relevant cross-project context.

**Coverage:** Inspected the committed diff and current `lib/hive/babysitter/dry_run_env.rb`, `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. Confirmed the command/module/testing pages already describe the new wrapper-launcher handoff and command-local `HIVE_BABYSITTER_REAL_*` override resistance. Updated [[gaps]] so the remaining live-agent dry-run smoke uncertainty includes the June 15 wrapper/env hardening. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]

### 2026-06-15 — Daily digest review hardening

- Gated the global digest dispatch through the concurrency controller
  (`kind: :digest`, off the task caps, at most one in flight) and added an
  in-flight backstop so a restart can't double-dispatch the same date.
- `DigestScheduler` now records an escalating failure backoff
  (`60`/`300`/`900`s) on non-zero exit and is reconfigured in place on SIGHUP
  (`digest.enabled` / `max_catchup_days` take effect within one tick).
- Collector logs dropped tasks (`git` failure / degraded `pr.md` read) instead
  of swallowing them; `pr_title` skips the boilerplate `## Summary` heading.
- `ShipTimes` uses a fixed-string (`-F`) grep; `ShippedItem#categorizer_id` is
  project-scoped so cross-project PR-number collisions keep distinct summaries.
- Shared `Hive::Digest::Categories` is the single ordered source for the
  categorizer's valid set and the renderer's section order; renderer escapes
  `)`/`\` in link targets; the runner pre-flights recipient/token before the
  paid categorizer run; `--json` derives `ok` from status.
- `digest.max_catchup_days` now accepts `0` (= unbounded) in the validator.

# tmux-mode stage completion hardening (marker-skip stranding)

Two levers so a tmux agent that finishes its work but returns to idle WITHOUT
stamping the terminal marker no longer strands the stage at `reason=timeout`:

- **Prompt hardening (U1):** `templates/{open_pr,artifacts,finalize,plan}_prompt.md.erb`
  gain a "## Completion — REQUIRED" section restating the exact terminal marker
  as the literal last line ("write it even if all work is already done; no other
  line follows it"). Marker strings unchanged. Runner-owned templates
  (`execute`, `review`) deliberately untouched — there the runner stamps the
  marker. New `test/unit/templates/marker_last_line_test.rb` renders each
  template and pins the marker as the last line.

- **Single bounded timeout re-entry (U2):** `StaleAgentHealer#auto_recoverable_error?`
  now clears-and-re-dispatches `reason=timeout` EXACTLY ONCE
  (`TIMEOUT_RECOVERY_LIMIT = 1`), gated to `TIMEOUT_RECOVERABLE_STAGES`
  (`5-open-pr`, `7-artifacts`). Capped via a new per-reason
  `error_auto_recovery_limit_for` (the general agent-loss budget stays 3), keyed
  by `[project, slug, stage, reason]` so a fresh timeout `marker_id` can't earn a
  fresh budget. After one retry it stays red with a `stage_timeout` exhaustion +
  remediation. open-pr re-enters its `open_pr_already_open` arm; artifacts
  idempotently re-collects `artifact.md`; only `3-plan` (unaffected here) needs
  the explicit requeue.

This **deliberately revises** the rule in
`docs/solutions/architecture-patterns/background-spawn-and-signal-aware-marker-healing-2026-04-28.md`
that `reason=timeout` is never auto-healed: the carve-out is narrow (two stages
whose re-entry is provably idempotent) and bounded (one attempt). See the
refinement note appended to that learning.

Implementation evidence: commits `f06ff172`, `cc10b0b1`, and `027f92eb`;
`templates/{open_pr,artifacts,finalize,plan}_prompt.md.erb`;
`lib/hive/daemon/stale_agent_healer.rb`;
`test/unit/templates/marker_last_line_test.rb`;
`test/unit/daemon/stale_agent_healer_test.rb`; and
`test/integration/daemon_stale_agent_healing_test.rb`.
No committed `docs/plans/2026-06-15-001-fix-tmux-marker-completion-hardening-plan.md`
file was present during the 2026-06-15 wiki refresh. The separate primary fix
(a nudge-on-idle inside `wait_for_terminal_marker`) remains tracked on its own.

---
date: 2026-06-15
slug: golden-path-slug-capture-audit
pages: [testing, gaps]
---

Audited commit `d76b3f60` (`test(web): capture golden-path slug before
navigation`) after it touched `web/test/e2e/golden_path_e2e.rb`, [[testing]], and
`wiki/log.d/20260615T080111Z-golden-path-slug-capture.md`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent compiled
[[log]] entries first. `qmd search "golden path slug capture Capybara stale
task row"` found the current testing/gaps coverage; the configured master wiki
path only had generic Capybara/Turbo guidance.

Verified the committed diff plus current `web/test/e2e/golden_path_e2e.rb`, the
status-grid `.task-slug` markup in `web/app/views/status/_projects.html.erb`,
the prior golden-path DOM-race wiki fragments, and [[testing]]. The current test
uses `task_slug_from_grid!` before `click_task_link!`, then passes that captured
slug to the daemon log/mtime answer-window guard, matching the updated testing
page. Updated [[gaps]] so the golden-path CI uncertainty records the PR #480
`NameError` fix and carries forward the remaining lack of an in-tree hosted
`hivebox web (Rails tests + system)` pass artifact after that fix. Page coverage
did not change, so [[index]] did not need a catalog update. Did not run `qmd update`
or `qmd embed`.

---
date: 2026-06-15
slug: golden-path-slug-capture
pages: [testing]
---

Fixed the PR #480 `hivebox web (Rails tests + system)` failure in
`web/test/e2e/golden_path_e2e.rb`: the test called a nonexistent `task_slug`
helper after navigating away from the status grid, raising `NameError` before
the daemon answer-window wait could run. The test now captures the slug with the
existing current-DOM helper before clicking into the task detail page, then uses
that captured slug for the daemon log/mtime synchronization.

Verified locally with `cd web && bin/rails test test/e2e/golden_path_e2e.rb`,
`bin/rails test`, `bin/rails test:system`, and `bin/rubocop --format github`.
Updated [[testing]] to describe the capture-before-click contract.

# golden-path E2E task slug CI fix

After rebasing PR #479, GitHub Actions failed `hivebox web (Rails tests + system)`
in `web/test/e2e/golden_path_e2e.rb` with:

`NameError: undefined local variable or method 'task_slug'`

The failing line came from the recent golden-path E2E stabilization that added
`task_slug_from_grid!` but then called an undefined `task_slug` local after
navigating to the task page. The documented intent in [[testing]] is to read the
slug from one current-DOM grid query before navigation, then use that stable
slug for the daemon answer-window wait. Updated the test to store
`task_slug = task_slug_from_grid!("Golden path sample idea")` before clicking
the row and pass that value to `wait_for_answer_window!`.

No new wiki page or index update was needed; [[testing]] already describes this
pattern.

**Refreshed pages:**
- [[testing]]

# babysitter askpass dry-run executable coverage

Refreshed command/API and executable-entrypoint wiki coverage after commit
`2b86e674` changed `bin/hive-babysitter-stub-git` and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first. `qmd search "babysitter dry-run git askpass
SSH_ASKPASS GIT_ASKPASS passthrough"` returned no indexed hits; the configured
master wiki path had only generic route/coverage guidance.

Inspected the committed diff plus current `bin/hive-babysitter-stub-git`,
`bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`,
`test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]],
[[modules/babysitter]], [[testing]], and [[gaps]]. Updated the dry-run git
stub contract so the known exec-capable environment seam list includes
`GIT_ASKPASS` and `SSH_ASKPASS`, allowed read passthrough scrubs both variables,
and the real-git argv now injects `-c core.askPass=` alongside
`-c core.fsmonitor=false`. Recorded that focused unit coverage exists, but no
checked-in artifact proves a full live-agent
`hive babysit --once PROJECT --dry-run` run after the askpass hardening. No new
page was needed, so [[index]] page coverage stayed at 78. Did not edit compiled
[[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

# babysitter binary argv skip-log refresh

Refreshed babysitter dry-run wiki coverage after commit `36631816` changed
`bin/hive-babysitter-stub-git` and `bin/hive-babysitter-stub-gh` so
`escape_control_chars` binary-encodes argv before escaping control bytes. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first; [[log]] is stale relative to newer
`wiki/log.d/` fragments, so the latest babysitter fragment was also checked
without editing [[log]].

`qmd search "babysitter skip log hardening dry-run stub"` and `qmd search
"hive babysitter dry-run git gh stub skip log"` found existing local babysitter
coverage; `qmd search "babysitter dry-run git gh stub skip log" -c master` and
the configured master wiki path had no relevant cross-project context.
Inspected the HEAD diff, both current stub files, `test/unit/babysitter/dry_run_env_test.rb`,
[[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

Updated babysitter command/module docs to record that skip-log argv rendering is
byte-scanned: ASCII control bytes are escaped as `\xHH`, invalid/non-UTF-8 bytes
do not raise inside `log_skip`, and high bytes pass through unchanged. Updated
testing/gap coverage to avoid overstating the test state: current tests cover
symlink refusal and ASCII control-character escaping, but this refresh found no
focused invalid/non-UTF-8 argv regression and no live `hive babysit --once
PROJECT --dry-run` artifact. No new wiki page was needed, so [[index]] did not
need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-15
slug: hive-new-wrapper-text-tail
pages: [cli, commands, commands/new, testing, gaps, index]
---

Refreshed command/API and executable-entrypoint wiki coverage after PR #478
fixed `bin/hive` so `hive new PROJECT TEXT...` treats flag-looking
tokens after `PROJECT` as task text instead of wrapper controls. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "wrapper
new task text control flags cli json boolean patrol hive new"` surfaced the
existing wrapper/gaps coverage, and the configured master wiki path had no
project-specific match.

Inspected the committed diff plus current `bin/hive`, `lib/hive/cli.rb`,
`lib/hive/commands/new.rb`, `test/integration/cli_version_test.rb`, [[cli]],
[[commands]], [[commands/new]], [[testing]], and [[gaps]]. Documented the new
`hive new` text-tail boundary: after the registered project argument, `--help`,
`-h`, and malformed-looking `--json=...` tokens remain literal idea text, while
wrapper options before that boundary keep the existing help/JSON validation
behavior. The focused checkout test now proves `hive new PROJECT add --help
docs` and `hive new PROJECT literal --json=yes text` create captured ideas
instead of rendering help or rejecting malformed JSON. Carried forward the
remaining packaging uncertainty: no in-tree artifact proves the RubyGems,
Homebrew, or AUR installed `hive` executable exercises the same wrapper path.

Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

# babysitter dry-run skip-log hardening refresh

Refreshed command/API and executable-entrypoint wiki coverage after commit
`f33ff951` changed `bin/hive-babysitter-stub-git`,
`bin/hive-babysitter-stub-gh`, and `test/unit/babysitter/dry_run_env_test.rb`.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first; the
compiled log is stale relative to newer `wiki/log.d/` fragments, so recent
fragments were also checked without editing [[log]]. `qmd search "babysitter
dry-run skip log symlink realpath stub git gh"` surfaced prior babysitter
dry-run history, and the configured master wiki had no relevant project-specific
hit.

Inspected the committed diff plus the current dry-run git/gh stubs,
`test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]],
[[modules/babysitter]], [[testing]], and [[gaps]]. Resolved the generated wiki
conflict by keeping the current source-backed dry-run surface: exact read-only
`git branch` forms, `git remote show -n`, `gh auth status` token skips,
`gh api` file/cache skips, browser-launch skips, hermetic git passthrough, and
the new skip-log guard. The skip-log coverage records that skipped-command
audit logging now opens the configured skip log with `File::NOFOLLOW`, creates
new logs as mode `0600`, requires a regular file owned by the current uid, warns
without unskipping when the audit sink is unsafe or unavailable, and escapes
ASCII control characters in argv as `\xHH` before writing logs or stderr.
Recorded that this is unit-pinned by the symlinked skip-log and
control-character tests, while the full live
`hive babysit --once PROJECT --dry-run` agent smoke remains missing. No new wiki
page was needed, so [[index]] did not need a catalog update. Did not run
`qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

## [2026-06-15T14:50:47Z] babysitter - block GIT_EXEC_PATH in git dry-run stub

**Action:** Hardened `bin/hive-babysitter-stub-git` so `GIT_EXEC_PATH` is treated like the unsafe `--exec-path` global option: a set value makes the dry-run stub skip even allowlisted reads, and the env var is scrubbed before any real-git passthrough.

**Coverage:** Added a `test/unit/babysitter/dry_run_env_test.rb` regression with a fake `git-remote-https` helper proving `git remote show origin` is skipped when `GIT_EXEC_PATH` points at attacker-controlled helpers. Refreshed [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]] wording for the env seam.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]], [[gaps]]

## [2026-06-15T14:38:51Z] babysitter — pin dry-run real-binary handoff

**Action:** Hardened `Hive::Babysitter::DryRunEnv` so the dry-run PATH overlay generates `git` / `gh` wrapper launchers instead of symlinks directly to the shared stubs. Each launcher overwrites `HIVE_BABYSITTER_REAL_GIT` or `HIVE_BABYSITTER_REAL_GH` with the parent-resolved literal before execing the shared stub, so command-local `HIVE_BABYSITTER_REAL_*` overrides cannot redirect an allowlisted passthrough command to an attacker-chosen binary.

**Coverage:** Added `test_with_env_pins_real_binaries_against_command_local_overrides` to `test/unit/babysitter/dry_run_env_test.rb`, proving allowlisted `git status --short` and `gh repo view` reach the resolved fake real binaries and do not execute command-local override binaries.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]]

### 2026-06-14 — Daily shipped digest

- Added `Hive::Digest`, `hive digest`, and `Hive::Daemon::DigestScheduler` for
  a local-midnight daily Telegram shipped digest across registered projects.
- Added first-class digest config defaults/validation
  (`digest.*`, `budget_usd.digest`, `timeout_sec.digest`, `bot.digest_chat_id`)
  plus deterministic unit coverage and an opt-in live agent + Telegram e2e.

## [2026-06-14T22:28:07Z] wiki — refresh digest command and API coverage

**Action:** Refreshed command/API surface coverage after the digest commit
series through `ab35b657` added the public `hive digest` Thor command,
`Hive::Commands::Digest`, `Hive::Digest::Sender`, and daemon-side
`Hive::Daemon::DigestScheduler`. Current workspace source also adds the global
digest config plumbing (`Config.load_global_digest_block`,
`Config.load_global_digest_config`, `digest.*`, and `bot.digest_chat_id`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "routes
handlers commands executable entrypoints README API surface"` surfaced prior
wiki-refresh patterns, and the configured master wiki path only had general
route/API coverage guidance. Inspected the committed diffs plus the current
digest subsystem (`lib/hive/digest.rb`, `lib/hive/digest/**`,
`templates/digest_prompt.md.erb`, `lib/hive/cli.rb`,
`lib/hive/commands/digest.rb`, `lib/hive/daemon/digest_scheduler.rb`,
`lib/hive/config.rb`) and focused digest/CLI/daemon/config tests.

Documented the new `hive digest [--date YYYY-MM-DD] [--dry-run] [--json]`
command, the `Hive::Digest.run` pipeline, ship-time selection, agent
categorizer output contract, Telegram MarkdownV2 renderer/sender seam, global
digest config loading, daemon scheduling through `Hive::Daemon::DigestScheduler`,
the opt-in live digest E2E, and success-only unregistered `hive-digest` JSON
shape. Added [[commands/digest]] and [[modules/digest]], updated [[cli]],
[[commands]], [[commands/daemon]], [[modules/daemon]], [[modules/config]],
[[commands/bot]], [[templates]], [[testing]], and [[index]], and recorded the
remaining uncertainty in [[gaps]]: no checked-in artifact proves a delivered
real digest from a live agent/Telegram run. Page coverage count increased from
78 to 80. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/digest]]
- [[modules/digest]]
- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[modules/config]]
- [[commands/bot]]
- [[templates]]
- [[testing]]
- [[gaps]]
- [[index]]

---
date: 2026-06-14
slug: golden-path-dom-race-audit
pages: [commands/status, modules/daemon, testing, gaps]
---

Audited commit `798beb74` (`test(web): avoid stale golden-path grid element`)
after it touched `web/test/e2e/golden_path_e2e.rb`, [[testing]], and a wiki log
fragment, then refreshed the audit after the next CI run exposed an adjacent
mtime-baseline race in the same golden-path E2E. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search "golden path DOM race stale grid
element web e2e"` surfaced prior golden-path/Turbo context but no conflicting
page.

Verified the committed diff plus current `web/test/e2e/golden_path_e2e.rb`,
the status-grid row markup in `web/app/views/status/_projects.html.erb`,
`Hive::Daemon::Policy`, `Hive::Daemon::Dispatcher`, [[commands/status]],
[[commands/web]], [[modules/daemon]], [[state-model]], and [[e2e]]. Updated the
duplicate Hivebox golden-path section in [[testing]] so it records both the
current-DOM slug lookup convention and the mtime guard before writing the
brainstorm answer. The second pass found the production precision bug behind
the repeated `needs_input` stall: `hive status --json` truncated subsecond
`File.mtime` values while daemon dispatch baselines kept microseconds. Updated
[[commands/status]], [[modules/daemon]], [[testing]], and [[gaps]] accordingly.
Page coverage did not change, so [[index]] did not need a catalog update. Did
not run `qmd update` or `qmd embed`.

---
date: 2026-06-14
slug: golden-path-dom-race
pages: [commands/status, modules/daemon, testing]
---

Fixed a flaky golden-path hivebox E2E failure observed on PR #463's
`hivebox web (Rails tests + system)` job. The browser test added an idea,
stored the matched `.task-row`, and later clicked through that saved Capybara
element while the foreground daemon was already broadcasting Turbo replacements
for `#projects`. In CI, Playwright prepared the click after the row had been
detached, raising "Element is not attached to the DOM" before the task page
loaded.

The test now reads the task slug from the current DOM with one JavaScript query
and visits `/tasks/:project/:slug` directly before answering the brainstorm. A
follow-up CI run then exposed the adjacent mtime race: the answer could be
written in the same filesystem mtime second as the daemon's edit-resume
baseline, and `hive status --json` was truncating subsecond task mtimes before
`StatusConsumer` compared them with the daemon's persisted baseline. That left
the row at `2-brainstorm needs_input`. Status JSON now emits microsecond
`mtime` / `folder_mtime` values, and the E2E also waits for the daemon's
`needs_input` classification plus a distinct `brainstorm.md` mtime tick before
submitting the answer.

That keeps the golden-path coverage focused on the real browser, daemon,
brainstorm answer, stage advancement, and worktree commit behavior without
retaining a volatile grid element across live updates or collapsing/truncating
the operator answer relative to the daemon's baseline mtime. Updated
[[commands/status]], [[modules/daemon]], and [[testing]] with the convention.

---
date: 2026-06-14
slug: daemon-mtime-precision-doc-audit
pages: [commands/status, state-model, modules/daemon]
---

Refreshed LLM wiki coverage after commit `81b554ac` fixed daemon edit-resume
mtime precision. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "status
mtime precision StatusConsumer"` found existing daemon coverage, and direct wiki
search found adjacent status/state-model wording.

Inspected the committed diff plus current `lib/hive/daemon/status_consumer.rb`,
`lib/hive/daemon/dispatch_baselines.rb`, `lib/hive/commands/status.rb`,
`lib/hive/daemon/concurrency_controller.rb`, `lib/hive/daemon/policy.rb`, and
`test/unit/daemon/status_consumer_test.rb`. Tightened [[commands/status]] and
[[state-model]] so public `tasks[].mtime` remains documented as whole-second
JSON while daemon edit-baseline comparisons are documented as local
`File.mtime(state_file)` re-stats when possible. Adjusted [[modules/daemon]] and
the `DispatchBaselines` source comments so persisted baselines are described as
preserving daemon-local precision, not compensating for an already rounded
comparison input.

No new page was added, so [[index]] page coverage did not change. The existing
[[gaps]] brainstorm-answer-window item still carries the remaining uncertainty;
this refresh did not find additional in-tree evidence beyond the committed
focused unit test and recorded golden-path E2E verification. Did not run
`qmd update` or `qmd embed`, and did not edit compiled [[log]].

---
date: 2026-06-14
slug: daemon-mtime-precision
pages: [modules/daemon, testing, gaps]
---

Fixed the hivebox golden-path CI failure where a browser-submitted brainstorm
answer could strand a task at `2-brainstorm` even after the E2E waited for the
daemon's answer window. `hive status --json` publishes `tasks[].mtime` at
whole-second ISO8601 precision, while the daemon records dispatch baselines from
`File.mtime` with subsecond precision. When an answer landed in the same
wall-clock second as the agent's `WAITING` write, the parsed status timestamp
compared older than the fractional post-child baseline and `Policy#decide_edit`
kept returning `:skip`.

`Hive::Daemon::StatusConsumer#parse_mtime` now prefers a local
`File.mtime(state_file)` when the row's `state_file` still exists, falling back
to the JSON timestamp only when the file is unavailable. Added
`test_valid_row_mtime_prefers_state_file_precision` to
`test/unit/daemon/status_consumer_test.rb`, preserving the public status payload
while keeping daemon-internal edit-resume comparisons subsecond-precise.

Refreshed [[modules/daemon]] for the `StatusConsumer` invariant and persisted
baseline section, [[testing]] for `daemon/status_consumer_test.rb` coverage, and
[[gaps]] to keep the broader pre-baseline brainstorm-answer window open while
noting that the same-second precision variant is fixed. Verified with:
`bundle exec ruby -Itest test/unit/daemon/status_consumer_test.rb`,
`bundle exec ruby -Itest test/integration/cli_version_test.rb`, and
`cd web && bundle exec rails test test/e2e/golden_path_e2e.rb`.

---
date: 2026-06-14
slug: verify-release-jq-audit
pages: [active-areas, testing, gaps]
---

Refreshed wiki planning/documentation coverage after commit `aa160a2c`
(`ci: harden verify-release jq setup`) touched
`.github/workflows/install-smoke.yml`, [[testing]], and the existing
`verify-release-jq-provisioning` wiki fragment. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first; the qmd search for wiki refresh and post-commit
documentation coverage surfaced prior Hive post-commit refresh patterns, and
the configured master wiki path had no matching project guidance.

Inspected the committed diff plus current `.github/workflows/install-smoke.yml`,
`packaging/verify-release.sh`, [[testing]], and release/install wiki mentions.
Confirmed [[testing]] covers the new CI provisioning contract: the
`verify-release.sh (end-to-end behavior)` job uses runner-provided `jq` when
present, falls back to apt only when missing, and disables transiently broken
`packages.microsoft.com` apt source files before retrying the fallback update.
Refreshed [[active-areas]] for the current HEAD and [[testing]] metadata/TLDR
so install-smoke/release-verify coverage is represented in the page summary.
Updated [[gaps]] to distinguish the now-passed hosted PR #474 verifier rerun
(`27500473396` at `aa160a2c`) from the separate v0.3.0 published-artifact
verification gap, which remains open. Page coverage did not change, so
[[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-14
slug: verify-release-jq-provisioning
pages: [testing]
---

Fixed the PR #474 install-smoke failure before `packaging/verify-release.sh`
started: the `verify-release.sh (end-to-end behavior)` job unconditionally ran
`sudo apt-get update -qq && sudo apt-get install -y -qq jq`, and the
Ubuntu 24.04 runner's preconfigured `packages.microsoft.com` repositories
returned 403 during `apt-get update`. That unrelated apt-source outage failed
the verifier job before the release behavior check could run.

The workflow now treats `jq` provisioning as idempotent: it uses runner-provided
`jq` when available, falls back to apt only when missing, and if the fallback
update is blocked by `packages.microsoft.com`, disables those Microsoft source
files and retries before installing `jq`. Verified the workflow YAML parses,
`install.sh` and `packaging/verify-release.sh` still pass `bash -n`, and
`packaging/verify-release.sh --version=v0.1.0 --report=json` passes with a
clean temporary `HOME` anchor. Updated [[testing]] with the CI provisioning
contract. No index update was needed because no new wiki page was created.

---
date: 2026-06-14
slug: hive-new-commit-lock-audit
pages: [commands/new, modules/lock, modules/git_ops, testing, gaps]
---

Audited commit `bdd9a9fa` after it touched `Hive::Commands::New`, integration
tests, and the `hive new` command wiki. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first; `qmd search "hive new commit lock capture git
commit state_home"` surfaced the current `hive new` and commit-lock coverage.

Verified the committed diff and inspected `lib/hive/commands/new.rb`,
`lib/hive/lock.rb`, `lib/hive/git_ops.rb`,
`lib/hive/display_name/generator.rb`, `test/integration/new_test.rb`,
[[commands/new]], [[modules/lock]], [[modules/git_ops]], and [[testing]].
Confirmed the command page already documents the captured-task commit lock and
the focused integration test. Refreshed [[modules/lock]] so the shared lock API
documents the bounded nonblocking flock, macOS/BSD `process_start_time`
fallback, and `hive new` as a commit-lock consumer. Refreshed
[[modules/git_ops]] so `hive_commit` documents scoped staging, optional
pathspec/body/empty-commit arguments, and the caller-owned commit-lock contract.

Recorded remaining uncertainty in [[gaps]]: the capture commit is serialized,
but no in-tree artifact proves the original parallel hivebox Rails/system-worker
failure is fixed end-to-end, and `Hive::DisplayName::Generator#commit_name`
still commits best-effort without taking `Hive::Lock.with_commit_lock`.
Page coverage did not change, so [[index]] needed no catalog update. Did not
run `qmd update` or `qmd embed`.

---
date: 2026-06-14
slug: hive-new-commit-lock
pages: [commands/new, testing]
---

Fixed a process-level `hive new` race exposed by the hivebox web system job:
parallel Rails/system-test workers could capture ideas against the same
project and run concurrent `Hive::GitOps#hive_commit` calls in the shared
`.hive-state` worktree. Git then failed on the worktree `index.lock`, leaving
the web suite with partial `.hive-state` setup errors such as existing
`hive/state` branches or unparseable HEADs.

`Hive::Commands::New#call!` now imports `Hive::Lock` explicitly and wraps the
captured-task `hive_commit(stage_name: "1-inbox", action: "captured")` in
`Hive::Lock.with_commit_lock(hive_state)`, matching the existing commit-lock
contract used by run/approve/drop/markers. The lock covers only the short
`git add && git commit` window; task file creation, id allocation, and
best-effort display-name generation remain outside it.

Added `test_new_serializes_hive_state_commit` to `test/integration/new_test.rb`
and verified a direct multi-process repro: before the change, 3 of 8 child
processes failed with git `index.lock` errors; after the change, all 8 exited
0 with no failure logs. Updated [[commands/new]] and [[testing]]. No index
change was needed because no new wiki page was created.

---
date: 2026-06-14
slug: json-usage-wrapper-residual-audit
pages: [commands/stage_action, gaps]
---

Post-commit command/API and executable-entrypoint wiki audit after the rebased
head `2b0d651f` only added the prior wrapper audit fragment for the
`bin/hive` JSON usage-error work. Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[architecture]], [[decisions]], [[gaps]], and recent compiled
[[log]] entries first. `qmd search "command API surface routes handlers
commands executable entrypoints README wiki coverage"` surfaced earlier wrapper
and command/API refreshes; the configured master wiki had only generic route
coverage guidance, so verification used the committed diff plus direct source
reads.

Inspected `HEAD`, the preceding residual wiki commit `66c470cd`, and the
rebased source commit `8b31acd6`, plus current `bin/hive`, `lib/hive/cli.rb`,
`lib/hive.rb`, `lib/hive/commands/rebase_status.rb`,
`lib/hive/commands/stage_action.rb`,
`test/integration/cli_version_test.rb`,
`test/integration/cli_usage_error_json_test.rb`, [[cli]], [[commands]],
[[commands/rebase-status]], [[commands/patrol]], [[commands/stage_action]],
[[testing]], and [[gaps]]. Confirmed [[cli]], [[commands]], and [[testing]]
already cover `JSON_USAGE_ERROR_CONTRACTS`: required-argument failures for
workflow verbs, `run`, `approve`, `drop`, `findings`, `markers`,
`rebase-status`, and `patrol` emit command-shaped JSON when `--json` is present;
registered schemas use `Hive::Schemas::ErrorEnvelope`, while
`hive-rebase-status` intentionally remains unregistered and unversioned.

Refreshed [[commands/stage_action]] because its examples still described the
current workflow-verb JSON contract as `schema_version: 1`; the producer now
uses `Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-stage-action")`, which is
version 2, and the current schema file is `schemas/hive-stage-action.v2.json`.
Updated [[gaps]] to cite the rebased source commit `8b31acd6` for the wrapper
usage-error expansion while preserving the unresolved uncertainty: no in-tree
artifact proves a packaged RubyGems/Homebrew/AUR `hive` executable exercises
the expanded wrapper path. Page coverage did not change, so [[index]] did not
need a page-list update. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

## [2026-06-14T11:17:17Z] testing — pin SkillCheck global npm root coverage

**Action:** Added deterministic unit coverage for `Hive::SkillCheck::Pi.global_npm_root`'s successful `npm root -g` parse path after the root CI coverage gate reported only `lib/hive/skill_check.rb:374-375` uncovered. The new `test/unit/skill_check_test.rb` case stubs `Open3.capture3("npm", "root", "-g")`, asserts the exact argv, and verifies the first output line is stripped and returned, making the 100% line coverage gate independent of whether a test environment happens to exercise a real global npm install. Updated [[testing]] to list `skill_check_test.rb` and its Pi npm-root coverage.

**Refreshed pages:**
- [[testing]]

## [2026-06-14T11:08:49Z] wiki — audit status-race refresh commit references

**Action:** Audited the status-race wiki refresh after HEAD became `f1a094a8` (`docs(status): refresh race follow-up wiki`). Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "status stage move race duplicate vanished folder state file TOCTOU"` returned no indexed hits, while direct wiki search found the existing status/TUI/testing/gaps coverage, and the configured master wiki path had no relevant project-specific hit. Inspected `git log --oneline`, the committed diff for `f1a094a8`, the source/test commits through `f6f03c59`, current `lib/hive/commands/status.rb`, `test/unit/commands/status_test.rb`, [[commands/status]], [[commands/tui]], [[testing]], and [[gaps]]. Corrected the status-race gap and previous log fragment to cite the branch's actual ancestor commits (`586b9d31`, `a274bf42`, `52585bc7`, `0976c9ee`, `02ebf151`, `85e76754`, `c6543d8f`, `b018341b`, and `f6f03c59`) instead of non-ancestor ids. Command/API page coverage already matched the source, page coverage did not change, and the missing live daemon/TUI polling artifact remains recorded. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]

## [2026-06-14T10:58:28Z] testing - eval dispatch capture follows queued bot commands

**Action:** Updated the eval harness after the full `test:eval` suite exposed stale
child-supervisor-only expectations for bot callbacks. The production supervisor
routes queue-routable Hive verbs through `DispatchRequestWriter`; the eval
harness now injects a fake writer and exposes `Harness#dispatched_commands` so
scenarios can assert command intent across queued requests, sequence
continuations, and non-queue child spawns.

**Verification:** Ran the focused failing eval scenario files, the full
`HIVE_EVAL_NO_JUDGE=1 bundle exec rake test:eval` suite, RuboCop on touched
Ruby files, and the default `bundle exec rake test` suite.

**Refreshed pages:**
- [[testing]]

## [2026-06-14T10:04:07Z] wiki — audit current JSON wrapper last-flag coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after the rebased branch put source commit `b9cad3cd` ahead of the residual wiki commit `0b631d0f`. Read the project instructions, `.llm-wiki/config.json`, [[cli]], [[e2e]], [[gaps]], and the recent JSON-wrapper log fragments first; `qmd search "JSON error mode false flags wrapper bin/hive bin/hive-e2e"` returned no indexed hits in the Hive or master collections, so verification used the committed diffs and direct source reads. Inspected `b9cad3cd`, `0b631d0f`, current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, `test/e2e/lib/hive_e2e_binary_test.rb`, and targeted references in [[commands]]. Confirmed the affected pages already document the current behavior: wrapper-owned usage/preflight/error output checks the last recognized JSON boolean flag, so a final false form such as `--no-json` or `--json=false` forces prose after an earlier `--json`. Updated [[gaps]] to name the current source commit and carry forward the remaining uncertainty: no in-tree artifact proves the packaged RubyGems/Homebrew/AUR `hive` executable exercises the same wrapper path. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]

---
ts: 2026-06-14T09:39:50Z
slug: skill-check-npm-root-postcommit-audit
tags: [wiki, doctor, testing, coverage]
---

## Wiki: audit SkillCheck global npm-root coverage refresh

**Action:** Refreshed wiki planning/documentation coverage after commit `ebb98db7` added focused coverage for `Hive::SkillCheck::Pi.global_npm_root` returning a stripped successful `npm root -g` path and touched [[commands/doctor]], [[testing]], and [[log]]. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "skill check global npm root doctor coverage"` surfaced the prior global npm package-root changelog entry, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/skill_check.rb`, `lib/hive/cli.rb`, `test/unit/skill_check_test.rb`, [[commands/doctor]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the behavior page already documents Pi discovery through `npm root -g`, while [[testing]] now documents the success/timeout test coverage. Updated [[commands/doctor]] frontmatter so the page date matches the refreshed coverage. No new page coverage was introduced, so [[index]] did not need a catalog update; no new uncertainty was found beyond existing [[gaps]] entries. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/doctor]]
- [[testing]]

# bench-submit default seam coverage audit

Refreshed LLM wiki coverage after commit `90aa0501` added tests for the
default `Hive::Commands::BenchSubmit` seams. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "bench submit default seams coverage gate
hive-bench Brakeman"` returned no indexed hits; the configured master wiki had
only the general [[learnings]] reminder to use array-form `system()` /
`Open3.capture3()` for user-influenced subprocess argv.

Inspected the committed diff plus `lib/hive/commands/bench_submit.rb`,
`test/unit/commands/bench_submit_test.rb`, `config/brakeman.ignore`,
[[commands/bench-submit]], [[testing]], and [[gaps]]. Updated stale wording
that still described the command tests as only injected-seam coverage. The
suite now also exercises the default local secret scanner, JSON/text reporter,
`run_git`, extractor invocation against a stub `harness/extract.rb`, and PR
opener through stub `git`/`gh` binaries. The live gap remains: no in-tree
artifact proves a real `HIVE_BENCH_PATH` checkout submission, generated corpus
validation, push, or GitHub PR. No new page was needed, so [[index]] page
coverage stayed at 78. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bench-submit]]
- [[testing]]
- [[gaps]]

# bench-submit Brakeman follow-up audit

Audited post-commit LLM wiki coverage after commit `c4e2cab5` changed
`lib/hive/commands/bench_submit.rb`, `config/brakeman.ignore`, and the
bench-submit wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; a QMD search for
bench-submit corpus coverage returned no exact indexed hits, and the configured
master wiki path had no matching `bench submit` / `hive-bench` context.
Inspected the committed diff plus
`lib/hive/commands/bench_submit.rb`,
`test/unit/commands/bench_submit_test.rb`, `config/brakeman.ignore`,
[[commands/bench-submit]], and [[testing]].

Verified the refreshed pages match the source: `hive bench submit` keeps
hive-bench extraction and `gh pr create` in argv-form subprocess calls, the
extractor now passes `ruby -I` and the harness path as separate argv elements,
and the remaining Brakeman ignore is documented as an array-form `Open3`
false positive for slug text used only in the PR title/body. [[gaps]] still
records the relevant uncertainty: no in-tree artifact proves a live
`HIVE_BENCH_PATH` submission, generated corpus validation, push, or GitHub PR.
No new wiki page was needed, so [[index]] page coverage stayed at 78. Did not
run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bench-submit]]
- [[testing]]
- [[gaps]]

# bench-submit command/API coverage refresh

Refreshed LLM wiki command/API coverage after commit `ef47b9c0` added
`hive bench submit SLUG [--project NAME]`, then re-checked HEAD after
follow-up commit `c4e2cab5` split the extractor `ruby -I` argv and added the
Brakeman false-positive ignore for `gh pr create`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first; `qmd search "bench submit hive bench command
corpus"` returned no prior indexed context and the configured master wiki path
had no matching hits. Inspected the committed diff plus
`lib/hive/cli.rb`, `lib/hive/commands/bench_submit.rb`,
`test/unit/commands/bench_submit_test.rb`, `config/brakeman.ignore`, and
adjacent command/testing wiki pages. Tightened [[commands/bench-submit]] to
the current source behavior, added the command to [[cli]], [[commands]],
[[testing]], and [[gaps]], bumped [[index]] page metadata to 78 pages, and
recorded the missing live hive-bench/`gh pr create` smoke evidence. Did not run
`qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bench-submit]]
- [[cli]]
- [[commands]]
- [[testing]]
- [[gaps]]
- [[index]]

# hive bench submit — corpus producer for hive-bench

Added `hive bench submit SLUG` (`lib/hive/commands/bench_submit.rb`, wired in
`lib/hive/cli.rb`): extracts a `9-done` task into a hive-bench corpus entry and
opens a submission PR. Thin orchestration over hive-bench's `harness/extract.rb`
(located via `HIVE_BENCH_PATH`) plus a local secret/PII preflight that aborts
before opening a PR. hive depends on hive-bench only as a producer; never the
reverse. Part of the hive-bench benchmark (plan U6).

---
ts: 2026-06-14T07:23:00Z
slug: babysitter-branch-allowlist-audit
tags: [wiki, babysitter, git, dry-run]
---

## Wiki: audit babysitter git branch dry-run allowlist coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `7e7cc939` changed `bin/hive-babysitter-stub-git` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], recent [[log]] entries, and relevant babysitter dry-run fragments first; `qmd search "git branch allowlist mutation capable babysitter dry run"` surfaced existing [[commands/babysit]], [[gaps]], and changelog coverage, and the configured master wiki path had no relevant project-specific hit. Inspected the committed diff plus current `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] and [[modules/babysitter]] so the dry-run git stub contract says `git branch` passes only exact read forms: bare, `--show-current`, `--contains`, `--contains <rev>`, or `--contains=<rev>`. Mixed mutation-capable branch invocations such as delete, rename, or upstream-setting flags are skipped even when they also include `--contains` or `--show-current`. Refreshed [[testing]] for the new focused dry-run branch allowlist regressions and kept [[gaps]] explicit that no checked-in live `hive babysit --once PROJECT --dry-run` agent-smoke artifact was found. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-14
slug: babysitter-gh-short-web-flag
pages: [commands/babysit, modules/babysitter, testing, gaps]
---

Post-commit command/API and executable-stub wiki refresh after commit
`73947cfc` changed `bin/hive-babysitter-stub-gh` and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "babysitter gh short web
flag dry run"` found existing [[testing]], [[gaps]], and prior dry-run log
coverage; targeted search of the configured master wiki path found no
Hive-specific guidance.

Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`,
[[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. The
change keeps the `gh` dry-run stub default-deny and narrows only the
browser-launch guard: short `-w` / `-w...` is now skipped for read-only `gh pr
checks`, `gh pr diff`, and `gh pr list`, matching the existing `gh pr view`,
`gh repo view`, `gh run view`, and `gh workflow view` protection; long `--web`
forms remain skipped. Updated command/module/testing coverage and carried
forward the existing uncertainty that no checked-in artifact proves a full
`hive babysit --once PROJECT --dry-run` live-agent run after these stub
changes. Page coverage did not change, so [[index]] was not edited. Did not
edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-14
slug: skill-check-global-npm-root-coverage
pages: [commands/doctor]
---

Patched the post-rebase coverage gap from `origin/main` by adding focused
`test/unit/skill_check_test.rb` coverage for `Hive::SkillCheck::Pi.global_npm_root`.
The existing implementation already shells out to `npm root -g`, returns the
first stripped output line on success, returns nil for blank output, and fails
closed on timeout or subprocess errors. The new tests pin the success and blank
branches that were previously uncovered, restoring the root CI coverage gate
without changing production behavior.

Updated [[commands/doctor]] so the SkillCheck test inventory mentions global
npm-root handling. Verified with `bundle exec ruby -Itest test/unit/skill_check_test.rb`.
Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-14
slug: colima-smoke-gap-refresh
pages: [commands/web, testing, dependencies, gaps]
---

Post-commit wiki coverage refresh after commit `abb62aae` added a
`wiki/gaps.md` note for the release workflow's macOS Colima hivebox smoke
failure. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], recent compiled [[log]] entries, and recent `wiki/log.d/` fragments
first. `qmd search "planning documentation coverage docs plans notes context
wiki refresh"` surfaced existing Hive post-commit refresh patterns, and the
configured master wiki path had no relevant Hivebox/Colima guidance.

Inspected the committed diff plus current `.github/workflows/release.yml`,
`.github/workflows/ci.yml`, `packaging/docker/smoke.sh`,
`packaging/docker/README.md`, `docs/RELEASING.md`, [[commands/web]],
[[testing]], [[dependencies]], and [[gaps]]. Consolidated the new Colima note
into the existing Hivebox golden-path install gap: current CI covers Rails web
tests, the golden-path browser E2E, and the Windows installer harness, but it
does not contain the older push/PR Docker image-smoke job. The release job still
pre-push-smokes amd64 before publishing, while the post-publish macOS arm64
Colima leg is currently an intended verification path, not proven coverage,
because `colima start --cpu 2 --memory 4` can fail when the hosted runner's Lima
VZ VM exits. The prior note says the image itself was separately checked by
multi-arch manifest and local `/health?deep=1` smoke, but no checked-in artifact
proves a hosted Colima retry/fallback or passing v0.3.0 release run.

Also corrected a stale [[dependencies]] standard-library note: current
`Hive::Lock.process_start_time` uses `/proc/<pid>/stat` when available and
falls back to `ps -o lstart= -p <pid>`, with unit coverage in
`test/unit/lock_test.rb`. Page coverage did not change, so [[index]] was not
edited. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

## Web: audit golden-path E2E stale-row coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `18333735` changed `web/test/e2e/golden_path_e2e.rb` and already added `wiki/testing.md` coverage plus `wiki/log.d/20260614-180312-golden-path-e2e-stale-row-click.md`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "golden path e2e stale row Turbo task link"` had no indexed hits, and the configured master wiki only had generic Turbo context. Verified the committed diff and current golden-path E2E source. Refined [[testing]] to match the helper's exact retry boundary (`Capybara::ElementNotFound` row-lookup windows and Playwright "not attached to the DOM" click failures), updated [[commands/web]] so its test summary includes the explicitly-run golden-path E2E, and carried the new commit plus remaining hosted/live evidence uncertainty into [[gaps]]. Page coverage count did not change, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[commands/web]]
- [[gaps]]

## Web: stabilize golden-path E2E task-row click

**Action:** Updated `web/test/e2e/golden_path_e2e.rb` so the browser test no longer retains a `.task-row` element across the daemon/Turbo update window. The task link is re-resolved and retried only for the observed stale-row case where Playwright reports that the element is no longer attached to the DOM.

**Root cause:** The golden-path E2E asserts that the submitted idea appears in the status grid, then the daemon can advance the task from `1-inbox` to `2-brainstorm` and Turbo can replace the row before the saved Capybara node is clicked. The hosted web CI failure on PR #459 hit that exact stale element race at `web/test/e2e/golden_path_e2e.rb:119`.

**Verified:** `cd web && bin/rails test test/e2e/golden_path_e2e.rb` (twice); `cd web && bin/rubocop test/e2e/golden_path_e2e.rb --format simple`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[testing]]

## [2026-06-13T23:46:57Z] wiki — audit current-branch gh cache dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after current-branch source commit `30a9b383` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run gh api cache"` returned existing babysitter module/gap/log coverage, and direct wiki/source searches showed the pages already contained the gh-cache behavior from the equivalent earlier patch.

**Coverage:** Inspected `git diff 30a9b383^ 30a9b383`, `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. Confirmed the current docs match the code: the dry-run `gh` stub skips both `gh api --cache <ttl>` and `gh api --cache=<ttl>` even when the method is explicitly GET because gh writes a local API cache, while explicit GET reads without `--cache` still pass through. The focused regression uses a fake gh binary plus `XDG_CACHE_HOME` and verifies the cache directory is not created. Updated [[gaps]] only to tie the remaining uncertainty to this current-branch audit: no in-tree live-agent `hive babysit --once PROJECT --dry-run` artifact was found. Page coverage stayed within existing babysitter pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]

## [2026-06-13T23:33:51Z] status/tui — refresh stage-move race follow-up coverage

**Action:** Refreshed command/API wiki coverage after the later status-race follow-up commits on the branch (`0976c9ee`, `02ebf151`, `85e76754`, `c6543d8f`, `b018341b`, and `f6f03c59`) narrowed `Hive::Commands::Status#collect_rows`'s `InvalidTaskPath` rescue, clarified the folder-level `ENOENT` re-raise contract, and added focused unit coverage for non-finalize forward moves, surviving-folder state-file `ENOENT`, the race test double's `to_path` timing, and three-member duplicate pruning. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "command API routes handlers commands executable entrypoints README post commit"` surfaced prior wiki-refresh context, and the configured master wiki path had no relevant project-specific hit. Inspected the committed diffs plus current `lib/hive/commands/status.rb`, `test/unit/commands/status_test.rb`, [[commands/status]], [[commands/tui]], [[testing]], and [[gaps]]. Updated the status/TUI pages to distinguish forward same-scan resurfacing from backward one-poll disappearance and to record that surviving-folder `ENOENT` propagates as a real status failure. Carried forward the uncertainty that no live daemon/TUI polling artifact proves the behavior during a real stage transition. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-13
slug: hive-eval-usage-refresh
pages: [testing, gaps]
---

Refreshed command/API and executable-entrypoint wiki coverage after the
eval-wrapper follow-up changed the checkout-local `bin/hive-eval` wrapper and
its reporter tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], and recent compiled [[log]] entries
first. Read-only `qmd search "hive-eval usage validation scenario selector"`
surfaced prior wiki log context but no fresher eval-runner page; targeted
search of the configured master wiki path found no Hive-specific eval guidance.

Inspected the committed diff plus current `bin/hive-eval`,
`test/eval/support/reporter_test.rb`, `test/eval/support/reporter.rb`,
`test/eval/scenarios/s3_noise_test.rb`, `test/eval/support/contract_assertions.rb`,
`test/eval/support/reason_classifier.rb`, `Rakefile`, `hive.gemspec`,
[[testing]], and [[gaps]]. Verified [[testing]] documents the
current OptionParser wrapper boundary: only `--scenario`, `--report`, and
`--no-judge` are accepted; usage errors exit `64` before report creation;
unexpected positional arguments use count-aware `argument` / `arguments`
wording; scenario selection is basename-only with separate separator and
unsafe-character checks; inherited `TEST` is cleared; and
`HIVE_EVAL_SCENARIO_ROOT` is the tmpdir fixture seam. Updated [[gaps]] so the
source map and open eval gap use the current reachable selector-hardening commit
and record the remaining full judged-eval smoke uncertainty. The focused
reporter suite now pins both positional-scenario and trailing-extra-argument
usage errors. [[index]] did not need a page-list update because page coverage
did not change. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

## [2026-06-13T22:56:01Z] wiki — audit residual JSON wrapper wiki refresh

**Action:** Audited residual commit `1c1b2026`, which committed the prior JSON-wrapper wiki refresh as 6-review residue. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "routes handlers commands executable entrypoints README"` and `qmd search "JSON wrapper boolean error mode false flags"` surfaced existing wrapper coverage, while the configured master wiki path had no relevant matching pattern. Verified the committed diff touched only wiki pages plus `wiki/log.d/20260611T182630Z-json-wrapper-last-flag-audit.md`, then inspected source commit `56f1fdcb` and the current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, and `test/e2e/lib/hive_e2e_binary_test.rb`. The existing [[cli]], [[commands]], [[e2e]], and [[testing]] coverage already matches the code: wrapper-owned usage/preflight/error formatting checks the last recognized JSON boolean flag, so a final `--no-json` or `--json=false` forces prose after an earlier `--json`. Updated [[gaps]] only to record that the packaged-install smoke uncertainty still remains after this residual audit. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]

---
date: 2026-06-13
slug: review-limit-healing-refresh
pages: [active-areas, stages/review, modules/daemon, state-model, testing, gaps]
---

Post-commit LLM-wiki refresh after commit `b6bba5d6` changed
`lib/hive/stages/review.rb` and `test/integration/run_review_test.rb` for
review-phase provider-limit recovery. Read `.llm-wiki/config.json`,
`AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent compiled [[log]] entries,
and recent `wiki/log.d/` fragments first. Searched the configured
`main_wiki_path` (`/home/asterio/wikis/master/wiki`) for usage-limit,
`limits_reached`, triage, and fix-phase terms before editing project pages; no
project-relevant master-wiki guidance was found. The other default
cross-project wiki paths did not exist. After the edits, a bounded read-only
`qmd search "review limits_reached triage fix provider limit"` surfaced the
newly refreshed pages plus existing review/agent context, with no additional
stale project page found.

Inspected recent git history and the `b6bba5d6` diff. The code now routes
triage and fix phase spawn failures through `mark_review_phase_failure`: when
the captured error text matches `Hive::AgentLimit.limit_reached?`, Hive writes
`REVIEW_ERROR phase=<triage|fix> reason=limits_reached retry_after=<iso8601>`
so `Hive::Daemon::StaleAgentHealer` can clear it after the existing cooldown;
ordinary non-limit failures still write terminal `triage_failed` /
`fix_failed`. `test/integration/run_review_test.rb` adds focused coverage for
triage limit vs non-limit marker behavior, while existing reviewer/healer tests
cover all-reviewers limit classification and cooldown clearing.

Updated [[stages/review]], [[modules/daemon]], and [[state-model]] so review
`limits_reached` documentation includes reviewers, triage, and fix phase
markers. Updated [[testing]] for the `run_review_test.rb` and
`run_reviewers_test.rb` coverage. Updated [[active-areas]] with the latest
review-limit healing commit. Updated [[gaps]] to record the remaining
uncertainty: no focused assertion was found for the fix-phase
`limits_reached` helper path, and no checked-in live artifact proves a fresh
headless/tmux/review run surfacing and daemon-healing the marker through
`hive status`, TUI, or daemon logs. Page coverage did not change, so
[[index]] was not edited. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

---
date: 2026-06-13
slug: hive-eval-cli-contract
pages: [testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`ffa51d56` changed the checkout-only `bin/hive-eval` runner. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "command API surface routes handlers executable entrypoints README"`
surfaced existing executable/test coverage, and the configured master wiki path
had only generic route-coverage guidance.

Inspected the committed diff plus current `bin/hive-eval`,
`test/eval/support/reporter_test.rb`, [[testing]], [[modules/bot]],
[[active-areas]], and [[gaps]]. Updated [[testing]] to document the eval
runner's usage contract: scenario selection must use `--scenario`, positional
arguments exit 64 before report creation, `--scenario` is resolved by safe
basename under `test/eval/scenarios/`, and path separators/traversal/dotted
names are rejected before the runner sets `TEST`. Corrected stale eval wording:
`s3_noise` now passes and pins daemon-enabled ready-row noise suppression, while
the reporter failure path uses a temporary `HIVE_EVAL_SCENARIO_ROOT` fixture.

Updated [[gaps]] so the source-coverage map names `bin/hive-eval` alongside the
other test/e2e executables, and recorded the remaining uncertainty: no in-tree
artifact was found for a full judge-enabled `bin/hive-eval` run after the
hardening. No new page was added, so [[index]] needed no catalog change.

Verified with `bundle exec ruby -Itest test/eval/support/reporter_test.rb`
(`16 runs, 91 assertions, 0 failures, 0 errors, 0 skips`). Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-13
slug: v024-refresh-followup
pages: [dependencies, log]
---

Post-commit wiki coverage follow-up after commit `e423632e` touched
[[active-areas]], [[dependencies]], and
`wiki/log.d/20260612T210436Z-v024-release-wiki-refresh.md`. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first. `qmd search "v0.2.4 release coverage
active areas dependencies"` returned no results, and targeted search of the
configured master wiki path found no Hive-specific guidance.

Inspected the committed diff for `e423632e`, the underlying v0.2.4 release
commit `c7d8aa4f`, the later v0.3.0 release commit `8146d481`, and current
`CHANGELOG.md`, `README.md`, `install.md`, `lib/hive.rb`, root `Gemfile.lock`,
`web/Gemfile.lock`, [[active-areas]], [[dependencies]], [[operating]], and
[[gaps]]. Confirmed current source/wiki release state is v0.3.0; the v0.2.4
note is historical. Updated [[dependencies]] to foreground the current `0.3.0`
path-gem state and note that both recent release lockfile commits changed only
local path metadata. Corrected the prior v0.2.4 log fragment so its
action/refreshed-pages list matches the committed file list and does not claim
[[operating]] or [[gaps]] were refreshed by `e423632e`. No page coverage
changed, so [[index]] was not edited. No new uncertainty beyond the existing
v0.3.0 artifact-verification gap in [[gaps]] was found. Did not edit compiled
[[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-13
slug: json-usage-wrapper-audit
pages: [cli, commands, testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`b4eeeeb3` changed `bin/hive` and `test/integration/cli_version_test.rb`.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. `qmd search
"command API surface routes handlers commands executable entrypoints README"`
surfaced prior wrapper-contract refreshes; the configured master wiki path had
only generic route/coverage guidance, so verification used the committed diff
plus direct source reads.

Inspected the commit diff and current `bin/hive`,
`test/integration/cli_version_test.rb`,
`test/integration/cli_usage_error_json_test.rb`, `lib/hive.rb`,
`lib/hive/cli.rb`, `lib/hive/commands/rebase_status.rb`, [[cli]],
[[commands]], [[commands/rebase-status]], [[commands/patrol]], [[testing]], and
[[gaps]]. Confirmed the executable wrapper now maps pre-dispatch Thor usage
errors for required-argument commands through `JSON_USAGE_ERROR_CONTRACTS`:
versioned schemas use `Hive::Schemas::ErrorEnvelope`, workflow verbs carry the
`verb` extra, finding toggles carry `operation`, `patrol` reports
`error_kind: "error"`, and the older `hive-rebase-status` inspector keeps its
unversioned sibling JSON shape.

Updated [[cli]] and [[commands]] for the wrapper-level usage-error JSON mapping,
[[testing]] for the focused checkout coverage, and [[gaps]] to carry the
remaining uncertainty: no checked-in artifact proves the packaged
RubyGems/Homebrew/AUR `hive` executable exercises the expanded wrapper path.
Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-13
slug: babysitter-gh-api-field-file-guard
pages: [commands/babysit, modules/babysitter, testing, gaps]
---

Post-commit command/API and executable-stub wiki refresh after commit
`43ebf687` fixed the babysitter dry-run `gh` stub's file-field detector.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. `qmd
search "babysitter gh api file fields guard dry-run stub"` found the existing
[[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]
coverage; targeted search of the configured master wiki path found no relevant
Hive-specific context.

Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`,
`test/unit/babysitter/dry_run_env_test.rb`, and the existing babysitter wiki
pages. The code now normalizes a leading `=` before splitting `-F` field
arguments, so the alternate glued form `-F=q=@secret` is classified like
`-Fq=@secret` and skipped as a local file payload even when `gh api` is
explicitly `--method GET`.

Updated [[commands/babysit]] and [[modules/babysitter]] to document the precise
explicit-GET boundary: scalar query fields may pass through, but `@file` and
`--input` payloads still skip because the GitHub CLI reads local content.
Updated [[testing]] for the new regression example and [[gaps]] to add the
babysitter daemon/stub row to the representative source-coverage map while
carrying the remaining uncertainty: no checked-in artifact proves a full
live-agent `hive babysit --once PROJECT --dry-run` run after this `gh api`
field-file hardening. No wiki page was added or removed, so [[index]] was not
edited. Did not edit compiled [[log]], and did not run `qmd update` or `qmd
embed`.

## [2026-06-13T23:10:44Z] testing/wiki - refresh hive-eval scenario selector coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after
commit `822a23bf` changed `bin/hive-eval` scenario selection. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search
"hive-eval scenario basename validation command API executable entrypoint"`
found [[testing]] plus prior wiki changelog context, and the configured master
wiki path had no matching context.

Inspected the committed diff plus current `bin/hive-eval`, `Rakefile`,
`test/eval/support/reporter_test.rb`, `test/eval/support/reporter.rb`, and
`test/eval/scenarios/s3_noise_test.rb`. Documented that `--scenario` now
accepts only safe basenames (`[A-Za-z0-9_-]+` after optional `_test` stripping),
rejects slash/backslash path separators and other unsafe names with exit 64
before report creation, and continues to ignore ambient `TEST` while routing
through `HIVE_EVAL_SCENARIOS_ONLY`. Corrected stale eval docs for `s3_noise`:
the scenario now pins daemon-enabled notification suppression rather than an
intentional baseline failure. Updated the source coverage map to include
`bin/hive-eval` and recorded that no in-tree artifact shows a live non-test
`bin/hive-eval --scenario` invocation after the hardening. Updated [[index]]
metadata while preserving the current page count at 78. Did not edit compiled [[log]], and did
not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[gaps]]
- [[index]]

---
ts: 2026-06-13T22:18:32Z
slug: skill-check-npm-root-coverage
tags: [wiki, doctor, testing, coverage]
---

## Wiki: cover deterministic SkillCheck global npm-root branch

**Action:** Added focused `test/unit/skill_check_test.rb` coverage for `Hive::SkillCheck::Pi.global_npm_root` returning a stripped path when `npm root -g` succeeds. This closes a local 100% coverage-gate miss on the success parsing branch after rebasing a babysitter PR onto current `main`.

**Coverage:** Updated [[commands/doctor]] and [[testing]] so the documented SkillCheck coverage includes both global npm-root success and timeout handling. Did not edit compiled [[log]].

---
ts: 2026-06-13T14:38:09Z
slug: babysitter-gh-auth-cluster-audit
tags: [wiki, babysitter, gh, dry-run, security]
---

## Wiki: refresh babysitter gh auth clustered shorthand coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `4341a90d` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb` to block pflag-style clustered `gh auth status` token shorthand. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter clustered gh auth status token shorthand"` returned no indexed hits, and the configured master wiki path had no matching context. Inspected the committed diffs plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]] so the dry-run `gh` boundary no longer reads as only bare `-t` / `--show-token`, superseding the narrower wording in the immediately prior residual audit fragment: clustered boolean forms containing `t` before value-taking `h` (for example `-at`, `-ta`, and `-ath`) are skipped and logged, while non-token forms such as plain status, `-a`, `-h github.com`, and `-hgithub.com` pass through. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. The live-agent `hive babysit --once PROJECT --dry-run` smoke gap remains open. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
ts: 2026-06-13T14:35:49Z
slug: babysitter-gh-auth-token-residual-audit
tags: [wiki, babysitter, gh, dry-run, security]
---

## Wiki: audit residual babysitter gh auth token dry-run coverage

**Action:** Audited residual wiki commit `b4419dba`, which updated [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]], and added `wiki/log.d/20260612-185329-babysitter-gh-auth-token-dry-run.md` after source commit `67537dce`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh auth token dry-run"` surfaced existing babysitter command/module/gap coverage, and the configured master wiki path had no matching context. Inspected the committed diffs plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the current pages match the code and tests: the dry-run `gh` stub passes plain `gh auth status`, skips and logs token-revealing `--show-token` / `-t` variants, keeps the existing `gh api` payload guard, and leaves the broader default-deny `git` stub coverage unchanged. No new page coverage was needed, so [[index]] did not need a catalog update. Refreshed [[gaps]] only to make the remaining uncertainty explicit for this audit: no checked-in artifact proves a full live-agent `hive babysit --once PROJECT --dry-run` run after the token-leak guard. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]

---
date: 2026-06-12
slug: release-v030-wiki-refresh
pages: [dependencies, operating, active-areas, gaps]
---

Post-commit command/API and README-surface wiki refresh after commit
`64b11b41` prepared release v0.3.0. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "release v0.3.0
hivebox README install version"` returned no indexed hits, and targeted search
of the configured master wiki path found no Hive-specific context.

Inspected the committed diff plus current `CHANGELOG.md`, `README.md`,
`install.md`, `lib/hive.rb`, `Gemfile.lock`, `packaging/docker/README.md`,
`docs/RELEASING.md`, [[commands]], [[commands/web]], [[dependencies]],
[[operating]], [[testing]], and [[active-areas]]. Confirmed the commit touches
release metadata and README/install snippets only: no Ruby routes, handlers,
Thor command handlers, executable entrypoints, or third-party dependency
versions changed. The lockfile diff changes only the local path gem from
`hive-cli (0.2.4)` to `hive-cli (0.3.0)`.

Updated [[dependencies]] for the current local path gem version, [[operating]]
for the current Linux installer and release-verification examples,
[[active-areas]] for the v0.3.0 release-prep row and current release/install
surface, and [[gaps]] to carry the remaining uncertainty: no checked-in artifact
was found proving `packaging/verify-release.sh --version=v0.3.0`, published
GitHub Release/Homebrew/AUR channel verification, or a published/smoke-passed
`ghcr.io/ivankuznetsov/hivebox:0.3.0` image after the tag exists. Page coverage
did not change, so [[index]] was not edited. Did not edit compiled [[log]], and
did not run `qmd update` or `qmd embed`.

# Box demo re-shot against the real shipped repo

The /box/ landing demo is now real footage end to end: a local hivebox
with real agents took "implement the pull-git stub" on the public
ivankuznetsov/shipped repo from idea to PR
(https://github.com/ivankuznetsov/shipped/pull/2, +1016/−13). Recorder:
web/script/record_box_demo_real.rb (+ _resume variant — survives an
agent limit wall mid-pipeline). Segment B (7-question Q&A) is timed 2×
in post; final cut 48.8s.

Product notes from the shoot:
- Session-limit wall now classifies as limits_reached (fixed this PR).
- The display-name agent produced "Agent Work In Progress" — generic;
  its prompt should ask for a TASK name, not an activity description.
- Six leaked sandbox daemons from test runs were sweeping foreign
  processes (see gaps.md).

---
date: 2026-06-12
slug: dispatch-request-writer-fixture-audit
pages: [log]
---

Post-commit wiki coverage audit after commit `99fe942d` changed
`test/unit/bot/dispatch_request_writer_test.rb` so the dispatch-request writer
fixture asserts `Hive::Daemon::DispatchRequestQueue::SCHEMA_VERSION` instead of
a stale hard-coded version number. Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent compiled [[log]] entries first.
Read-only `qmd search "dispatch-request schema version fixture writer wiki
documentation coverage"` surfaced prior dispatch-request schema context in
[[decisions]] and [[log]]; a targeted search of the configured master wiki path
did not find project-relevant prior guidance.

Inspected the committed diff and current source for
`test/unit/bot/dispatch_request_writer_test.rb`,
`lib/hive/bot/dispatch_request_writer.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`, `lib/hive.rb`,
`schemas/hive-dispatch-request.v1.json`,
`schemas/hive-dispatch-request.v2.json`, and the dispatch-request schema
coverage in `test/unit/schema_files_test.rb`. Also inspected the already-dirty
wiki refresh for commit `c0630426` and left it intact.

No additional wiki page or gap edits were needed for `99fe942d`: the current
dirty wiki pages already document `hive-dispatch-request.v2`,
`DispatchRequestQueue::SCHEMA_VERSION`, strict `unknown_schema_version`
rejection, the `bot|healer` requestor enum, and current schema-file coverage.
Page coverage did not change, so [[index]] was not edited. No new uncertainty
was added to [[gaps]] because this commit only keeps an existing unit fixture
aligned with the queue schema constant and does not change runtime behavior or
verification scope. Did not edit compiled [[log]], and did not run `qmd update`
or `qmd embed`.

# ce-code-review round 2 — 7 findings fixed (PR #300)

- P1: compose.example.yml + docker README now bind 127.0.0.1 (claimable
  box must not face the LAN pre-claim).
- hive-dispatch-request v2: requestor enum gains "healer"; queue
  SCHEMA_VERSION bumped per the schema's own coordinated-upgrade protocol.
- hive-drop.v2.json $id/title fixed; new schema-identity test ties
  filename ↔ $id ↔ title ↔ SCHEMA_VERSIONS for every exported schema.
- Telegram setup strictly parses chat IDs (422 on blank/@handle input)
  before any network call or save.
- Repos clone refuses a pre-existing non-directory target; clone! never
  rm_rf's a path it didn't create.
- /health?deep=1 verifies the daemon via its pidfile (PidFile ownership
  semantics); Dockerfile HEALTHCHECK uses it.
- Task diff is bounded: own process group, 15s deadline, 512KB cap with
  a truncation notice.

Dogfood note: leaked sandbox daemons (tests/E2E spawning `hive daemon
start` without teardown, surviving via detach) can sweep-kill foreign
processes — six were found and stopped on the dev machine. Gap filed.

---
date: 2026-06-12
slug: ce-review-round2-wiki-audit
pages: [commands/web, commands/daemon, modules/daemon, state-model, decisions, testing, gaps]
---

Post-commit command/API and route-handler wiki refresh after commit `c0630426`
fixed ce-code-review round-2 findings across hivebox controllers, Docker
entrypoints/docs, dispatch-request schemas, and web integration tests. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. Read-only
`qmd search "hivebox health deep daemon pidfile dispatch request v2 healer task
diff bounded telegram numeric chat id clone target"` returned no exact indexed
hits; a targeted search of the configured master wiki path also found no
project-relevant prior pattern.

Inspected the committed diff and current source for `lib/hive.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`,
`schemas/hive-dispatch-request.v2.json`, `schemas/hive-drop.v2.json`,
`web/config/routes.rb`, `web/app/controllers/health_controller.rb`,
`web/app/controllers/repos_controller.rb`,
`web/app/controllers/tasks_controller.rb`,
`web/app/controllers/telegram_controller.rb`,
`web/app/views/tasks/diff.html.erb`, `packaging/docker/Dockerfile`,
`packaging/docker/README.md`, `packaging/docker/compose.example.yml`, focused
daemon/schema tests, and the web integration tests for health, repos, tasks,
and Telegram setup.

Updated [[commands/web]] for strict Telegram chat-ID parsing before network
calls/saves, non-directory repo clone-target refusal, bounded task diff
rendering (`HIVEBOX_DIFF_TIMEOUT_SEC`, process group, tempfile, 512 KiB cap),
and `/health?deep=1` daemon-pidfile semantics used by the Docker healthcheck.
Updated [[commands/daemon]], [[modules/daemon]], [[state-model]], and
[[decisions]] so the dispatch-request queue documents current
`hive-dispatch-request.v2`, the `bot|healer` requestor enum, strict version
rejection, and claimed files staying schema-valid for the version produced.
Updated [[testing]] for the new schema
identity coverage plus the health/repos/tasks/telegram Rails integration
coverage. Updated [[gaps]] to close the obsolete `hive-drop.v2` copied-v1
metadata note while preserving live-browser/Docker/provider uncertainty.

Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

## [2026-06-12T21:04:36Z] release/wiki — refresh v0.2.4 release coverage

**Action:** Refreshed release/install and dependency wiki coverage after commit `c7d8aa4f` tagged `v0.2.4`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], and recent [[log]] entries first. Searched the configured master wiki path `/home/asterio/wikis/master/wiki` plus the default cross-project paths; only the configured master path existed and it had no matching Hive-specific `v0.2.4` / Claude model-effort release guidance. `qmd search "claude model effort v0.2.4 patrol native reviewer release"` returned no results, so verification used direct git/source/wiki reads.

Inspected the clean working tree, recent git history, commit `c7d8aa4f`, and the then-current `lib/hive.rb`, `Gemfile.lock`, `CHANGELOG.md`, `README.md`, and `install.md`. Updated [[dependencies]] with a historical `hive-cli (0.2.4)` lockfile note and refreshed [[active-areas]] with v0.2.4 plus adjacent release/dependency rows. Current HEAD has since advanced to v0.3.0 through `8146d481`; [[operating]] and [[gaps]] already carry the current v0.3.0 install/release-verification examples and artifact-verification uncertainty from that later refresh. Page coverage did not change, so [[index]] needed no structural update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[dependencies]]

## [2026-06-12T18:41:51Z] wiki — audit residual babysitter gh cache coverage commit

**Action:** Audited residual wiki commit `db383620`, which committed the previous babysitter dry-run documentation refresh after source commit `2c30a5d1` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh api cache dry-run stub"` returned the existing babysitter module/gap/log coverage, and the configured master wiki path only had unrelated cache references. Inspected the committed wiki diff, the source commit diff, and current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the current pages are source-synced: dry-run `gh api` skips `--cache` and `--cache=<ttl>` even for explicit GET requests because gh writes a local API cache, explicit GET reads without `--cache` still pass through, and the focused regression uses a fake gh binary plus `XDG_CACHE_HOME` to prove the cache directory is not created. The existing [[gaps]] entry still records the remaining uncertainty: no in-tree artifact shows a full live-agent `hive babysit --once PROJECT --dry-run` run after the dry-run stub hardening. Page coverage stayed within existing babysitter pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Verified:**
- `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Refreshed pages:**
- [[log]]

## [2026-06-12T18:34:21Z] wiki — audit babysitter gh api cache dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `2c30a5d1` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run gh api cache"` returned the existing babysitter module/gap/log coverage, and the configured master wiki path had no relevant cross-project pattern beyond unrelated cache references. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Documented that the dry-run `gh` stub skips `gh api --cache` and `gh api --cache=<ttl>` even when the method is explicitly GET, because the GitHub CLI writes a local API cache under the caller's cache home. Refreshed command/module/test/gap coverage for the new focused regression that uses a fake gh binary writing under `XDG_CACHE_HOME` and verifies the cache directory is not created. Page coverage stayed within existing babysitter pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-12
slug: hivebox-ci-wiki-audit
pages: [testing, gaps, log]
---

Post-commit wiki refresh after commit `06674fcc` updated [[testing]],
[[gaps]], and added the prior hivebox Bundler/installer CI audit fragment.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hivebox golden path
bundler installer Write-Host GOLDEN_E2E_BUNDLE_PATH"` returned no indexed hits;
targeted `rg` over the configured master wiki path and this checkout found only
the current hivebox CI/wiki references.

Inspected the committed diff for `06674fcc`, then re-checked the underlying
source commit `6ff018e0` and current `.github/workflows/ci.yml`,
`web/test/e2e/golden_path_e2e.rb`, `packaging/docker/install-box.ps1`, and
`packaging/docker/test-install-box.ps1`. Confirmed the wiki text matches the
source: the web CI job installs the root bundle into `vendor/root-bundle`,
passes it through `GOLDEN_E2E_BUNDLE_PATH`, the golden-path E2E pins the daemon
to the root `Gemfile` while clearing inherited web-bundle keys, and the
PowerShell installer emits failure copy with `Write-Host` so the file-backed
child-`pwsh` harness can capture it after `exit`.

No stale page content was found. [[testing]] and [[gaps]] already reflect the
current CI/test contracts and still preserve the remaining uncertainty about
tagged-release CI, hosted installer availability, Windows Docker Desktop, and
full live Docker/provider first-run evidence. Page coverage did not change, so
[[index]] was not edited. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

---
date: 2026-06-12
slug: hivebox-bundler-installer-ci-audit
pages: [testing, gaps]
---

Post-commit wiki refresh after commit `6ff018e0` fixed the hivebox
golden-path E2E daemon's CI Bundler isolation and changed the Windows
PowerShell installer's failure copy from `Write-Error` to `Write-Host`. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first. `qmd search "hivebox golden path bundler
BUNDLE_PATH Windows installer Write-Host"` returned no indexed hits, and
targeted `rg` over the configured master wiki found no Hivebox-specific
context.

Inspected the committed diff plus current `.github/workflows/ci.yml`,
`web/test/e2e/golden_path_e2e.rb`, `packaging/docker/install-box.ps1`,
`packaging/docker/test-install-box.ps1`, [[testing]], [[commands/web]], and the
recent hivebox E2E/installer wiki fragments. Confirmed the source change is
test/CI hardening, not a new product command surface: CI now installs the root
bundle into `vendor/root-bundle`, passes that path to the Rails E2E as
`GOLDEN_E2E_BUNDLE_PATH`, and `GoldenPathE2E#spawn_daemon!` pins
`BUNDLE_GEMFILE`, sets `BUNDLE_PATH`, and deletes inherited web-bundle
deployment/config keys before both the daemon env probe and foreground daemon
spawn. `install-box.ps1` now emits `Fail` messages with `Write-Host` so the
file-backed child-`pwsh` harness can capture friendly failure text before
`exit` unwinds the process.

Updated [[testing]] with the explicit root-bundle isolation and `Write-Host`
capture contract. Updated [[gaps]] so the hivebox golden-path install gap
includes `6ff018e0` while preserving the remaining uncertainty: no checked-in
artifact proves a tagged-release CI pass after this fix, hosted installer
availability, a Windows Docker Desktop end-to-end install, or the full live
Docker/provider first-run path. Page count did not change, so [[index]] was
not edited. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

---
date: 2026-06-12
slug: hivebox-e2e-installer-diagnostics-audit
pages: [testing, gaps]
---

Post-commit wiki refresh after commit `03006e61` improved diagnostics for the
hivebox golden-path E2E daemon spawn and the Windows PowerShell installer
harness. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], and recent compiled [[log]] entries first. `qmd search "hivebox golden
path daemon env probe Windows installer file capture"` returned no indexed
hits; targeted `rg` over the configured master wiki found no Hivebox-specific
context.

Inspected the committed diff plus current `web/test/e2e/golden_path_e2e.rb`,
`packaging/docker/test-install-box.ps1`, `packaging/docker/install-box.ps1`,
`.github/workflows/ci.yml`, [[testing]], [[commands/web]], and the recent
golden-path / Windows-installer wiki fragments. Confirmed the source change is
test-harness diagnostic coverage, not a product behavior change:
`GoldenPathE2E#spawn_daemon!` now runs `bundle exec ruby -Ilib bin/hive
--version` with the exact daemon environment before `Process.spawn`, and the
failure teardown prints daemon stdout, PID liveness, and `$HIVE_HOME/logs`
inventory. `test-install-box.ps1` now redirects child installer output to a
temp file because `exit` inside `install-box.ps1` tears down piped PowerShell
capture before `Out-String` flushes.

Updated [[testing]] with the daemon-env preflight, expanded failure artifacts,
and file-backed PowerShell capture contract. Updated [[gaps]] to keep the
hivebox golden-path gap current: the workflow and diagnostics are pinned in
source/tests, but there is still no checked-in artifact proving a tagged
release CI pass, hosted installer availability, Windows Docker Desktop
end-to-end install, or full live Docker/provider first-run path. Page count did
not change, so [[index]] was not edited. Did not edit compiled [[log]], and did
not run `qmd update` or `qmd embed`.

---
date: 2026-06-12
slug: brakeman-ignore-wiki-refresh
pages: [testing, gaps]
---

Post-commit wiki refresh after commit `83f0a800` added a Brakeman
false-positive ignore for the hivebox task log path and committed the earlier
PR #300 command/API wiki-refresh fragment. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search "brakeman registry laundered log path"`
returned only prior log context, and direct `rg` over the project and
configured master wiki found generic Brakeman dependency/convention coverage.

Inspected the committed diff plus current `config/brakeman.ignore`,
`web/app/controllers/tasks_controller.rb`,
`web/app/controllers/application_controller.rb`, `web/config/routes.rb`,
`web/test/integration/tasks_test.rb`, `.github/workflows/ci.yml`,
[[commands/web]], [[testing]], and [[dependencies]]. Verified the ignore
rationale against source: `params[:project]` is resolved by
`find_project!` from registered projects before `hive_state_path` is used,
the route constrains `:slug`, and `latest_log` additionally applies
`File.basename(params[:slug])` before joining under the registry-derived
log root.

Updated [[testing]] so the CI static-analysis surface includes the Brakeman
job and `config/brakeman.ignore` false-positive policy, and updated [[gaps]]
with source-file coverage for CI/security-tooling config plus the remaining
uncertainty that no focused regression test exercises the task-log route with
malicious project/slug shapes. Parsed `config/brakeman.ignore` as JSON and ran
the CI Brakeman command successfully:

```bash
bundle exec brakeman --force --no-pager --quiet --format github --ignore-config config/brakeman.ignore
```

Page count did not change, so [[index]] was not edited. Did not edit compiled
[[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-12
slug: pr300-command-api-wiki-refresh
pages: [architecture, decisions, cli, commands/web, commands/drop, modules/daemon, state-model, stages/index, stages/plan, testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`279a9380` touched hivebox routes/controllers, dispatch handlers, Docker
installers, the `hive-drop` schema, daemon healing, and the manual web demo
recorder. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], and recent compiled [[log]] entries
first. Read-only `qmd search "routes handlers commands executable entrypoints
README hivebox"` against the project and master collections returned no hits,
so verification used the committed diff plus direct source reads.

Inspected `lib/hive.rb`, `lib/hive/daemon/stale_agent_healer.rb`,
`lib/hive/web/dispatcher.rb`, `lib/hive/web/supervisor.rb`,
`web/app/controllers/application_controller.rb`,
`web/app/controllers/repos_controller.rb`, `web/app/controllers/tasks_controller.rb`,
`web/config/routes.rb`, `web/script/record_box_demo.rb`,
`packaging/docker/install-box.sh`, `packaging/docker/install-box.ps1`,
`schemas/hive-drop.v1.json`, `schemas/hive-drop.v2.json`, and focused unit /
integration tests around web dispatch, auth, schema files, stale-agent healing,
web command boot, Docker installer argv, and hivebox status/log behavior.

Updated [[commands/web]], [[architecture]], and [[decisions]] for request-time
owner re-check and session eviction, clone process-group timeout and partial
target cleanup, bounded task log tail reads, queue-grammar 422s, the manual
`web/script/record_box_demo.rb` entrypoint, and installers binding
`127.0.0.1` by default with `HIVEBOX_BIND` as the opt-out. Updated
[[commands/drop]] and [[cli]] so `hive drop --json` is documented as current
`hive-drop.v2` with v1 retained for pinned validators. Updated
[[modules/daemon]], [[state-model]], [[stages/index]], and [[stages/plan]] so
`3-plan` requeue coverage includes any successful terminal `ERROR` clear there,
including elapsed `limits_reached`, not only terminal agent loss. Updated
[[testing]] for the new unit/test coverage and [[gaps]] for remaining live
smoke gaps, the unrun demo recorder, and the observed copied v1 `$id`/title
metadata in `schemas/hive-drop.v2.json`.

Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-12
slug: dependency-rack-test-lockfile
pages: [dependencies, gaps, operating, active-areas]
---

Post-commit dependency coverage refresh after commit `2e307a19` touched
`Gemfile.lock`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[dependencies]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "rack-test dependency Gemfile.lock"` and
`qmd search "v0.2.4 release Gemfile.lock hive-cli"` returned no indexed hits;
the configured master wiki path only had general dependency notes, not
Hive-specific coverage.

Inspected the committed diff plus current `Gemfile`, `hive.gemspec`,
`Gemfile.lock`, `web/Gemfile`, and `web/Gemfile.lock`. Confirmed
`2e307a19` removes the stale root `rack-test` spec and top-level
`DEPENDENCIES` entry left after the root manifest removal in `b0a31edf`;
the separate web bundle still resolves `rack-test` transitively through
Rails/Capybara. Also inspected release commit `c7d8aa4f` because the current
root lockfile path gem is `hive-cli (0.2.4)`; that release diff changes only
the local path gem entry in `Gemfile.lock`, not third-party root dependency
constraints or resolved versions.

Updated [[dependencies]] for the resolved root `rack-test` lockfile state and
the current `hive-cli (0.2.4)` path-gem version. Updated [[gaps]] to close the
stale root `rack-test` uncertainty and carry the current unresolved
v0.2.4 release-channel verification gap. Updated [[operating]] and
[[active-areas]] release snippets that point at the current install/release
version. Page coverage did not change, so [[index]] was not edited. Did not
edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

---
date: 2026-06-12
slug: hivebox-image-ci-audit
pages: [commands/web, testing, gaps]
---

Post-commit wiki coverage audit for `4328b59a` (`ci(hivebox): test the image
on linux+mac, the installer on windows`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent compiled
[[log]] entries, and recent `wiki/log.d/` fragments first. `qmd search
"hivebox image CI installer Windows PowerShell smoke docker GitHub Actions"`
returned no indexed hits, and the configured master wiki path had no matching
Hivebox context.

Inspected the committed diff plus current `.github/workflows/ci.yml`,
`.github/workflows/release.yml`, `packaging/docker/smoke.sh`,
`packaging/docker/test-install-box.ps1`, `packaging/docker/install-box.sh`,
`packaging/docker/install-box.ps1`, `web/test/e2e/golden_path_e2e.rb`,
`test/e2e/tg/drive_idea.py`, [[commands/web]], [[testing]], and [[gaps]].
Refreshed [[testing]] and [[commands/web]] so they describe the new
workflow-pinned smoke matrix: Linux push/PR image boot smoke, release pre-push
amd64 smoke, post-publish macOS/Colima arm64 smoke, and Windows PowerShell
installer-script checks against stubbed Docker. Refined [[gaps]] rather than
closing it: the workflow code now pins the front-door image/installer checks,
but no checked-in artifact proves a successful tagged release run, hosted
`hivecli.sh` installer availability, Windows Docker Desktop end-to-end install,
or the full Docker path with real GitHub/gh/provider credentials. Page coverage
did not change, so [[index]] did not need a catalog update. Did not edit
compiled [[log]], run `qmd update`, or run `qmd embed`.

---
date: 2026-06-12
slug: golden-path-e2e-wiki-audit
pages: [testing, gaps]
---

Post-commit wiki coverage audit for `cb549192`
(`wiki: document the hivebox golden-path E2E in testing`) after it touched
[[testing]]. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], recent compiled [[log]] entries, and recent
`wiki/log.d/` fragments first. `qmd search "hivebox golden path e2e testing"`
returned no indexed hits, so verification used direct wiki/source reads plus
the configured master wiki path (only generic E2E conventions, no Hivebox
constraints).

Inspected the committed diff and current `web/test/e2e/golden_path_e2e.rb`,
`web/test/e2e/support/claude`, `web/test/system/pipeline_flow_test.rb`,
`test/e2e/tg/_drive.py`, `test/e2e/tg/drive_idea.py`, [[commands/web]],
[[commands]], [[e2e]], [[testing]], and [[gaps]]. Confirmed the local
golden-path E2E documents a real browser/Rails app, real daemon subprocess,
real stage transitions, and real worktree commit with GitHub HTTP and Claude
agent output stubbed. Fixed the malformed [[testing]] heading/backlinks from
the prior wiki edit. Also fixed the Telegram E2E driver to import
`drive_start`; without that import the documented `/start` leg would raise
before exercising the live Bot API path. Refined [[gaps]] so `/start` is
classified as source/unit/E2E-harness pinned while still lacking a checked-in
live Bot API or Docker run artifact. Page coverage did not change, so
[[index]] did not need a catalog update. Did not edit compiled [[log]], run
`qmd update`, or run `qmd embed`.

---
date: 2026-06-12
slug: windows-hivebox-installer-audit
pages: [index, commands, commands/web, gaps]
---

Post-commit command/API/executable/README coverage audit for `4c14bc3f`
(`feat(hivebox): Windows PowerShell installer`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search "Windows PowerShell hivebox
installer install-box.ps1 Docker"` returned no indexed hits; targeted wiki and
configured master-wiki search found only the existing hivebox installer context.

Inspected the committed diff plus current `packaging/docker/install-box.ps1`,
`packaging/docker/install-box.sh`, `packaging/docker/README.md`, and
`.github/workflows/release.yml`. Confirmed the new PowerShell script matches
the shell installer contract: Docker availability/running checks, existing
container-name refusal, `HIVEBOX_IMAGE` / `HIVEBOX_NAME` / `HIVEBOX_PORT` /
`HIVEBOX_DATA` overrides, image pull, persistent `/data` mount, restart policy,
local URL printout, and first-login claim reminder. Refreshed [[index]],
[[commands]], and [[commands/web]] so the public install surface includes both
`https://hivecli.sh/box` and `https://hivecli.sh/box.ps1`; updated [[gaps]] to
record missing hosted-installer and Windows Docker Desktop live-smoke evidence.
Page count did not change. Did not edit compiled [[log]], run `qmd update`, or
run `qmd embed`.

---
date: 2026-06-12
slug: golden-path-surface-audit
pages: [index, architecture, decisions, commands, commands/web, modules/config, dependencies, testing, gaps]
---

Post-commit command/API/executable/README coverage audit for `bf3e7ee`
(`feat(hivebox): golden-path install — claim, same-origin, gh relay, image`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "hivebox golden path install claim same-origin gh relay docker image"`
returned no indexed hits, and the configured master wiki path had no matching
Hivebox context.

Inspected the committed diff plus current `lib/hive/web/github_auth.rb`,
`lib/hive/web/agents_auth.rb`, `web/app/controllers/sessions_controller.rb`,
`web/config/routes.rb`, `web/config/environments/production.rb`,
`packaging/docker/install-box.sh`, `packaging/docker/README.md`,
`packaging/docker/Dockerfile`, `.github/workflows/release.yml`, and the focused
web auth tests. Confirmed [[commands/web]] already documented the core web
surfaces, then refreshed adjacent coverage for the changed ownership/config
contract, `gh` relay dependency/API, same-origin Action Cable behavior,
GHCR/install-box release surface, and source-test evidence. Recorded remaining
uncertainty in [[gaps]]: no checked-in artifact proves the published GHCR image,
the hosted `hivecli.sh/box` installer, or a full live Docker first-run with
real GitHub/gh/repo push. Page count did not change. Did not edit compiled
[[log]], run `qmd update`, or run `qmd embed`.

---
date: 2026-06-12
slug: bot-start-welcome-audit
pages: [commands/bot, modules/bot, testing, gaps]
---

Post-commit bot command/module coverage audit after `4353734f`
(`feat(bot): /start replies with a welcome instead of a shrug`) added
`Router` intent `:slash_start`, `SlashHandlers#start`, and focused router /
slash-handler tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "telegram /start bot welcome hivebox bot supervision"` returned no
indexed hits, and the configured master wiki path had no matching context.

Inspected the committed diff plus current `lib/hive/bot/router.rb`,
`lib/hive/bot/handlers/slash_handlers.rb`, `lib/hive/bot/supervisor.rb`,
`test/unit/bot/router_test.rb`, `test/unit/bot/slash_handlers_test.rb`,
`test/unit/bot/supervisor_test.rb`, the committed `bot-start-welcome`
fragment, and the affected wiki pages. Updated [[commands/bot]] with the
supported `/start` behavior while keeping `setMyCommands` accurate: the
registered quick-actions menu still contains the nine typeable workflow
commands, and `/start` is handled separately for Telegram's automatic
first-contact update. Refreshed [[modules/bot]] for the new router/handler
surface, [[testing]] for the source-tree coverage, and [[gaps]] for the missing
live Bot API / Dockerized hivebox smoke evidence. Page coverage did not change,
so [[index]] required no catalog update. Verified the fragment with
`bundle exec ruby -Itest test/unit/wiki_log_test.rb`. Did not edit compiled
[[log]], run `qmd update`, or run `qmd embed`.

---
date: 2026-06-12
slug: review-remediation-surface-audit
pages: [commands/web, commands/drop, testing, gaps]
---

Post-commit command/API surface audit for `65e90ebe`
(`fix(hivebox): review remediation - round transitions, honest failures`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "hivebox review remediation red task retry recovery heal_requeue_failed answers controller drop pr_closed status broadcaster"`
returned no indexed hits, and the configured master wiki path had no matching
context.

Inspected the committed diff plus current `lib/hive/commands/drop.rb`,
`lib/hive/daemon/logger.rb`, `lib/hive/daemon/stale_agent_healer.rb`,
`lib/hive/web/dispatcher.rb`, `lib/hive/web/status_feed.rb`,
`web/app/models/status_broadcaster.rb`, `web/app/controllers/tasks_controller.rb`,
`web/app/helpers/application_helper.rb`, `web/app/javascript/controllers/answers_controller.js`,
`web/app/javascript/controllers/project_filter_controller.js`, relevant Rails
views, focused unit/integration/system tests, and the affected wiki pages.
Confirmed existing pages already covered the data-model queue/status-broadcaster
shape, `heal_requeue_failed`, web Retry recovery, and most hivebox remediation.
Refreshed [[commands/web]] to document Q&A form morph behavior and marker-only
markdown-comment stripping, bumped [[commands/drop]] for the clarified
`pr_closed` contract, corrected stale hivebox status-broadcast test coverage in
[[testing]], and refined [[gaps]] for the remaining Advanced Drop live-smoke
uncertainty. Page coverage did not change, so [[index]] required no catalog
change. Verified the fragment with `bundle exec ruby -Itest
test/unit/wiki_log_test.rb`. Did not edit compiled [[log]], `qmd update`, or
`qmd embed`.

---
date: 2026-06-12
slug: data-model-status-broadcaster-audit
pages: [state-model, commands/web, modules/daemon, testing, gaps, index]
---

Post-commit data-model coverage audit after `65e90ebe`
(`fix(hivebox): review remediation - round transitions, honest failures`)
touched the Rails model `web/app/models/status_broadcaster.rb` plus daemon
queue/healer and web dispatcher/controller paths. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[dependencies]],
[[gaps]], and recent compiled [[log]] entries first. `qmd search
"hivebox status broadcaster web dispatcher stale agent healer recovery route
task state"` returned no indexed hits, and the configured master wiki had no
matching context.

Inspected the committed diff plus current `web/app/models/status_broadcaster.rb`,
`lib/hive/web/status_feed.rb`, `lib/hive/web/dispatcher.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`,
`lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/commands/drop.rb`,
`web/app/controllers/tasks_controller.rb`, `web/app/controllers/repos_controller.rb`,
focused broadcaster/status-feed/dispatcher/healer tests, and the touched wiki
pages. Confirmed no `web/db/*_schema.rb` or migration file changed; the model
touch is a non-ActiveRecord Turbo bridge over `hive status` snapshots. Refreshed
[[state-model]] so the data-model page now covers the global dispatch-request
JSON queue, `.claimed` / `.claim` / `.sequence` files, web recovery sequence
cleanup, `StatusFeed` snapshot/dedup semantics, and `StatusBroadcaster`'s
refresh-before-projects-frame ordering. Corrected [[commands/web]] so dedup is
attributed to `StatusFeed`, added [[modules/daemon]] coverage for
`heal_requeue_failed` and web sequence continuations, updated [[testing]] for
the new focused coverage, and refined [[gaps]] for the remaining no-live-smoke
and no-focused-refresh-order-test uncertainty. Page coverage metadata changed
because [[state-model]] now names the web model and daemon queue sources, so
[[index]] was bumped. Did not edit compiled [[log]], run tests, `qmd update`, or
`qmd embed`.

---
date: 2026-06-12
slug: web-recovery-route-audit
pages: [architecture, commands/web, testing, gaps]
---

Post-commit command/API surface audit for `9d0fc9ef`
(`feat(hivebox): Retry button + diagnostic banner for red tasks`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first, then checked [[architecture]] before
editing.
Read-only `qmd search "hivebox web recovery retry diagnostic banner red task"`
returned no indexed hits; direct wiki/master-wiki search found older diagnostic
and route/command history, but not this new task-page route.

Inspected the committed diff plus current `lib/hive/web/dispatcher.rb`,
`web/config/routes.rb`, `web/app/controllers/tasks_controller.rb`,
`web/app/helpers/application_helper.rb`, `web/app/views/tasks/_state.html.erb`,
`lib/hive/bot/handlers/recovery_sequence.rb`,
`lib/hive/bot/notification_builders.rb`,
`test/unit/web/dispatcher_test.rb`, and `web/test/integration/tasks_test.rb`.
Refreshed [[commands/web]] for `POST /tasks/:project/:slug/recover`, the
diagnostic banner, and the `trigger=web_recover` daemon-queue sequence; refreshed
[[architecture]] so the hivebox mutation summary includes web recovery via the
bot `RecoverySequence`; refreshed [[testing]] for the new unit/Rails integration
contracts; and refreshed [[gaps]] to record that source/Rails integration
coverage plus commit-message live verification exist, while browser-system/Docker
artifacts remain absent. Page coverage did not change, so [[index]] was not
edited. Did not run tests, `qmd update`, or `qmd embed`.

---
ts: 2026-06-12T18:53:29Z
slug: babysitter-gh-auth-token-dry-run
tags: [wiki, babysitter, gh, dry-run, security]
---

## Wiki: refresh babysitter gh auth token dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `67537dce` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh stub dry-run token auth passthrough"` surfaced the existing babysitter command/module/testing/gap coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] and [[modules/babysitter]] so the `gh` dry-run allowlist no longer reads as blanket `auth status`: only plain `gh auth status` passes through, while token-revealing `--show-token` / `-t` variants are skipped and logged. Refreshed [[testing]] for the focused dry-run regression coverage and [[gaps]] to carry the same uncertainty forward: no checked-in artifact proves a full live-agent `hive babysit --once PROJECT --dry-run` run after this token-leak guard. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-12
slug: pr-review-remediation-3
pages: [commands/web, commands/drop, modules/daemon]
---

External ce-code-review pass on PR #300 (4×P1, 4×P2), all addressed:

- Installers bind 127.0.0.1 by default (HIVEBOX_BIND opt-out): a fresh
  box is claimable by its FIRST login, so it must not be reachable by
  network peers before the owner signs in.
- require_login re-checks the CURRENT owner each request: rotating
  web.github.owner (or re-claiming) evicts old sessions, which hold
  repo-scoped tokens.
- hive-drop schema bumped to v2 for the pr_closed semantic change
  (true = PR cleanup clean incl. no-PR case); v1 file kept for pinned
  external validators.
- Web clone! runs in its own process group with a hard deadline
  (HIVEBOX_CLONE_TIMEOUT_SEC, default 180s) and removes partial targets —
  a wedged gh can no longer hold a Puma worker forever.
- Queue-grammar rejections of dispatchable names surface as typed 422s.
- The polled log tail reads a 256KB byte window, not the whole file.
- EVERY 3-plan heal requeues the rerun (limits_reached cooldown left the
  same markerless empty plan.md as agent loss).
- Compiled wiki/log.md restored to main; fragments only in the PR.

---
date: 2026-06-12
slug: image-ci-matrix
pages: [testing, commands/web]
---

CI now tests the shippable artifact on three OSes, each at the deepest
level the platform allows:

- Linux (every push, ci.yml): the golden-path browser E2E joins the web
  job, and a new hivebox-docker job builds the image (gha-cached) and runs
  packaging/docker/smoke.sh — boot, /health, CLAIMABLE login copy (one
  assertion proving config defaults + web tier + claim flow survived the
  image build), owner-gate 302. The smoke uses a random host port
  (parallel-safe; dev machines already running a box on 4567).
- Release (release.yml): the amd64 image must pass the same smoke BEFORE
  the multi-arch push — no tag can reach ghcr without booting. After
  publish, a macos-15 (arm64) job pulls the real registry image and smokes
  it under colima — covering the Docker-Desktop-on-Mac layer (VM port
  forwarding, native arm64 pull).
- Windows (every push, ci.yml): hosted runners cannot run Linux containers
  (Windows-container mode only, no WSL2), so the per-OS surface under test
  is install-box.ps1 itself on real Windows PowerShell with a stubbed
  docker CLI: missing-docker failure copy, happy-path argv shape
  (pull/run/-v/-p), existing-container refusal.

---
date: 2026-06-12
slug: golden-path-e2e
pages: [testing, gaps]
---

hivebox golden-path E2E: browser-driven claim (stubbed GitHub HTTP, real
device-flow logic), idea → brainstorm Q&A answered in the UI → plan →
execute under a REAL daemon with a stage-aware fake claude, ending at
"Ready to open PR" with a real worktree commit (~35s; opt-in via explicit
path — not *_test.rb). The tg e2e (real Bot API) gained a /start welcome
leg. Hunting flakes surfaced a REAL product edge now in [[gaps]]: answers
written within one daemon tick of round-end are invisible to the resume
watcher (baseline seeded after reap); the E2E syncs on the daemon event
log, a product fix is sketched. Also fixed en route: the catch-all fake
agent case was committing into the PROJECT repo via the display-name
backfiller, and sandbox worktrees now stay inside the sandbox
(worktree_root config beats HIVE_WORKTREE_BASE).

---
date: 2026-06-12
slug: golden-path
pages: [commands/web]
---

Golden-path install work (mother test): (1) release.yml gains a
hivebox-image job — multi-arch (amd64/arm64) GHCR publish on every tag,
gated on release-finalize; (2) packaging/docker/install-box.sh — the
one-command installer (curl | sh shape, overridable via HIVEBOX_* env);
(3) first-login-claims-owner — an ownerless box admits the first
successful device-flow login and writes it into web.github.owner under
the config lock (concurrent-claim race: exactly one wins, the loser gets
the owner 403); (4) Action Cable accepts same-origin-as-host, killing
the web.origin trap (live updates silently dead on any non-localhost
URL); (5) gh joins the Agents-page PTY relay with auto-answered
Press-Enter prompt — the last docker-exec step is gone. Docker README
rewritten around the golden path.

---
date: 2026-06-12
slug: bot-start-welcome
pages: [commands/web, modules/bot]
---

Dogfood report: a freshly connected hivebox bot greeted its first /start —
the command Telegram sends automatically on first contact — with "I did
not understand that", and the operator saw "no menu and no commands". Two
causes: /start had no route (now → a welcome reply with concrete next
steps: /status, /idea, /help), and the command menu (setMyCommands at bot
boot) plus all replies require a running bot process — which the BOX
supervisor manages, but a dev-host bare `rails server` does not; noted in
[[commands/web]] that `hive bot start` is manual there.

---
date: 2026-06-12
slug: review-remediation-2
pages: [commands/web, modules/daemon, commands/drop]
---

Second multi-agent review pass (span 90f0f0cc..HEAD) and its remediation:

- REAL BUG confirmed and fixed: morphing cannot remove data-turbo-permanent
  elements, so a new Q&A round left the previous round's form lingering
  (round-transition system test now pins it). Typing survival moved from
  permanence to an answers controller that snapshots/restores textarea
  values + caret across morphs, keyed by field name — stale drafts die
  with their round by construction.
- Healer: requeue failure after a successful clear now logs its own
  heal_requeue_failed event (with remediation command) instead of the
  misleading marker_heal_failed; real-queue integration test pins the
  full healer → queue → allowlist contract.
- Web recover: discards its .sequence sidecar when the request write
  fails (bot-supervisor parity); refuses marker-less rows (a bare rerun
  behind a "Recovery queued" flash would be a hidden Run).
- render_markdown strips only MARKER_RE-shaped comments — fenced code
  samples documenting markers keep their content.
- Drop: pr_closed is now unambiguous (true = PR cleanup clean incl.
  no-PR case; false = a recorded PR would not close) and the web notice
  qualifies itself on it.
- project_filter re-applies after morphs (turbo:render) and resets ghost
  ?project= deep links instead of showing an empty grid; deep-link and
  ghost system tests added.
- Vacuous tests tightened: tail-pause now provably outlasts two real
  ticks via a data-poll-ticks beacon; the Q&A morph test gained a real
  sync point (the task's own content changes).
- normalize_origin! logs its skip paths; broadcaster sends the refresh
  signal before the fallible grid render; nine stale/wrong comments
  corrected (incl. the false "TUI recovers byte-identically" claim).

## [2026-06-12T10:11:17+01:00] wiki — audit Claude model/effort command and agent surface

**Action:** Refreshed command/API and executable-wrapper wiki coverage after commit `8d180e2e` added project-global `claude.model` / `claude.effort` pins for hive-launched Claude sessions. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "claude model effort config init prompt agent spawn tmux wrapper"` surfaced the existing gaps/log context but no fuller project page. Inspected the committed diff plus current `lib/hive/config.rb`, `lib/hive/agent.rb`, `lib/hive/stages/base.rb`, `lib/hive/claude_launcher.rb`, `lib/hive/scripts/interactive_claude_wrapper.sh`, `lib/hive/commands/init.rb`, `lib/hive/commands/init/prompts.rb`, `templates/project_config.yml.erb`, `schemas/hive-init.v1.json`, and focused init/agent/launcher tests.

Documented that `hive init` now asks two additional Claude questions after permission mode, that `hive-init.v1` carries `claude_model` / `claude_effort` in the nested `answers` object rather than as top-level fields, and that `Hive::Config.claude_cli_flags` feeds both the headless `Hive::Agent` argv and the tmux wrapper. Updated ADR-030 in [[decisions]] so the global Claude launch decision now records the model/effort follow-up instead of stopping at mode and permission mode. Corrected the earlier fragment so it no longer claims branch-side web questionnaire/task-page changes or links to a missing `commands/web` page. Recorded the remaining uncertainty: argv wiring is unit-pinned, but no in-tree live Claude Code smoke artifact proves `--model default` or explicit `--effort` values against the installed CLI. Page coverage count stayed 76; [[index]] was updated for metadata/TLDR only. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands/init]]
- [[decisions]]
- [[modules/agent]]
- [[modules/config]]
- [[testing]]
- [[gaps]]
- [[index]]
- [[log]]

---
date: 2026-06-12
slug: web-recovery-button
pages: [commands/web]
---

Operator-reported: a "Needs recovery" task (reviewer died on claude token
limits) had no recovery affordance on its web page. Task pages now show a
red diagnostic banner (the row's diagnostic.summary — WHY it is red, not
just that it is) and a "Retry stage" primary button for the three
diagnostic actions (recover_review/recover_execute/error).
`Web::Dispatcher#recover` reuses the bot's
`Handlers::RecoverySequence` verbatim — manual-only guard, guarded
`hive markers clear --match-attr`, then the stage verb — written to the
daemon queue as one request sequence (the retry stays invisible until the
clear exits 0), trigger=web_recover. Web, bot, and TUI now recover
byte-identically. Live-verified by recovering the real stuck review.

## [2026-06-11T21:04:41Z] wiki — refresh patrol native-reviewer documentation

**Action:** Refreshed wiki planning/documentation coverage after inspecting recent source commits `b2e568ba` (native `codex review` reviewer for patrol PRs), `852cc10c` (patrol mode default back to `medium`), and the latest v0.2.3 wiki follow-up commit `0212469b`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent [[log]], and the latest `wiki/log.d/` fragments first. Searched the configured master wiki path `/home/asterio/wikis/master/wiki` and checked the default cross-project wiki paths; only the configured master path exists, and it had no Hive-specific patrol reviewer guidance. `qmd search "patrol review reviewers codex native review init config"` surfaced the existing native-reviewer fragment plus stale [[modules/config]] wording.

Verified current source in `lib/hive/config.rb`, `lib/hive/commands/init/prompts.rb`, `lib/hive/reviewers/codex_review.rb`, `templates/project_config.yml.erb`, and focused test coverage. Updated [[architecture]], [[commands/init]], [[commands/patrol]], [[commands/doctor]], [[modules/config]], [[stages/index]], [[stages/review]], and [[gaps]] so they consistently describe `codex-native-review` (`kind: codex_review`) as the patrol PR reviewer default, Codex/Claude CE reviewers as opt-ins, `patrol_reviewers=codex-native-review` in the non-TTY init summary, Doctor's current non-agent reviewer behavior, and the current config default caps. Page coverage did not change, so [[index]] needed no structural update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands/init]]
- [[commands/patrol]]
- [[commands/doctor]]
- [[modules/config]]
- [[stages/index]]
- [[stages/review]]
- [[gaps]]

---
date: 2026-06-11
slug: telegram-setup-guide-audit
pages: [commands/web, gaps]
---

Post-commit command/API coverage audit for `b47f6627`
(`feat(hivebox): first-timer setup guide on the Telegram page`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first. `qmd search "hivebox telegram setup
guide bot token chat id"` returned no indexed hits, and the configured master
wiki only had generic Telegram gem references.

Inspected the committed diff plus current
`web/app/views/telegram/show.html.erb`,
`web/app/assets/stylesheets/application.css`,
`web/app/controllers/telegram_controller.rb`,
`web/test/integration/telegram_test.rb`, [[commands/web]], and [[gaps]].
Confirmed the Rails page now renders a collapsible first-timer guide that
starts open while `bot.enabled` is false, links BotFather and userinfobot,
walks bot creation, numeric chat ID lookup, `/start` before test messages,
long-polling/no-webhook setup, and `/revoke` token rotation. Updated
[[commands/web]] for the surface and integration-test contract, and updated
[[gaps]] to carry the new source-test evidence while keeping the missing
browser/Docker/live-agent smoke uncertainty. Page coverage did not change, so
[[index]] was not edited. Did not run tests, `qmd update`, or `qmd embed`.

---
date: 2026-06-11
slug: hivebox-log-frame-morph-audit
pages: [commands/web, testing, gaps]
---

Post-commit wiki coverage audit for `463fff29`
(`fix(hivebox): log refreshes morph in place -- no more 3s blink`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first. `qmd search "hivebox task log artifact
turbo morph refresh"` returned no indexed hits, so verification used the
committed diff, direct source reads, and targeted `rg` over the configured
master wiki path plus project docs/wiki.

Inspected `web/app/views/tasks/show.html.erb`,
`web/app/views/tasks/_log.html.erb`, `web/app/javascript/controllers/poll_controller.js`,
`web/app/javascript/controllers/artifacts_controller.js`,
`web/app/controllers/tasks_controller.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the code keeps the log
inside the existing `tasks#log` turbo-frame surface, adds `refresh: "morph"` to
the turbo-permanent log frame, and pins the no-blink contract with a Playwright
system assertion that a tagged `pre[data-tail-follow]` DOM node survives a poll
refresh that brings in a new log line.

Refreshed [[commands/web]] and [[testing]] so the browser coverage explicitly
mentions node-preserving log-frame morph reloads, and updated [[gaps]] so the
remaining uncertainty is only live Docker / long-running-agent evidence for the
same behavior against a deployed hivebox while real agents append logs and
artifacts. Page coverage did not change, so [[index]] did not need a catalog
update. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-11
slug: hivebox-rail-composer-audit
pages: [commands/web, gaps]
---

Post-commit command/API coverage audit for `24c41980`
(`feat(hivebox): rail selection preselects the composer + Add project link`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hivebox project filter
composer add project"` returned no indexed hits; the configured master wiki only
had broad Rails/wiki context.

Inspected the committed diff plus current
`web/app/javascript/controllers/project_filter_controller.js`,
`web/app/views/status/index.html.erb`,
`web/app/assets/stylesheets/application.css`,
`web/config/routes.rb`, `web/app/controllers/status_controller.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the follow-up keeps the
project rail client-side: explicit project clicks now sync the composer select,
filtered deep links preselect only when the composer is unset, widening back to
All projects preserves the chosen project, and `+ Add project` is a Repos link
rather than a filter button. Updated [[commands/web]] to document those surface
and system-test contracts, and updated [[gaps]] so the hivebox residual entry
carries the `24c41980` source/test evidence while the deployed/live-agent
uncertainty remains open. Page coverage did not change, so [[index]] was not
edited. Did not run tests, `qmd update`, or `qmd embed`.

---
date: 2026-06-11
slug: hivebox-project-filter-audit
pages: [commands/web, gaps]
---

Post-commit command/API coverage audit for `70d60980`
(`feat(hivebox): project filter rail + select polish`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hivebox project filter
rail select placeholder status projects"` returned no indexed hits; the
configured master wiki only had broad Rails/wiki context.

Verified the committed diff plus current `web/app/javascript/controllers/project_filter_controller.js`,
`web/app/views/status/index.html.erb`, `web/app/views/status/_projects.html.erb`,
`web/app/assets/stylesheets/application.css`, `web/config/routes.rb`,
`web/app/controllers/status_controller.rb`, Stimulus controller autoloading, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the rail adds no route or
handler: it filters the already-rendered status grid client-side, mirrors the
choice into `?project=` with `history.replaceState`, and re-applies after Turbo
Stream replace/morph updates. The composer project select now uses a
disabled+hidden placeholder via `select_tag`, and global select styling draws a
custom chevron. Updated [[commands/web]] so the Tests section names the
project-rail system coverage, and updated [[gaps]] so the hivebox residual entry
carries the `70d60980` evidence while the deployed/live-agent uncertainty
remains open. Page coverage did not change, so [[index]] was not edited. Did not
run `qmd update` or `qmd embed`.

---
date: 2026-06-11
slug: hivebox-artifact-tabs-audit
pages: [commands/web, gaps]
---

Post-commit audit for `c52e4e83` (`style(hivebox): artifact tabs are
chrome, documents are documents`). Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "hivebox artifact tabs documents"` returned no indexed hits; the
configured master wiki only had broad Rails/markdown context. Verified the
committed diff in `web/app/assets/stylesheets/application.css` plus the current
task page view (`web/app/views/tasks/show.html.erb`), artifact controller, and
web tests covering markdown rendering, artifact ordering, log placement, and
open-state preservation.

Refreshed [[commands/web]] so the task page docs distinguish artifact
summaries as filename-tab UI chrome from rendered markdown document panels.
Carried uncertainty forward in [[gaps]]: no checked-in screenshot,
visual-regression artifact, live Docker smoke, or long-running-agent hivebox
run proves the artifact-tab/document visual distinction in a browser. Page
coverage did not change, so [[index]] was not edited. Did not run `qmd update`
or `qmd embed`.

---
date: 2026-06-11
slug: dependency-coverage-audit
pages: [dependencies, gaps]
---

Post-commit dependency coverage audit after the hivebox branch touched
dependency manifests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[dependencies]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "dependency Gemfile Gemfile.lock web Gemfile Rails Redcarpet"`
returned no indexed hits; the configured master wiki only had general Rails
dependency patterns. Verified the latest dependency-touching commit
`d7ce55a9` (`web/Gemfile`, `web/Gemfile.lock`) plus the current root and web
manifests/lockfiles.

Confirmed Redcarpet is a web-bundle dependency only (`~> 3.6`, locked
3.6.1), added by `d7ce55a9` for sanitized markdown artifact rendering in
hivebox task pages. Refreshed [[dependencies]] so root dev/test coverage now
includes `rubocop-rails-omakase`, `brakeman`, and `bundler-audit`, and so the
web dev/test bundle and transitive `rack-test` use are covered. Recorded
uncertainty in [[gaps]]: commit `b0a31edf` removed the root `rack-test`
manifest declaration, but current `Gemfile.lock` still lists it as a
top-level dependency. Page coverage did not change, so [[index]] was not
edited. Did not run `qmd update` or `qmd embed`.

## [2026-06-11T20:16:38Z] status/tui — transient stage-move race coverage

**Action:** Refreshed command/API wiki coverage after commits `bd0b965a`, `4099bbc4`, and `520660e9` touched `Hive::Commands::Status`. Read `AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `.llm-wiki/config.json` points at `/home/asterio/wikis/master/wiki`, and `qmd search "status vanished task folders Errno::ENOENT stage_task_entries"` returned no indexed hits. Inspected the committed diffs plus current `lib/hive/commands/status.rb`, `test/unit/commands/status_test.rb`, `test/integration/status_test.rb`, [[commands/status]], [[commands/tui]], [[state-model]], and [[testing]]. Documented the status scan's `Errno::ENOENT` tolerance for vanished task folders, the `stage_task_entries` seam, the duplicate-slug cleanup that drops only rows whose folders no longer exist, and the TUI implication that normal stage moves should not render a one-poll duplicate row. Recorded that this race is now covered by focused unit regressions, while live TUI/daemon smoke evidence remains absent. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[gaps]]

---
date: 2026-06-11
slug: hivebox-artifact-reading-audit
pages: [commands/web, dependencies, testing, gaps]
---

Post-commit wiki coverage audit for `d7ce55a9`
(`feat(hivebox): finalize-first artifacts, markdown rendering, log last`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "routes handlers commands executable entrypoints README hivebox"`
returned no indexed hits, so verification used the committed diff, direct
source reads, and targeted `rg` over the configured master wiki path plus
project docs/wiki.

Inspected `web/config/routes.rb`, `web/app/controllers/tasks_controller.rb`,
`web/app/helpers/application_helper.rb`, `web/app/views/tasks/show.html.erb`,
`web/Gemfile`, `web/Gemfile.lock`, `web/test/integration/tasks_test.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the route table did not
change; the surface change is task-page behavior: `TasksController` now orders
artifacts chronologically until `8-finalize`/`9-done`, then puts `artifact.md`
first so the deliverable opens by default; the task view renders artifacts
before the log; and `ApplicationHelper#render_markdown` uses Redcarpet with
GFM tables/fenced code/autolinks, drops leading YAML front matter, escapes raw
HTML before rendering, and sanitizes the rendered output with an explicit
allowlist.

Existing [[commands/web]] coverage already matched the handler/view behavior,
including the Redcarpet and finalize-first artifact details. Refreshed
[[dependencies]] so the separate Rails web bundle and its Redcarpet dependency
are covered, refreshed [[testing]] so the Rails integration layer mentions
artifact ordering/markdown/log-layout regressions, and updated [[gaps]] to
include `d7ce55a9` in hivebox's source-pinned-but-not-live-Docker-smoked
coverage. Page coverage did not change, so [[index]] did not need a catalog
update. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-11
slug: hivebox-grid-scroll-audit
pages: [commands/web, testing, gaps]
---

Post-commit wiki coverage audit for `0dea8aa6`
(`fix(hivebox): grid updates no longer reset page scroll`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search` for `hivebox grid scroll preserve
turbo morph status index composer permanent system test` and `Turbo morph
scroll preserve data turbo permanent composer Rails status index` returned no
indexed hits, so verification used the committed diff, direct source reads,
and targeted `rg` over the configured master wiki path plus project docs/wiki.

Inspected `web/app/views/status/index.html.erb`,
`web/app/models/status_broadcaster.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed that the status page now
opts the shared status-channel refresh signal into Turbo morph refresh with
scroll preservation, keeps the composer form `data-turbo-permanent` because
typed draft text and staged image chips live in browser state, and pins the
behavior with a Playwright system test that overflows the grid, scrolls down,
types into the composer, lands a live broadcast, and verifies scroll position
plus composer text survive.

Refreshed [[commands/web]] and [[testing]] so the status-grid scroll/composer
contract is documented alongside the existing Turbo Stream and task-page morph
coverage. Updated [[gaps]] so the hivebox residual entry includes `0dea8aa6`
and keeps the remaining uncertainty scoped to live Docker / long-running-agent
evidence against a deployed hivebox. Page coverage did not change, so
[[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`.

---
date: 2026-06-11
slug: hivebox-log-artifact-audit
pages: [commands/web, testing, gaps]
---

Post-commit command/API-surface audit for `eb971b55`
(`fix(hivebox): logs and artifacts are readable while live-updating`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. `qmd search
"hivebox log tail artifact details poll controller turbo permanent"` returned
no indexed hits, so verification used the committed diff plus direct source
reads.

Inspected the changed Stimulus controllers and views:
`web/app/javascript/controllers/poll_controller.js`,
`web/app/javascript/controllers/artifacts_controller.js`,
`web/app/views/tasks/show.html.erb`, and `web/app/views/tasks/_log.html.erb`,
plus `web/config/routes.rb`, `web/app/controllers/tasks_controller.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the route/API surface did
not add a new endpoint: the task page still uses `GET
/tasks/:project/:slug/log` rendered by `TasksController#log`, but the log
frame is now `data-turbo-permanent`, current source gives its own frame reloads
`refresh: "morph"`, and its poll controller follows the tail, pauses reloads
while scrolled up, and resumes at the bottom. Artifact details now preserve
operator open/closed state only across Turbo morphs while content continues to
update.

Existing [[commands/web]] coverage already described the new behavior. Refreshed
[[testing]] so `web/test/system/pipeline_flow_test.rb` includes the log-tail and
artifact-morph regressions, and narrowed [[gaps]]: `tasks#log` is no longer an
uncovered browser happy path, while live Docker / long-running-agent evidence
for this reading behavior remains absent. Page coverage did not change, so
[[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`.

## [2026-06-11T18:26:30Z] wiki — refresh JSON wrapper last-flag coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `56f1fdcb` changed `bin/hive`, `bin/hive-e2e`, and focused wrapper tests so wrapper-owned usage/error formatting consults the last recognized JSON boolean flag instead of any truthy flag. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "JSON wrapper boolean error mode false flags"` surfaced existing wrapper coverage, and the configured master wiki path had no relevant matching pattern. Inspected the committed diff plus current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[cli]], [[commands]], [[e2e]], [[testing]], and [[gaps]]. Updated the affected pages to document that duplicate JSON boolean flags are resolved by the final recognized boolean for wrapper-owned usage/preflight/error output, so final false forms like `--no-json` or `--json=false` force prose even after an earlier `--json`. The existing packaged-wrapper uncertainty remains: no in-tree artifact proves the RubyGems/Homebrew/AUR-installed `hive` executable exercises this wrapper path. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[e2e]]
- [[testing]]
- [[gaps]]

---
date: 2026-06-11
slug: healer-plan-requeue-audit
pages: [architecture, modules/daemon, state-model, stages/plan, modules/task_action, testing, gaps]
---

Post-commit audit for `5f7ba051` (`fix(daemon): healer requeues 3-plan
reruns instead of deadlocking`). Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "stale agent healer 3-plan dispatch request heal_requeued"`
returned no indexed hits, and the configured master wiki path had no matching
healer/requeue context.

Inspected the committed diff plus current
`lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/daemon/logger.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`, `lib/hive/task_action.rb`,
`test/unit/daemon/stale_agent_healer_test.rb`, and
`test/integration/daemon_stale_agent_healing_test.rb`. Corrected stale wiki
coverage, including [[architecture]], that still described terminal agent-loss
auto-clears as late-stage-only: the current healer covers every non-review stage
(`2-brainstorm`, `3-plan`, `4-execute`, `7-artifacts`, `8-finalize`), while
`3-plan` additionally queues `hive plan <slug> --project <project> --from
3-plan` with `requestor=healer` / `trigger=terminal_agent_loss` because an
empty markerless `plan.md` otherwise remains an undispatchable `:error`.

During source verification, found that `StaleAgentHealer` emitted
`heal_requeued` but the closed daemon log enum did not include it. Added the
enum entry and the integration closed-enum assertion so the documented trace
event is accepted by the real logger. Recorded the remaining uncertainty in
[[gaps]]: no in-tree live artifact proves a real daemon observes a red
`3-plan` terminal-agent-loss row, writes the queue request, dispatches it, and
surfaces recovery or bounded exhaustion. Verified with
`bundle exec ruby -Itest test/unit/daemon/stale_agent_healer_test.rb test/integration/daemon_stale_agent_healing_test.rb`
and `bundle exec rubocop --format simple lib/hive/daemon/logger.rb
test/integration/daemon_stale_agent_healing_test.rb`. Page coverage did not
change, so [[index]] did not need a catalog update. Did not run `qmd update`
or `qmd embed`.

---
date: 2026-06-11
slug: web-drop-task-audit
pages: [architecture, commands, commands/web, commands/drop, testing, gaps]
---

Post-commit audit for `4a09cdb9` (`feat(hivebox): Drop task card in Advanced
— Shift+X parity`). Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], and recent compiled [[log]] entries
first. `qmd search "hivebox drop task Advanced Shift X dispatcher tasks
controller routes"` returned no indexed hits; local wiki search found the new
drop references in [[commands/web]], [[commands/drop]], and the existing TUI
Shift+X coverage.

Inspected the committed diff plus current `lib/hive/web/dispatcher.rb`,
`web/app/controllers/tasks_controller.rb`, `web/config/routes.rb`,
`web/app/views/tasks/show.html.erb`, `lib/hive/commands/drop.rb`,
`test/unit/web/dispatcher_test.rb`, and `web/test/integration/tasks_test.rb`.
Refreshed command/API coverage so the web Drop route is documented as an
in-process `Commands::Drop` call, not a daemon queue request; the task page
posts the rendered stage as `from`, so a stale page raises `Hive::WrongStage`
and renders 422 without deleting the moved task. Refreshed [[commands/web]]
frontmatter/TLDR for the gem-side `lib/hive/web/` dispatcher path, refreshed
[[testing]] for the new dispatcher/integration coverage, and recorded the
remaining live-browser / Docker smoke gap in [[gaps]]. Page coverage did not
change, so [[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`.

---
date: 2026-06-11
slug: telegram-setup-guide
pages: [commands/web]
---

The Telegram page gained a first-timer setup guide (collapsible, open
while the bot is unconfigured): create the bot via @BotFather /newbot,
get the numeric chat ID by messaging @userinfobot (the mother-grade
version of README's curl+ruby getUpdates recipe), and /start the bot
before the round-trip test. Notes the no-webhook/long-polling model and
the /revoke rotation path. Shared .setup-guide/.setup-steps styles for
future agent-page guides.

---
date: 2026-06-11
slug: project-rail-select-polish
pages: [commands/web]
---

Operator-requested grid navigation: a left project rail (TUI left-pane
parity) filters the task list client-side — "All projects" plus one button
per registered project. Buttons, not links: a navigation would discard the
permanent composer's typed text. The choice mirrors into `?project=` via
history.replaceState, and a MutationObserver re-applies the filter after
each broadcast replace/morph (the replace drops client-set hidden
attributes). System test covers filter, URL sync, survival across a live
broadcast, and restore via "All projects".

Composer select polish: the "Project…" prompt no longer appears as a
selectable row (disabled+hidden placeholder via select_tag — FormBuilder
insists on injecting a blank option for required selects), and selects get
a custom chevron with right breathing room (native arrows hug the edge).

---
date: 2026-06-11
slug: markers-stripped-from-markdown
pages: [commands/web]
---

Operator-requested: stage markers (`<!-- COMPLETE -->` and friends) no
longer show as literal text in rendered artifacts. `render_markdown` now
strips ALL HTML comments (plus the existing front-matter strip) before
rendering — matching how GitHub renders markdown, where comments are
invisible. The stage badge owns state display; prose should not repeat it.

---
date: 2026-06-11
slug: finalize-artifact-reading
pages: [commands/web]
---

Task-page reading order and rendering, operator-requested: artifact order
is stage-aware (chronological while working; artifact.md first — and
therefore open — from 8-finalize/9-done, where the deliverable is what the
page is opened for), the log moved below the artifacts as an appendix, and
.md artifacts render as real markdown via redcarpet (GFM tables/fenced
code, autolink, strikethrough). LLM-authored content gets two safety
layers: escape_html turns raw HTML into visible text (markers like
<!-- WAITING --> stay legible), and Rails sanitize with an explicit
tag/attribute allowlist strips what survives. Leading YAML front matter is
dropped from the rendered body. Integration tests pin the finalize/early
ordering, the Artifacts-before-Log layout, and the sanitized rendering.

---
date: 2026-06-11
slug: grid-scroll-preserve
pages: [commands/web, gaps]
---

Operator-reported: grid updates on `/` yanked the page back to the top. The
status channel's refresh signal (added for task pages) also reaches the
index, which had no morph metas — Turbo fell back to a full-body replace
refresh, resetting window scroll. The index now carries the same
`turbo-refresh-method=morph` + `turbo-refresh-scroll=preserve` metas, and
the composer form is `data-turbo-permanent` (it holds typed-but-unsent idea
text and staged image chips — Stimulus state a morph cannot re-render).
System test pins scroll position and composer text across a live broadcast.

Also recorded in [[gaps]]: the review fix phase does not detect agent loss
when the tmux server itself dies (observed during the third
sweep-kills-server incident, this one from a pre-fix long-running child;
recovery is TERMing the review parent so the daemon re-dispatches).

---
date: 2026-06-11
slug: log-tail-artifact-reading
pages: [commands/web]
---

Operator-reported: the log's 3s poll and the page's pushed morphs yanked
scroll/open state, making logs and artifacts unreadable mid-scroll. The log
frame is now data-turbo-permanent (morphs never touch it) and its poll
controller gained `tail -f` semantics: pinned to the pane's bottom while
following (data-following beacon), paused while scrolled up reading, resumes
at the bottom. Artifacts keep morphing (content stays live while agents
write) but a Stimulus controller snapshots the operator's details-open
choices before each morph and reapplies them after, keyed by artifact name
and scoped to morphs only so state never leaks across task pages. System
tests pin both: pause/resume with a real growing log file, and an
open-second-artifact surviving a broadcast-triggered morph with updated
content.

---
ts: 2026-06-11T18:17:33Z
slug: babysitter-remote-show-surface-audit
tags: [wiki, babysitter, commands, dry-run]
---

## Wiki: audit babysitter remote-show dry-run surface

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `1d9cd8ec` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, and existing babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "routes handlers commands executable entrypoints README API surface"` surfaced existing wrapper/babysitter audit coverage. Inspected the committed diff plus the current git dry-run stub, focused dry-run env test, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the dry-run contract is now `git remote show -n <remote>` only; plain `git remote show <remote>` skips before a repo-local `protocol.ext.allow=always` plus `ext::` helper can execute. Updated command/module/testing coverage to name that boundary and kept the existing uncertainty in [[gaps]]: no in-tree live `hive babysit --once PROJECT --dry-run` agent-smoke artifact was found. Page coverage stayed within existing pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
ts: 2026-06-11T18:07:00Z
slug: babysitter-remote-show-no-query
tags: [babysitter, git, security, dry-run]
---

## Babysitter: skip network-contacting git remote show in dry-run

**Action:** Tightened `bin/hive-babysitter-stub-git` so `git remote show` only passes through when the no-query flag is present (`remote show -n <remote>`). Plain `remote show <remote>` is now skipped because it can contact the remote and honor repo-local transport configuration before the dry-run guard gets another chance to intervene.

**Tests:** Added a regression in `test/unit/babysitter/dry_run_env_test.rb` with repo-local `protocol.ext.allow=always` and an `ext::` origin helper. The test proves `git remote show origin` is logged as skipped and the helper marker file is not created. Verified with `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`.

**Refreshed pages:**
- [[commands/babysit]]
- [[gaps]]

---
date: 2026-06-11
slug: healer-plan-requeue
pages: [modules/daemon, gaps]
---

Dogfood incident #2 with the unmerged orphan-sweep fix (PR #446): a review
pass's old pkill sweep matched the tmux SERVER argv and killed it, taking a
parallel 3-plan agent down (`tmux_session_terminated`). The healer healed
the marker — and deadlocked: clearing the ERROR left an empty plan.md,
which `TaskAction#incomplete_plan_artifact?` classifies straight back to
`:error`, an action Policy skips and the healer can no longer match (no
marker reason left).

Fix: `StaleAgentHealer` 3-plan agent-loss heals now also enqueue
`hive plan <slug> --from 3-plan` through `DispatchRequestQueue`
(requestor=healer, logged as `heal_requeued`), so re-entry is explicit.
Other stages keep the passive edit-resume path — their state files
classify dispatchable once the marker clears. The queue's concurrency
gates and the heal retry budget (3) still bound the reruns.

## [2026-06-11T17:15:30Z] wiki - follow up v0.2.3 release/orphan-sweep coverage

**Action:** Refreshed wiki planning/documentation coverage after commit
`6b9f14bb` touched wiki release and Claude/tmux orphan-sweep pages. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent [[log]] entries first; `qmd search "v0.2.3 release orphan sweep claude
tmux"` and `qmd search "dependencies Gemfile.lock hive-cli 0.2.3 release"`
returned no indexed hits, and the configured master wiki path had no matching
release/orphan-sweep context.

Inspected the committed diff plus source commits `ad9b6204` and `024b29b0`.
Checked `Gemfile`, `hive.gemspec`, `Gemfile.lock`, `lib/hive.rb`,
`CHANGELOG.md`, `README.md`, `install.md`, `lib/hive/claude_launcher.rb`, and
`test/unit/stages/brainstorm_tmux_sentinel_test.rb`. Confirmed the current
pages are source-synced on the v0.2.3 path-gem/version bump and on the
`pgrep` + per-PID `TERM` orphan sweep that skips matched `tmux` server
commands and logs killed/skipped rows. Removed stale May 25 active-history
wording from [[active-areas]], corrected [[operating]] so the install section
names the direct runtime gems now owned by `hive.gemspec`, and refined [[gaps]]
to make the two unresolved verification points explicitly span the 2026-06-11
refreshes. Page coverage did not change, so [[index]] needed no structural
update. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[operating]]
- [[gaps]]

---
date: 2026-06-11
slug: web-drop-task
pages: [commands/web]
---

Task pages gained a Drop card in the Advanced section — the web parity of
the TUI's Shift+X. `Hive::Web::Dispatcher#drop` calls `Commands::Drop`
in-process (kills the agent, removes folder/worktree/branch, closes a draft
PR; hard delete, no undo). The card is confirm-gated, and the `from` stage
scopes the resolve so a stale page refuses (`Hive::WrongStage` → 422)
instead of deleting a task whose state moved on.

## [2026-06-11T17:09:29Z] dependencies/wiki - refresh v0.2.3 lockfile coverage

**Action:** Refreshed dependency wiki coverage after commit `ad9b6204` touched
`Gemfile.lock` during the v0.2.3 release prep. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[dependencies]], [[gaps]], and recent
[[log]] / `wiki/log.d/` entries first; `qmd search "dependencies Gemfile.lock
hive-cli 0.2.3 release"` returned no indexed hits. Inspected the committed diff
plus current `Gemfile`, `hive.gemspec`, `Gemfile.lock`, `lib/hive.rb`, and
the existing v0.2.3 release/orphan-sweep wiki fragment.

Confirmed the committed dependency-file diff only changes the local path gem
entry from `hive-cli (0.2.2)` to `hive-cli (0.2.3)`, matching
`Hive::VERSION`; no third-party gem constraints or resolved third-party
versions changed in that commit. Updated [[dependencies]] because the manifest
ownership and counts were stale: runtime constraints live in `hive.gemspec`,
`Gemfile` pulls them through `gemspec`, direct runtime gems include
`faraday`/`faraday-multipart`, and the development/test table now lists
`rubocop-rails-omakase`, `brakeman`, and `bundler-audit`. Updated [[gaps]] to
make dependency-manifest coverage explicit and to carry the remaining
uncertainty that this source/lockfile refresh does not prove installed
v0.2.3 channel behavior. Updated [[index]] metadata only; page count stayed 76.
Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[dependencies]]
- [[gaps]]
- [[index]]

## [2026-06-11T17:05:39Z] release/wiki — refresh v0.2.3 install and tmux orphan-sweep coverage

**Action:** Refreshed command/API, README/install, release, and Claude/tmux wiki coverage after commit `ad9b6204` prepared `v0.2.3` and the immediately preceding hotfix commit `024b29b0` changed `Hive::ClaudeLauncher` cleanup behavior. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "release v0.2.3 README install version hive-cli"` returned no indexed hits, and the configured master wiki path had no relevant local hits. Inspected the committed release diff plus `lib/hive.rb`, `Gemfile.lock`, `README.md`, `install.md`, `CHANGELOG.md`, `lib/hive/claude_launcher.rb`, and `test/unit/stages/brainstorm_tmux_sentinel_test.rb`.

Documented that the current pinned Linux installer examples and release-verification examples now target `v0.2.3`; `Hive::VERSION` and the lockfile path gem are `0.2.3`; and the hotfix release notes correspond to the tmux orphan-sweep change. Updated [[modules/agent]], [[stages/brainstorm]], and [[testing]] for the cleanup contract: `sweep_orphan_processes` searches by the task `--add-dir`, kills matched non-tmux PIDs individually, skips matched tmux server commands, and logs killed/skipped entries to `claude-tmux-orphan-sweep.log`. Updated [[gaps]] to carry two remaining uncertainties: no in-tree artifact proves `packaging/verify-release.sh --version=v0.2.3` or published channel verification, and no post-fix live artifact proves two real Claude/tmux tasks can run in parallel while one task finishes and the sibling session survives. Page coverage did not change, so [[index]] was not edited. Did not run `qmd update` or `qmd embed`.

---
date: 2026-06-11
slug: hivebox-origin-audit
pages: [architecture, commands, commands/web, testing, gaps, index]
---

Post-commit audit for `8be458bd` (`fix(hivebox): normalize cloned repos to
https origins`). Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], recent compiled [[log]] entries, and
the latest `wiki/log.d/` fragments first. `qmd search "hivebox https origin gh
auth git credential quarantine"` returned no indexed hits, and the configured
master wiki path had only generic command-injection guidance.

Inspected the committed diff plus current `web/app/controllers/repos_controller.rb`,
`web/config/routes.rb`, `web/test/integration/repos_test.rb`, and
`packaging/docker/Dockerfile`. Refreshed web command/API coverage so the Repos
surface now matches source: registration runs origin normalization after both
clone and existing-directory paths, leaves absent/non-GitHub remotes alone,
rewrites GitHub SSH origins to https, and relies on the Docker image's
`gh auth git-credential` helper for GitHub push auth. Refreshed [[testing]] for
the new Rails integration regression and recorded the remaining live-Docker
push smoke gap in [[gaps]]. Corrected [[index]] page-count/date metadata after
confirming the catalog already listed all 77 non-fragment wiki pages. Did not
run `qmd update` or `qmd embed`.

---
date: 2026-06-11
slug: https-origin-normalization
pages: [commands/web, gaps]
---

Dogfood incident: a task reached `5-open-pr` with work committed, but the
push failed three times (`git@github.com: Permission denied (publickey)`) and
the daemon quarantined the task — the web row kept saying "Ready to open PR"
with no visible error. Root cause: `gh repo clone` honored the operator's
`git_protocol: ssh`, producing an ssh origin the headless daemon can't
authenticate (SSH auth lived in the 1Password agent; the container has no
keys at all).

Fixes: hivebox registration now rewrites github ssh origins to https
(`ReposController#normalize_origin!`, regression-tested), and the Docker
image configures `gh auth git-credential` as git's https credential helper
for github.com. The quarantine-invisibility problem is recorded as an open
gap in [[gaps]].

## 2026-06-11 — claude.model / claude.effort: hive stops inheriting the operator's interactive model

hive-launched claude sessions now pass `--model` (and optionally
`--effort`). The default `claude.model: default` uses Claude Code's live
"default" alias — tracking ITS recommended model (Opus-class today)
without hardcoding a name — instead of inheriting whatever the operator
last picked interactively (dogfooding found pipeline runs silently
billing Fable). `inherit` restores the old behavior; any alias/full name
passes through (`sonnet` = budget pick). `claude.effort` defaults to
Claude Code's own tier (high today) by omitting the flag; low/medium/high
pass through. Selected during init on BOTH surfaces: new TTY prompts
(scripted-answer order gains two slots after permission mode) and the web
setup questionnaire. Flags ride `Hive::Config.claude_cli_flags` into the
tmux wrapper and the headless Agent argv. The task page's Reject/Force
approve moved into a described Advanced section at the page bottom.
See [[modules/config]], [[commands/init]], [[commands/web]].

## [2026-06-10T14:30:00Z] feat — codex native-review reviewer as the patrol PR reviewer

**Action:** Added `Hive::Reviewers::CodexReview` (`lib/hive/reviewers/codex_review.rb`), a new reviewer adapter that runs codex's native single-pass `codex review` subcommand and captures its stdout into the `reviews/<output_basename>-<pass>.md` GFM-checkbox findings file, replacing the expensive multi-persona `ce-code-review` fan-out for patrol PRs. Wired it as the DEFAULT `patrol.review.reviewers` entry in `Hive::Config::DEFAULTS` (`name: codex-native-review`, `kind: codex_review`, `agent: codex`, `prompt_template: reviewer_codex_native_review.md.erb`); human-PR `review.reviewers` is unchanged.

**Design notes (verified against codex-cli 0.139.0):**
- `codex review --base <BRANCH>` works but is MUTUALLY EXCLUSIVE with a custom `[PROMPT]` (`"the argument '--base <BRANCH>' cannot be used with '[PROMPT]'"`), and the native `--base` output is codex's own free-form summary, not Hive's checkbox format. So the adapter uses **custom-PROMPT mode**: argv is `[codex, "review", "--title", <title>, <prompt>]` (never `--base`), and the prompt itself scopes the review to `git diff <default_branch>...HEAD` and coerces the High/Medium/Nit output.
- Output is captured (combined stdout+stderr) under a wall-clock timeout with process-group TERM on timeout; validated to contain ≥1 `## High|Medium|Nit` header, else the per-reviewer error path runs and no malformed findings file is left for triage.
- No `UsageDb` recording — `codex review` surfaces no machine-parseable usage event (that's `codex exec --json` only); fabricating zeros would pollute the ledger.

**Dispatch / config:** `Hive::Reviewers.dispatch` gained a `codex_review` branch on the existing `kind` discriminator. `Hive::Config.validate_reviewer_entries!` now validates `kind` against `REVIEWER_KINDS = %w[agent codex_review linter]` and exempts `codex_review` from the `skill` requirement (name/output_basename uniqueness still enforced). `hive init`'s patrol-reviewer multiselect adds `codex-native-review` as index 1 / the blank default.

**Tests/quality:** New `test/unit/reviewers/codex_review_test.rb` + `test/fixtures/fake-codex` (fakes the codex subprocess; no real codex spawned). `bundle exec rake coverage` → 100.00% line coverage, gate passed, 0 failures. `bundle exec rubocop` on changed Ruby files → no offenses.

**Refreshed pages:**
- [[modules/reviewers]]
- [[modules/patrol]]

## [2026-06-10T00:04:10Z] wiki — audit merged finalize error archive coverage

**Action:** Refreshed command/API and helper-module wiki coverage after commit `d05fb4c3` touched the archive workflow flag, `StageAction`, the daemon dispatcher/merge watcher, `Hive::Gh.pr_state`, and focused tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "merged finalize error archive pr_state stage_action daemon pr_merge_watcher"` returned no indexed hits, and the configured master wiki path had no relevant match. Inspected the committed diff plus current `lib/hive/cli.rb`, `lib/hive/commands/stage_action.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/pr_merge_watcher.rb`, `lib/hive/gh.rb`, and focused daemon/stage-action/GitHub tests. Corrected [[modules/daemon]] so the documented full-tick order matches source: the PR-merge watcher ticks before dispatch-request processing and per-row dispatch, so newly enqueued recoverable finalize error rows are polled on a later tick. Added coverage-gate tests for the `hive generate-name` CLI delegation and Codex stdin display-name prompt path, and documented those rows in [[testing]]. Carried forward the missing live-daemon smoke uncertainty in [[gaps]]. Page coverage count stayed 76, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/daemon]]
- [[testing]]
- [[gaps]]

## 2026-06-10 — hivebox web tier rewritten as a vanilla Rails 8 + Turbo app

The Sinatra/Puma web UI (and its SSE limiter + hand-rolled reconciliation
JS) is replaced by a `rails new` app in `web/`: Turbo Streams over
solid_cable for live status, Stimulus composer with image attach (clipboard
paste + upload button → `[imageN]` + `assets/`, the TUI contract), repos
page listing the operator's GitHub repositories via the retained
device-flow token (scope `repo`), claude.com-style design system, readable
typed-error pages, and a Force-approve gate action. `hive web` now execs
`bin/rails server` (HIVEBOX_WEB_APP_DIR / `web/`), with SECRET_KEY_BASE
derived from the persisted session secret and solid-stack sqlite under
state_home on `/data`. Sinatra, rack-protection, and puma left the gemspec;
the Sinatra-layer tests were replaced by Rails integration tests plus
Capybara + Playwright system tests (CI `web` job). Recorded as ADR-037;
device flow (ADR-036) unchanged. See [[commands/web]].

## 2026-06-10 — hivebox GitHub sign-in switched to OAuth device flow

The web gate's authorization-code web flow (per-operator OAuth app, callback
URL coupled to `web.origin`, `HIVEBOX_GITHUB_CLIENT_SECRET`) is replaced by
the device flow (RFC 8628): `POST /auth/github` requests a user code,
`GET /auth/github/wait` displays it and polls GitHub at the stated interval
(one poll per render, `slow_down`-aware). No callback URL or client secret
exist; `web.github.client_id` defaults to the shared hivebox OAuth app and
stays overridable. Owner-only gating, session renewal, and 403 semantics are
unchanged; GitHub transport failures now map to `Hive::Error` (friendly 422).
Recorded as ADR-036 in [[decisions]]; details in [[commands/web]] and
[[modules/config]].

## [2026-06-10T12:18:20Z] hivebox — refresh web command and API surface coverage

**Action:** Refreshed LLM wiki command/API coverage after commit `22b1f796` documented the Hivebox web workflow and added `docs/notes/hivebox-agent-oauth-relay.md`, the manual-gated Playwright contract, [[commands/web]], and `/hive web` OpenClaw coverage. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "hivebox web agents oauth relay"` and the configured master wiki path had no extra matching context. Inspected the committed diff plus current `lib/hive/commands/web.rb`, `lib/hive/web/**`, `lib/hive/config.rb`, Docker packaging, OpenClaw skill text, and focused `test/unit/web/**` / `test/e2e/hivebox_happy_path.spec.js` coverage. Updated docs so Hivebox intervention is recorded as a brainstorm-answer write, status/log SSE streams are bounded and shared, GitHub/agent auth boundaries match source, Docker supervisor behavior is covered, and missing live provider/Docker smoke plus stale README/FAQ wording remain explicit gaps. Page coverage count stayed 76, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands]]
- [[commands/web]]
- [[modules/config]]
- [[testing]]
- [[gaps]]
- [[log]]

## [2026-06-10T12:00:00Z] config — `hive init` patrol-mode default reverted to `medium`

**Action:** Reverted the `hive init` patrol-mode default (`Hive::Config::DEFAULT_PATROL_MODE`) from `low` back to `medium`, undoing PR #436. Only the patrol-**mode** default was reverted; the patrol-**reviewer** default (`patrol.review.reviewers` → `codex-native-review`, introduced by #440) was left untouched. Updated the constant + its comment in `lib/hive/config.rb`, reverted the init-default assertions in `test/unit/commands/init/prompts_test.rb` and `test/integration/init_test.rb` (renamed `test_interactive_patrol_mode_blank_defaults_to_low` → `_medium`; the no-explicit-knobs render now derives `timer`/`14400`), and corrected the `wiki/modules/config.md` prose. Explicit-mode tests (the `low` / mixed-case-`LOW` / mode-derivation-table cases) were intentionally preserved — `low` remains a valid mode, just not the default.

**Reasoning:** With the cheap native codex-review reviewer just merged (#440), per-cycle review cost is low, so scan **cadence** dominates cost again. `low`'s `new_commits` trigger fires on **every** commit, which on a high-velocity repo is more frequent (and costlier) than `medium`'s 4h timer. `medium`'s steady cadence is therefore the better default.

**Refreshed pages:**
- [[modules/config]]

## [2026-06-10T09:31:27Z] wiki — audit scrollable TUI help overlay coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `bd549d0c` documented the scrollable `hive tui` help overlay. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "tui scrollable help overlay page down page up"` returned no indexed hits, so verification used the committed diff plus direct source and test reads. Inspected `wiki/commands/tui.md`, the committed log fragment, `lib/hive/tui/views/help_overlay.rb`, `lib/hive/tui/key_map.rb`, `lib/hive/tui/update.rb`, `lib/hive/tui/bubble_model.rb`, `lib/hive/tui/app.rb`, `lib/hive/tui/messages.rb`, and focused TUI unit tests. Confirmed the wiki's command coverage matches source behavior: the overlay is height-bounded, wraps content, scrolls via keys and mouse wheel, reclamps on resize, uses explicit close keys, no-ops unrelated keys, and has a 10x40 fallback. Clarified [[commands/tui]] test coverage and recorded the remaining uncertainty in [[gaps]]: no checked-in real-terminal smoke artifact proves the full help overlay path. Page coverage did not change, so [[index]] was left unchanged. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/tui]]
- [[gaps]]

## [2026-06-10T00:34:27Z] wiki — verify JSON wrapper grammar executable coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after the rebased PR #427 commit changed `bin/hive`, `bin/hive-e2e`, focused wrapper tests, and existing wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "command api surface routes handlers commands executable entrypoints README"` found existing command/testing coverage, and the configured master wiki path had no relevant local hits. Inspected the committed diff plus current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[cli]], [[commands]], [[e2e]], and [[testing]]. The affected pages already document Thor-exact JSON boolean normalization, unsupported `--json=<value>` assignment rejection, command-local help rewrites, e2e single-document JSON output, and the focused checkout test coverage. Updated [[gaps]] to pin the remaining uncertainty: no in-tree artifact proves the packaged `hive` executable from RubyGems/Homebrew/AUR exercises the same wrapper path. Page coverage did not change, so [[index]] was not edited. Did not run `qmd update` or `qmd embed`.

## [2026-06-10T00:34:07Z] babysitter - rebase JSON wrapper grammar onto e2e single-dispatch main

**Action:** Rebasing PR #427 onto `origin/main` dropped the stale merge commit and replayed the JSON wrapper grammar fix as one commit. Resolved the wiki conflicts by preserving both the main-branch `bin/hive-e2e` single-document/single-dispatch JSON contract and this PR's Thor-exact wrapper JSON boolean grammar for `bin/hive` and `bin/hive-e2e`. Verified the focused wrapper contracts with `test/integration/cli_version_test.rb`, `test/e2e/lib/hive_e2e_binary_test.rb`, and RuboCop over the changed Ruby entrypoints/tests.

**Refreshed pages:**
- [[commands]]
- [[e2e]]
- [[testing]]

## [2026-06-09T21:00:00Z] patrol/config — default patrol mode is now `low`

**Action:** Changed `Hive::Config::DEFAULT_PATROL_MODE` from `"medium"` to `"low"`.

This is the mode the `hive init` *prompt* suggests (and writes into `templates/project_config.yml.erb`) when a project opts into patrol and accepts the default. `low` uses the `new_commits` trigger — patrol runs only when there are new commits, rather than `medium`'s every-4h timer — which keeps token spend modest by default; users can still pick `medium`/`high`/`ultrapatrol` explicitly. The opt-in gate is unchanged: a project with no `patrol.mode` stays disabled (`DEFAULT_PATROL_MODE` is only the prompt default, never a config-resolution default). `DEFAULTS["patrol"]["mode"]` stays `"medium"` as the inert placeholder (never applied because patrol is `enabled: false` until an explicit `mode:` is written).

**Refreshed pages:**
- [[modules/config]] — opt-in prose now states `low` is the prompt default and why.

# 2026-06-09 - Bot success confirmations

- Generalized Telegram bot success handling so exit-0 child completions
  no longer stay silent or surface raw `exit 0` diagnostics. `hive new`
  keeps its idea-captured message, while other successful commands now
  render command-specific confirmations such as approve, run, archive,
  status, and findings actions. See [[modules/bot]].
- Changed daemon dispatch-result notices from failure-only feedback to
  bot-originated completion feedback. The daemon now writes an exit-0
  result notice for completed queued bot requests, suppressing only
  intermediate success notices that promote the next command in a hidden
  recovery sequence. See [[modules/daemon]].

## [2026-06-09T18:15:28Z] wiki — audit babysitter textconv/index dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `872d6765` changed `bin/hive-babysitter-stub-git` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run git textconv index writes"` surfaced prior babysitter dry-run changelog coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `lib/hive/babysitter/gh_ops.rb`, `lib/hive/babysitter/pr_fixer.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] and [[modules/babysitter]] so the dry-run `git` stub surface documents both new safeguards: exact `--textconv` plus every Git-accepted abbreviation down to `--t` are skipped before read passthrough, and allowed reads execute with `GIT_OPTIONAL_LOCKS=0` so `git status`-class reads cannot refresh `.git/index`. Refreshed [[testing]] for the new exact/abbreviated textconv regression coverage, and refined [[gaps]] to keep the live-agent dry-run smoke uncertainty open while also noting that no in-tree live artifact proves the optional-lock no-index-write behavior under a real project workload. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

## [2026-06-09T17:50:16Z] wiki — audit babysitter git-stub command surface

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `6975bc7` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, and babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "command API surface routes handlers commands executable entrypoints README babysitter"` surfaced existing command/testing/log coverage, and the configured master wiki path had no relevant hit. Inspected the committed diff plus current `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Updated [[commands/babysit]] so the user-facing dry-run command surface names the new `--textconv` rejection and the hermetic allowed-read passthrough controls: neutralized HOME/XDG config, disabled system/global git config, cleared trace/config/SSH/pager env seams, `core.fsmonitor=false`, and `--no-ext-diff --no-textconv` for `diff` / `log` / `show`. Refreshed [[modules/babysitter]] and [[testing]] metadata/coverage wording, removed stale duplicate dry-run test wording, and updated [[gaps]] to record that this audit still found no live-agent `hive babysit --once PROJECT --dry-run` artifact after the 2026-06-09 stub hardening. Page coverage did not change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

## [2026-06-09T17:41:15Z] babysitter — hermetic git dry-run passthrough config

**Action:** Hardened `bin/hive-babysitter-stub-git` so allowlisted read passthrough no longer inherits user/system git config or local exec-capable diff/fsmonitor behavior. The stub now neutralizes `HOME` / `XDG_CONFIG_HOME`, disables system/global config for real git, forces `core.fsmonitor=false`, injects `--no-ext-diff --no-textconv` on `diff` / `log` / `show`, and rejects explicit `--textconv`.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with real-git regressions for HOME `.gitconfig`, `XDG_CONFIG_HOME/git/config`, local `.git/config diff.external`, local textconv, and local `core.fsmonitor`.

**Links:** [[modules/babysitter]], [[testing]], [[gaps]]

## [2026-06-09T10:16:56Z] wiki — audit JSON wrapper grammar command coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after the JSON wrapper grammar fix changed `bin/hive`, `bin/hive-e2e`, and the focused wrapper tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "json flag wrapper grammar Thor bin/hive-e2e"` returned no indexed hits, and the configured master wiki path had no matching `json flag` / `bin/hive-e2e` pattern. Inspected the committed diff plus current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, `test/e2e/lib/hive_e2e_binary_test.rb`, and the existing [[cli]], [[commands]], [[e2e]], and [[testing]] pages. Refreshed [[cli]] and [[commands]] so the public wrapper surface documents Thor-exact JSON boolean normalization and unsupported assignment rejection, refreshed [[testing]] to include the single-dispatch regression scope, and updated [[gaps]] with the remaining release-installed `hive` smoke uncertainty. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

---
ts: 2026-06-09T10:15:40Z
slug: babysitter-grep-pager-abbrev-audit
tags: [wiki, babysitter, git, dry-run]
---

## Wiki: refresh babysitter grep pager abbreviation coverage

**Action:** Refreshed wiki coverage after commit `a7088180` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], and added the source-change fragment `20260609-101443-babysitter-grep-pager-abbrev-and-cluster-parse`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the new fragment first; `qmd search "babysitter git grep abbreviated open-files-in-pager value taking short option"` returned no indexed hits, and the configured master wiki path had no relevant cross-project hit. Inspected the committed diff plus the current git/gh dry-run stubs, `Hive::Babysitter::DryRunEnv`, `Hive::Babysitter::GhOps`, focused dry-run/rebase tests, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. Updated command/module/testing/gap coverage so the dry-run contract includes abbreviated `git grep --open-files-in-pager` spellings down to `--op`, precise short-cluster parsing, and value-taking grep options such as `-eTODO` / `-fNEEDLEFILE.txt` remaining allowed. The existing uncertainty remains unchanged: no checked-in live `hive babysit --once PROJECT --dry-run` agent-smoke artifact was found. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
- [[log]]

---
ts: 2026-06-09T10:14:43Z
slug: babysitter-grep-pager-abbrev-and-cluster-parse
tags: [babysitter, git, security, dry-run]
---

## Babysitter: block abbreviated grep pager long options and parse short clusters

**Action:** Refined the grep pager guard in `bin/hive-babysitter-stub-git` on two fronts:

- **Abbreviated long options.** Git resolves any unambiguous long-option prefix, so `--open`, `--open-files`, down to the shortest unique `--op`, all reach `--open-files-in-pager`. The guard now blocks the whole abbreviation range (with or without a glued `=<cmd>`), not just the full spelling.
- **Short-option cluster parsing.** The old `include?("O")` cluster check produced false positives: a read-only attached pattern such as `-eTODO` was skipped because its value contained an uppercase `O`. `grep_short_cluster_has_pager?` now walks the cluster char by char and stops when a value-taking option (`-e`/`-f`/`-m`/`-A`/`-B`/`-C`) consumes the remainder as its operand, so only a genuine `-O` pager flag is rejected.

**Tests:** Added regressions in `test/unit/babysitter/dry_run_env_test.rb` proving abbreviated `--open`/`--open-files`/`--op` pager forms skip, and that `-eTODO` / `-f<file>` read-only searches reach real git. Targeted dry-run env unit test passed (5 runs, 617 assertions).

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]

## [2026-06-09T10:14:05Z] e2e — keep bin/hive-e2e to one Thor dispatch

**Action:** Fixed a `bin/hive-e2e` wrapper regression where the executable called `Hive::E2E::Binary.start` twice after the JSON flag grammar change. Successful JSON commands such as `bin/hive-e2e list --json` emitted two envelopes, so `test/e2e/lib/hive_e2e_binary_test.rb` failed with `JSON::ParserError`. Removed the stale second dispatch, preserved the single `debug: true` path for wrapper-formatted usage errors, and updated [[e2e]] with the single-dispatch invariant. Verified `test/integration/cli_version_test.rb`, `test/e2e/lib/hive_e2e_binary_test.rb`, `bundle exec rake e2e:lib_test`, and `bundle exec rake test`. Did not run `qmd update` or `qmd embed`.

---
ts: 2026-06-09T10:13:30Z
slug: babysitter-grep-cluster-residual-audit
tags: [wiki, babysitter, git, dry-run]
---

## Wiki: audit residual babysitter grep pager coverage

**Action:** Audited residual wiki commit `0ca7e307` after it committed documentation updates for source commit `2c62e0e9`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter git grep clustered pager dry-run stub"` returned existing babysitter dry-run history, and the configured master wiki path had no relevant cross-project hit. Inspected the residual diff, the underlying source diff, `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `lib/hive/babysitter/gh_ops.rb`, `test/unit/babysitter/dry_run_env_test.rb`, `test/unit/babysitter/gh_ops_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. Confirmed the dry-run coverage matches the code: `git grep` skips `--open-files-in-pager` plus glued, separate, and clustered short `-O` pager forms such as `-nO<cmd>`, while `git grep -o`, `git ls-files -o`, and `diff`/`log`/`show -O` read forms stay allowed. Corrected stale [[commands/babysit]] auto-rebase wording so it matches `GhOps.rebase_onto_base`: the base fetch uses the remote's effective push URL, falls back to `origin` when unresolved, and rebases onto `FETCH_HEAD`. [[gaps]] already records the remaining uncertainty: no checked-in live `hive babysit --once PROJECT --dry-run` agent-smoke artifact was found. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[log]]

---
ts: 2026-06-09T10:03:00Z
slug: babysitter-grep-cluster-audit
tags: [wiki, babysitter, git, dry-run]
---

## Wiki: audit babysitter clustered grep pager guard coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `2c62e0e9` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, and the babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter git grep pager open-files-in-pager dry-run stub"` returned existing babysitter command/module coverage plus prior dry-run changelog history, and the configured master wiki path had no relevant cross-project hit. Checked the git stub, the `DryRunEnv` PATH overlay, the gh stub boundary, the focused dry-run env test, [[commands/babysit]], [[modules/babysitter]], and [[testing]]. Confirmed the documented command/module behavior matches the code: `git grep` now skips `--open-files-in-pager` plus glued, separate, and clustered short `-O` pager forms such as `-nO<cmd>`, while `diff`/`log`/`show -O` ordering reads stay allowed. Updated [[gaps]] to keep the missing live `hive babysit --once PROJECT --dry-run` agent-smoke uncertainty current. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

---
ts: 2026-06-09T09:55:17Z
slug: babysitter-grep-clustered-pager-guard
tags: [babysitter, git, security, dry-run]
---

## Babysitter: reject clustered git grep pager short options

**Action:** Tightened `bin/hive-babysitter-stub-git` so the grep-only `--open-files-in-pager` guard rejects short-option clusters containing uppercase `O`, such as `git grep -nO<cmd> needle`, before passthrough. This closes a dry-run bypass where Git parsed the bundled `O` as the pager option while the stub only recognized tokens that started with `-O`.

**Tests:** Added a `test/unit/babysitter/dry_run_env_test.rb` regression proving clustered `-nO<cmd>` is skipped and does not reach real git. Targeted dry-run env unit test passed.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]

## [2026-06-09T09:46:07Z] cli/e2e — align wrapper JSON flag grammar with Thor

**Action:** Hardened `bin/hive` and `bin/hive-e2e` wrapper-level `--json` handling so accepted assignment forms match Thor's exact boolean grammar. Leading accepted forms such as `--json=true` are normalized behind the command before dispatch, while unsupported assignments such as `--json=1` and `--json=yes` now fail as usage before their values can become task targets or e2e run patterns. Added focused regressions in `test/integration/cli_version_test.rb` and `test/e2e/lib/hive_e2e_binary_test.rb`; refreshed [[cli]], [[e2e]], and [[testing]]. Did not run `qmd update` or `qmd embed`.

## [2026-06-09T08:31:25Z] patrol/config/daemon — make patrol opt-in and per-project scan cap

**Action:** Fixed two patrol-system bugs.

1. **Patrol opt-in (`Hive::Config.resolve_patrol_mode!`).** An unset `patrol.mode` previously fell back to `DEFAULT_PATROL_MODE` (`"medium"`), which injected medium's `enabled: true` knob over `DEFAULTS["patrol"]["enabled"] = false` — so every project with no patrol section (or no `mode:`) was silently enabled. `resolve_patrol_mode!` now `return`s without injecting knobs unless `mode:` is explicitly present in the raw config (`return unless nested_key?(data, "patrol", "mode")`), so patrol falls through to `DEFAULTS` (`enabled: false`). `medium` remains the `hive init` *prompt* default (writes an explicit `mode:` into `templates/project_config.yml.erb`); the `DEFAULT_PATROL_MODE` constant is kept only for that prompt. Net: no patrol section → disabled; explicit `mode: medium` → enabled + timer/14400 (unchanged); `mode: off` → disabled; no-mode + explicit `enabled: true` → stays enabled.

2. **Per-project patrol-scan cap (`Hive::Daemon::ConcurrencyController#can_dispatch_patrol_scan?`).** The scan count summed ALL running patrol scans across every project, so `daemon.max_concurrent_patrol_scans = 1` serialized patrol across projects and starved them. Now counts only the given project's scans (`entry[:kind] == :patrol_scan && entry[:project] == project`), making the cap per-project: different projects patrol in parallel, while a second scan for the same project still returns `:patrol_scan_cap`.

**Refreshed pages:**
- [[modules/config]] — opt-in resolution prose; `daemon.max_concurrent_patrol_scans` documented as per-project.
- [[modules/patrol]] — daemon-triggers and safety-invariants sections now state patrol is opt-in (no section / no `mode:` → disabled).

## [2026-06-08T16:42:25Z] testing — cover pr_state error branches

**Action:** Fixed the PR #405 CI coverage gate by adding focused `Hive::Gh.pr_state` unit coverage for non-zero `gh pr view` failures and unparseable JSON responses. Refreshed [[testing]] and [[modules/gh]] so the documented `gh_test.rb` contract includes `pr_state` success/error parsing.

**Tests:**
- `bundle exec ruby -Itest test/unit/gh_test.rb`
- `bundle exec rake coverage`

## [2026-06-08T16:07:41Z] wiki — refresh merged finalize error archive coverage

**Action:** Refreshed command/API and helper-module wiki coverage after the daemon-only merged finalize error archive path was added. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "finalize merged error archive pr merge watcher daemon stage_action"` found existing gaps/log context, and the configured master wiki path had no relevant Hive-specific match. Inspected the committed diff plus current `lib/hive/cli.rb`, `lib/hive/commands/stage_action.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/pr_merge_watcher.rb`, `lib/hive/gh.rb`, and focused daemon/stage-action/GitHub tests. Added [[modules/gh]] as the source-backed home for `Hive::Gh`, documented the internal `hive archive --recover-merged-error-reason` safety gates in [[cli]], [[commands/stage_action]], [[commands/daemon]], [[modules/daemon]], [[state-model]], and [[stages/finalize]], and recorded missing live-daemon smoke evidence in [[gaps]]. Updated [[index]] for the new page count. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/gh]]
- [[index]]
- [[cli]]
- [[commands/stage_action]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[state-model]]
- [[dependencies]]
- [[stages/finalize]]
- [[testing]]
- [[gaps]]

## [2026-06-08T21:42:25Z] test - harden tmux runner timeout harness

**Action:** Rebased PR #420 onto current `origin/main` and investigated the red `rake test (Ruby 3.4)` job. The failure was `TmuxRunnerTest#test_send_prompt_times_out_when_enter_submit_hangs`: CI timed out during fake `load-buffer` Ruby startup before reaching the intended hanging `send-keys` assertion. Swapped that fake tmux script to a lightweight shell script and `exec sleep 5` for the `send-keys` branch, keeping setup commands under the timeout budget and avoiding thread exception noise after the timeout kill.

**Verified:**
- `bundle exec ruby -Itest test/unit/tmux_runner_test.rb`
- `bundle exec ruby -Itest test/e2e/lib/hive_e2e_binary_test.rb`
- `bundle exec ruby -Itest test/unit/tui/state_source_test.rb`
- `bundle exec rake test`
- `bundle exec rubocop --format simple bin/hive-e2e test/e2e/lib/hive_e2e_binary_test.rb test/unit/tmux_runner_test.rb`

**Refreshed pages:**
- [[testing]]

## [2026-06-08T21:37:18Z] wiki - audit e2e single JSON contract coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `96242e97` fixed duplicate successful JSON output from `bin/hive-e2e`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "hive-e2e duplicate JSON documents"` surfaced prior e2e executable coverage, and the configured master wiki path added no project-specific constraints. Inspected the committed diff plus current `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[e2e]], [[testing]], [[commands]], and [[gaps]]. Confirmed the committed [[e2e]] update documents the single-document stdout contract, then refreshed [[commands]] and [[testing]] so the interaction-surface and test-contract pages also say successful `list --json` / `clean --json` outputs are one parseable JSON document. Recorded the remaining uncertainty that no in-tree artifact shows a live patrol/babysitter wrapper consuming those e2e JSON surfaces after the fix. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands]]
- [[testing]]
- [[gaps]]

---
ts: 2026-06-08T20:43:39Z
slug: babysitter-rebase-fetch-push-url
tags: [babysitter, github, git, bugfix, headless]
---

## Babysitter: fetch the rebase base over the push URL so auto-rebase works headless

**Bug.** `GhOps.rebase_onto_base` (lib/hive/babysitter/gh_ops.rb) fetched the base with `git fetch origin <base>` via `Hive::Gh.capture3`. `capture3` forces `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`. In the babysitter's systemd `--user` service there is no SSH agent (`SSH_AUTH_SOCK` unset), and origin's **fetch** URL is SSH (`git@github.com:…`). The fetch died with `Permission denied (publickey)`, so `rebase_onto_base` returned `:failure` every tick and green-but-`BEHIND` PRs stayed `BEHIND` (`action=rebase outcome=failure` on each pass). The force-push already worked: origin's **push** URL is HTTPS (`git remote get-url --push origin`) and gh's credential helper authenticates it.

Empirical results:
- `git fetch origin main` → works (interactive)
- `GIT_SSH_COMMAND="ssh -o BatchMode=yes" git fetch origin main` → fails (publickey denied)
- `git fetch <https-push-url> main` → works

**Fix.** `rebase_onto_base` now resolves the remote's effective push URL via `git remote get-url --push origin` (new `GhOps.fetch_source` helper) and fetches the base from that URL (`git fetch <push-url> <base>`), then rebases onto `FETCH_HEAD` (instead of `origin/<base>` — avoids touching the shared tracking ref). If the push URL can't be resolved (command fails or returns empty) it falls back to the literal `"origin"` so non-github / unusual remotes behave as before. Conflict handling is unchanged: rebase failure → best-effort `git rebase --abort` → `:conflict`; fetch failure → `:failure`; dry-run is still a no-op success. `RebaseResult` shape and `success?`/`conflict?` predicates unchanged. `Hive::Gh.capture3` (BatchMode is intentional for other callers) and `force_push_with_lease` are untouched.

**Tests.** `gh_ops_test`: fetch targets the resolved push URL (`https://github.com/o/r.git`) not bare `origin`, then `git rebase FETCH_HEAD`; push-url resolve failure → fallback to `origin`; empty push URL → fallback to `origin`; conflict path (rebase fails → `--abort` → `:conflict`); fetch-failure path (`:failure`, stops after resolve+fetch); dry-run skips git. `pr_fixer_test` stubs `rebase_onto_base` directly so its auto-rebase tests are unaffected. Full `rake test` gate passed at 100% line coverage; rubocop clean on changed files.

**Refreshed pages:**
- [[modules/babysitter]]

---
ts: 2026-06-08T20:15:00Z
slug: babysitter-rebase-push-head-branch
tags: [babysitter, github, bugfix]
---

## Babysitter: auto-rebase must force-push to the PR head branch, not the internal worktree branch

**Bug (shipped in #422).** `PrFixer#auto_rebase` rebased a green-but-`BEHIND` PR's worktree cleanly, then force-pushed via `GhOps.force_push_with_lease(worktree.path, worktree.branch, …)`. `worktree.branch` is the babysitter's INTERNAL ref name `hive-babysitter/pr-<n>`, so the push targeted `origin/hive-babysitter/pr-<n>` — NOT the PR's real head branch. Worse, the bare `git push --force-with-lease` form has no local remote-tracking ref for that name, so it failed with "stale info". Net: the rebase was thrown away, the PR stayed `BEHIND`, and the babysitter emitted `action=rebase outcome=failure` every tick (verified live on PR #300, whose real head is `i-m-thinking-of-hivebox-260602-97bc`).

**Fix.**

- `GhOps.force_push_with_lease(worktree, branch, cfg:, dry_run:, expected_oid: nil)` — new optional `expected_oid`. When present (non-nil/non-empty) it uses the explicit lease form `git push --force-with-lease=<branch>:<expected_oid> origin HEAD:<branch>`, which protects against clobbering a concurrent push WITHOUT needing a local remote-tracking ref. When absent it keeps the backward-compatible bare `--force-with-lease`. Dry-run no-op and the `PushResult` return shape are unchanged.
- `PrFixer#auto_rebase(status, started)` now receives the status rollup (threaded from `handle_green`) and force-pushes to `@pr.fetch("headRefName")` with `expected_oid: status["headRefOid"] || @pr["headRefOid"]`. Fork PRs are excluded upstream, so `origin` is always the right remote.

**Tests.** `gh_ops_test`: bare lease (no `expected_oid`), explicit lease (`--force-with-lease=feature:abc123`), empty-string OID treated as bare, dry-run skips git. `pr_fixer_test`: green+BEHIND asserts the push targets `feature-branch` (NOT `hive-babysitter/pr-42`) with the rollup's `headRefOid`; plus the `@pr["headRefOid"]` fallback path and the `nil`→bare-lease path. Full `rake coverage` gate passed (4980 runs, 0 failures/0 errors, 100% line coverage). rubocop clean on changed files.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]

---
ts: 2026-06-08T19:15:21Z
slug: babysitter-auto-rebase-behind-prs
tags: [babysitter, github, decision]
---

## Babysitter: auto-rebase green-but-BEHIND PRs to keep them mergeable

**Problem.** Strict branch protection on `main` requires a PR branch to be up-to-date with the base before it can merge. When `main` advances, an open PR goes `mergeStateStatus=BEHIND` — but it is still `mergeable=MERGEABLE` and green, so `PrFixer#already_green?` short-circuited to a `noop`/`already-green` event. The PR stayed BEHIND and un-mergeable forever; the babysitter did nothing about it.

**Change.** When a PR is green, `PrFixer` now routes through `handle_green`:

- **green + `BEHIND` + auto-rebase enabled** → materialize the PR worktree, `GhOps.rebase_onto_base` (`git fetch origin <base>` then `git rebase origin/<base>`), then on a clean rebase `GhOps.force_push_with_lease`. Emits `rebase`/`success`; returns `:rebased` (tallied as `fixed`). A rebase that hits conflicts is `git rebase --abort`ed and left for a human — no force-push, no fix agent, no label — emits `rebase`/`conflict`; returns `:rebase_conflict` (tallied as `needs_human`); re-evaluated cheaply next tick. A fetch/other failure or a failed push emits `rebase`/`failure` and returns `:failure`. Dry-run emits `rebase`/`dry_run`, returns `:dry_run`, and touches no git.
- **green + not `BEHIND`** → unchanged `noop`/`already-green`.

`behind?` reads `status["mergeStateStatus"]` from the rollup, falling back to the PR object's `mergeStateStatus`. Auto-rebase is gated on `babysitter.auto_rebase` with **nil treated as true** — only an explicit `false` opts out (mirrors the "do not silently flip legacy projects" convention).

**New rebase helper.** `GhOps.rebase_onto_base(worktree, base_ref, cfg:, dry_run:)` returns a `RebaseResult` Struct (`status` ∈ `:success`/`:conflict`/`:failure`, plus `stdout`/`stderr` and `success?`/`conflict?` predicates), built via `Hive::Gh.capture3` in the same style as `force_push_with_lease`. Conflicts run a best-effort `git rebase --abort`.

**Events.** Added action `rebase` and outcome `conflict` to the closed allowlists in `events.rb`; `emit` still raises on anything outside them.

**Config.** Added `babysitter.auto_rebase => true` to `Config::DEFAULTS` and to `templates/project_config.yml.erb`; `validate_babysitter!` now boolean-validates `auto_rebase` alongside `enabled`/`dry_run`.

**Tally.** `ProjectTick` maps `:rebased` → `fixed` and `:rebase_conflict` → `needs_human`.

**Tests.** `gh_ops_test` (rebase success / conflict-abort / fetch-failure / dry-run), `pr_fixer_test` (green+BEHIND → rebased + push, conflict → no push + no agent, push-failure → failure, rebase-error → failure, `auto_rebase:false` → noop, green+CLEAN → noop, dry-run → rebase/dry_run + no git, plus the `@pr` mergeStateStatus fallback), `events_test` (rebase/conflict accepted; unknown still raises), `project_tick_test` (`:rebased`/`:rebase_conflict` tally), `config_test` (auto_rebase default true + round-trip + non-boolean rejected). Full `rake test` green: 4975 runs, 0 failures/0 errors, 100% line-coverage gate satisfied. rubocop clean on changed files.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]

## [2026-06-08T17:36:20Z] e2e - single JSON document contract

**Action:** Fixed `bin/hive-e2e` so successful commands dispatch Thor once instead of starting `Hive::E2E::Binary` twice. `list --json`, `clean --json`, and `clean --json --dry-run` now emit exactly one top-level JSON document on stdout. Refreshed [[e2e]] to document the single-document JSON contract and added focused assertions in `test/e2e/lib/hive_e2e_binary_test.rb`.

**Refreshed pages:**
- [[e2e]]

## [2026-06-08T16:51:31+01:00] hivebox — post-commit command/API coverage audit

**Action:** Refreshed Hivebox command/API, packaging, and executable-entrypoint
wiki coverage after current `HEAD` (`bc45da35`) restored supervisor process
state and recent parent commits changed the Docker image, gem payload, web
assets, OpenClaw `/hive web` surface, and manual Playwright contract. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]],
[[gaps]], and recent [[log]] entries first; `qmd search "hivebox web docker
supervisor process state packaged web templates public assets"` and `qmd search
"hivebox web"` returned no indexed hits, while the configured master wiki had
only generic Docker references. Inspected the committed diff plus current
`lib/hive/web/supervisor.rb`, `lib/hive/commands/web.rb`, `lib/hive/web/app.rb`,
`hive.gemspec`, `packaging/docker/Dockerfile`,
`packaging/docker/entrypoint.sh`, `test/unit/web/supervisor_test.rb`, and
`test/e2e/hivebox_happy_path.spec.js`.

Corrected wiki coverage to match source: Docker agent CLI npm install is now
fail-closed, not best-effort; `hive.gemspec` packages Hivebox ERB views and
public CSS/JS; Puma is constrained to `~> 7.2`, `>= 7.2.1`; and the Hivebox
Playwright contract fails loudly when `HIVEBOX_URL` is absent. Page count stayed
76, so [[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`, and did not edit compiled [[log]].

**Refreshed pages:**
- [[commands/web]]
- [[commands]]
- [[dependencies]]
- [[testing]]
- [[gaps]]

## [2026-06-08T14:22:01Z] bot, daemon — fix-forward on #416: don't mask real errors behind the schema-skew degrade; surface skew in bot /status

**Action:** Fix-forward on #416 (commit 8b1cf115) addressing pr-review-toolkit findings on the `hive-status` forward-skew handling in `Hive::Bot::StatusWatcher#fetch` and `Hive::Daemon::StatusConsumer#fetch`.

**Findings fixed:**

1. **(CRITICAL) The `:newer` rescue over-swallowed and discarded the real error.** The single broad `rescue StandardError` keyed the "just restart" message off `schema_skew(doc) == :newer` alone and threw away `e`. Two consequences: (a) a genuine bug in `extract_rows`/`extract_projects`/`extract_legacy_stage_dirs` on a newer doc got relabeled "restart to pick up the new version" (operator restarts → same bug → defect stays invisible); (b) `validate_envelope!`'s own `ArgumentError` ("envelope ok=false: …" / "missing schema") is a `StandardError` too, so on a `:newer` doc it ALSO degraded to the skew message, masking the real `ok=false` reason. **Fix:** both `#fetch` methods now run `validate_envelope!` OUTSIDE the degrade, and wrap ONLY the extraction phase in its own `begin/rescue`. That inner rescue `raise unless skew == :newer` (an exact/equal-version extraction throw re-raises to surface the raw `#{e.class}: …`); when it does degrade, the surfaced message PRESERVES the underlying exception (`… (underlying error: <Class>: <msg>)`). The bot also logs the underlying error (class + message + first 3 backtrace lines) under `:poll_schema_skew`. Existing `JSON::ParserError` handling kept before the broad rescue.

2. **(HIGH) Bot `/status` showed degraded data with NO indicator.** Added a `warning` field to the bot `StatusWatcher::Result` (mirrors the daemon Result), populated on the `:newer` best-effort success path. `Supervisor#execute_dispatch` prepends a plain-text banner ("⚠️ hive status: running on a newer schema than this bot understands; data may be incomplete — restart the bot.") when the fetch carries a warning (via `status_fetch_warning`, tolerant of older Result shapes like `status_legacy_stage_dirs`).

3. **(MEDIUM) Forward-skew advisory was logged under `:poll_failure` (overloaded).** The bot's `warn_forward_skew` (and the new underlying-error log) now use a distinct `:poll_schema_skew` event. Added `poll_schema_skew` to `Hive::Bot::Logger::EVENTS` and to the `hive-bot-log.v2` schema `event` enum (additive append — no SCHEMA_VERSION bump). The daemon already used a distinct `:status_schema_skew`.

4. **(LOW) KeyError-in-rescue fragility.** The bot's `schema_skew`/`forward_skew_summary`/`older_skew_message` used `SCHEMA_VERSIONS.fetch("hive-status")`, which would raise `KeyError` inside a rescue-reachable path if the key were absent. Replaced with a memoized `expected_schema_version` using the non-raising `["hive-status"]` form, computed once and reused (mirrors the daemon, which already used `[]`).

**Deferred (not implemented):** per-tick / per-poll log dedup of the skew advisory — currently it can log once per tick/poll while the skew persists. Noted as a follow-up enhancement.

**Tests:** `status_watcher_test.rb` and `status_consumer_test.rb` extended — a `:newer` + `ok=false` envelope returns the REAL ok=false message (not the skew hint); a `:newer` extraction throw returns a message containing BOTH the restart hint AND the underlying `e.class: e.message` and logs the real error (bot), result `ok:false`, never raises; an exact-version extraction throw surfaces the raw error (not the skew hint). Bot: `:newer` best-effort success sets `Result#warning`; supervisor render prepends the banner (and omits it when clean). `:poll_schema_skew` fires on the bot success-path skew. The `hive-bot-log` logger test (whitelist scan + schema-valid emit) covers the new event. Full coverage gate green at 100.0% (changed files all 100%).

**Refreshed pages:**
- [[modules/bot]]
- [[modules/daemon]]

## [2026-06-08T13:00:00+01:00] hivebox — restore supervisor process state after run exits

**Action:** Fixed an order-dependent web test failure after rebasing PR #300:
`Hive::Web::Supervisor#run` published `HIVEBOX_SUPERVISOR_PID` and installed
TERM/INT/HUP traps, but did not restore that process-global state when the run
loop returned in-process. A later Telegram token-save route inherited the stale
pid and signalled the test process instead of redirecting reliably. `run` now
restores the previous env value and signal handlers in its ensure path, while
the supervisor unit test asserts that child startup still sees the supervisor
pid before cleanup.

**Tests:**
- `bundle exec ruby -Itest -e 'require File.expand_path("test/unit/web/supervisor_test.rb"); require File.expand_path("test/unit/web/telegram_routes_test.rb")' -- --seed 37831`
- `bundle exec ruby -Itest -e 'Dir["test/unit/web/*_test.rb"].sort.each { |f| require File.expand_path(f) }; require File.expand_path("test/integration/web/approve_flow_test.rb")' -- --seed 37831`

**Refreshed pages:**
- [[commands/web]]

## [2026-06-08T12:49:08Z] bot, daemon — tolerate hive-status schema_version skew instead of crashing

**Action:** Made both long-running `hive-status` consumers forward-tolerant of a `schema_version` skew instead of raising a raw `ArgumentError`. Root cause: `Hive::Bot::StatusWatcher#validate_envelope!` and `Hive::Daemon::StatusConsumer#validate_envelope!` enforced an EXACT match against the in-memory `Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status")`. When the gem is updated (schema bumped) but the bot/daemon process is NOT restarted, the in-memory `expected` is stale while the `hive status --json` subprocess emits the newer version, so the consumer hard-failed. In production this surfaced as the Telegram bot replying `hive status unavailable: ArgumentError: schema_version mismatch: got 3, want 2` to every `/status` until restart.

Fix: `validate_envelope!` now enforces only the envelope SHAPE (missing/wrong `schema`, `ok=false`) as a hard error. Version skew is classified by a new `schema_skew(doc)` → `:match` / `:newer` / `:older`. `:newer` (updated binary, additive envelope) parses best-effort and logs a one-line skew warning (bot: `poll_failure`; daemon: new closed-enum `:status_schema_skew` event surfaced via a new non-fatal `Result#warning` the dispatcher logs once per tick); if best-effort extraction throws, it degrades to an actionable `… is newer than this process (vM); restart the hive bot/daemon to pick up the new version`. `:older` (stale binary on PATH) returns an actionable `… is older than this process (vM); update/reinstall the hive binary on PATH`. `:match` is the unchanged happy path. The contract: a long-running consumer never crashes `/status` (or a daemon tick) with a raw `ArgumentError` purely because a schema_version was bumped without a restart.

`Hive::Bot::Supervisor#diagnose_reply_for_child` consumes the sibling `hive-status-diagnose` envelope but only checks `schema == ...` (never `schema_version`), so it did NOT share the brittleness and was left out of scope.

Tests: extended `status_watcher_test.rb` (+3) and `status_consumer_test.rb` (replaced the old mismatch test with +3) to prove newer = best-effort parse/warning, older = actionable failure, exact = unchanged, and that envelope-shape errors still hard-fail; added a dispatcher test proving a forward-skew result still dispatches and logs `:status_schema_skew`.

**Refreshed pages:**
- [[modules/daemon]]
- [[commands/bot]]

## [2026-06-08T12:45:42+01:00] hivebox — refresh Docker web command/API coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after
commit `a4103844` added `.dockerignore` and `packaging/docker/` for hivebox.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search
"hivebox docker packaging supervisor web entrypoint"` returned no indexed hits,
and the configured master wiki had only generic Docker references. Inspected the
committed diff plus current `packaging/docker/Dockerfile`,
`packaging/docker/entrypoint.sh`, `packaging/docker/README.md`,
`packaging/docker/compose.example.yml`, `.dockerignore`,
`lib/hive/commands/web.rb`, `lib/hive/web/**`, web config validation, web unit
tests, and the manual Playwright hivebox contract. Updated the wiki to cover the
Docker image build path, `/data` persistence boundary, `tini` entrypoint,
custom-argv behavior, `/health` healthcheck, compose environment, fail-closed
agent CLI npm install, web runtime gems, and the remaining lack of live
provider/container smoke evidence. Page count stayed 76, so [[index]] did not
need a catalog update. Did not run `qmd update` or `qmd embed`, and did not edit
compiled [[log]].

**Refreshed pages:**
- [[commands/web]]
- [[architecture]]
- [[commands]]
- [[dependencies]]
- [[testing]]
- [[gaps]]

## [2026-06-08T12:25:36Z] worktree — HIVE_WORKTREE_BASE override stops tests seeding real ~/Dev

**Action:** Centralized the default worktree-root fallback behind `Hive::Worktree.worktree_base` (`ENV["HIVE_WORKTREE_BASE"] || File.expand_path("~/Dev")`) and `Hive::Worktree.default_worktree_root(project_name)` (`<base>/<project>.worktrees`). Replaced the seven hardcoded `File.expand_path("~/Dev/#{X}.worktrees")` fallbacks (`worktree.rb` ×2, `task.rb`, `diagnosis_agent.rb`, `stages/execute.rb`, `stages/review.rb`, `commands/init.rb`) with the shared helper; behavior is identical when the env var is unset. The test suite now sets `HIVE_WORKTREE_BASE ||= Dir.mktmpdir("hive-test-wtbase")` in `test_helper.rb` and cleans it via `Minitest.after_run`, so worktree-creating tests no longer leak `hive-test<...>.worktrees` dirs into the developer's real `~/Dev` (1402 had accumulated). Extended `rake test:clean_tmp` to also sweep the legacy `~/Dev/hive-test*.worktrees` leak (the `hive-test` prefix cannot match the production `~/Dev/hive.worktrees`).

**Refreshed pages:**
- [[modules/worktree]]

## [2026-06-08T12:02:43Z] config/patrol — add patrol.mode and patrol token attribution

**Action:** Added the `patrol.mode` frequency dial (`ultrapatrol`, `high`, `medium`, `low`, `off`) and documented that `Config.load` resolves it on raw YAML before defaults merge so explicit granular scheduler keys still win. Fresh `hive init` now prompts for the mode, writes only `patrol.mode` for scheduling, and includes `patrol_mode` in the init JSON contract. Patrol reviewer/fixer agent wrappers now record usage rows tagged `patrol-review` / `patrol-fix`, and token usage aggregation exposes a scoped `patrol` attribution bucket rendered in the TUI token matrix.

**Refreshed pages:**
- [[modules/config]]
- [[commands/init]]
- [[modules/patrol]]
- [[token-usage]]

## [2026-06-08T12:00:00Z] tui — scrollable help overlay

**Action:** Updated the TUI help overlay so the `?` screen is height-bounded, word-wraps binding descriptions, and scrolls instead of overflowing the alt-screen on short terminals. Help now keeps a fixed footer, renders a right-edge scrollbar when content overflows, re-clamps its offset on resize, and shows a centered "terminal too small" fallback below 10x40. Keyboard scrolling uses Up/Down, `j`/`k`, PgUp/PgDn, Home/End, and `g`/`G`; mouse wheel events scroll help by three lines after enabling Bubbletea mouse cell reporting. Explicit close keys are `q`, `Esc`, and `?`; unrelated keys no-op instead of dismissing.

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-08T12:00:00Z] daemon/agent — auto-retry limits_reached tasks after a cooldown

**Action:** Tasks parked because a reviewer/agent hit a usage/credit limit stayed red until a human ran `hive markers clear`, even after the usage window reset. The `StaleAgentHealer` only admitted `review_agent_died` and the tmux-death subset of `reviewer_partial_failure`; `limits_reached` was never auto-recoverable. Added a cooldown-based self-heal: `Hive::AgentLimit` now owns `RETRY_COOLDOWN_SEC` (default 3600s = 1h, overridable via `HIVE_LIMITS_RETRY_COOLDOWN_SEC`) and `retry_after(now:)`. Every `limits_reached` marker writer stamps `retry_after = now + cooldown` at write time — `Stages::Review` (reviewers `REVIEW_ERROR`, only the limit branch; `all_failed` stays manual), `ClaudeLauncher#limits_reached_marker`, and `Agent#handle_exit`. The healer threads the tick's frozen `now` into `auto_recoverable_review_error?` / `auto_recoverable_error?` and clears a `limits_reached` marker only once `now >= Time.parse(retry_after)`; a missing/unparseable stamp stays manual (legacy markers). The cooldown gate is evaluated before the retry-budget increment, so cooldown-wait ticks do not consume budget — a persistently-limited task still gets up to the bounded number of cooldown-spaced clears (default 3) before staying red. Heals log `reason=limits_reached` (terminal) / `reason=reviewer_limits_reached` (review) to distinguish them from tmux-death retries; exhausted-budget remediation hints point at topping up credits / `hive markers clear`. The provider's wall-clock reset hint is deliberately not parsed (noted as a future enhancement in gaps). Added unit tests for the cooldown helpers, all marker writers' `retry_after` stamp, and both healer paths (before/at/after cooldown, missing/unparseable stamp, budget bound, waits-don't-burn-budget). Full coverage gate: 100% lines.

**Refreshed pages:**
- [[daemon]]
- [[agent]]
- [[state-model]]

## [2026-06-08T12:00:00Z] hivebox — rebase web command coverage onto current wiki model

**Action:** Resolved PR #300's Hivebox web documentation onto the current wiki model. Kept the single OpenClaw `hive-cli` umbrella-skill policy, registered [[commands/web]] alongside the newer [[commands/wiki]] page, and recorded `hive web`/hivebox in the wiki index instead of reviving the obsolete per-command OpenClaw skill list.

**Refreshed pages:**
- [[index]]
- [[log]]

## [2026-06-08T11:54:15Z] wiki — audit daemon display-name backfill TTL coverage

**Action:** Refreshed LLM wiki planning/documentation coverage after commit `a0b0ca3b` bounded `Hive::Daemon::DisplayNameBackfiller` inflight entries and expanded unit coverage. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "daemon display name backfill generate-name meta.yml"` returned no indexed hits, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/daemon/display_name_backfiller.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/logger.rb`, `test/unit/daemon/display_name_backfiller_test.rb`, `test/unit/daemon/dispatcher_test.rb`, and related display-name/task-identity wiki pages.

**Action:** Updated [[modules/daemon]], [[commands/daemon]], and [[commands/generate-name]] so the durable docs describe the new `{pid, at}` inflight shape, `MAX_INFLIGHT_AGE_SEC = 120` retry unpinning behavior, and `:fatal` logging for unexpected backfiller failures. Updated [[gaps]] to carry the new test-pinned reliability coverage while keeping the live-smoke uncertainty open: no in-tree artifact yet proves a real daemon backfilled an existing blank `meta.yml` name and surfaced it through status/TUI/bot. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/daemon]]
- [[commands/daemon]]
- [[commands/generate-name]]
- [[gaps]]

## [2026-06-08T11:51:13Z] wiki — audit bot draft-confirm residue cleanup

**Action:** Refreshed command/API and handler wiki coverage after commit `c680ac29` removed dead Telegram bot confirm/draft residue left behind by the Codex draft-assist retirement. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "CodexConversation confirm draft residue conversation_store path_a bot codex draft assist"` returned no indexed hits, and the configured master wiki path had no relevant draft-assist context. Inspected the committed diff plus current `lib/hive/bot/conversation_store.rb`, `lib/hive/bot/router.rb`, `lib/hive/bot/handlers/free_text_handler.rb`, `lib/hive/bot/handlers/callback_handlers.rb`, `lib/hive/bot/handlers/slash_handlers.rb`, and focused bot tests.

Documented that `ConversationStore::State` now carries only the active answer context (`chat_id`, `project`, `slug`, `question_n`, `mode`, `updated_at`), with no `history`, `draft`, `awaiting_confirm`, or `pending_confirm_count` API; that `/done` clears and dispatches the active conversation directly with no draft-confirm guard; that Path A/B is compatibility-only and both modes route through `write_answer_then_reply`; and that legacy Path-A buttons degrade to the deterministic `/answer` instructions while retired `codex_*` callback data remains unknown. Carried forward the live-smoke uncertainty for old Telegram buttons, live `:path_a` answer writes, and installed `hive-bot-log.v2` consumers. Page coverage count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bot]]
- [[modules/bot]]
- [[state-model]]
- [[gaps]]

## [2026-06-08T11:39:52Z] tui — refresh immediately when task lock changes

**Action:** Fixed a TUI stale-status window where a task could keep rendering as `Needs your input` after its answered row had already been picked up by a live runner. Root cause: `Hive::Tui::StateSource` cached status snapshots by registry/stage/state-file mtimes but did not include each task's `.lock`; a runner can acquire that lock before `AGENT_WORKING` is written, and `Hive::TaskAction` intentionally classifies a live lock as `agent_running`. The fingerprint now watches `<task>/.lock` so lock creation, update, and removal force an immediate status reparse. Added StateSource coverage for lock appearance, disappearance, and mtime updates.

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-08T11:34:30Z] wiki — audit daemon display-name backfill coverage

**Action:** Refreshed LLM wiki planning/documentation coverage after commit `9516efb1` added `Hive::Daemon::DisplayNameBackfiller` and already touched [[commands/daemon]], [[modules/daemon]], and a daemon feature log fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "daemon display name backfill generate-name task display_name"` found existing task-identity coverage in [[state-model]] and prior [[log]] entries, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/daemon/display_name_backfiller.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/logger.rb`, focused daemon tests, and related display-name wiki pages.

**Action:** Updated task-identity documentation so [[state-model]], [[stages/inbox]], [[commands/new]], and [[commands/generate-name]] no longer imply missing display names are recovered only by the initial best-effort spawn, manual `hive generate-name`, or `hive migrate`; the daemon now retries blank sidecars cosmetically by spawning `hive generate-name <folder>` on later ticks. Refreshed [[commands/daemon]] and [[modules/daemon]] metadata for the new daemon module coverage, and recorded in [[gaps]] that the backfill path is unit-pinned but lacks an in-tree live daemon smoke artifact. Page count stayed 75, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/daemon]]
- [[modules/daemon]]
- [[state-model]]
- [[stages/inbox]]
- [[commands/new]]
- [[commands/generate-name]]
- [[gaps]]

## [2026-06-08T12:00:00Z] daemon — DisplayNameBackfiller inflight TTL + reap error logging

**Action:** Hardened `Hive::Daemon::DisplayNameBackfiller` reliability (PR #411 review follow-up). `@inflight` entries now store `{pid:, at:}` instead of a bare pid, and `reap_inflight(now)` evicts an entry when its child is gone (the existing `kill(0)`/ESRCH/EPERM liveness semantics are unchanged) **or** when it has outlived the new `MAX_INFLIGHT_AGE_SEC = 120` TTL (≈2× generate-name's 60s timeout). The TTL fixes a P1 bug: after the child was reaped, a reused pid could keep reporting "alive" (same-user `kill(0)` succeeds; foreign-user EPERM is also treated alive), permanently pinning the folder's inflight slot and disabling backfill for that folder until daemon restart. The TTL is threaded from `backfill(now:)` → `consider_row` → `backfill_row`, so live children within a single tick (age 0) are unaffected.

**Action:** The `reap_inflight` block-level `rescue StandardError` no longer swallows unexpected errors silently — it logs a `:fatal` event (`display_name_backfiller reap raised: ...`) before returning false (entry retained), matching the file's other rescues. Backfill still never raises.

**Action:** Brought `display_name_backfiller.rb` to 100% line coverage (was 84.72%, failing the strict coverage gate) and covered the dispatcher's backfiller `:fatal` rescue (dispatcher.rb line 239) by adding unit tests for: dead-pid reap (ESRCH), foreign-pid retention (EPERM), TTL eviction, reap-error logging, the outer `#backfill` rescue, unreadable-meta handling, injected-spawn raise, the real `Process.spawn` failure path, and the waiter-thread ECHILD rescue. See [[modules/daemon]].

## [2026-06-08T11:30:50Z] daemon — self-heal tasks left without a display_name

**Action:** Added `Hive::Daemon::DisplayNameBackfiller`, a tick-time self-healer that closes the gap where a task whose one-shot name generation failed at `hive new` (typically an agent/codex outage or rate-limit) is left showing its raw slug forever — name generation today is a fire-and-forget spawn at `hive new` with no retry. On each tick the dispatcher now drives the backfiller over the status rows right after `StaleAgentHealer`, wrapped in the same `begin/rescue StandardError` that logs `:fatal ... keeping_previous: true` so a backfiller bug can never crash the tick. For any row whose `Hive::TaskMeta.read(folder)[:display_name]` is nil/blank and that is not already inflight, it re-spawns `hive generate-name <folder>` using the exact detached, pgroup, log-to-`state_home/logs/display-name.log`, fully-rescued fire-and-forget pattern from `Hive::Commands::New#spawn_name_generator`. The change is purely additive: it never touches markers, dispatch, or existing heal logic. Anti-churn is by construction — a set name is a natural fixed point (the next status read no longer flags it), an `@inflight` map (folder => pid, reaped by `Process.kill(0, pid)` liveness rather than a `wait` that would race new.rb's detached waiter thread) blocks double-spawns while a child runs, and `max_per_tick` (default 2) drains a post-outage backlog over several ticks instead of fork-bombing; a failed attempt simply leaves the name unset and is retried on a later tick with no backoff beyond the tick interval. The backfiller is constructed at both dispatcher sites where `StaleAgentHealer` is built (boot + SIGHUP reload) carrying the `dry_run` flag, and `display_name_backfill` was added to the closed `Hive::Daemon::Logger` event enum.

**Tests:** Added `test/unit/daemon/display_name_backfiller_test.rb` (spawns only for missing/blank names, respects `max_per_tick`, never re-spawns an inflight folder, dry-run logs without spawning, nil-pid spawn is retried not tracked, blank/exploding-folder rows degrade to a no-op) and a dispatcher wiring test asserting a tick drives the backfiller and emits `display_name_backfill` without a `:fatal`. Verified `test/unit/daemon/display_name_backfiller_test.rb`, `dispatcher_test.rb`, `stale_agent_healer_test.rb`, and `logger_test.rb` green; rubocop clean on all changed files.

**Refreshed pages:**
- [[modules/daemon]]
- [[commands/daemon]]

## [2026-06-08T10:59:08Z] wiki — audit retired bot Codex draft-assist coverage

**Action:** Refreshed command/API, handler, config, schema, template, and executable-entrypoint wiki coverage after commit `723906be` retired the Telegram bot's Codex draft-assist flow. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "bot codex draft assist path a answer log schema"` found only older generic bot command context, and the configured master wiki path had no matching draft-assist context. Inspected the committed diff plus current `lib/hive/bot/router.rb`, `lib/hive/bot/handlers/callback_handlers.rb`, `lib/hive/bot/handlers/free_text_handler.rb`, `lib/hive/bot/logger.rb`, `lib/hive/config.rb`, `schemas/hive-bot-log.v2.json`, `templates/hive_config.yml.erb`, and focused bot/config/logger tests.

Confirmed the committed [[architecture]], [[commands/bot]], [[modules/bot]], [[state-model]], and [[templates]] updates match the current code: brainstorm answering is deterministic for Path A and Path B, `Hive::Bot::CodexConversation` and its prompt template are gone, retired `codex_*` callback-data no longer parses to a live intent, the bot config no longer exposes Codex budget/timeout knobs, and `hive-bot-log.v2` removes the three Codex events while preserving `hive-bot-log.v1` for historical lines. Added [[gaps]] coverage for the remaining uncertainty: source-tree tests pin the behavior, but no in-tree live Telegram artifact proves old Path-A buttons, retired Codex callback-data, deterministic live `:path_a` answer writes, or installed log consumers against `hive-bot-log.v2`. Page coverage count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands/bot]]
- [[modules/bot]]
- [[state-model]]
- [[templates]]
- [[gaps]]
- [[log]]

## [2026-06-08T10:47:25Z] bot — retire Codex draft-assist feature

**Action:** Removed the Telegram bot's "Codex draft-assist" flow (the Path-A mobile-brainstorm path where the bot spawned Codex to draft an answer to a brainstorm question, offering write-draft / edit / cancel buttons). Brainstorm answering is now deterministic Q-by-Q for every conversation mode: the operator's reply is written verbatim into the next unanswered `brainstorm.md` slot and the bot sends the next question.

Specifically:
- Deleted `lib/hive/bot/codex_conversation.rb` (`Hive::Bot::CodexConversation`) and its prompt template `templates/bot_brainstorm_codex_prompt.md.erb`.
- Bumped `Hive::Bot::Logger::SCHEMA_VERSION` 1 → 2 and dropped the `codex_spawned` / `codex_succeeded` / `codex_failed` events from `EVENTS`.
- Added `schemas/hive-bot-log.v2.json` (event enum minus the three codex_* events, `schema_version` const 2). `schemas/hive-bot-log.v1.json` is kept as-is for historical log lines.
- Removed the `codex_budget_usd` / `codex_timeout_sec` bot defaults and their `BOT_NUMERIC_BOUNDS` entries from `lib/hive/config.rb`, and the matching commented lines in `templates/hive_config.yml.erb`.
- Removed the `callback_codex_write_draft` / `callback_codex_edit` / `callback_codex_cancel` intents, the `codex_write:` / `codex_edit:` / `codex_cancel:` callback parsing, and the `start_codex` / `confirm_codex_draft` allowed-actions from `lib/hive/bot/router.rb`. Retired callback-data now classifies as `:unknown`.
- Dropped the three codex callbacks from the legacy retirement-notice branch in `lib/hive/bot/handlers/callback_handlers.rb` (the Path-A `path_a_yes` / `path_a_just_type` legacy fallback is kept and still returns the "Codex draft flow was removed" steer).
- Removed the `action: :start_codex` branch from `lib/hive/bot/handlers/free_text_handler.rb`; a `:path_a` conversation now falls through to the same deterministic `write_answer_then_reply` path as `:path_b`.

**Kept (correctness guardrail):** The `"Answer mode started for <slug>."` reply-reattach matcher in `router.rb` and `free_text_handler.rb` is part of the GENERAL answer-mode reply flow — it lets a free-text reply to an old bot message reattach to that slug's brainstorm answer flow (`mode: :path_b`) and is independent of Codex. The text is not Codex-specific and is not sent by any removed code path, so it was retained.

**Tests:** Deleted `test/unit/bot/codex_conversation_test.rb`. Updated `callback_handlers_test.rb`, `router_test.rb`, `supervisor_test.rb`, `config_test.rb`, `spawn_agent_test.rb`, `logger_test.rb` (now validates against `hive-bot-log.v2.json` and asserts `schema_version == 2`), and eval support `reason_classifier.rb` / `harness.rb` — removed draft-assist intents/fixtures/config while preserving coverage for everything that remains. Suite green.

**Refreshed pages:**
- [[architecture]]
- [[state-model]]
- [[templates]]
- [[modules/bot]]
- [[commands/bot]]

## [2026-06-08T10:15:00Z] config — document daemon.max_concurrent_patrol_scans

**Action:** `wiki/modules/config.md` did not mention `daemon.max_concurrent_patrol_scans` even though the setting is live on `main` (`Config::DEFAULTS` daemon block = 1, validated `>= 1`, enforced by `Hive::Daemon::ConcurrencyController` as a `:patrol_scan_cap` separate from task-dispatch slots). Added a grounded sentence to the notable-defaults prose: daemon-scheduled `hive patrol PROJECT` scans run on their own in-flight budget so a long codex-backed scan never consumes a `daemon.max_concurrent_runs` task slot (scans tagged `kind: :patrol_scan`, excluded from the per-project/global caps).

**Refreshed pages:**
- [[modules/config]]

## [2026-06-08T00:00:00Z] agent/review — surface usage-limit as limits_reached, not generic failure

**Action:** Patrol/review tasks were landing in a red `reason=all_failed` (and agents in generic `exit_code=1`) when the underlying CLI had actually hit a usage/credit limit. Root cause: codex reports the limit as a structured `{"type":"error","message":"…you've hit your usage limit…"}` / `turn.failed` JSON stream event, which `MessageExtractor` does not surface as a final message, so the limit text never reached `Agent#handle_exit` (which only scanned `final_message`). Fix: `Agent#spawn_and_wait` now scans every raw stream line via `Hive::AgentLimit` and captures `result[:limit_text]`; `limit_error_message` prefers it. In `Stages::Review.run_reviewers`, per-reviewer error messages are collected and an all-failed phase whose failures are limit errors returns `:all_failed_limit`, landing a `REVIEW_ERROR reason=limits_reached message="all reviewers hit a usage/credit limit"` marker instead of `reason=all_failed`. Added agent unit tests (limit_text path + end-to-end structured-error capture) and a run_reviewers `:all_failed_limit` test.

**Refreshed pages:**
- [[testing]]

## [2026-06-07T19:26:14Z] daemon — archive merged finalize error rows

**Action:** Updated finalize merge recovery so already-merged PRs no longer stay red solely because their stale local worktree cannot pass finalize's pre-push Git checks. `Hive::Daemon::Dispatcher` now hands whitelisted `8-finalize` `ERROR` rows (`git_status_failed`, `claude_launch_failed`) to `PrMergeWatcher`; after `gh pr view` reports `MERGED`, the watcher dispatches `hive archive` with an internal `--recover-merged-error-reason` flag. `Hive::Commands::StageAction` accepts that archive only when the current marker is `ERROR`, its `reason=` exactly matches the flag, and the `pr.md` URL still reports `MERGED`, preserving the normal manual path for open PRs and mismatched errors.

**Coverage:** Added focused tests for merge-watcher command generation, unknown-reason filtering, dispatcher routing of `git_status_failed` finalize rows, and archive-stage acceptance/rejection of matching, mismatched, and still-open merged-error recovery reasons. Refreshed [[modules/daemon]] and [[testing]]. Did not run `qmd update` or `qmd embed`.

## [2026-06-07T20:00:00Z] daemon — tighten terminal agent-loss retry review fixes

**Action:** Fixed the terminal agent-loss exhausted-budget remediation to emit a runnable
`hive run <slug> --project <project> --stage <stage>` command, expanded unit coverage to
the full late-stage/reason allowlist matrix, and pinned negative coverage for the same
reasons outside late stages.

**Files:**
- `lib/hive/daemon/stale_agent_healer.rb`
- `test/unit/daemon/stale_agent_healer_test.rb`

**Impact:** Agents can use the logged manual fallback when retry budget is exhausted, and
future changes are guarded against broadening terminal agent-loss auto-retry beyond
`7-artifacts`/`8-finalize`.

## [2026-06-07T18:55:00Z] daemon — retry late-stage terminal agent-loss errors

**Action:** Extended `Hive::Daemon::StaleAgentHealer` so late-stage terminal agent-loss errors are recovered by the normal daemon flow instead of staying red after ordinary interruptions. `7-artifacts` and `8-finalize` rows with `ERROR reason=tmux_session_terminated` or `ERROR reason=agent_orphaned` now clear when no live task lock exists, using the same marker-id guard, pre-clear dispatch-baseline seeding, bounded per-process retry budget, and one-shot `marker_heal_exhausted` logging used by finalize `ERROR reason=unpushed_commits`. The healer logs these retries as `reason=terminal_agent_loss`, keeps the original marker reason in `marker_reason`, and leaves repository-state/manual failures such as `ERROR reason=git_status_failed` red for operator inspection. Added focused tests for artifacts tmux-session loss, finalize orphaned-agent loss, marker-id races, live-lock skips, git-status manual skips, and retry-budget exhaustion, then refreshed daemon, artifacts, finalize, testing, and gaps docs.

**Tests:**
- `bundle exec ruby -Itest test/unit/daemon/stale_agent_healer_test.rb`

**Refreshed pages:**
- [[modules/daemon]]
- [[stages/artifacts]]
- [[stages/finalize]]
- [[testing]]
- [[gaps]]

## [2026-06-07T18:49:17Z] wiki — audit late-stage terminal agent-loss retry coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `0dde0c69` extended `Hive::Daemon::StaleAgentHealer` and already touched daemon, artifacts, finalize, testing, gaps, and log pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "stale agent healer terminal agent loss retry artifacts finalize tmux_session_terminated agent_orphaned"` surfaced existing daemon/log coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/stages/artifacts.rb`, `lib/hive/stages/finalize.rb`, `lib/hive/stages/base.rb`, `lib/hive/claude_launcher.rb`, `lib/hive/markers.rb`, and focused stale-healer/status tests. Confirmed the committed page updates were source-synced, then refreshed cross-reference pages that still implied all daemon `error` rows are manual skips: [[cli]], [[commands/daemon]], [[stages/index]], and [[state-model]]. Refined [[gaps]] to record that the new late-stage terminal agent-loss retry path remains unit-pinned only; no live or integration artifact proves the full status -> healer clear -> redispatch loop for artifacts/finalize tmux loss. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands/daemon]]
- [[stages/index]]
- [[state-model]]
- [[gaps]]

## [2026-06-07T17:00:00Z] review fix-pass 03 — finalize healer doc/observability polish

**Action:** Applied 6-review pass-03 findings to `Hive::Daemon::StaleAgentHealer`, its logger, tests, and [[modules/daemon]]. Dropped the unreferenced `MARKER_ERROR_REASONS`/`HEAL_LOG_LABELS` constants; unified the heal event attempt-count key to plural `attempts:` across `marker_healed` and `marker_heal_exhausted`; derived the review-path `marker_heal_failed` reason label from the row (so a `review_agent_died` failure is no longer mislabeled as the tmux-death channel); and made `observe_pre_clear_mtime` emit a new `marker_heal_observer_missing` debug event instead of silently no-op'ing when a controller lacks the method. Tightened the class doc: removed the inaccurate "auth" cause of the unpushed-commits marker (auth raises before the push gate), reordered the finalize re-run checks to "auth, clean-exit, push" to match `finalize.rb#run!`, softened the limit wording to "configured limit (default 3)", and noted the intentional asymmetry with `review_error_signature`. Extended the exhausted-event comment to call out the SIGHUP-reload reset of the `seen` dedup maps. Reverted the manual `wiki/log.md` edits (fragments already exist in `wiki/log.d/`). Added focused tests: status-JSON error-row marker_id contract, observer-missing logging, and exhausted-event one-shot suppression across 3+ heal passes; the redispatch integration test now derives its `action` from the real status pipeline.

**Refreshed pages:**
- [[modules/daemon]]

## [2026-06-07T16:13:56Z] wiki — audit entrypoint help rewrite coverage fragment

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after this branch changed `bin/hive` and `bin/hive-e2e` help rewriting. Read `AGENTS.md`, `.llm-wiki/config.json`, [[cli]], [[commands]], [[e2e]], [[testing]], and [[gaps]] first; `qmd search "bin hive-e2e --version command-local help wrapper"` returned no local hits, while the configured master wiki search surfaced the existing Hive CLI/e2e/testing pages. Inspected the rebased diff and current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, and `test/e2e/lib/hive_e2e_binary_test.rb`. Confirmed existing [[cli]], [[commands]], [[e2e]], [[testing]], and [[gaps]] coverage matches the code: command-local help now preserves any leading wrapper options before the subcommand, rewrites to `help <cmd>`, and drops command arguments after the subcommand so option-bearing requests such as `hive approve --from 2-brainstorm --help` and `bin/hive-e2e run --filter tui --help` print usage instead of running partial command validation. [[gaps]] records the remaining uncertainty that the packaged `hive` executable has not been release-install-smoked for this path; `bin/hive-e2e` remains checkout-only. Page coverage did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[e2e]]
- [[testing]]
- [[gaps]]

## [2026-06-07T16:08:13Z] babysitter — fix detached restart process identity

**Action:** Live-smoked a stale babysitter after the current checkout and reproduced that `hive babysit restart --detach` could leave the long-lived process running under the `restart --detach` argv. Later restarts then waited on that process instead of quickly replacing it. Updated `Hive::Commands::Babysit#restart_daemon` so detached restart stops the old process and re-execs the canonical `hive babysit start --detach` command before daemonizing, preserving the PID-file/startup invariant. Kept the long 600-second stop drain because an active babysitter tick can be inside a synchronous PR repair agent; review pass 1 caught that shortening the drain would orphan child agents and temporary worktrees. The same review found that stop could suppress KILL after ownership became unverified yet still delete the PID file and print success, so stop now leaves the PID file and warns when the process may still be alive; KILL escalation is also explicit in stderr. Review pass 2 found that restart could still continue after such a refused stop and that detached re-exec should use the installed stable wrapper rather than raw process argv. Restart now aborts when stop leaves a live PID, direct `stop` exits non-zero in the same refused-stop paths, and detached re-exec resolves the command through `Hive::InvokedBinary.path`. Later review passes found narrow races where a process could exit during initial or post-grace ownership probes; stop now re-checks liveness around those probes and treats a now-dead PID as a clean stale cleanup instead of requiring manual intervention. The final cleanup review found that successful stop cleanup could remove a replacement PID file created by a concurrent `start`; reservation and cleanup now share a bounded sidecar lock and cleanup removes only when the file still matches the payload being stopped, while the detached re-exec call is direct/auditable. Added unit regressions for detached restart re-exec, no-dry-run argv, re-exec failure reporting, unresolved wrapper errors, restart abort after refused stop, direct stop failure on refused stop, ownership-probe clean exits including the pre-KILL recheck, replacement PID-file preservation, lock-acquire timeout, KILL-success cleanup, and skip-KILL PID-file preservation, then refreshed babysitter command/module/testing docs plus the stale-runtime gap.

**Tests:**
- `bundle exec ruby -Itest test/unit/commands/babysit_test.rb`
- `bundle exec ruby -Itest test/unit/babysitter/coverage_gaps_test.rb`
- `bundle exec rubocop lib/hive/commands/babysit.rb test/unit/commands/babysit_test.rb test/unit/babysitter/coverage_gaps_test.rb`

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

## [2026-06-07T16:00:00Z] review fix-pass — finalize unpushed healer hardening

**Action:** Applied 6-review findings to `Hive::Daemon::StaleAgentHealer` and its tests. Collapsed duplicated marker reason helpers into one `marker_reason(row)`, extracted the review-path heal-label ternary into `review_heal_label`, and documented the intentional silent no-op when `clear_current` returns false (no event, no retry budget consumed). Added a dispatcher-level integration test proving finalize re-dispatches (not `:record_baseline`) after the unpushed-commits clear via the seeded pre-clear mtime, plus unit tests for clear-false-no-budget, duplicate rows in one heal pass, and per-process budget reset on a fresh healer instance. Strengthened existing assertions with explicit non-default mtime, `Markers.current.none?`, and `refute marker_heal_failed` on negative skips. Noted in [[modules/daemon]] that the recovery budget is in-memory and resets on restart/SIGHUP reload.

**Refreshed pages:**
- [[modules/daemon]]

## [2026-06-07T15:52:00Z] daemon — expose exhausted marker-heal budgets

**Action:** Added `marker_heal_exhausted` as a one-shot daemon log event when bounded marker auto-recovery gives up. The event now carries `budget_scope=per_process`, `suggested_next_action=manual_fix`, and a remediation hint so operators know the budget refills after daemon restart/SIGHUP and can recover manually. Strengthened finalize unpushed recovery tests for fresh marker-id retries, per-task budget isolation, race-shaped no-id marker guards, duplicate rows in one heal pass, and pre-clear baseline redispatch.

**Tests:** Verified `test/unit/daemon/stale_agent_healer_test.rb`, `test/integration/daemon_stale_agent_healing_test.rb`, and `test/unit/daemon/logger_test.rb`.

**Refreshed pages:**
- [[modules/daemon]]
- [[stages/finalize]]
- [[testing]]

## [2026-06-07T15:05:00Z] daemon — auto-heal interrupted finalize push leftovers

**Action:** Extended `Hive::Daemon::StaleAgentHealer` so `8-finalize` rows with `ERROR reason=unpushed_commits` and no live task lock are automatically cleared with a bounded per-process retry budget. The clear uses the observed `marker_id` when present, falling back to legacy no-id markers only, so a stale status row cannot erase a newer same-reason error marker. After a successful clear, the healer seeds the controller's edit-resume baseline with the pre-clear state-file mtime; the next status read sees the marker-clear rewrite as newer than that baseline and dispatches finalize after the normal debounce instead of first-sight `record_baseline` stranding the row. The retry does not push directly inside the healer; it lets the normal daemon dispatch rerun finalize, preserving the existing clean-exit scope check, residue auto-commit path, GitHub auth check, and push validation. Manual-only finalize errors such as `ensure_clean_on_exit_failed` remain red for operator inspection, and repeated push failures stay red after the budget is exhausted.

**Tests:** Added focused unit coverage for unpushed finalize auto-recovery, live-lock skip, non-finalize skip, manual clean-exit skip, retry-budget exhaustion, and marker-clear failure logging. Verified `test/unit/daemon/stale_agent_healer_test.rb`, `test/unit/task_action_test.rb`, and `test/integration/run_finalize_test.rb`.

**Refreshed pages:**
- [[modules/daemon]]
- [[stages/finalize]]
- [[testing]]

## [2026-06-07T14:41:00Z] docs - add public Discord link to README

**Action:** Added the public Hive Discord invite from Ivan's Hive announcement post to the top of the GitHub README, verified the invite redirects through `discord.com/invite/Qg5E7rMt` with HTTP 200, and recorded the canonical community URL in [[operating]]. No command/API behavior changed.

**Refreshed pages:**
- [[operating]]

## [2026-06-07T14:17:52Z] wiki — audit finalize unpushed auto-retry coverage

**Action:** Refreshed wiki planning/documentation coverage after the finalize unpushed auto-retry change updated `Hive::Daemon::StaleAgentHealer`, focused unit tests, and the daemon/finalize/testing wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "finalize unpushed commits stale healer auto retry"` found only existing CLI/log context, and the configured master wiki path had no relevant Hive context. Inspected the committed diff and current `lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/stages/finalize.rb`, `lib/hive/gh.rb`, `lib/hive/task_action.rb`, `test/unit/daemon/stale_agent_healer_test.rb`, `test/integration/daemon_stale_agent_healing_test.rb`, and `test/integration/run_finalize_test.rb`. The existing [[modules/daemon]] and [[stages/finalize]] updates were source-synced; refreshed [[testing]] to include the existing status-to-healer integration test, and recorded missing live-daemon retry evidence in [[gaps]]. Page count stayed 74, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[gaps]]

## [2026-06-07T12:50:58Z] wiki — refresh OpenClaw wiki-command coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `b47231e8` extended the OpenClaw `/hive` skill and focused tests for the `hive wiki compile-log` surface. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "openclaw hive wiki compile-log fragments slash command"` and the configured master wiki path produced no relevant prior guidance. Verified the committed diff plus current `openclaw/skills/hive/SKILL.md`, `openclaw/README.md`, `lib/hive/commands/wiki.rb`, `lib/hive/wiki_log.rb`, `test/integration/wiki_command_test.rb`, `test/unit/openclaw_skills_test.rb`, [[commands/wiki]], [[commands]], [[operating]], and [[testing]]. Updated wiki command coverage for the OpenClaw `/hive wiki compile-log --check` path, the fragment-first policy, legacy-entry/template-prose behavior, focused command/OpenClaw tests, the representative OpenClaw source map, and the remaining lack of a live OpenClaw invocation artifact. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/wiki]]
- [[commands]]
- [[operating]]
- [[testing]]
- [[gaps]]

## [2026-06-05T22:15:00Z] wiki — fragment-based changelog compilation

**Action:** Added `hive wiki compile-log`, `Hive::WikiLog`, and the `wiki/log.d/*.md` fragment flow so concurrent PRs can record wiki updates without all editing the hot `wiki/log.md` tail. Updated managed llm-wiki bootstrap prompts/context, checked-in AGENTS/CLAUDE guidance, and the current generated `.llm-wiki/*.sh` scripts to ask agents for fragments instead of direct compiled-log edits in feature PRs, initialized new projects with `wiki/log.d/.gitkeep`, documented the command, and added compiler/CLI/init coverage. Review follow-ups tightened legacy-body extraction so fresh wiki template prose is not preserved as a bogus changelog entry and added the OpenClaw `/wiki` skill surface for the new Thor command.

**Refreshed pages:**
- [[commands/wiki]]
- [[index]]
- [[testing]]
<!-- END GENERATED WIKI LOG FRAGMENTS -->

## [2026-06-07T13:24:34Z] wiki - audit babysitter dry-run env hardening coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `a8774462` changed `bin/hive-babysitter-stub-git`, `test/unit/babysitter/dry_run_env_test.rb`, and existing babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run git stub env var config injection"` found the current babysitter docs and prior refresh history, while the configured master collection had no relevant hit. Inspected the committed diff plus `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `lib/hive/cli.rb`, and focused dry-run tests. Updated [[commands/babysit]] to describe option screening as scoped to each CLI's honored option regions, refreshed [[testing]] metadata, and tied the remaining live-agent dry-run smoke gap to `a8774462`. Page coverage count stayed 74, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[testing]]
- [[gaps]]
- [[log]]

## [2026-06-07T13:20:50Z] babysitter - rebase dry-run git env hardening onto stale-runtime main

**Action:** Resolved PR #316 onto current `main` after the stale-runtime babysitter docs landed. Kept the `hive babysit restart` / stale detached-runtime documentation from [[commands/babysit]] and [[modules/babysitter]], while preserving the PR's final dry-run `git` hardening: fail-closed skips for known exec-capable git env seams, default-deny `GIT_CONFIG_COUNT` parsing, scoped `grep` pager and `ls-files -o` read-option handling, pathspec separator handling, and invalid real-git diagnostics. Refreshed [[testing]] and [[gaps]] to match the focused regression surface.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
- [[log]]
## [2026-06-07T10:55:00Z] wiki - refresh stale babysitter runtime command surface

**Action:** Refreshed command/API surface coverage after commit `dc0f540f` (`fix(babysitter): detect stale runtime`) changed `lib/hive/cli.rb`, `lib/hive/commands/babysit.rb`, `test/unit/commands/babysit_test.rb`, and existing babysitter wiki notes. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "command API surface routes handlers README entrypoint"` surfaced prior command/API refresh context, and the configured master wiki path had only generic route/command guidance. Verified the committed diff plus current `lib/hive/cli.rb`, `lib/hive/commands/babysit.rb`, `test/unit/commands/babysit_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[cli]], and [[operating]]. Documented the new `hive babysit restart` lifecycle subcommand, the boundary that `reload` refreshes config/log settings but not loaded Ruby source, the source-mtime stale-process recommendation printed by `status`, and the remaining lack of a live detached-process stale-runtime smoke artifact. Page coverage count stayed 74, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[cli]]
- [[operating]]
- [[gaps]]
- [[log]]

## [2026-06-07T10:45:00Z] wiki - refresh OpenClaw command/API coverage after ClawHub listing copy commit

**Action:** Refreshed command/API surface coverage after commit `704b9705` (`docs(openclaw): improve ClawHub skill listing`) changed README/OpenClaw documentation, `openclaw/skills/hive/SKILL.md`, `test/unit/openclaw_skills_test.rb`, and existing wiki pages. Read `AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; also read `.llm-wiki/config.json`. `qmd search "command API surface routes handlers entrypoints README"` returned existing OpenClaw and release-context hits. Verified the committed diff plus `README.md`, `openclaw/README.md`, `openclaw/skills/hive/SKILL.md`, `test/unit/openclaw_skills_test.rb`, [[operating]], [[cli]], and [[commands]]. The commit does not add Ruby routes, HTTP handlers, Thor command handlers, or executable entrypoints; the changed public surface is the OpenClaw/ClawHub wrapper over the existing CLI.

**Coverage:** Expanded [[commands]] so it covers `bin/hv`, the single ClawHub `hive-cli` listing, `/hive` slash-command dispatch, guided setup aliases, safe argument passing, JSON preference, and destructive/foreground confirmation rules. Updated [[operating]] source metadata and OpenClaw operating text for the public listing URL and checked-in skill version `0.1.1`. Recorded in [[gaps]] that `clawhub inspect` evidence is logged but the explicit `clawhub scan --slug hive-cli --version 0.1.1 --json` command did not return a durable checked-in artifact. No page count change, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands]]
- [[operating]]
- [[gaps]]
- [[log]]

## [2026-06-07T10:37:00Z] openclaw - improve ClawHub listing copy

**Action:** Checked live ClawHub examples and confirmed the public detail page uses `SKILL.md` frontmatter `description` as the hero/search/OpenGraph summary, then renders the opening markdown body under the `SKILL.md` tab. Updated Hive's single `hive-cli` ClawHub skill to version `0.1.1` with a more specific summary for the folder-based coding-agent pipeline, added a visible install/common-path section before the agent runtime rules, kept the single `/hive` umbrella model, and refreshed README/OpenClaw docs plus [[index]] and [[operating]]. Published `hive-cli@0.1.1` under `ivankuznetsov`; `clawhub inspect hive-cli --json` now reports `latest: 0.1.1` and the new summary. The explicit `clawhub scan --slug hive-cli --version 0.1.1 --json` command submitted but hung without returning; the registry inspect moderation fields still report `verdict: clean`, `isSuspicious: false`, and `isMalwareBlocked: false`.

**Tests:** `bundle exec ruby -Itest test/unit/openclaw_skills_test.rb`; `bundle exec rubocop --format simple test/unit/openclaw_skills_test.rb`; YAML frontmatter parse check; `git diff --check`.

**Refreshed pages:**
- [[index]]
- [[operating]]
- [[log]]

## [2026-06-06T19:12:04Z] bot - tighten audio answer coverage docs

**Action:** Followed up the audio-answer E2E work after the CI coverage gate exposed unhit voice edge branches. Added focused coverage for legacy answer-prompt reattach, unmatched voice replies, no-project voice confirm, missing voice file IDs, payload/download failures, disabled answer transcription, no-speech/unsupported/failed audio answers, failed idea transcription with an existing non-voice draft, default transcriber client setup, and malformed transcription language entries. Refreshed stale [[commands/bot]] and [[modules/bot]] metadata/TLDR so the bot overview mentions transcribed voice answers. The earlier PR #332 wiki lookup used `qmd search "telegram voice e2e audio answers bot"` and found no relevant project guidance; no new page coverage was needed. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bot]]
- [[modules/bot]]
- [[log]]

## [2026-06-06T19:07:48Z] bot - cover audio ideas and audio answers in live E2E

**Action:** Added voice-answer coverage to the Telegram voice-note branch. The router now routes voice notes sent during active or reattached `/answer` conversations to `transcribe_voice` with answer context; `Supervisor#execute_transcribe_voice` writes successful answer transcripts through the existing brainstorm answer writer instead of creating an idea draft. Extended `test/e2e/tg/run_idea_e2e.sh` so `TG_IDEA_MODE=voice` drives both a new audio idea and a seeded audio `/answer` path with the checked-in voice fixture. Added focused router, supervisor, and in-process bot scenario coverage. Refreshed [[commands/bot]], [[modules/bot]], [[testing]], and [[gaps]].

**Refreshed pages:**
- [[commands/bot]]
- [[modules/bot]]
- [[testing]]
- [[gaps]]

## [2026-06-06T06:58:00Z] bot - apply transcription reload review fixes

**Action:** Addressed pass-2 review findings on the voice-note branch. `Supervisor#reload_config_if_requested` now rebuilds `Hive::Bot::Transcriber` from the reloaded `bot.transcription` config so endpoint/model/retry/language settings apply on `hive bot reload`; the `:ok` transcription path now logs and replies if the draft disappears before transcript storage instead of sending a dead Confirm button. Added focused coverage for reload rebuild, unsupported-language hint wording, failed-fallback staging cleanup, secondary post-`getFile` size guard, malformed `no_speech_prob`, and transcription config validation branches. Refreshed [[modules/bot]] reload behavior.

**Refreshed pages:**
- [[modules/bot]]

## [2026-06-06T06:45:00Z] bot - hard-fail missing voice E2E secret

**Action:** Resolved the pass-2 voice E2E review escalation by making explicit `TG_IDEA_MODE=voice` fail when `HIVE_WHISPER_API_KEY` is unset instead of reporting a green skip. Updated the shell wrapper message, the voice fixture README, and [[testing]] so the documented contract matches the driver.

**Refreshed pages:**
- [[testing]]

## [2026-06-06T06:31:00Z] bot - voice fixture and draft-preservation review fix

**Action:** Addressed 6-review pass-2 voice findings on the Telegram voice-note idea branch. Added the checked-in `test/fixtures/voice/voice-idea.oga` Ogg/Opus speech sample used by the secret-gated voice E2E, and documented it in [[testing]]. Guarded `Router`/`Supervisor` so a bare voice note sent while a non-voice idea draft is open replies with an explicit finish/discard prompt and preserves the existing draft instead of clearing it through `IdeaDraftStore#start`. Refreshed [[modules/bot]] and narrowed [[gaps]] to the remaining live Telegram/OpenAI smoke evidence.

**Refreshed pages:**
- [[modules/bot]]
- [[testing]]
- [[gaps]]

## [2026-06-06T00:00:00Z] review - voice-transcription fix pass ([[commands/bot]])

**Action:** Applied 6-review auto-fix findings on the voice-note idea-capture branch. Code: normalized the Whisper language gate so full-name `language` output ("english"/"russian") matches ISO-code `supported_languages` ("en"/"ru") — the default config previously rejected every real voice note; derived `Transcriber::DEFAULT_CONFIG` from `Hive::Config::DEFAULTS["bot"]["transcription"]` (single source of truth); dropped Faraday `:raise_error` so the 4xx-vs-5xx handling runs in production as tested; narrowed the broad `rescue StandardError` to transport/parse errors so programmer bugs surface; added a `Transcriber::Result` STATUSES guard and `IdeaDraftStore` PHASES/ORIGINS validation; gated voice-draft reuse/clear on `origin == :voice` (data-loss fix); split the supervisor download-vs-staging rescue with accurate messages + chat_id-tagged failure logging; derived the unsupported-language hint from config; guarded oversize on the payload size before the getFile round-trip; extracted shared `IdeaKeyboards` (transcript/confirm/project helpers). Docs: corrected the `/idea` voice flow ordering (picker appears only after `Confirm`) and added the OpenAI-vs-OpenRouter (plan Q1) rationale. Added the checked-in `test/fixtures/voice/voice-idea.oga` speech fixture and made the voice E2E fail (not skip) when the Whisper secret is set but the fixture is absent.

## [2026-06-05T22:04:03Z] wiki — refresh pass 02 patrol/archive/tui coverage

**Action:** Refreshed wiki coverage after commit `217459fe` (`fix(review): apply pass 02 findings`). Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "patrol review handoff archive filter tui format"` only surfaced the prior related log entry, so verification used the committed diff plus direct source reads. Checked `lib/hive/patrol/review_handoff.rb`, `lib/hive/archive_filter.rb`, `lib/hive/tui/snapshot.rb`, `lib/hive/tui/views/archive_pane.rb`, `lib/hive/tui/views/format.rb`, and focused unit tests. Documented patrol handoff's sparse-finding normalization, archive filtering's nil-timestamp fail-open behavior, Archive-pane display-cell alignment, and the expanded unit-test edge cases. No page coverage changed, and no new uncertainty was found beyond existing patrol/archive live-smoke gaps. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/patrol]]
- [[commands/status]]
- [[commands/tui]]
- [[testing]]

## [2026-06-05T22:00:24Z] wiki — audit residual handoff/format coverage commit

**Action:** Audited commit `8d3c93ce` after it committed residual wiki changes from 6-review. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "patrol command bin hv tui executable fallback"` found prior testing/gaps/log context. Verified the committed wiki diff plus the `HEAD` versions of `lib/hive/patrol/review_handoff.rb`, `lib/hive/patrol/pr_opener.rb`, `lib/hive/tui/views/projects_pane.rb`, `lib/hive/tui/views/format.rb`, `test/unit/patrol/review_handoff_test.rb`, and `test/unit/tui/views/format_test.rb`. Confirmed [[modules/patrol]], [[commands/tui]], [[state-model]], and [[testing]] are source-synced for patrol `idea.md` provenance, nil/sparse evidence formatting, project-pane display-cell padding, and focused unit coverage. Page coverage did not change and no new uncertainty was found beyond existing [[gaps]] patrol live-smoke coverage; did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[log]]

## [2026-06-05T21:54:00Z] patrol/tui — refresh handoff evidence and cell-format coverage

**Action:** Refreshed command/API wiki coverage after commit `b8d4c157` tightened patrol review handoff rendering and TUI project-row formatting. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "patrol review handoff idea_text evidence TUI Format ljust_cells"` had no indexed hits for this exact cleanup. Verified the committed diff plus current `lib/hive/patrol/review_handoff.rb`, `lib/hive/tui/views/projects_pane.rb`, `lib/hive/tui/views/format.rb`, `test/unit/patrol/review_handoff_test.rb`, `test/unit/tui/views/format_test.rb`, [[commands/patrol]], [[modules/patrol]], [[commands/tui]], [[state-model]], and [[testing]]. Documented the intentional `idea.md` body/`original_text` duplication for patrol tasks, nil-evidence handling, project-pane display-cell padding, and focused unit coverage. No new page coverage or new uncertainty was found; did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/patrol]]
- [[commands/tui]]
- [[state-model]]
- [[testing]]

## [2026-06-05T21:41:29Z] wiki - post-commit audit of `hv` documentation refresh

**Action:** Audited commit `dba72bbd` after it refreshed wiki coverage for the RubyGem `hv` executable fix. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "RubyGem hv executable install wrapper"` found the updated operating-page context. Verified the committed wiki diff plus commit `02591fbb`, current `hive.gemspec`, `install.sh`, `bin/hv`, Homebrew/AUR packaging templates, `test/unit/gemspec_test.rb`, `test/unit/install_script_test.rb`, `test/unit/hv_test.rb`, [[cli]], [[operating]], [[testing]], and the existing [[gaps]] channel-smoke entry. Confirmed the pages are source-synced and page coverage did not change; no new uncertainty was found beyond the already-recorded missing published-channel smoke evidence. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[log]]

## [2026-06-05T21:10:00Z] wiki - audit RubyGem `hv` executable coverage

**Action:** Audited commit `02591fbb` after it fixed the broken RubyGems `hv` executable surface. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "patrol command bin hv fallback command bin"` found prior `hv`/testing/gaps context. Verified the committed diff plus current `hive.gemspec`, `install.sh`, `bin/hv`, Homebrew/AUR packaging templates, `test/unit/gemspec_test.rb`, `test/unit/install_script_test.rb`, [[cli]], [[operating]], and [[testing]]. Clarified that the bash installer always writes its internal `hv` wrapper and only conditionally exposes it in the user bin directory, and recorded the missing published-channel smoke evidence. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[operating]]
- [[gaps]]

## [2026-06-06T20:24:46Z] openclaw — publish as one ClawHub skill

**Action:** Corrected the OpenClaw publishing model after live ClawHub preflight showed that installing one skill folder is the right user surface. Hive now documents and tests a single ClawHub listing, `hive-cli`, whose installed `SKILL.md` still exposes `/hive`; all workflows are invoked as `/hive ...` arguments rather than separate shortcut listings. Deleted the accidental `ivankuznetsov` ClawHub shortcut listings `hive-accept-finding`, `hive-archive`, `hive-artifacts`, and `hive-babysit`; `hive-bot` never published because ClawHub rejected it at the new-skill rate limit. Refreshed the README, OpenClaw README, [[index]], [[operating]], and [[gaps]] so future publication uses only `clawhub skill publish openclaw/skills/hive --slug hive-cli`.

**Refreshed pages:**
- [[index]]
- [[operating]]
- [[gaps]]

## [2026-06-05T20:52:02Z] release/install - remove `hv` from RubyGem executables

**Action:** Fixed the RubyGem executable surface so `hive.gemspec` advertises only the Ruby `hive` entrypoint, not the bash `bin/hv` launcher that RubyGems would wrap in an unusable Ruby binstub. Adjusted `install.sh` so it no longer moves a gem-installed `hv` shim before writing its own working `hv` wrapper. Added focused assertions in `gemspec_test.rb` and `install_script_test.rb`; verified an isolated `gem build` + `gem install` creates `bin/hive` and no `bin/hv`. Refreshed `[[cli]]`, `[[operating]]`, and `[[testing]]` to document that channel installers own `hv` creation.

**Refreshed pages:**
- [[cli]]
- [[operating]]
- [[testing]]

## [2026-06-05T17:35:00Z] daemon/review - heal wedged review locks and Claude prompt-footer readiness

**Action:** Added daemon recovery for `REVIEW_WORKING` rows whose recorded Claude child has died while the Ruby review parent still holds `.lock` but has no child processes. `StatusConsumer::Row` now carries marker attrs; `StaleAgentHealer` logs `reason=review_agent_died` with `phase`/`pass`, clears the stale `REVIEW_WORKING` marker, terminates the wedged holder, and deletes the lock so the daemon sees the row as ready and retries review instead of counting it as `Agent running` until wall-clock expiry. The healer only takes this path when child inspection succeeds and returns empty; live children or failed inspection are left alone. Also fixed the Claude tmux readiness detector for the observed patrol failure where the captured tail omitted the `Claude Code` banner but showed the live prompt footer (`PR #316 ... for agents`), causing `pr-review-toolkit` to time out while Claude was idle. Added focused unit coverage for both paths.
## [2026-06-06T12:12:34Z] agents - normalize legacy Compound Engineering invocations

**Action:** Double-checked the installed Compound Engineering plugin metadata (`compound-engineering` v3.11.1): the CE workflows are still exposed as bare `/ce-*` skills such as `/ce-code-review`; the official `/code-review` command is a separate PR-comment workflow and does not satisfy Hive's reviewer-file contract. Updated Hive defaults, templates, and docs to emit `/ce-brainstorm`, `/ce-code-review`, `/ce-commit-push-pr`, and `/ce-test-browser` forms. Added `AgentProfile#format_skill_invocation` compatibility normalization so existing `compound-engineering:ce-*` config values still render to current CE syntax for Claude/Codex and `/skill:ce-*` for Pi.

**Refreshed pages:**
- [[modules/agent_profile]]
- [[stages/brainstorm]]
- [[stages/open-pr]]
- [[stages/review]]
- [[commands/doctor]]

## [2026-06-05T15:00:00Z] review - fix partial-failure regression + operator breadcrumbs (PR #313 review)

**Action:** Addressed `/pr-review-toolkit:review-pr` findings on PR #313. **Critical:** `pass_completion_status` returned `:triage_incomplete` whenever `errors-NN.md` existed, checked *before* the fix-success resolution — so a pass that hit a partial reviewer failure but still triaged + fixed surviving findings would re-run reviewers on re-entry and clobber the operator's `[x]` marks. Reordered so a fresh `fix-success-NN.md` keeps the pass `:complete` regardless of a lingering `errors-NN.md`; the errors-driven retry now fires only while the fix is incomplete. **Minor:** moved the `reviewer_partial_failure` CLI next-action from the now-dead `REVIEW_WAITING` branch to `REVIEW_ERROR` (JSON + human paths), so an operator is pointed at `reviews/errors-NN.md` (resolving the [[gaps]] note about the stale legacy branch); and branched the bot cause sentence so a partial failure reads "some reviewers failed; coverage is incomplete" instead of "the review agent crashed". Added regression tests (`pass_completion_status` errors-after-fix, the migrated `REVIEW_ERROR` next-action, the partial-failure cause sentence). 100% line coverage, rubocop clean.

## [2026-06-05T14:07:35Z] review/wiki - audit partial reviewer failure recovery coverage

**Action:** Refreshed wiki coverage after commit `55a5cf4c` (`fix(review): treat partial reviewer failures as recovery`). Read AGENTS.md, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search` found only prior changelog context in the hive collection and no master hits. Verified the committed diff plus `lib/hive/stages/review.rb`, `test/integration/run_review_test.rb`, current `lib/hive/commands/run.rb`, and relevant review/marker/run wiki pages. Added the missing [[state-model]] coverage that pass-local `reviews/errors-NN.md` now classifies a pass as `:triage_incomplete`, so marker-clear recovery reruns reviewers and clears stale errors at reviewer-run start. Recorded the unresolved legacy `REVIEW_WAITING reason=reviewer_partial_failure` JSON branch/test in [[gaps]]. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[state-model]]
- [[gaps]]

## [2026-06-05T13:30:00Z] review - classify partial reviewer failure as recovery

**Action:** Changed mixed reviewer success/failure with no findings from `REVIEW_WAITING reason=reviewer_partial_failure` to `REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure`. This keeps the safety invariant that partial reviewer coverage must not auto-complete, but classifies the task as recoverable review infrastructure failure instead of user input. Status diagnostics already include `reviews/errors-NN.md`, so retry/autofix flows can clear `REVIEW_ERROR` and rerun reviewers.

**Refreshed pages:**
- [[stages/review]]
- [[commands/run]]
- [[modules/markers]]

## [2026-06-07T11:05:00Z] babysitter - detect stale detached runtime

**Action:** Diagnosed a live babysitter process that had been running since 2026-06-03 and was still rejecting `patrol.trigger: continuous`, even though current `main` accepts and documents that trigger. Added `hive babysit restart`, made `hive babysit status` recommend restart when the PID-file `started_at` predates the current Hive source checkout, and made `hive babysit reload` warn that SIGHUP only reloads config/log settings, not Ruby code. Updated [[modules/babysitter]] with the operational rule.

## [2026-06-05T13:30:00Z] patrol - make `continuous` the default trigger

**Action:** Flipped the default `patrol.trigger` from `new_commits` to `continuous` so patrol keeps mining existing feature slices on the `poll_interval_sec` timer (in addition to default-branch SHA changes) out of the box. Changed `Config::DEFAULTS["patrol"]["trigger"]`, the `PatrolScheduler#due?` fetch fallback, the init template (`templates/project_config.yml.erb`, with an inline mode comment), and the `config_test` default assertion. Refreshed [[commands/patrol]], [[modules/patrol]], and `docs/cli.md` to mark `continuous` as the default. `new_commits` / `timer` remain opt-in.

**Refreshed pages:**
- [[commands/patrol]]
- [[modules/patrol]]

## [2026-06-05T12:57:21Z] patrol/wiki - refresh review-handoff coverage after commit 4d0541d6

**Action:** Refreshed the wiki after commit `4d0541d6` added `Hive::Patrol::ReviewHandoff`, defaulted `patrol.review_prs` to true, and changed `PrOpener` so opened patrol PRs keep their worktree and create synthetic `6-review/patrol-.../` tasks by default. Follow-up hardening documents `review_handoff_failed` retry behavior, `hive patrol --json` `review_handoff_errors`, and YAML-serialized patrol handoff frontmatter. Verified the committed diff and current source/test files, corrected stale PR-only patrol TLDRs, documented the config default/validator, noted the synthetic task/state shape in [[state-model]] and [[stages/review]], refreshed test coverage notes, updated [[index]], and recorded the missing live daemon/TUI smoke evidence in [[gaps]]. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/patrol]]
- [[modules/patrol]]
- [[modules/config]]
- [[state-model]]
- [[stages/review]]
- [[testing]]
- [[gaps]]
- [[index]]

## [2026-06-05T09:45:00Z] patrol - hand opened PRs to 6-review

**Action:** Documented the new `patrol.review_prs` default: successful patrol PRs now keep their validated worktree and create a synthetic `6-review/patrol-.../` task with display name `Patrol: <finding title>`, `task.md`, `worktree.yml`, `pr.md`, and `reviews/`. This routes patrol-created PRs through the standard review/TUI/daemon flow instead of leaving them as PR-only outputs. Projects can set `patrol.review_prs: false` to keep the previous cleanup-only behavior. Updated [[commands/patrol]] and [[modules/patrol]].

## [2026-06-05T09:30:00Z] patrol - continuous hybrid trigger

**Action:** Added and documented `patrol.trigger: continuous`, a hybrid daemon scheduling mode that dispatches patrol when either the default branch SHA changed or `poll_interval_sec` elapsed. This keeps large repositories under active patrol between infrequent merges while preserving the `last_scanned_sha` freshness marker after each successful scan. Updated [[commands/patrol]] and [[modules/patrol]].

## [2026-06-05T09:10:00Z] babysitter - refresh rebased PR-head cache refs

**Action:** Documented the babysitter worktree fix that force-refreshes internal `refs/hive-babysitter/pr-*` cache refs when fetching `pull/<PR>/head`. The refs are Hive-owned cache refs, not user branches, so force-updating them is the correct behavior when a PR branch is rebased or force-pushed; otherwise `git fetch pull/<PR>/head:refs/hive-babysitter/pr-<PR>` can fail with a non-fast-forward reject and leave babysitter unable to inspect that PR. Updated [[modules/babysitter]].

## [2026-06-05T08:42:50Z] bot/wiki - post-commit refresh for PR #281 follow-up coverage

**Action:** Refreshed wiki coverage after commit `26be3aff` (`fix(bot): address PR #281 review — thread-safe ConversationStore + observability`). Read AGENTS.md, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, the committed diff, current bot source/tests, and `schemas/hive-bot-log.v1.json`; also ran `qmd search` for the bot suppression terms and checked the configured master wiki path. Tightened [[modules/bot]]'s `NotificationDispatcher` row so it now documents project+slug active-conversation suppression, lenient nil-project matching, `notification_skipped_active_conversation` logging, and the no-alert-store-entry behavior that lets a still-waiting task re-alert after the conversation ends. [[gaps]] already recorded the remaining uncertainty: no live Telegram bot plus daemon WAITING-flap smoke artifact was found. No page count or catalog coverage changed, so [[index]] did not need a structural update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/bot]]
- [[log]]

## [2026-06-05T01:00:00Z] patrol - similarity dedup so re-found findings don't re-open PRs

**Action:** Fixed patrol re-opening the same PRs every scan. The exact fingerprint (`[feature_id, category, path, snippet]` SHA) is agent-volatile — the review agent re-files the same issue with a different feature attribution, title, and snippet each run, so the SHA never matches a prior PR and the finding is re-opened forever (observed: #284/#290/#303 and #288/#303/#304 were all the same "dry-run gh implicit-POST" issue with different fingerprints). Added a similarity gate: `Fingerprint.record_seen` now stores the finding's `category` + normalized `title_tokens`; `Fingerprint.similar_known?` skips a new finding whose same-category title-token overlap (Szymkiewicz–Simpson) ≥ `SIMILARITY_THRESHOLD` (0.6) with an open/merged/dismissed finding; `commands/patrol.rb#skip_reason` returns `similar_to_existing`; the `Dismissals` reconciler carries the content into dismissed entries. Documented in [[modules/patrol]]. 100% line coverage, rubocop clean.
## [2026-06-05T00:00:00Z] bot - suppress daemon-auto-approved 3-plan pauses (+ fix label)

**Action:** Fixed a spurious-notification bug: a 3-plan `waiting` marker is a plan-draft/approval pause that the daemon's `PlanApproval` auto-approves when `daemon.enabled`, but the bot's status poll raced the daemon and pinged the operator with an unactionable "questions waiting" alert (mislabelled "Brainstorm questions"). Added `NotificationDispatcher#suppress_daemon_plan_pause?` — suppresses `needs_input` + stage `3-plan` + marker `waiting` rows when the daemon is enabled (logging `notification_skipped_daemon_plan_pause`, added to the bot Logger enum + `hive-bot-log.v1.json`), mirroring `suppress_ready_action?`. Also split `NotificationBuilders#needs_input` so a 3-plan `waiting` renders "Plan draft is ready for your review" (daemon-off case) instead of the brainstorm "Answer in chat" text. 100% line coverage, rubocop clean.
## [2026-06-05T02:00:00Z] review - tmux reviewer resilience + room for 1-2h reviewers

**Action:** Fixed `6-review` getting stuck at `reviewer_partial_failure`. The claude-tmux reviewers run sequentially in ONE shared tmux session; when reviewer #1 exhausted its fair-share deadline (or its claude crashed), the shared session closed and every later reviewer failed with "session no longer exists" — cascading the whole pass into `reviewer_partial_failure`, which auto-triage (rightly) won't auto-advance. Three changes:

- **Recover the dead session** (`ClaudeLauncher`): `with_shared_session` exposes a `reestablish` closure on the `SessionHandle`; `send_prompt_and_wait!` self-heals via `reestablish_dead_session!` — a reviewer that finds the session gone restarts claude and proceeds instead of cascade-failing.
- **Stop the deadline squeeze** (`Stages::Review#reviewer_deadline`): each reviewer now gets the FULL remaining wall-clock budget (its own `timeout_sec` is the real per-reviewer cap), not `remaining / specs_remaining`. The even split killed thorough 1-2h reviewers mid-run.
- **Room for long reviews**: `Reviewers::Agent::DEFAULT_TIMEOUT_SEC` 3600→7200 (2h), `review.max_wall_clock_sec` default 5400→14400 (4h), and the init template's reviewer `timeout_sec` 3600→7200.

100% line coverage, rubocop clean.
## [2026-06-05T00:00:01Z] tui - document residual idle cost of liveness fallback (6-review pass 2)

**Action:** Updated [[commands/tui]] latency section to call out, against the plan's "near-zero idle CPU" AC, that `LIVENESS_REPARSE_FALLBACK_SECONDS` (3s) re-incurs a full `json_payload` + `Dir.glob` fingerprint rebuild ~20×/min even when mtimes are unchanged — an accepted correctness tradeoff that never causes a redraw thanks to the snapshot dedup in `App.start_snapshot_poller`.

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-05T23:20:00Z] tui — seed first snapshot before Bubbletea loop

**Action:** Investigated slow `hive tui` startup. `hive status --json` and
`StateSource` were fast in isolation, but a PTY probe showed the background
`StateSource#refresh_once` entering before the first frame and then being
starved by the Bubbletea render/input loop, leaving the UI on the loading grid.
Added synchronous `StateSource#refresh_now` and seeded the initial TUI model with
that snapshot before starting the runner. Local PTY first useful paint improved
to about 0.24s and the smoke tests now assert seeded projects appear without a
multi-second loading grid (a generous 5s regression bound, not a benchmark).

**Verified:**
- `bundle exec ruby -Itest test/unit/tui/state_source_test.rb test/integration/tui_smoke_test.rb test/integration/tui_smoke_charm_test.rb`
- `bundle exec rubocop --format simple lib/hive/tui/app.rb lib/hive/tui/state_source.rb test/unit/tui/state_source_test.rb test/integration/tui_smoke_test.rb test/integration/tui_smoke_charm_test.rb`

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-05T22:12:41Z] wiki — audit TUI startup seed coverage

**Action:** Audited commit `570beeba` after it added synchronous
`StateSource#refresh_now` startup seeding for `hive tui`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]]
entries first; `qmd search "StateSource refresh_now TUI startup seed first
useful paint"` returned no indexed hits, and the configured master wiki path had
no matching TUI startup note. Inspected the committed diff and current
`lib/hive/tui/app.rb`, `lib/hive/tui/state_source.rb`, TUI PTY smoke tests, and
the existing Charm API solution note. Confirmed [[commands/tui]] already covered
the boot-time synchronous refresh and updated the test-coverage documentation so
the new state-source startup seed and first-useful-paint PTY assertion are not
missing from the wiki. No page count or catalog coverage changed, so [[index]]
did not need a structural update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[commands/tui]]
- [[log]]

## [2026-06-05T00:00:00Z] tui/daemon - latency-reduction review fixes (6-review pass 1)

**Action:** Applied accepted `/ce-code-review` findings on the TUI/daemon latency-reduction work:

- **TUI mtime gate** (`Hive::Tui::StateSource`): the cached-snapshot gate could mask state indefinitely because the fingerprint only watches file mtimes. Added `LIVENESS_REPARSE_FALLBACK_SECONDS` (3s) time-bounded fallback so liveness-derived fields (`live_task_lock`, `claude_pid_alive`) that flip without touching a file still self-heal, and added the global project registry (`Hive::Config.global_config_path`) to the fingerprint so `hive init`/`forget` changes reflect within the latency budget.
- **Daemon run loop**: gated `version_drift_detected?` (which hashes the schema file via `Digest::SHA256.file`) behind `full_tick_due?` so the hash runs at the ~30s poll cadence instead of every ~1s fast probe (Unit 2 cheap-only intent).
- **`refresh_tracked_state_file_mtimes`**: dropped the `|| row.state_file_mtime` fallback so an absent tracked file stores `nil` consistently, avoiding a perpetual full-tick loop from `nil != <Time>` comparisons.
- Added clarifying comments documenting the benign double-`reap_all` on the child-exit path and the expected post-dispatch redundant full tick.

Refreshed [[commands/tui]] and [[modules/daemon]]. Tests + rubocop clean. Did not run `qmd update` or `qmd embed`.

## [2026-06-04T21:30:00Z] patrol - default draft_prs to false (open ready PRs)

**Action:** Flipped `Config::DEFAULTS["patrol"]["draft_prs"]` from `true` to `false` so patrol opens ready (non-draft) PRs by default. Draft PRs are skipped by the babysitter (`labels_ignore: draft` + the GitHub-draft skip from #280), so the previous default left patrol-found fixes piling up as un-mergeable drafts. Per-project `patrol.draft_prs: true` still reverts to drafts. Also flipped the init template + `hive patrol` long_desc to match. Updated `test/unit/config_test.rb` default assertion and the [[commands/patrol]] / [[modules/patrol]] docs. 100% line coverage, rubocop clean.

## [2026-06-03T20:30:00Z] daemon - PR #244 review follow-up #254 (extract QueueCommand)

**Action:** Extracted the read-only queue-inspection surface from `Commands::Daemon` into `Hive::Commands::Daemon::QueueCommand` (`lib/hive/commands/daemon/queue_command.rb`), mirroring the `ServiceInstaller` extraction (#254). `Commands::Daemon#queue_command` now lazily requires and delegates. The extracted `call` folds forward #262's `Hive::InternalError` wrapping (exit 70 on internal failure) so a later rebase onto a main carrying #297 cannot lose it. Branch stacked on `fix/daemon-queue-244-followups-a` (#294) because the moved `queue_prune` already carries #265's `remove_if_unclaimed`; must merge after #294/#295/#297. Documented in [[modules/daemon]]. 100% line coverage, rubocop clean.

## [2026-06-03T20:00:00Z] daemon/bot - PR #244 review follow-ups, batch D (docs + security)

**Action:** Implemented the docs + security cluster of the deferred PR #244 `/ce-code-review` issues:

- **#263** (security) `Supervisor#drain_dispatch_results` now re-checks each notice's `chat_id` against `chat_id_allowlist` before relaying — a chat removed from the allowlist mid-flight, or a notice forged in the 0700 dir, is dropped + removed (logging the new `:dispatch_result_rejected_unauthorized` bot event, added to the logger enum + `hive-bot-log.v1.json`) instead of relayed. Documented in [[modules/bot]].
- **#262** (docs) documented the `hive daemon queue` exit codes in the `daemon` `long_desc` ([[cli]]) and the [[commands/daemon]] exit-codes table: `list`/`prune` → 0; `show` → 0 found / 1 not-found; unknown action or missing REQUEST_ID → 64 (USAGE); internal error → 70 (SOFTWARE). The issue's "70 on internal error" was NOT true of the code — a bare `StandardError` re-raise exited 1 — so `queue_command` now wraps internal failures in `Hive::InternalError` so the exit code matches the `--json` envelope's `error_kind:"internal"`.
- **#266** (docs) documented `child_kill_grace_sec` as a tick-jittered **minimum**, not a precise timer (enforced once per `poll_interval_sec`; `0` ≠ immediate KILL) in the config knob comment and [[modules/daemon]].

100% line coverage, rubocop clean. Did not run `qmd update` or `qmd embed`.
## [2026-06-03T19:30:00Z] daemon - PR #244 review follow-ups, batch C (maintainability)

**Action:** Implemented the maintainability cluster of the deferred PR #244 `/ce-code-review` issues (except #254, which depends on #265 and waits for PR #294 to merge):

- **#251** added `dispatch_result_state_home:` injection + accessor to `Dispatcher`, used by `notify_dispatch_failure` AND `prune_dispatch_results` (both operate on the result queue). Previously they used `dispatch_request_state_home`, so a test sandboxing only the request queue silently wrote/pruned result notices where the bot never looked. Updated the reap/prune tests to inject the result home; added a focused test asserting notices land in the result home, not the request home.
- **#252** dropped both `@supervisor.respond_to?(:enforce_timeouts)` / `respond_to?(:update_timeouts)` seams; added `enforce_timeouts(now:)` to every `FakeSupervisor` (six doubles across unit + integration tests) so the dispatcher can call them unconditionally.
- **#253** extracted `Hive::Daemon::QueueDirectory.directory_for(dirname:, state_home:)` and reused it from both `DispatchRequestQueue#directory` and `DispatchResultQueue#directory`, so the owner-only (0700) invariant lives in one place. Documented in [[modules/daemon]].
## [2026-06-03T19:00:00Z] daemon - PR #244 review follow-ups, batch B (schema & test parity)

**Action:** Implemented the schema/test-parity cluster of the deferred PR #244 `/ce-code-review` issues:

- **#258** `schemas/hive-dispatch-result.v1.json` `chat_id` now machine-checks **non-zero** (`not: {const: 0}`) instead of the issue's literal `minimum: 1` — Telegram group/supergroup/channel chat ids are negative, so `minimum: 1` would wrongly reject a valid group relay target; 0 is the only never-valid id. Documented in [[modules/daemon]].
- **#256** added `hive-dispatch-result` existence + required-key-drift + producer round-trip tests (validating actual `DispatchResultQueue.write!` output with nil `update_id` and a negative group `chat_id`), and a `hive-daemon-queue` producer round-trip (list/show/prune envelopes via `queue_envelope`/`queue_request_hash`) in `schema_files_test.rb`.
- **#257** added the missing `WRONG_SUBCOMMAND_FLAG` case to the enroll error-payload round-trip, plus a guard asserting every `EnrollErrorKind::ALL` member is exercised so a future kind can't slip past again.
- **#260** made `test_recover_dispatch_claims_alive_lambda_paths` deterministic by pinning `Hive::Lock.process_start_time`, so the PID-reuse removal asserts unconditionally instead of being skipped behind `if live` on /proc-less platforms.
- **#261** tightened weak assertions: `test_recover_dispatch_claims_swallows_errors` now asserts the `:fatal` log event (was zero-assert); the aged-claim recovery test pins `reason == "claim_expired"` via the handler; added an AC-05 two-tick test proving a `needs_input` alert fires exactly once while its marker persists (the property that makes the queue path's no-reset safe).
- **#247** added a `schema_files_test` assertion that a `.json.claimed` file still validates against `hive-dispatch-request.v1` (no stray `claim` key) — completing the contract pin deferred from batch A.

100% line coverage, rubocop clean. Did not run `qmd update` or `qmd embed`.
## [2026-06-03T18:30:00Z] daemon - PR #244 review follow-ups, batch A (dispatch-queue correctness)

**Action:** Implemented the correctness/durability cluster of the deferred PR #244 `/ce-code-review` issues and refreshed [[modules/daemon]]:

- **#249** `ChildSupervisor#pgid_for` returns `nil` (not the pid) on `ESRCH`, so the timeout-kill callers' `if pgid` guard short-circuits instead of signaling a possibly-recycled `-pid`.
- **#248** `DispatchRequestQueue.claim` fsyncs the `dispatch_requests/` directory after the `.claimed` rename so the at-most-once commit point is crash-durable (best-effort `fsync_directory`).
- **#250** `recover_claims(alive:)` is now a required kwarg — the old `alive: nil` default silently reaped every non-aged live claim.
- **#259** `parse_data` rejects a single-element `argv` (`length >= 2`), mirroring the schema's `argv minItems: 2`, so `queue list` can't emit a nil verb.
- **#255** the `child_timeout_sec` fetch fallbacks (start, reload, `claim_expiry_sec`) reference `Hive::Config::DEFAULTS.dig("daemon","child_timeout_sec")` instead of a `0` literal (the issue's "7200 default" premise was stale; the real default is `0`/disabled — this is drift-proofing, behavior-preserving).
- **#265** `hive daemon queue prune` uses the new `remove_if_unclaimed`, which skips any id the daemon has since claimed and counts only files actually unlinked — never deleting a live `.claimed`'s recovery state under the lock-free prune race.
- **#264** documented the still-alive-orphan auto-advance window (comment + wiki); re-registration in the controller was rejected to avoid a guaranteed multi-hour stuck slot vs. the narrow, `.lock`-backstopped window.
- **#247** verified by the existing claim test (`refute data.key?("claim")`): the sidecar design already keeps the `.claimed` file schema-valid; the full schema-validation assertion lands in batch B.

100% line coverage, rubocop clean. Did not run `qmd update` or `qmd embed`.
## [2026-06-03T14:54:56Z] babysitter - narrow dry-run git remote passthrough

**Action:** Tightened `bin/hive-babysitter-stub-git` so `git remote` is no longer blanket read-only in babysitter dry-run. The stub now passes only listing, `show [-n]`, and `get-url` forms through to the real git binary; mutating forms such as `remote set-url`, `remote add`, and `remote remove` are skipped and logged. Updated `test/unit/babysitter/dry_run_env_test.rb` to pin both the mutating skips and read-only passthrough examples.

**Refreshed pages:**
- [[commands/babysit]]

## [2026-06-03T14:10:33Z] release/wiki - refresh v0.2.0 release prep coverage

**Action:** Refreshed command/API, executable-entrypoint, install, and dependency wiki coverage after PR #289 prepared `0.2.0`. Read the required wiki pages first, inspected the release-prep diff, and verified the release claims against `lib/hive.rb`, `Gemfile.lock`, `README.md`, `install.md`, `CHANGELOG.md`, `hive.gemspec`, the babysitter dry-run stubs, `Hive::Babysitter::DryRunEnv`, and `test/unit/babysitter/dry_run_env_test.rb`. Updated stale release/install examples from `v0.1.11` to `v0.2.0`, refreshed dependency rows for `sqlite3`, `minitest`, and `rubocop`, clarified that SQLite is limited to token-usage metrics rather than workflow state, and recorded that no in-tree artifact proves published `v0.2.0` channel verification yet. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[operating]]
- [[dependencies]]
- [[active-areas]]
- [[architecture]]
- [[state-model]]
- [[gaps]]

## [2026-06-03T15:05:00Z] babysitter - refresh gh api dry-run payload guard coverage

**Action:** Refreshed command/API and executable-stub wiki coverage after merge commit `fc8e7739` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Verified the committed diff plus the current dry-run wrapper and stub source. Documented that `gh api` calls with payload flags (`-f`, `-F`, `--raw-field`, `--field`, `--input`) are skipped as implicit writes unless the method is explicitly GET, while explicit GET calls can still pass through with query fields. Recorded that the remaining full live-agent `hive babysit --once PROJECT --dry-run` smoke evidence is still absent. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

## [2026-06-03T13:20:00Z] bot/wiki - refresh PR #281 suppress-while-answering follow-up coverage

**Action:** Refreshed bot wiki coverage after the PR #281 follow-up changed `ConversationStore`, `NotificationDispatcher`, `Logger`, `hive-bot-log.v1`, and focused bot tests. Verified the current staged source diff while resolving the wiki rebase conflict. Documented that `ConversationStore` is now mutex-guarded because the Telegram poll thread mutates conversations while the status-poll thread reads/prunes through `active_for_slug?`; that active-conversation suppression is scoped by project+slug with a lenient nil fallback; and that suppression now emits `notification_skipped_active_conversation` in the bot log schema. Preserved the unrelated babysitter wiki entries from the other side of the conflict. No page count changed, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/bot]]
- [[gaps]]
- [[log]]

## [2026-06-03T13:00:00Z] fix — PR #281 ce-code-review: thread-safe ConversationStore + suppression observability

**Action:** Addressed the `/ce-code-review` findings on PR #281 (the waiting-alert suppression):

- **Thread safety:** `ConversationStore` is now read from the status-poll thread (`active_for_slug?`, which prunes) while mutated from the Telegram poll thread (`start`/`update`/`clear`). Added a `Mutex` guarding every `@states` access, mirroring `AlertStore`/`ChildSupervisor`, with a lock-free `prune_locked` body to avoid re-entrancy.
- **Observability:** `suppress_active_conversation?` now logs `:notification_skipped_active_conversation`, registered in the bot Logger enum and `hive-bot-log.v1.json`, matching the other `:notification_skipped_*` events.
- **Correctness:** `NotificationDispatcher` uses `Hive::Schemas::TaskActionKind::NEEDS_INPUT` instead of a magic string and scopes suppression by `(project, slug)`. `ConversationStore` refuses cross-suppression only when both projects are known and different; project-less/unresolved conversations still suppress to avoid a silent regression.
- **Tests:** Coverage includes the multi-tick re-fire lifecycle, suppressed rows leaving no dedup entry, logged suppression, `review_waiting`, nil/empty store, partial expiry across chats, project scoping, and concurrent access.

**Pages:** [[modules/bot]]
## [2026-06-03T11:05:00Z] babysitter - skip draft PRs explicitly

**Action:** Fixed the babysitter PR selector so GitHub draft PRs are skipped before worktree materialization and agent spawn. The prior label filter treated `draft` as a label, but GitHub exposes draft state as `isDraft`; live babysitter activity showed draft PR #278 being selected despite `labels_ignore: [draft]`. Added the `draft_pr` skipped event outcome and focused ProjectTick coverage.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]

## [2026-06-03T10:48:47Z] babysitter - refresh dry-run stub API coverage

**Action:** Refreshed wiki command/API surface coverage after commit `889b0b65` changed the babysitter dry-run `git` and `gh` stub executables from mutating-command blocklists to read-only allowlists. Verified the committed diff and current source for `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `lib/hive/babysitter/gh_ops.rb`, and `test/unit/babysitter/dry_run_env_test.rb`. Expanded the `hive babysit --dry-run` docs with the exact current pass-through surface, refreshed babysitter module metadata, and recorded the remaining live-agent dry-run smoke uncertainty. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[gaps]]

## [2026-06-03T10:45:00Z] babysitter - harden dry-run stub command classification

**Action:** Tightened the babysitter dry-run PATH stubs so unknown `git` / `gh` commands are skipped by default and only known read-only commands pass through to the real binaries. This closes the patrol-discovered gap where commands like `gh pr ready`, `gh pr create`, `gh pr close`, `gh workflow run`, `gh api -X POST`, `git commit`, or `git merge` could mutate state despite dry-run. Added direct stub coverage with recording fake binaries for global-option stripping, mutating-command skips, unknown-command skips, and read-only passthrough.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]

## [2026-06-03T11:00:19Z] bot/wiki - refresh waiting-alert suppression coverage after commit 0d9bf875

**Action:** Post-commit wiki refresh for `0d9bf875` (`fix(bot): suppress "questions waiting" push while operator is answering`). Read AGENTS.md, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, the committed diff, and the relevant bot source/tests. Verified that `ConversationStore#active_for_slug?` is prune-aware, `NotificationDispatcher#suppress_active_conversation?` only gates `needs_input` rows, `Supervisor` injects the same store during startup and SIGHUP reload, and tests cover same-slug suppression plus recovery non-suppression. Expanded [[modules/bot]]'s `ConversationStore` row so the active-slug helper is documented outside the long dispatcher row. Recorded the remaining uncertainty in [[gaps]]: no live Telegram smoke artifact was found for the mid-answer flap scenario. No page count changed, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/bot]]
- [[gaps]]
- [[log]]

## [2026-06-03T10:02:12Z] release - correct prepared version to 0.1.11

**Action:** Corrected the prepared release metadata from `0.2.0` to `0.1.11` to match Hive's micro-release versioning convention. Updated `Hive::VERSION`, the lockfile package version, current installer URLs, the newest changelog section, and active release/install wiki references.

**Refreshed pages:**
- [[operating]]
- [[active-areas]]

## [2026-06-03T03:35:00Z] patrol - rebase wiki coverage onto 0.2.0 main

**Action:** Rebased the draft patrol feature onto current `main` after the babysitter/daemon/release merge batch. Added catalog entries for [[commands/patrol]] and [[modules/patrol]] while preserving the current 0.2.0 release, babysitter, daemon queue, and bot dispatch-result wiki coverage.

**Refreshed pages:**
- [[index]]
- [[commands/patrol]]
- [[modules/patrol]]

## [2026-06-03T02:45:00Z] release/wiki - refresh 0.2.0 install surface coverage

**Action:** Refreshed wiki command/API surface coverage after commit `7bafcfa1` prepared `0.2.0`. Verified the committed diff (`README.md`, `install.md`, `lib/hive.rb`, `Gemfile.lock`, `CHANGELOG.md`) and the relevant install/update source files. Updated operating and active-area release coverage from stale v0.1.0-era wording to the current v0.2.0 public channels, recorded that AUR/Homebrew are now live surfaces, and narrowed release gaps to tag-trust hardening, macOS x86_64 install support, and external skill/ClawHub publication evidence. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[operating]]
- [[gaps]]
- [[active-areas]]
- [[index]]

## [2026-06-03T02:20:04Z] release - prepare 0.2.0 after merge batch

**Action:** Prepared the next minor release after the merge batch that added the experimental babysitter PR repair daemon, OpenClaw skill bundle, daemon/bot dispatch hardening, TUI slug-following fix, review/autofix dirty-worktree recovery fixes, and llm-wiki hook environment sanitization. Bumped `Hive::VERSION`, synced the lockfile package version, added a newest-first `CHANGELOG.md` section, and updated pinned installer URLs in `README.md` / `install.md` to `v0.2.0`.

**Tests:** Verified `Hive::VERSION == "0.2.0"`, built `hive-cli-0.2.0.gem` locally, and checked for stale `v0.1.10` installer references outside the historical changelog entry.

## [2026-06-03T02:00:00Z] fix - bot suppresses the "questions waiting" push while the operator is actively answering

**Action:** Fixed the bot re-pushing the proactive "Brainstorm questions are waiting / Tap Answer" alert mid-answer. Root cause: when a brainstorm row briefly flaps out of `WAITING` (e.g. a mid-answer daemon resume re-runs the agent), `NotificationDispatcher#process_recoveries` purges the non-recovery dedup entry immediately (no grace), so the return to `WAITING` re-fires the alert.

- `ConversationStore#active_for_slug?(slug)` - true while any chat has a non-expired answer conversation for the slug (prune-aware).
- `NotificationDispatcher` now takes an injected `conversation_store` and skips `needs_input` (brainstorm/review "waiting") pushes for a slug being actively answered (`suppress_active_conversation?`). The first alert still fires; error/recovery alerts are never gated; an abandoned conversation stops suppressing once it TTL-expires.
- Wired through `Supervisor` (initial build + SIGHUP reload).

The deeper cause (the daemon resuming mid-Q&A) is fixed separately by the answers-pending gate (PR #268).

**Tests:** full suite 4438 runs / 0 failures, 100% line coverage, rubocop clean.

**Pages:** updated [[modules/bot]] (`NotificationDispatcher` suppress-while-answering).

## [2026-06-03T01:35:11Z] babysitter - review follow-up skill and init drift guard

**Action:** Review follow-up for the experimental PR babysitter branch. Added the dedicated OpenClaw `/babysit` skill plus the planned `hive-babysit` ClawHub row so the Thor command drift guard covers the new lifecycle surface. Tightened `Hive::Commands::Init::ProjectConfigBinding` so `babysitter_enabled` and `daemon_autostart` remain required prompt-answer keys instead of silently defaulting in the ERB binding. Added a Brakeman false-positive ignore for `Gh#pr_diff_stat`: `Hive::Gh.capture3` uses `Process.spawn` argv form, and the Git revspec is a single argv element rather than shell input. The CI coverage gate exposed untested babysitter lifecycle/error branches; added focused coverage-gap tests, included `test/babysitter/**/*_test.rb` in the default Rake suite, and fixed `Hive::Babysitter::Logger#event` so a rotation reopen failure that falls back to stderr does not continue into `@file.puts` with a nil file handle.

**Tests:** `test/unit/openclaw_skills_test.rb` now covers the babysit skill; `test/unit/commands/init_test.rb` continues to require every prompt answer key. `test/unit/babysitter/coverage_gaps_test.rb` pins lifecycle, logger fallback, GitHub operation, and coverage-gate branches.

## [2026-06-03T20:00:00Z] tui — cursor follows slug across snapshot polls

**Action:** Upgraded `Update.apply_snapshot_arrived` from coord-based reclamping to **slug-identity following**. The prior reclamp (landed 2026-04-28 in the TUI robustness pass) covered drop/truncate snapshot deltas but missed the in-bounds reorder case: when a peer task advanced a stage between two polls, the cursor's `[project_idx, row_idx]` stayed in bounds while a different slug slid under it, so `s` (steer) and Enter dispatched against the row the operator *was* looking at, not the row they thought they were looking at. The fix captures `prior_slug` from the OLD visible snapshot before adopting the new one, then `cursor_for_slug(visible, slug, prior_project_idx)` looks it up in the NEW visible — prior project preferred (slugs are not globally unique across projects), with a global cross-project scan as the fallback so tasks that migrate project boundaries still keep the cursor pinned. When the slug is gone entirely (archived, finalized, filtered out by scope), the helper returns nil and the call chain falls back to the existing `reclamp_cursor` so coords-only behaviour is preserved for non-followable cursors.

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-03T00:00:00Z] fix — PR #244 queue-claim and recovery-sequence hardening

**Action:** Repaired the PR #244 follow-up branch after rebase onto current `main`. Dispatch-request claims now keep the request JSON schema-valid and store mutable `pid` / `process_start_time` / `claimed_at` fields in a `.claim` sidecar; the daemon preclaims before spawn and releases the claim if spawn fails. Bot recovery sequences now enqueue only the first queue request and persist the retry as a `.sequence` sidecar that the daemon promotes only after the current request exits 0; failed or killed clears discard the retry, and first-request enqueue failures discard the orphan sidecar. Restored `daemon.child_timeout_sec` to `0` by default so existing configs keep historical unbounded children unless operators opt into a cap. Request and claim timestamps now include microseconds. Top-level `hive daemon queue ... --json` argv-shape failures now emit `hive-daemon-queue.v1` (`error_kind=invalid_arguments`) instead of leaking through the enroll schema.

**Tests/docs:** Added focused queue and dispatcher tests for schema-valid claim sidecars, spawn-failure release, sequence promotion/discard, and the default timeout. Updated [[modules/bot]], [[modules/daemon]], and [[commands/daemon]] to match the sidecar and timeout behavior.

## [2026-06-03T00:00:00Z] feat — brainstorm Q&A: create missing answer slots (#269) + surface unanswered count in status (#270)

**Action:** Follow-ups to the PR #268 review, stacked on that branch.

- **#269** — `Hive::Bot::BrainstormAnswerWriter` now **creates** a missing `### A{n}.` slot (at the end of the Q-block, before the next Q/Round/marker boundary, via the parser's canonical `answer_header`) instead of dead-ending with `:answer_slot_missing`. A brainstorm agent that emitted a question without an answer block no longer strands the operator (which, with the daemon's answers-pending gate, held the task indefinitely). `:answer_slot_missing` remains a defensive fallback.
- **#270** — `hive status --json` task rows now carry `unanswered_questions` (count of open `### Q{n}.` slots for a `2-brainstorm` `needs_input` row, computed via the shared `Hive::BrainstormParser`; 0 elsewhere). Additive field, no `SCHEMA_VERSIONS` bump (same policy as `live_task_lock`). Lets a consumer tell a gate-hold from a broken/first-wait task.

**Tests:** full suite passing, 100% line coverage, rubocop clean.

**Pages:** updated [[modules/bot]] (answer-writer slot creation), [[commands/status]] (`unanswered_questions`), [[modules/daemon]] (gate now observable + answerable).

## [2026-05-26T11:02:31Z] decisions — record review fallback auto-commit ADR

**Action:** Added ADR-034 to [[decisions]] documenting the Phase 4 trust-boundary decision where Hive auto-commits successful fix-agent worktree edits, the pre-fix dirty guard, trailer contract, rollback path, and the current signed-commit limitation.

**Refreshed pages:**
- [[decisions]] - records the fallback auto-commit ADR under the current ADR numbering.

## [2026-05-26T22:15:00Z] markers - record tmux-capture embedded-marker mis-read footgun

**Action:** Documented a marker-parsing footgun found while forcing a manual re-review on two writero tasks. `Hive::Markers.current` scans the whole state file and returns the *last* `MARKER_RE` match (and `set` rewrites the last match). In tmux-mode stages `task.md` is a pane capture that includes the stage prompt, which contains literal example markers (e.g. an embedded `<!-- REVIEW_COMPLETE pass=1 browser=skipped -->` in the prompt instructions). When the real trailing marker is removed via the documented hand-edit recovery, `current` falls back to the embedded example and mis-classifies the task, so the daemon advances it instead of re-reviewing and `hive run` short-circuits "already complete". Worked around by appending an authoritative `<!-- EXECUTE_COMPLETE -->` at EOF.

**Refreshed pages:**
- [[gaps]] - added open-question #14 under "Open questions about the codebase".

## [2026-05-26T12:08:56Z] architecture - silent stage rename state drift pattern

**Action:** Added a documented solution for the repeated stage-rename drift class where `Hive::Stages::DIRS` changes but old on-disk task folders remain under legacy stage directories. The note captures the migration-map contract, producer-side `legacy_stage_dirs` warning, and the paired unit/integration test pattern from PR #93.

**Refreshed pages:**
- [[decisions]] - linked ADR-024 to the durable stage-rename drift pattern.

## [2026-06-02T01:00:00Z] fix — PR #268 ce-code-review: harden the brainstorm answers-pending gate

**Action:** Addressed the actionable `/ce-code-review` findings on PR #268:

- **Parse-error hardening (#1):** `Hive::BrainstormParser.parse` is now total — it scrubs invalid UTF-8 and rescues `ENOENT`/`EACCES`/`IOError` → so a torn concurrent read (the bot appends an answer while the daemon parses) or garbled bytes degrade instead of raising. The dispatcher's residual `:fatal` rescue is deduped per `[project, slug]` so a persistently unreadable file can't log every ~30s tick.
- **Fail-open rationale (#2, reconsidered):** the adversarial "fail closed on zero questions" suggestion was **not** adopted — the bot locates questions with the *same* parser, so a zero-parseable-question file can't be answered via the bot anyway; resuming (re-running the agent to regenerate) is the self-healing path and holding would strand. Documented in code + wiki.
- **End-to-end test (#5):** added a `handle_row` test proving the daemon actually *resumes* (spawns) on a parse error, plus dedup, multi-round, no-A-slot, and zero-question tests.
- **Doc:** updated `wiki/modules/bot.md` to describe `Hive::Bot::BrainstormParser` as a back-compat alias.

Deferred to follow-up issues: the "question with no fillable `### A` slot → indefinite hold" strand (bot answer-writer concern) and surfacing an `unanswered_questions` count in `hive status` (schema change).

**Tests:** full suite 4171 runs / 0 failures, 100% line coverage, rubocop clean.

## [2026-06-02T00:00:00Z] fix — daemon holds brainstorm resume until all Q&A answers are in (#267)

**Action:** Fixed the daemon resuming a brainstorm mid-Q&A. The bot writes each Telegram answer to `brainstorm.md` individually (bumping mtime), and the daemon's `needs_input` edit-resume fired ~`edit_debounce_sec` after the **first** answer — re-running `hive brainstorm` with partial answers and grabbing the task `.lock`.

- Relocated the pure parser to `Hive::BrainstormParser` (`lib/hive/brainstorm_parser.rb`); `Hive::Bot::BrainstormParser` is now a back-compat alias so the daemon can share it.
- `Policy.decide` gained `answers_pending:` and a new `:wait_for_answers` outcome — it downgrades only the terminal `:dispatch`, leaving `:record_baseline` / `:skip` / `:wait_for_debounce` intact so the editor-bulk-save path still resumes when complete.
- `Dispatcher#brainstorm_answers_pending?` parses a `2-brainstorm` `needs_input` row's file (fails open on error); the hold is logged `:skipped reason=answers_pending`.

Surface-agnostic (Telegram-incremental or one editor save), and the published `hive-status` schema is untouched.

**Tests:** full suite 4166 runs / 0 failures, 100% line coverage, rubocop clean.

**Pages:** updated [[modules/daemon]] (new "Brainstorm answers-pending gate" section + Policy outcomes) and [[commands/daemon]] (needs_input row behavior).

## [2026-06-02T23:20:00Z] fix(openclaw) - avoid core slash-command collisions and unsafe agent paths

**Action:** Review follow-up for the in-tree OpenClaw skill bundle. Renamed the Hive new/approve shortcuts to `/hive-new` and `/hive-approve` so they do not collide with OpenClaw's built-in `/new` and `/approve` commands, kept already-prefixed skill names from being published as `hive-hive-*`, and strengthened skill instructions for foreground daemon commands, streaming tails, `approve --force`, nested destructive umbrella commands, and `init --json` TTY prompt behavior.

**Refreshed pages:**
- [[gaps]] - OpenClaw publication is still an external maintainer step; the in-tree bundle now documents the collision-safe skill names.

## [2026-06-02T08:13Z] fix — post-review hardening of llm-wiki hook environment sanitization

**Action:** Addressed 4 findings from `/ce-code-review` on PR #245 (managed_hook_content regex too narrow, bash-3.2 empty-array safety in run_without_git_env, thin env-var scrub coverage in tests, missing negative test for unwrapped codex/qmd calls):

1. **Regex broadening**: `managed_hook_content` now detects any terminal `exit …` line (not just `exit 0`), preserving the original exit text. Early-return `exit 0` inside `if/then/fi` is documented as an unsupported pattern.
2. **bash 3.2 safety**: `run_without_git_env` expands `GIT_ENV_UNSET_ARGS` via the null-safe `${arr[@]+"${arr[@]}"}` form in all three locations.
3. **Test coverage**: env-leak integration test now iterates every name from `git rev-parse --local-env-vars` rather than asserting only `GIT_INDEX_FILE`/`GIT_DIR`/`GIT_WORK_TREE`.
4. **Negative test**: new sweep asserts every `codex exec` line in the generated scripts is wrapped by `run_without_git_env`.

**Tests added**: `test_init_places_managed_post_commit_hook_before_terminal_non_zero_exit` plus extensions to `test_llm_wiki_post_commit_refresh_clears_git_hook_environment_for_nested_tools` and the script-content assertion block.

**Pages refreshed**: none (no public-surface changes).

## [2026-06-01T18:31:39Z] fix — sanitize llm-wiki post-commit child Git environment

**Action:** Hardened Hive's managed llm-wiki refresh scripts and active local post-commit hook after a Git hook `GIT_INDEX_FILE` leak let nested agent/plugin Git operations write marketplace index entries into a project worktree index. Generated refresh scripts now collect `git rev-parse --local-env-vars` and run Codex/QMD child processes through `env -u ...`; the runtime hook installer places the managed llm-wiki block before a preserved terminal `exit 0`; and the active Hive hook now delegates only to `.llm-wiki/post-commit-refresh.sh`.

**Tests added:** Integration coverage verifies generated scripts contain Git-env sanitization, preserved hooks with terminal `exit 0` still execute the managed block, and fake Codex/QMD children launched by post-commit refresh do not receive `GIT_INDEX_FILE`, `GIT_DIR`, or `GIT_WORK_TREE`.

**Pages refreshed:**
- [[commands/init]] — documents sanitized nested Codex/QMD calls in generated llm-wiki scripts.

## [2026-06-01T01:00:00Z] fix — PR #244 ce-code-review: ADV-1/C3 hardening

**Action:** Ran `/ce-code-review` on PR #244 (11 reviewers) and fixed the P1 + feature-integrity P2 findings:

1. **#1 (P1)** — `Bot::Supervisor#drain_dispatch_results` removed a notice even when the Telegram relay failed (silent loss). Now removes only after a confirmed send; failures stay on disk for the next reaper tick.
2. **#2 (P1)** — `hive daemon queue` emitted nothing under `--json` on unknown-action / missing-id / internal errors. Added a `hive-daemon-queue.v1` ErrorPayload arm + `queue_usage_error!`/`emit_queue_error_envelope`; all failure paths now emit a structured envelope.
3. **#3 (P2)** — C3 claim rename→unlink window could leave both `<id>.json` and `.claimed` → double-dispatch on restart. `pending` now hides a `.json` whose request_id has a `.claimed` sibling; `recover_claims` removes the orphan `.json` too.
4. **#4 (P2)** — a timeout/signal-killed child has a nil exit_code; the reap guard `exit_code.to_i.zero?` swallowed it → no ADV-1 notice. Changed to `exit_code == 0`; the bot renders nil as `killed (signal/timeout)`.
5. **#5 (P2)** — `recover_claims` aged claims out at the 600s `EXPIRY_SEC`, dropping live ~90-min runs after 11 min on restart. Added `CLAIM_EXPIRY_SEC`; the dispatcher sizes the window to `child_timeout_sec + kill_grace + 2·poll + margin`.
6. **#6 (P2)** — `DispatchResultQueue` had no expiry/prune/cap → unbounded growth + reconnect flood. Added `EXPIRY_SEC` + `expired?` + `prune_expired` (daemon prunes each tick); the bot drops stale notices without relaying and caps a backlog at `DISPATCH_RESULT_SEND_CAP` with a per-chat summary.

Deferred to a follow-up (review #7–#19): schema-test parity, `claim` fsync, `pgid_for` nil-on-ESRCH, `chat_id` allowlist re-check on drain, `directory()`/`pending()` dedup, `respond_to?` test-seam removal, `QueueCommand` extraction, `child_timeout_sec` fetch-fallback.

**Tests:** full suite 4242 runs / 0 failures, 100% line coverage, rubocop clean.

**Pages:** updated [[modules/daemon]] (C3 claim-window guards, claim-expiry sizing, ADV-1 reliability contract).

## [2026-06-01T00:00:00Z] feat — PR #241 deferred follow-ups (AC-05, R-02, AN-1/2/3, ADV-1, C3)

**Action:** Implemented the six deferred follow-ups from the PR #241 ce-code-review on branch `feat/queue-dispatcher-followups`:

1. **AC-05 — Queue-path alert-reset race**: `Bot::Supervisor#enqueue_command_sequence` no longer resets the alert optimistically at enqueue time. The daemon hasn't run `markers clear` yet, so removing the alert-store fingerprint let the next status tick re-fire the same alert (`process_current` sees `entry.nil?`). State-driven recovery + dedupe now remove the alert once the daemon acts.
2. **R-02 — Per-verb child timeout**: `ChildSupervisor` resolves a per-verb wall-clock timeout at spawn (`daemon.child_verb_timeouts[verb]` → `daemon.child_timeout_sec`, default 7200, 0 disables) and `Dispatcher#enforce_child_timeouts` SIGTERMs then SIGKILLs (after `daemon.child_kill_grace_sec`, default 30) over-deadline children each tick, logging `:child_timeout`. Knobs validated in `Config`.
3. **AN-1/2/3 — Queue inspection CLI**: `hive daemon queue [list|show <id>|prune]` (+`--json`, schema `hive-daemon-queue.v1`) wraps `DispatchRequestQueue` read primitives.
4. **ADV-1 — Failure feedback to Telegram**: new `Hive::Daemon::DispatchResultQueue` (`<state_home>/dispatch_results/`, schema `hive-dispatch-result.v1`). The daemon writes a notice on a non-zero request-driven exit (reading `chat_id` from the claimed file before unlink); the bot drains it each `reaper_loop` and relays a `⚠️` message to the originating chat.
5. **C3 — Atomic-claim restart recovery**: `DispatchRequestQueue.claim` renames `<id>.json` → `<id>.json.claimed` at spawn (stamping pid + process_start_time), making the request invisible to `pending` (at-most-once dispatch). `Dispatcher#recover_dispatch_claims` sweeps stale claims at startup — owner-gone/aged claims removed without re-dispatch, owner-alive left alone — logging `:dispatch_request_recovered`.

New daemon events: `:child_timeout`, `:dispatch_request_recovered`, `:dispatch_result_written`. AC-02 (`:dispatch_request_written` naming) was assessed as a won't-fix nit (`via=queue` on `:dispatched_command` already disambiguates).

**Tests:** full suite 4223 runs / 0 failures, 100% line coverage, rubocop clean.

**Pages:** updated [[modules/daemon]] (claim lifecycle, timeouts, result channel + events), [[commands/daemon]] (`queue` subcommand + timeout caps).

## [2026-05-28T23:30:00Z] fix — PR #241 ce-code-review fixups: schema file, argv+slug validation, security hardening, reliability

**Action:** Addressed 14 findings from `/ce-code-review` on PR #241 across 10 reviewers (correctness, testing, maintainability, project-standards, agent-native, learnings, reliability, security, adversarial, api-contract, cli-readiness):

1. **PS-01/AC-01 — Schema file**: Added `schemas/hive-dispatch-request.v1.json`. Was registered in `SCHEMA_VERSIONS` but the corresponding file was missing, breaking `test/unit/schema_files_test.rb`'s invariant that every key has a published schema. External validators / third-party producers can now reference it.
2. **SEC-1+SEC-5+L-1 — Slug/project/argv validation**: `valid_argv?` now requires argv length ≥ 2, all non-empty strings, and validates the positional slug at `argv[2]` against ADR-012's regex (`^[a-z][a-z0-9-]{0,62}[a-z0-9]$`) for non-`markers` verbs. `parse_data` validates `project` against a name regex and `slug` against the ADR-012 regex — blocks path-traversal candidates at the queue boundary.
3. **SEC-3 — Queue dir 0700**: `directory()` now `mkdir_p(..., mode: 0o700)` plus chmod-tightens an already-existing dir. Without this, default umask 0022 left the dir world-readable.
4. **C2 — Conversation preservation on queue write failure**: `auto_run_after_answers` only clears the conversation on a non-nil dispatch return. A queue write failure (read-only state dir, ENOSPC) no longer strands the operator without a `/done` backstop.
5. **AC-04 — Producer-side project/slug guards**: `DispatchRequestWriter.write!` raises `ArgumentError` on empty project or slug. Producer-side failure is louder and actionable rather than swallowed downstream.
6. **R-01 — Per-iteration rescue in `process_dispatch_requests`**: A `Process.spawn` failure (Errno::EAGAIN under fork-exhaustion) in one iteration no longer aborts the rest of the pending queue. Failure logs `reason: spawn_failure: <class>: <message>` and the request file stays for retry.
7. **C4 — `project_enabled?` gate**: Mirrors `handle_row`. A disabled project's queued requests log `:dispatch_request_blocked reason=project_disabled` and stay for retry once re-enabled.
8. **R-04/M-05 — Gate ordering**: `running_task?` now precedes `can_dispatch?` so an in-flight slug doesn't incur the more expensive cap-counting scan.
9. **M-02 — Dead `respond_to?` guard removed**: `ChildExit` always defines `request_id` (nilable); the `respond_to?` check was dead code.
10. **PS-02 — ADR-033 added**: Records the single-dispatcher invariant. Supersedes ADR-026's "subprocess caller" model for state-mutating verbs while preserving it for read-only verbs (status / doctor / new / approve / accept-finding / reject-finding).

**Tests added** (5):
- `test_dispatch_request_blocked_when_project_is_disabled` (C4).
- `test_dispatch_request_spawn_failure_logs_and_does_not_abort_subsequent_iterations` (R-01).
- `test_write_rejects_empty_project_or_slug` (AC-04).
- `test_directory_is_created_with_user_only_permissions` (SEC-3).
- Updated `test_pending_rejects_missing_fields_and_bad_created_at` to cover new `invalid_project` and `invalid_slug` reasons (SEC-5).

**Coverage:** 100.00% line coverage (17667/17667). RuboCop clean. Full suite: 4131 / 15061 / 0 failures / 0 errors / 2 skips.

**Refreshed pages:**
- [[decisions]] — ADR-033 records the single-dispatcher invariant and the ADR-026 amendment.

**Deferred** (out of scope for the fix pass; tracked as follow-ups):
- AN-1/AN-2/AN-3: `hive bot dispatch-requests --json` / `hive dispatch drain` / `hive dispatch enqueue` CLI verbs.
- R-02: per-verb child timeout (current behavior: hung child indefinitely locks per-slug gate until daemon restart).
- ADV-1: child non-zero exit → Telegram error reply (currently observable only in daemon.log).
- C3: atomic claim + restart-recovery to prevent duplicate dispatch after daemon SIGKILL.
- AC-02: clarify whether `:dispatch_request_written` event should exist alongside `:dispatched_command via=queue` (current implementation uses the latter; consistent with bot.log conventions).
- AC-05: alert-reset timing change in `dispatch_command_sequence` for queue-routable sequences.

## [2026-05-28T22:30:00Z] fix — PR #239 ce-code-review fixups: Q-context-aware answer-slot scan + ENOENT distinction + structured answer_slot_missing event

**Action:** Addressed 10 findings from `/ce-code-review` on PR #239:

1. **Q-context-aware slot location**: `Hive::Bot::BrainstormAnswerWriter.find_empty_answer_slot` now anchors on the parser-identified target Q's line (via a new `target_question_line_index` helper) and walks forward to the first empty A-section before the next block boundary. Replaces the two-step strict-then-fallback scan, which ignored Q/round context — a brainstorm.md with empty `### A1.` in Round 1 (still unanswered) AND Round 2's own `### A1.` would route the operator's Round-2 answer into Round-1's slot. Same combined function also handles the original off-by-one A-header tolerance (e.g. `### A2.` after `### Q1.`) without misattributing.
2. **ENOENT distinguished from lock contention**: `try_append` returns the `:enoent` sentinel when `brainstorm.md` is missing mid-write; `append!` maps it to `:question_not_found` (short-circuit) instead of polling the full 5s retry deadline and returning a misleading `:lock_busy`.
3. **Structured answer_slot_missing event**: added to `Hive::Bot::Logger::EVENTS` and the `schemas/hive-bot-log.v1.json` enum. Supervisor's branch now emits the event alongside the Telegram reply — operator-agents tailing `bot.log` see the malformed-slot state without parsing the human-readable text.
4. **Consolidated regex constants**: `BrainstormAnswerWriter` now reuses `BrainstormParser::{QUESTION,ANSWER,ROUND,MARKER}_RE` directly; the in-file copies subtly diverged (writer's `QUESTION_RE` didn't capture title) and the duplication was a silent-drift risk.
5. **Canonical heading helpers**: `Hive::Bot::BrainstormParser.question_header(n)` / `.answer_header(n)`. Supervisor's `:answer_slot_missing` reply uses them instead of hard-coding `### A#{n}.`. If the brainstorm.md format ever changes, this is the single place to update.
6. **Enriched operator instruction**: the reply now says "Ensure exactly one empty `### A{n}.` sits immediately after `### Q{n}.` (remove any stale mis-numbered `### A.` header in between)" — guarding against the double-A-header trap the prior wording could lead an operator into.

**Refreshed pages:**
- [[modules/bot]] — `BrainstormParser` and `BrainstormAnswerWriter` rows expanded to describe the lenient-A-header rule, Q-context-aware slot location, and the `:answer_slot_missing` / `:question_not_found` mapping.

## [2026-05-28T21:00:00Z] refactor — single-dispatcher via file-backed dispatch-request queue (plan 2026-05-28-002)

**Action:** Eliminated the bot↔daemon dual-writer race for
`hive run`-class verbs. Before: both the daemon AND the bot could
spawn `hive run`, but only the daemon refreshed its
`last_dispatched_mtime` baseline on reap. Bot-spawned reaps were
invisible to the daemon, so the agent's own write to brainstorm.md
looked like a new user edit on the next tick → redundant redispatch
→ task lock held 1-2 min → bot rejects user answers with "Try again
— another run holds the lock". Smoking gun on 2026-05-28 18:13:14
→ 18:13:44 in `daemon.log`.

The fix collapses the two dispatchers into one:

- New `Hive::Daemon::DispatchRequestQueue` (`lib/hive/daemon/dispatch_request_queue.rb`):
  file-backed queue at `<state_home>/dispatch_requests/<ts>-<id>.json`,
  allowlists `run develop brainstorm plan review open-pr artifacts
  finalize archive markers`. Schema `hive-dispatch-request` v1.
- New `Hive::Bot::DispatchRequestWriter` (`lib/hive/bot/dispatch_request_writer.rb`):
  atomic tmp+rename JSON write. Validates argv against the queue's
  allowlist at the call site too.
- `Hive::Daemon::Dispatcher#tick` runs
  `process_dispatch_requests(now:)` BEFORE the per-row scan. Gates
  per request: allowlist → expiry (10 min) → project lookup →
  per-slug in-flight → concurrency caps → spawn. Threads
  `request_id` through `ChildSupervisor#spawn` and `ChildExit` so
  `reap_completed` can unlink the file and log
  `:dispatch_request_completed`.
- `Hive::Bot::Supervisor#execute_dispatch` rewrites queue-routable
  argv into `DispatchRequestWriter.write!`; the bot stops being a
  child-process launcher for those verbs.
- Per-slug in-flight gate added to `dispatch_or_block` so the
  row scan can't double-spawn a slug whose request just dispatched
  earlier in the same tick.

New telemetry events in `daemon.log`:
`dispatch_request_observed/_dispatched/_completed/_blocked/
_rejected/_expired`. Bot's `:dispatched_command` event gains a
`via=queue` tag and `request_id` to distinguish the two paths.

**Tests:** four integration tests including
`test/integration/regression_redundant_redispatch_test.rb` which
replays the exact 18:13 sequence and asserts no redundant
redispatch.

**Refreshed pages:**
- [[modules/daemon]] — new module-map row for
  `DispatchRequestQueue`; new "Single-dispatcher" section describing
  per-step gates + telemetry.
- [[modules/bot]] — new module-map row for `DispatchRequestWriter`;
  new "Single-dispatcher invariant" section with the audit
  command.
- [[architecture]] — new "Dispatch flow" section with the bot →
  queue → daemon → child diagram.

## [2026-05-28T13:50:00Z] fix — CleanExit follow-ups: bot callback reason encoding + agent-actionable next_action

**Action:** Two further CleanExit fixes:

1. **`Hive::Markers.error_recovery_match_attr` encodes both `marker_id` and `reason`** when both are present (comma-separated, `marker_id=...,reason=...`). Telegram inline-button callbacks now reconstruct enough attrs for `Hive::Bot::Handlers::RecoverySequence.manual_only?` to refuse `dirty_worktree` / `ensure_clean_on_exit_failed` — previously the callback path only carried `marker_id=<hex>` and the manual-only check (which reads `attrs["reason"]`) never matched, so the bot kept dispatching the retry verb. `Hive::Bot::AlertStore.parse_match_attr` keeps using the leading token (`marker_id=...`) as its race-safe invalidation guard.
2. **`hive run --json` next_action for `:error reason=ensure_clean_on_exit_failed`** now emits an `EDIT` envelope (target = worktree path, `residue_paths` parsed as an array, `instructions` carrying the canonical recovery one-liner, `markers_to_clear: ["error"]`, `rerun_with` set). `Hive::TaskAction#suggested_next_action_payload` gets a `clean_exit_manual_failure?` predicate returning `{kind: "manual_fix", command: nil}` — mirroring the `auto_commit_manual_failure?` shape so polling consumers see the explicit "do not auto-retry" signal that matches the bot's manual-only routing decision.

**Refreshed pages:**
- [[bot]] — `RecoverySequence` now refuses inline-button retries on the new manual-only reasons via the comma-encoded `match_attr` round-trip.

## [2026-05-28T13:30:00Z] fix — CleanExit follow-ups: stale result[:commit], ConfigError surfacing, 300s git timeout

**Action:** Three follow-up fixes to the CleanExit invariant landed today:

1. **`enforce_clean_exit!` clears stale `result[:commit]`** — when CleanExit overwrites a runner's success marker with `ensure_clean_on_exit_failed`, `Hive::Stages::Base#enforce_clean_exit!` now returns `{status:, overwrote_marker:}`, and `with_stage_events` mutates `result[:commit] = "ensure_clean_on_exit_failed"` + `result[:status] = :error` so `commands/run.rb#commit_after` writes a hive-state commit matching the on-disk marker instead of a stale `"review_complete"`.
2. **`Hive::ConfigError` no longer silently dropped** — invalid `review.fix.auto_commit.sign_policy` config now overwrites the marker to `:error reason=ensure_clean_on_exit_failed detail="invalid sign_policy config: ..."` (200-char truncated) instead of falling into the generic `StandardError` warn-and-continue branch. Other `StandardError` keeps the warn+nil transient path.
3. **300s timeout on clean-exit git ops** — `CleanExit.porcelain_status` (`git status --porcelain`), `CleanExit.run!` add-step (`git add -A`), `CleanExit.failure_with_unstage` (`git reset HEAD --`), `AutoCommit.staged_auto_commit_paths` (`git diff --cached --name-only`), and `AutoCommit.auto_commit_failure_with_unstage` (`git reset HEAD --`) are now bounded by `AutoCommit.capture_git_with_timeout` (300s via `Timeout.timeout` around `Open3.capture3`). A hung pre-commit hook or frozen pager surfaces as `{success: false, timed_out: true, message: "<label> timed out after 300s"}` propagated as `:git_failed`, causing the canonical `ensure_clean_on_exit_failed` marker.

**Refreshed pages:**
- [[state-model]] — marker-grammar row for `ensure_clean_on_exit_failed` now spells out the `detail=` carrier for the ConfigError variant, the 300s timeout on git ops, and the `result[:commit]` rewrite that keeps the hive-state commit aligned with the on-disk marker.

## [2026-05-28T12:00:00Z] feat — Hive::Stages::CleanExit invariant + ensure_clean_on_exit config + bot manual-only routing

**Action:** Shipped the clean-worktree-on-exit invariant (`lib/hive/stages/clean_exit.rb`) as a `with_stage_events` post-yield hook gated on the new global config key `stages.ensure_clean_on_exit` (default `true`). Hooks every stage in `WORKTREE_OWNING_STAGES = %w[4-execute 6-review 8-finalize]`; PAUSE_MARKERS (currently `:execute_waiting`, `:review_waiting`) skip enforcement. Behavior: on a clean worktree do nothing; on dirty residue that is fully inside `review.fix.auto_commit.scope_check.allowed_paths`, auto-commit via the shared `Hive::Stages::AutoCommit` primitives so per-pass review-fix and stage-exit share one implementation; on scope-violating or git-failed residue, overwrite the current marker to `<!-- ERROR reason=ensure_clean_on_exit_failed residue_paths=<rel,paths> -->`. Finalize now also runs CleanExit as an *entry* backstop so 6-review residue self-heals before finalize logic begins. The bot routes `ensure_clean_on_exit_failed` (alongside the legacy `dirty_worktree`) into the manual-only reply path — no inline retry button — because the residue requires operator inspection. CleanExit + finalize's residue-log writer keep the marker grammar in `Hive::Markers::KNOWN_NAMES` honest by reusing the existing `ERROR` name with a new `reason` attr.

**New/refreshed pages:**
- [[stages/finalize]] — Precondition #4 rewritten to describe the entry+exit CleanExit invariant and the new `ensure_clean_on_exit_failed` marker shape.
- [[state-model]] — marker grammar row updated to mention `ensure_clean_on_exit_failed` with `residue_paths` attr; per-project config schema documents `stages.ensure_clean_on_exit`.
- [[stages/review]] — Phase 4 / AutoCommit ownership now also called out as the implementation shared by the stage-exit invariant.
- [[bot]] — manual-only reply enrichment notes that `dirty_worktree` and `ensure_clean_on_exit_failed` both route to the manual path.

## [2026-05-28T10:30:00Z] refactor — extract Hive::Stages::AutoCommit from Review

**Action:** Pure-extract of the per-pass auto-commit primitives (scope-check, sign-policy, git-commit invocation, signing-error pattern set, unstage-on-failure) out of `Hive::Stages::Review` into `lib/hive/stages/auto_commit.rb` so the upcoming stage-exit `CleanExit` invariant can share one implementation. Review's behavior is byte-identical — same `fix(review): apply pass NN findings` commit message + Hive-Fix-* trailers + `auto_commit_fix_worktree` flow; Review's in-file consumers now delegate to `AutoCommit` module-functions, and legacy `Review::AUTO_COMMIT_*` constants remain as aliases.

**Refreshed pages:**
- [[stages/review]] — source list now includes `lib/hive/stages/auto_commit.rb`; Phase 4 prose names the module as the shared owner of the scope/sign/commit primitives.

## [2026-05-28T10:00:00Z] fix(daemon) — review-fix delta on dispatch-baseline persistence

**Action:** Addressed ce-code-review findings on the persistence PR. P0: four newly-written dispatcher tests were silently dropped because they sat below `private` — Minitest only discovers public methods, so the regression that motivates the whole file had zero behavioral coverage in CI; reordered so tests stay public above `private`. P2: closed an FD leak in `DispatchBaselines#acquire_lock` (flock-raise after `File.open` succeeded skipped the close — symmetric to the existing `release_lock` fix). P2: added `:daemon_dispatch_baselines_loaded` (boot-time signal with entry count + suspend flag) and `:daemon_dispatch_baselines_newer_schema_suspended` (positive signal that downgrade protection is engaged), so a silently-disabled persistence layer cannot mask the very regression it exists to prevent. P2: made `prune_dispatch_baselines(scope_projects:)` REQUIRED (was nil-defaulted) — a future caller forgetting it would have silently re-stranded answered tasks across per-project status errors. P2: moved the broad `rescue StandardError` defense-in-depth from `ConcurrencyController#persist_dispatch_baselines!` INTO `DispatchBaselines#write` itself, so the store now owns its entire error surface (controller no longer needs a `logger:` kwarg). P3 cleanups: dropped the unreachable `version < SCHEMA_VERSION` load branch, tightened vacuous test assertions (release_lock close-attempted sentinel, root-safe write-failure test via `file_as_parent`), and rewrote `test_nil_store_keeps_state_in_memory` to assert on real behavior instead of a circular `Dir.glob`. Updated [[modules/daemon]]'s failure-mode-visibility paragraph and added the scope-projects-required note.

**Refreshed pages:**
- [[modules/daemon]]

## [2026-05-27T23:40:00Z] fix(daemon) — persist dispatch baselines across restart

**Action:** Documented the new `Hive::Daemon::DispatchBaselines` store and the restart-survival behavior it gives the daemon's first-sight edit baseline. The `[project, slug] → state_file_mtime` map (in `ConcurrencyController`) was in-memory only, so a daemon restart re-stranded already-answered `needs_input` tasks (a pre-restart answer stopped looking "newer than baseline"); it's now write-through-persisted to `daemon_dispatch_baselines.json` under the state home, fail-closed on load, pruned to the live task set each successful tick. Replaces the rejected marker-`ts` approach (closed PR #229) — no marker-format dependency, mtime-to-mtime comparison. Added a "Persisted dispatch baselines" section and a module-map row to [[modules/daemon]].

**Refreshed pages:**
- [[modules/daemon]]

## [2026-05-27T18:00:00Z] feat — daemon-driven update flow (check + nudge, U1–U5)

**Action:** Added the update flow (plan 2026-05-27-002): `Hive::UpdateCheck` release probe, `UpdateCheck::State` shared JSON store, `update.check`/`update.auto` config, dispatcher integration (throttled check + per-channel nudge), and the nudge surfaces (TUI footer + once-per-version bot push). Every channel is nudge-only for now; bash auto-update (U7) is deferred.

**New/refreshed pages:**
- [[update-flow]] · [[state-model]] · [[commands/update]]

## [2026-05-27T12:00:00Z] ci — cross-OS install verification (real installs)

**Action:** CI now does real installs of every channel on its native OS via `packaging/verify-channel.sh` + the reusable `.github/workflows/install-verify.yml` (matrix: bash/ubuntu x86+arm, brew/macos-15, aur/arch container). Three layers: a pre-release `install-gate` in `release.yml` (gem-installs on macos+ubuntu-arm before publishing), `post-release-verify` (real brew/yay/install.sh of the published version), and a weekly `install-canary.yml`. Failures open/update a single `install-failure` GitHub issue. This matrix immediately caught and drove fixes for real channel bugs (broken `yay -S hive-bin`, brew `hv` shim, brew marker path) shipped in v0.1.5. aarch64-AUR deferred (official `archlinux` image is x86_64-only). Runbook: `docs/RELEASING.md#install-verification`.

## [2026-05-27T09:50:00Z] bot/daemon — service-state in status --json + uninstall teardown doc

**Action:** Review follow-up on the autostart PR. Added a non-mutating `service_state` probe to `ServiceInstaller::Base` (read-only `systemctl --user is-enabled` / `launchctl list`) and surfaced `service_installed` / `service_enabled` / `unit_path` in BOTH `hive bot status --json` and `hive daemon status --json` (additive to the v1 envelopes), closing the agent-native gap where an agent could install/uninstall the autostart unit but not query its state without a mutating call. Documented the new fields in [[commands/bot]] and [[commands/daemon]], and filled the [[commands/uninstall]] gap (it documented the daemon-service teardown but never the bot-service teardown added in this PR). Also made the `hive bot install` `--help` long_desc spell out the `outcome`-branching agent idiom (parse the envelope's `outcome`, re-run with `--force` on `drifted`).

**Refreshed pages:**
- [[commands/bot]], [[commands/daemon]], [[commands/uninstall]]

## [2026-05-27T09:45:00Z] claude - permission_mode applies to all launches, not tmux-only

**Action:** Corrected init help, the init prompt, the config template comment, and wiki wording that described `claude.permission_mode` as applying only to "interactive tmux Claude sessions." The setting is global for Claude: the suggested default `bypassPermissions` is used everywhere (both tmux and headless), and the operator may choose another mode that likewise applies to every Claude-backed stage.

**Refreshed pages:**
- [[commands/init]], [[state-model]] - reworded to "every Claude-backed stage (tmux and headless)."

## [2026-05-27T09:30:53Z] tui - widen subprocess diagnosis marker lookup

**Action:** Rebased issue #14 on top of the current TUI marker-id/backoff work. `Hive::Tui::Subprocess.diagnose_recent_failure` now starts with the existing 64 KiB marker-log tail read, then walks backward in 64 KiB increments up to 1 MiB before falling back to the generic exit-code flash. `Messages::SubprocessExited` carries the spawn id so concurrent same-verb failures diagnose the exact per-spawn capture instead of the newest same-verb marker, and marker argv serialization now round-trips quoted values such as project names with spaces. Per-spawn stdout/stderr capture remains capped separately; the wider marker lookup only recovers the BEGIN[id] line needed to map a failing verb to its capture file and argv.

**Refreshed pages:**
- [[commands/tui]] - documented the 64 KiB to 1 MiB bounded marker-log lookup and exact-spawn diagnostic routing.

## [2026-05-27T09:30:00Z] claude - unify bypassPermissions flag across tmux and headless

**Action:** Made `claude.permission_mode: bypassPermissions` resolve to the same `--dangerously-skip-permissions` flag on both the headless `-p` path and the interactive tmux path. Previously the tmux wrapper emitted `--permission-mode bypassPermissions` while headless emitted `--dangerously-skip-permissions` — a documented divergence flagged in code review. Extracted the mode→argv mapping into a single `AgentProfile#permission_flags(mode)` used by both `Hive::Agent#build_cmd` and `Hive::ClaudeLauncher#wrapper_command`, and taught `interactive_claude_wrapper.sh` to forward a valueless `--dangerously-skip-permissions`.

**Refreshed pages:**
- [[modules/config]], [[stages/brainstorm]], [[modules/agent_profile]] - documented the shared `permission_flags` mapping and the bypassPermissions equivalence.

## [2026-05-27T09:03:53Z] tui - throttle failed auto-heal retries

**Action:** Rebased the kill-class auto-heal backoff fix on top of marker-id guarded ERROR recovery. `BubbleModel#auto_heal_kill_class_errors` now refreshes the same `HEAL_REPEAT_INTERVAL_SECONDS` folder timestamp when `hive markers clear` fails, so persistent lock or filesystem failures retry later without spawning one heal thread per status snapshot.

**Refreshed pages:**
- [[commands/tui]] - documented kill-class auto-heal retry throttling on clear failure.

## [2026-05-27T07:57:49Z] init - JSON success envelope and partial rollback

**Action:** Rebased and documented issue #24's `hive init` hardening on top of the current daemon-autostart behavior: `--json` now emits a single `hive-init.v1` success payload with resolved prompt answers and project metadata, the non-TTY defaults prose is suppressed in JSON mode, and the disk-writing init window snapshots and rolls back `.hive-state/config.yml`, the `.hive-state` worktree, `hive/state`, init-created main-checkout commits/files, runtime hook/scheduler files, and the global registry path before surfacing failures as typed Hive errors. Prompt edge cases were also pinned: digit-only agent profile names resolve as names before indexes, leading-comma timeout-only limits remain valid, and trailing-comma budget-only limits re-prompt.

**Refreshed pages:**
- [[commands/init]] - usage, JSON shape, rollback/recovery semantics, daemon autostart semantics, prompt edge-case contract, tests.
- [[cli]] - command table and `--json` support matrix updated for `hive init --json`.

## [2026-05-27T07:08:56Z] config - atomic registry review hardening

**Action:** Code-review follow-up for #184: global config atomic rewrites now restore the existing file mode after tempfile creation so a restrictive process umask cannot silently narrow `config.yml`; lock/write path-shape failures such as directory lockfiles, `EISDIR`, `ENOTDIR`, and symlink loops are rewrapped as `Hive::ConfigError`; and mixed register/forget/prune fork tests cover the locked read-modify-write paths. Refreshed config/state docs to name the XDG global config path while preserving the migrated legacy `~/Dev/hive/config.yml` note.

**Refreshed pages:**
- [[modules/config]]
- [[state-model]]

## [2026-05-27T06:32:37Z] prune - real_path review hardening

**Action:** Code-review follow-up for #182: malformed private `real_path` metadata is now treated like legacy absence instead of being trusted as a comparison target, so a hand-edited non-string value cannot prune a live project row. Refreshed prune schema/help prose to name realpath-mismatch removals alongside missing paths and invalid rows.

**Refreshed pages:**
- [[modules/config]]
- [[commands/prune]]
- [[cli]]
- [[state-model]]

## [2026-05-27T04:25:37Z] bot - legacy warning status parity

**Action:** Code-review follow-up for #174: Telegram legacy-stage warnings now render project-scoped `hive migrate <project_path>` commands and the pull `/status`/`/queue` surface includes the same project-level warning even when there are no canonical task rows. Bot docs now describe daemon-aware ready notifications and the text-only legacy warning.

**Refreshed pages:**
- [[modules/bot]] - corrected ready-alert semantics and recorded `/status` legacy warning parity.
- [[commands/bot]] - documented the text-only legacy-stage warning.
- [[commands/status]] - recorded the bot's project-path-scoped migrate command.

## [2026-05-27T04:17:33Z] bot - legacy warning dedupe follow-up

**Action:** Code-review follow-up for #174: legacy-stage Telegram warning fingerprints are project-level, so changes to hidden task counts or stage-dir detail do not re-alert until the project reports clean and later regresses again. Fresh alert-store seeding now leaves legacy-stage migration warnings eligible for immediate delivery. Added dispatcher/status-watcher/builder regression coverage.

**Refreshed pages:**
- [[modules/bot]] - clarified project-level dedupe while legacy-dirty.
- [[commands/status]] - clarified bot dedupe semantics.

## [2026-05-27T02:41:29Z] dependencies - faraday audit floor

**Action:** Updated the lockfile security floor for Telegram Bot API HTTP transport after `bundler-audit --update` began flagging `faraday` 2.14.1 for CVE-2026-33637 / GHSA-5rv5-xj5j-3484. `Gemfile.lock` now resolves `faraday` 2.14.2 and `faraday-net_http` 3.4.3.

**Refreshed pages:**
- [[dependencies]] - recorded the Faraday audit floor behind `telegram-bot-ruby`.

## [2026-05-27T01:30:00Z] bot — autostart service (`hive bot install`)

**Action:** Added `hive bot install [--force] [--json]`, a per-user autostart service for the Telegram bot (systemd-user unit on Linux, launchd plist on macOS) that survives reboot/login and starts the bot immediately — one command, no separate `hive bot start`. Implemented by extracting `Hive::Commands::ServiceInstaller::Base` from the daemon installer (daemon behavior byte-identical) and a `Bot::ServiceInstaller` subclass; the unit runs `hive bot start --foreground` with no inline token (the bot loads `~/.config/hive/.env`) and no `TimeoutStopSec=900`. Opt-in only — not wired into `install.sh`/`hive init`. `hive uninstall` tears the unit down. New `hive-bot-install.v1` schema; exit codes mirror the daemon (0 / 64 drift / 70 service-manager failure). Documented the new subcommand, an Autostart section, and exit codes in [[commands/bot]]; updated `docs/cli.md`.

**Refreshed pages:**
- [[commands/bot]]

## [2026-05-28T20:50:00Z] openclaw — in-tree skill bundle

**Action:** Added `openclaw/skills/` as Hive's OpenClaw skill surface. The bundle uses an umbrella `/hive` skill for arbitrary `hive ...` commands plus shortcuts for the day-to-day workflow (`/plan`, `/work`, `/ce-review`, and related stage/finding/admin helpers). Each skill preflights `command -v hive`, documents safe argument passing, and dispatches to the existing CLI instead of adding an OpenClaw TypeScript plugin runtime.

**Docs:** `README.md` now has a "Works with OpenClaw.ai" section. `openclaw/README.md` records the Skills-vs-Plugin recommendation, the local install commands, planned ClawHub slugs, and the dry-run publish loop. ClawHub publication and listing evidence remain external maintainer steps.

**Refreshed pages:**
- [[operating]]
- [[gaps]]

## [2026-05-27T00:00:00Z] release — implement Homebrew + AUR publishing (gem-based)

**Action:** Implemented the brew/AUR last mile (per ADR-032). Added `packaging/render.rb` — one fail-closed ERB renderer for both the Homebrew formula and the AUR PKGBUILD. Replaced the `exit 1` AUR placeholder in `release.yml` with a real signature-gated `aur-publish` container job (pinned cosign identity, `makepkg --printsrcinfo`-generated `.SRCINFO`, idempotent push). Deleted the stale tebako `.SRCINFO.template`. Created the `ivankuznetsov/homebrew-hive` tap (serving v0.1.0). Added the `docs/RELEASING.md` maintainer runbook. Rewrote `gaps.md` "Release install follow-ups" §1: automation built; remaining work is the human AUR account/key/bootstrap + secrets + `v*` tag protection.

**Refreshed pages:**
- [[gaps]]

## [2026-05-26T23:30:00Z] daemon - reclassify no-systemd autostart as unsupported (review follow-up)

**Action:** Code-review follow-up on the autostart-install branch. A Linux host with no systemd-user no longer reports a `failed` / exit-70 envelope (this supersedes the 22:55Z entry below): the unit is still written, but autostart-unavailable is now a `:autostart_unavailable` installer result that maps to the `unsupported` success outcome (exit 0) with `target_path` set to the written unit. A genuine service-manager rejection (systemctl enable/reload, or macOS launchctl load) still exits 70. Also hardened: `install.sh daemon_autostart_setup` captures the real exit code in an `else` branch (was always reporting `exit 0`) and treats `unsupported`/unreadable-JSON distinctly; `hive init`'s `register_daemon_service!` now degrades any unexpected `StandardError` to a warning so it can't abort an already-committed init; dead `which` delegators removed in favor of `Hive::InvokedBinary`; README scoped so only `install.sh` is described as auto-running `hive daemon install`.

**Impact:** WSL/containers without systemd-user get a clean exit 0 and a quiet `hive init` instead of a spurious failure; the `hive-daemon-install.v1` `unsupported` outcome can now carry a `target_path`. Schema description updated accordingly.

**Refs:** [[commands/daemon]], [[commands/init]], [[operating]]

## [2026-05-26T23:18:07Z] review - enforce wall-clock attribution for fair-share deadlines

**Action:** Review-code follow-up for #155: when all reviewers return errors after consuming rolling shares, `run_reviewers` re-checks the outer wall clock before falling back to `:all_failed`, preserving `REVIEW_STALE reason=wall_clock`. Shared Claude review sends now thread the reviewer deadline into tmux readiness, so a busy shared session cannot spend time outside that reviewer's fair share.

**Refreshed pages:**
- [[stages/review]] - noted that shared Claude tmux readiness waits count against the current reviewer deadline.

## [2026-05-26T22:55:00Z] daemon - autostart install repair

**Action:** Tightened install-time daemon autostart so service units preserve the invoked user-facing wrapper (`hive` or `hv`) instead of baking the inner gem shim, and so Linux hosts without usable systemd-user get a failed `hive-daemon-install` envelope rather than a false enabled-autostart success. Agent install instructions now carry the verified `hive_cmd` through daemon install and project init.

**Impact:** Bash/Homebrew installs keep wrapper-provided GEM_HOME/GEM_PATH across reboot, Apache Hive collision hosts can use `hv` safely for daemon setup, and installer automation can distinguish "unit written" from "autostart enabled".

**Refs:** [[commands/daemon]], [[operating]]

## [2026-05-26T21:22:40Z] daemon - install-time autostart by default

**Action:** Moved daemon autostart to install-time/global setup. The bash installer now runs `hive daemon install` after installing the gem; the agent installer prompt tells agents to run `hive daemon install --json` for Homebrew/AUR/existing installs. `hive init` no longer asks a second autostart question; it only asks whether the current project should render `daemon.enabled: true`. The init path still idempotently ensures the service for dev-clone/manual users.

**Refreshed pages:**
- [[commands/init]] - prompt flow and non-TTY summary now describe project enrollment only.
- [[commands/daemon]] and [[operating]] - service autostart is global install-time infrastructure; project enable/disable is dispatch enrollment.
- [[cli]] and [[decisions]] - updated command and ADR wording for the new install/init split.

## [2026-05-26T18:00:00Z] bot — /status reverts to inline buttons (text-links can't carry the slug)

**Action:** Real-device testing confirmed that tapping a rendered `/answer <slug>` text-link in a `/status` reply sends only `/answer` (Telegram's `bot_command` entity covers the token, not the argument), so the slug was dropped and the tap hit the usage hint. Reverted the `/status`/`/queue` surface from slash-command text suffixes to an inline callback keyboard: `Supervisor#status_keyboard` / `status_action_button` build one button per actionable row (✏️ answer / ✅ approve / 🔧 autofix / 🔍 details), reusing `NotificationBuilders` callback constructors so the callbacks are byte-identical to the push-notification buttons. `slash_link_for` removed. The `/answer`/`/approve`/`/autofix`/`/details` slash commands remain typeable and in the quick-actions menu. Corrected the prior wiki claim that text links were one-tap.

**Refreshed pages:**
- [[commands/bot]]

## [2026-05-26T15:30:00Z] bot — /status slash-link surface + /autofix + /details

**Action:** The `/status` reply now formats every actionable row with an inline `/command <slug>` suffix. Telegram clients auto-render these as one-tap blue links inside bot messages, giving every Brainstorm-waiting, ready-to-X, retryable-recovery, and manual-only-recovery row a one-tap recovery path with NO inline keyboard. Row classification reuses `NotificationBuilders.retryable_recovery?` / `manual_only_recovery?` so the text-link surface stays consistent with the push-notification button surface. Two new slash commands (`/autofix <slug>`, `/details <slug>`) were added; both resolve the slug against the latest `StatusWatcher` snapshot. Recovery dispatch logic was extracted into `Hive::Bot::Handlers::RecoverySequence` so the inline 🔧 Autofix button (`CallbackHandlers#autofix`) and the `/autofix` slash command (`SlashHandlers#autofix`) produce byte-identical argvs for the same row. `Supervisor::BOT_COMMANDS` extended from 7 to 9 commands.

**Refreshed pages:**
- [[commands/bot]]

## [2026-05-26T14:30:00Z] bot — register slash commands with Telegram on start

**Action:** Added `Hive::Bot::Telegram#set_my_commands` (thin wrapper over the Bot API) and `Hive::Bot::Supervisor#register_bot_commands` called once in `run_forever` after `:bot_started`. The seven supported slash commands (`/idea`, `/status`, `/queue`, `/answer`, `/approve`, `/done`, `/help`) and their descriptions live in `Hive::Bot::Supervisor::BOT_COMMANDS`. Failures are swallowed and logged as `:send_failure source: "set_my_commands"` so a Telegram outage at bot start does not prevent `poll_loop` from running. Intentionally NOT re-issued on SIGHUP/config reload — the command list does not depend on config. Operators now see the slash commands stacked in Telegram's blue quick-actions menu when they tap the `/` icon.

**Refreshed pages:**
- [[commands/bot]]

## [2026-05-26T15:30:00Z] install - managed QMD for llm-wiki

**Action:** Made QMD part of Hive's install and diagnostics path. `install.sh` now installs `@tobilu/qmd` with npm into Hive's data prefix (`${XDG_DATA_HOME:-~/.local/share}/hive/qmd`) and links `qmd` beside the Hive binary unless the operator opts out with `HIVE_INSTALL_QMD=0`. Generated `.llm-wiki` scripts now resolve QMD through `HIVE_QMD_BIN`, PATH, Hive's managed data-prefix install, or the `install-prefix` sidecar so systemd timers are not dependent on an interactive shell PATH. `hive doctor` adds a non-fatal `wiki/qmd` row for initialized projects and reports native Node ABI failures with a `npm rebuild better-sqlite3` repair hint.

**Refreshed pages:**
- [[operating]] - documented managed QMD install flags and agent-assisted install repair.
- [[dependencies]] - added QMD/npm to external CLI dependencies.
- [[commands/init]] - documented generated script QMD resolution.
- [[commands/doctor]] - documented the `wiki/qmd` row and JSON history.

## [2026-05-26T14:30:00Z] claude-launcher - preserve project-owned .claude/settings.json

**Action:** Documented the launcher's new backup/restore behavior for `.claude/settings.json`. Root cause was that `StopHookInstaller.install_at` unconditionally deleted-and-overwrote the file, then `cleanup_scratch` unconditionally deleted it on spawn end — destructive for any project that committed `.claude/settings.json` via `hive init`'s llm-wiki bootstrap (`git_ops.rb:140`). Symptom was a recurring `dirty_worktree` marker in 4-execute / 6-review / 8-finalize because the post-stage check saw the deletion in `git status`. Fix: snapshot the existing file to `.claude/settings.json.hive-pre-install` before the install overwrite (only on first install per spawn pair, to avoid backing up the hive stub on re-entry), and have `cleanup_scratch` prefer restore-from-backup over delete.

**Refreshed pages:** None — fix is internal launcher plumbing; existing module pages remain accurate.

## [2026-05-26T13:43:04Z] babysitter - experimental open-PR daemon

**Action:** Documented the new experimental `hive babysit` process. The command is separate from `hive daemon`, uses its own PID/log files, polls projects with `babysitter.enabled: true`, filters open PR labels, spawns the development agent in `.hive-state/babysitter/worktrees/<pr>/`, writes per-project babysitter events/status, and supports best-effort dry-run stubs for agent-side `git`/`gh` mutations.

**Refreshed pages:**
- New: [[commands/babysit]] - CLI lifecycle, one-shot mode, config contract, PR processing, dry-run behavior, and tests.
- New: [[modules/babysitter]] - module map, wiring, event shape, and v1 boundaries.
- [[cli]] - command table and JSON-support note.
- [[commands/init]] - babysitter opt-in prompt and non-TTY summary.
- [[modules/config]] - defaults and validation for `babysitter`.
- [[operating]] - dry-run shakedown and kill-switch guidance.
- [[index]] - added the new pages and bumped the catalog count.

## [2026-05-26T14:11:12Z] tui - token footer ordering

**Action:** Documented that the grid-mode footer now renders action hints before the compact token usage block on wide terminals, preserving the ` · ` separator between blocks and leaving the below-80-column compact-only usage path unchanged.

**Refreshed pages:**
- [[token-usage]] - updated the TUI surface description and example footer order.
- [[commands/tui]] - refreshed the dashboard footer diagram to show hints before usage.

## [2026-05-26T12:19:00Z] bot - legacy stage directory notifications

**Action:** Documented the Telegram bot parity path for `legacy_stage_dirs`. `StatusWatcher` now surfaces project-level legacy-stage warnings, `Supervisor#status_tick` feeds them through the alert lifecycle with task rows, and the bot sends one deduped notification on the clean-to-legacy transition telling the operator to run `hive migrate`.

**Refreshed pages:**
- [[modules/bot]] - recorded the watcher/supervisor/dispatcher notification flow.
- [[commands/status]] - noted bot parity for legacy-stage warnings.

## [2026-05-26T11:49:11Z] brainstorm - fail fast on tmux prompt submit loss

**Action:** Documented the tmux prompt submit failure path. `TmuxRunner#send_prompt` now lets `NoServerRunning`, hung tmux commands, and other `send-keys Enter` failures propagate while retaining buffer cleanup, so an unsubmitted prompt fails immediately instead of waiting for the stage timeout. `HIVE_TMUX_COMMAND_TIMEOUT_SEC` bounds each tmux client call.

**Refreshed pages:**
- [[stages/brainstorm]] - recorded the fail-fast tmux submit semantics.

## [2026-05-26T11:37:50Z] brainstorm - pin Claude TUI ready predicates

**Action:** Documented the Claude TUI predicate contract for tmux mode. Trust and ready markers are pinned in `Hive::ClaudeLauncher` to the observed Claude Code 2.1.133 TUI; readiness is based on the current prompt block, requires the prompt marker on the last non-blank pane line, ignores stale trust/permission scrollback, and rejects numbered menu options as non-ready.

**Refreshed pages:**
- [[stages/brainstorm]] - recorded the pinned TUI predicate and stale-scrollback guard.

## [2026-05-26T11:27:00Z] brainstorm - Claude tmux ready timeout fallback

**Action:** Documented the shared Claude tmux readiness fallback. `CLAUDE_READY` now follows the shared `READY_WAIT_TIMEOUT_SEC` env override when its specific env var is unset, while keeping the long 120s bare default for slow Claude TUI startup.

**Refreshed pages:**
- [[stages/brainstorm]] - recorded the `HIVE_CLAUDE_TMUX_*` readiness inheritance contract.

## [2026-05-26T11:14:24Z] init - prompt answer binding fail-fast

**Action:** Restored `ProjectConfigBinding` to the documented "never invent defaults" contract. The binding now requires the complete current `Prompts#collect` answer hash, validates every nested budget/timeout `LIMIT_KEYS` entry, and `hive init` renders the config immediately after prompt collection so incomplete prompt data raises before `.hive-state` or `hive/state` can be created.

**Refreshed pages:**
- [[commands/init]] - documented the complete-answer fail-fast contract, pre-side-effect render order, nested limit validation, and unit/integration coverage.

## [2026-05-26T10:30:00Z] review - accepted finding count source of truth

**Action:** Fixed issue #156 by carrying accepted-findings text and count together through the 6-review Phase 4 path. The auto-commit fallback now writes `Hive-Fix-Findings` from the collector's count instead of reparsing rendered accepted-findings lines, removing the duplicate line-format regexes.

**Refreshed pages:**
- [[stages/review]] - documented that auto-commit fallback uses the collector count for `Hive-Fix-Findings`.
- [[modules/metrics]] - clarified the trailer's count source.

## [2026-05-26T10:15:00Z] daemon - self-reexec on source-file drift

**Action:** Surfaced the daemon's new auto-re-exec behavior triggered by `lib/hive.rb` SHA-256 drift. Adds `ADR-031` recording the diagnosis (8,946 `schema_version` mismatches between PR #78 and the next restart) and the chosen mitigation. Updates `wiki/modules/daemon.md` with operator-facing details: fingerprint scope, rate-limit (60s), kill switch (`HIVE_DAEMON_NO_AUTO_REEXEC=1`), and what kinds of edits do and don't trigger re-exec.

**Refreshed pages:**
- [[decisions]] - new ADR-031 inserted ahead of ADR-030.
- [[modules/daemon]] - added "Self-reexec on source drift" section before Backlinks.

## [2026-05-26T10:07:52Z] review - auto-commit staged path scope gate

**Action:** Fixed issue #157 by adding a default-on staged-path scope check before Hive Phase 4 auto-commit fallback writes a trailered fix commit. The runner still stages with `git add -A`, but then reads `git diff --cached --name-only -z`, rejects denied/out-of-allowlist paths from `review.fix.auto_commit.scope_check`, unstages on failure, and surfaces the block as `REVIEW_ERROR phase=fix reason=fix_auto_commit_failed`.

**Refreshed pages:**
- [[stages/review]] - documented the staged-path gate in Phase 4.
- [[architecture]] - added the scope gate to the review-stage safety boundary list.
- [[state-model]] - documented the new review.fix.auto_commit.scope_check config shape.

## [2026-05-26T10:00:00Z] review - fair per-reviewer wall-clock deadlines

**Action:** Fixed issue #155 by changing `Stages::Review.run_reviewers` to give each reviewer a rolling fair share of the remaining `review.max_wall_clock_sec` budget instead of handing every reviewer the full remaining deadline. This preserves sequential reviewer execution while preventing one hung reviewer from starving later reviewers in the same pass.

**Refreshed pages:**
- [[stages/review]] - documented the rolling fair-share deadline behavior for Phase 2 reviewers.

## [2026-05-25T18:28:15Z] claude.mode - init permission-mode selection

**Action:** Added project config and `hive init` support for `claude.permission_mode`. Fresh projects now render `bypassPermissions` by default for every Claude-backed stage (tmux and headless), while the init prompt lets operators choose `auto` for Claude Code auto-mode rules or another supported Claude Code permission mode. `Hive::ClaudeLauncher` now reads the configured value before building the tmux wrapper command.

**Refreshed pages:**
- [[commands/init]] - documented the new prompt, defaults summary, and scripted-answer contract.
- [[modules/config]] - documented defaults, validation, and `Config.claude_permission_mode`.
- [[stages/brainstorm]] and [[state-model]] - recorded the launcher/config surface.

## [2026-05-25T14:33:37Z] testing - live global Claude tmux dogfood

**Action:** Dogfooded the merged project-global `claude.mode: tmux` path against real Claude in a disposable project. The run used a temporary `HIVE_HOME` plus private `HIVE_TMUX_SOCKET`, verified `hive doctor --json`, ran brainstorm to `marker_after=waiting`, filled the answer, reran to `marker_after=complete`, confirmed `round_waiting`/`round_complete` events, `hive status --json` `ready_to_plan`, and tmux cleanup.

**Refreshed pages:**
- [[testing]] - recorded the live dogfood shape and evidence for global Claude tmux mode.

## [2026-05-25T00:00:00Z] testing - default 100 percent coverage gate

**Action:** Made `bundle exec rake coverage` enforce 100% line coverage by default, with CI also exporting `HIVE_COVERAGE_MIN_LINE=100` explicitly. Added unit coverage for the default threshold and updated the ProcessKill permission-denied tests to exercise production-reachable `EPERM` behavior.

**Refreshed pages:**
- [[testing]] - documented the default 100% coverage threshold and the override role of `HIVE_COVERAGE_MIN_LINE`.

## [2026-05-24T16:46:47Z] release notes - final verified PR merge batch

**Action:** Refreshed `docs/notes/2026-05-24-verified-pr-merge-notes.md` after #134 and #135 merged. The note now covers the full ordered #121-first pass through #135, includes the docs checkpoint #136, records the PR #135 CI flake fix and verification evidence, and updates the line-change scoreboard/fun stats.

**Refreshed pages:** None - docs-only release note plus this changelog entry.

## [2026-05-24T15:40:33Z] release notes - verified PR merge batch from #121

**Action:** Added `docs/notes/2026-05-24-verified-pr-merge-notes.md` to record the ordered #121-first PR merge pass, final verification evidence, merged PR metadata, and line-change scoreboard. The batch covered #121, #126, #131, #127, and #129; #125 is listed only as same-day context because it was already on `main` before the ordered pass began.

**Refreshed pages:** None - docs-only release note plus this changelog entry.

## [2026-05-24T15:40:00Z] testing - Telegram bot eval harness

**Action:** Added an opt-in `test/eval/` suite and `bin/hive-eval` runner for the Telegram bot. The harness drives the real `Hive::Bot::Supervisor` through fake Telegram/status/child-process boundaries, captures structured bot logs, classifies every outbound payload into the v1 typed-reason contract, and writes JSON reports for agent consumption. Scenario `s3_noise` is intentionally baseline-failing today because proactive ready/finished notifications are classified as `task_finished`, while the v1 contract permits only `agent_blocked_question` and `fatal_error` proactively.

**Refreshed pages:**
- [[testing]] - documented `rake test:eval`, `bin/hive-eval`, JSON reporting, `--no-judge`, and the expected S3 failure.
- [[modules/bot]] - documented that the eval harness is test-only and does not change production bot behavior.

## [2026-05-24T15:36:02Z] observability - token usage stats

**Action:** Documented the new hive-driven token usage capture path. The reader thread extracts profile-specific usage events, `Stages::Base.spawn_agent` writes rows to `Hive::UsageDb`, and `hive tui` reads scoped aggregates for the footer and `T` matrix view.

**Refreshed pages:**
- [[token-usage]] - new page covering capture boundaries, SQLite schema/location, aggregation buckets, TUI surfaces, and tests.
- [[index]] - added the page to the catalog.
- [[gaps]] - tracked the Codex/Pi real-stream extractor refinement follow-up.

## [2026-05-23T18:00:00Z] claude.mode — tmux envelope parity + daemon-headless callout

**Action:** Hardened the `claude.mode: tmux` path after PR review. `Hive::ClaudeLauncher` now emits the same envelope shape as the headless `claude -p` runner so consumers (status/daemon/bot) see identical `{status, error_message, ...}` regardless of mode; the obsolete `HIVE_BRAINSTORM_TMUX_*` env knobs were removed (config is the single source). CLAUDE.md gained an explicit callout that daemon/service hosts that cannot run tmux must set `claude.mode: headless`. G3+G5 tests expand per-stage `allowed_tools` and tmux session-name coverage so reviewers/finalize don't drift from the launcher contract.

**Refreshed pages:** No structural changes needed — [[decisions]] ADR-030 already names the daemon-headless guidance and the tmux runtime-dep contract; [[active-areas]] already lists the global Claude launch mode row.

## [2026-05-23T15:00:00Z] claude.mode — review-pass 1 follow-up fixes

**Action:** Applied the round-1 reviewer findings on `claude.mode`. `Stages::Base.spawn_claude!` now PROPAGATES `Hive::AgentError` (R7 hard-fail contract); a new `spawn_claude_with_tmux_marker!` wraps the top-level Claude stages (brainstorm / plan / execute / open_pr / artifacts / finalize) so the `:error reason="tmux_unavailable"` marker still lands for those, while the 6-review path's outer rescue lands the dedicated `:review_error reason="tmux_unavailable"` marker. `run_reviewer_spec` re-raises tmux-unavailable AgentErrors so they no longer land as N per-reviewer `errors-NN.md` lines plus `:all_failed`. The TMUX_UNAVAILABLE regex was narrowed (a session-startup timeout is transient, not "tmux missing"). Doctor surfaces a row when `.hive-state/config.yml` is unreadable. Renamed `docs/notes/brainstorm-interactive-tmux.md` → `claude-tmux-launch-mode.md` to match its retitled content. Wiki/init.md and Init#collect docs updated to 10 LIMIT_KEYS and to drop the "five sections" undercount.

**Refreshed pages:** [[commands/init]].

## [2026-05-23T11:30:00Z] drop — pass-1 + pass-2 review-finding fixes hardened hard-delete

**Action:** Recorded the two follow-up fix passes against `hive drop` after the initial feat/U1+U3 commit. Pass-1 (24 findings) and pass-2 (48 findings) tightened idempotency, PID-reuse safety, locale-stable git stderr parsing, worktree-pointer root validation, malformed-YAML rescue in `Worktree.read_pointer`, daemon-row `folder_missing_nil` distinction, and a closed `commit_action` enum on the drop schema. The `9-done` refusal prose in [[commands/drop]] was folded into the refusals-table caption. [[cli]] is already in sync (drop row + exit-code/`--json` envelope row). Schema enum + `holder`/`lock_path` extras were aligned with `DropErrorKind` during pass-1.

**Refreshed pages:**
- [[commands/drop]] — refusal prose tightened around the table; no surface change to flags, exits, or JSON keys (those were correct from feat commit).

## [2026-05-23T10:00:00Z] claude.mode — global Claude launch mode (tmux | headless)

**Action:** Documented ADR-030 work shipped on `we-added-tmux-mode-for-260519-69be` (U1–U8). Added top-level `claude.mode` config (default `tmux`) honored by every Claude-backed stage via `Hive::Stages::Base.spawn_claude!` + `Hive::ClaudeLauncher`. `hive init` prompts for the mode, `hive doctor` reports it, 6-review shares one tmux session per reviewer pass for Claude reviewers (Codex/Pi remain headless). `brainstorm.runtime` deprecated to brainstorm-only fallback. `tmux >= 3.0` becomes a hard runtime dependency when `claude.mode: tmux`.

**Refreshed pages:** [[decisions]] (ADR-030 already authored), [[active-areas]].

## [2026-05-23T09:45:00Z] readme - add daemon-first TUI getting started

**Action:** Reworked the README quickstart into a five-minute TUI getting-started path before the Telegram section. The happy path now explains that the daemon advances ready tasks automatically while the TUI is for watching the queue, capturing a rough idea, and answering waiting prompts. Manual stage keys are framed as power-user controls, not the day-one flow.

**Refreshed pages:** None - README-only user-facing onboarding change; existing [[commands/tui]] and [[commands/daemon]] remain the deep references.

## [2026-05-23T09:20:00Z] bot - default start backgrounds for manual use

**Action:** Simplified Telegram onboarding by making `hive bot start` background the bot by default. `--foreground` is now the explicit mode for systemd, launchd, and terminal debugging; legacy `--detach` remains accepted as a no-op compatibility flag because backgrounding is already the default. README now includes a short BotFather -> numeric chat id -> allowlist -> `hive bot start` path based on the OpenClaw-style quick onboarding pattern.

**Refreshed pages:** [[commands/bot]], [[modules/bot]], [[operating]], [[state-model]].

## [2026-05-23T00:00:00Z] events — task-local event log + derived status.md (U1–U4)

**Action:** Documented the new `Hive::Events` module and the lifecycle hooks added across `Hive::Agent`, `Hive::Stages::Base`, `Hive::Stages::Review`, and `Hive::Commands::Run`. Every task now writes append-only JSON records to `<task>/events.jsonl` and a derived `status.md` after each emit. Stage runs are bracketed by `stage_enter` / `stage_exit` (with `error` + closing `stage_exit` on rescue paths), agent spawns by `agent_start` / `agent_end` (always emitted in `ensure`), and the review loop adds per-phase `agent_start` / `agent_end` pairs that nest above per-reviewer spawns. Marker-driven `round_waiting` / `round_complete` events fire when brainstorm or plan land on those terminal markers; error-class markers (`error`, `review_error`, `review_ci_stale`, `review_stale`) emit an `error` event with marker reason/phase/pass details.

Implementation invariants captured: single O_APPEND write per record (POSIX append-atomicity guarantee), 16 KiB trailing read window for tail rendering, 20-event recent-events list with a wider 200-line walk for current-agent recovery, atomic rename for `status.md` writes, and torn-record tolerance via silent skip on `JSON::ParserError`. `Stages::Review` keeps phase brackets balanced through `@open_phase_event` and a tail `ensure`. `Hive::Agent` detects `SyntheticTask` vs real `Hive::Task` via `respond_to?` to derive the right slug and stage labels without branching by class.

**Refreshed pages:**
- New: [[modules/events]] — module reference (event types, record shape, atomicity contract, status.md renderer, bracket discipline, SyntheticTask handling).
- [[commands/run]] — `runner.call` is now wrapped by `Hive::Stages::Base.with_stage_events`.
- [[stages/review]] — `mark_working` doubles as the phase-bracket emitter; tail `ensure` in `run!` guarantees the closing `agent_end`.
- [[index]] — added `modules/events` entry, bumped page count to 62.

## [2026-05-23T00:00:00Z] tui — red-status detail screen simplified to a two-action contract

**Action:** Documented the simplification of the red-status detail screen to a unified two-action contract. The previous `[f] manual fix` and `[R] refresh diagnosis` bindings are removed; the screen now exposes only `[Enter] Recover` (re-runs hive's automated recovery and closes the screen — rows with no auto-recovery recipe surface a refusal flash naming `Open in agent`) and `[o] Open in agent` (suspends the TUI into the configured development agent — same path as grid `s` — and closes the detail screen). `q` / `Esc` returns to the grid.

The supporting cleanup:

1. **`RedStatusDetailState#marker_signature` is gone.** The freshness gate it served (the "marker changed since you opened this view — refresh (R)" banner) was removed when `R` was dropped; the field was being written on every snapshot poll but never read. Update no longer recomputes a per-snapshot signature.
2. **`refresh_red_status_diagnosis` and its `@diagnosis_inflight` dedup set were removed from `BubbleModel`.** No `R` keystroke routes here anymore.
3. **Agent-label resolution moved out of `Views::RedStatusDetail` and `Update.apply`.** It now lives in `BubbleModel#resolve_agent_label`, called from a side-effect handler before delegating to `Update.apply`. The view is a pure projection again; Update stays no-I/O. Rescue list was widened to `Psych::Exception`, `SystemCallError`, and `IOError` so a corrupt project config (chmod 000, hand-edited `!ruby/object:` tag, dangling path) falls back to the canonical `your project's development agent` label instead of crashing the TUI on Enter.
4. **`Hive::Tui::RedStatusDetailKeys`** is the new shared module for the detail-screen key list — referenced by both the view (footer rendering) and `KeyMap` (refusal-flash hint copy) so a future key rename in one surface cannot drift away from the other.

**Refreshed pages:**
- `wiki/commands/tui.md` — updated red-status detail mode docs to the new two-action contract.
- `wiki/modules/diagnosis_agent.md` — removed the TUI `R` key entry-point reference; only `hive status --diagnose <slug> --write` remains as the consumer.
- `wiki/decisions.md` ADR-027 — replaced the three-gesture (`Enter` / `f` / `R`) action surface with the new unified two-action contract.
- `docs/solutions/architecture-patterns/red-status-diagnose-then-act-2026-05-16.md` — pattern doc Section 5 reflects the two-action contract; refresh-via-headless-agent is now documented as a CLI-only affordance.
## [2026-05-22T22:34:07Z] tui — `i` opens a full-screen read-only info panel

**Action:** Documented the upgraded grid-mode `i` affordance. The footer now advertises `[i] info`; `OpenIdeaPreview` still enters `:idea_preview`, but the view is now a full-screen read-only info panel instead of a 6-row bottom strip. The panel renders task identity (slug, stage, `created_at`, absolute stage folder, latest `.hive-state/logs/<slug>/*.log` path, original idea text) plus stage-specific plain-text extras (`brainstorm.md`, `plan.md`, or the latest execute-log tail). It performs one read pass at open time, mutates no files, spawns no subprocess, and closes only on `q`, `Esc`, or `i`; other keys are no-ops.

**Refreshed pages:**
- [[commands/tui]] — footer, mode table, keybinding table, read-only info-panel behavior, and test surface updated.

## [2026-05-22T13:30:00Z] rebase / review — close three post-merge follow-up gaps from PR #104 review

**Action:** Documented three follow-up fixes after the initial PR #104 review pass surfaced sharper failure modes than the first round caught.

1. **Rebase post-loop dirty guard.** The conflict-resolution loop's success path now runs `git.dirty?` before returning `Result.succeeded`. Without this, an agent that staged its resolution AND left untracked scratch files produced a "succeeded" envelope with a contaminated worktree, and later stages silently absorbed the cruft. The new `:dirty_after_success` reason runs the standard fail-soft sequence (abort + reset to ORIG_HEAD + clean), undoing the rebase rather than carrying the contamination forward. The agent-called-continue-itself branch already required `!dirty?` (PR #69 B9); the post-loop guard extends the same contract to the orchestrator-driven path.

2. **Review preflight refuses untrusted compare ref source.** `Hive::Stages::Review.reviewer_compare_ref` previously fell back to `Hive::GitOps#detect_default_branch` even when its result came from `git rev-parse --abbrev-ref HEAD` — which in a worktree is the task branch. When `origin/HEAD` was unset AND neither `origin/main` nor `origin/master` existed, reviewers ended up diffing the task branch against itself. The new `Hive::GitOps#origin_default_branch` returns the default branch only when derived from a trusted remote source (origin/HEAD symref or a remote-tracking branch probe), otherwise `nil`. `reviewer_compare_ref` uses this stricter method and exits 1 with the two remediation paths named when no trusted source exists.

3. **Ref existence probe uses full ref path.** `ref_exists?("origin/main")` was ambiguous with a tag named `origin/main` (rev-parse short-form resolves both). Callers now pass the full `refs/remotes/origin/<branch>` path so a like-named tag cannot satisfy a remote-tracking ref check.

**Refreshed pages:**
- [[modules/rebase]] — new `:dirty_after_success` reason and the post-loop contamination guard documented under "Post-loop contamination guard."
- [[modules/git_ops]] — `origin_default_branch` introduced as the trusted-source primitive; `detect_default_branch` rewired to call it first; `ref_exists?` doc clarifies the full-path requirement for remote-tracking checks.
- [[stages/review]] — Phase 2 prose now describes the preflight refusal path when no trusted compare-ref source is available.

## [2026-05-22T13:30:00Z] git_ops — default_branch probes origin/main and origin/master before HEAD fallback

**Action:** Documented the `detect_default_branch` ordering fix and the new `ref_exists?` helper. `Hive::GitOps.new(worktree_path).default_branch` previously returned the worktree's task branch when `origin/HEAD` was unset (common after `git worktree add`), defeating the same stale-base hardening PR #104 introduced for reviewer compare refs. The probe step inserts before the `git rev-parse --abbrev-ref HEAD` fallback so worktrees without `origin/HEAD` still resolve to the project default. Also covers `ref_exists?` as a public primitive shared with [[stages/review]].

**Refreshed pages:**
- [[modules/git_ops]] — new probe step in `detect_default_branch` ordering; `ref_exists?` added to the public API surface.

## [2026-05-20T09:11:00Z] brainstorm — read-only Stop-hook + bounded trust loop

**Action:** Documented two safety fixes on `fix/brainstorm-tmux-interactive-live-smoke`. `Hive::StopHookInstaller` now `chmod 0o444`s the installed `.claude/settings.json` (dropping it first for idempotency) so a prompt-injected `idea.md` cannot rewrite the Stop hook command and execute arbitrary shell on graceful exit. `BrainstormTmux#prepare_claude_session!`'s trust-prompt branch now respects `claude_ready_wait_timeout` instead of looping Enter forever when the trust strings persist. The dead `--allowed-tools` kebab alias was removed from `interactive_claude_wrapper.sh`; only `--allowedTools` is wired up.

**Refreshed pages:**
- [[stages/brainstorm]] — Stop-hook installer chmod + bounded trust-prompt loop noted in the runtime description.

## [2026-05-20T00:12:57Z] TUI image paste mode boundary

**Action:** Clarified that Ctrl+V is inert outside the `:new_idea` composer, including while the help overlay is visible. This preserves the image-paste boundary documented for the composer and keeps overlays from closing on an image-paste probe.

**Refreshed pages:**
- `wiki/commands/tui.md` — documented the Ctrl+V no-op behavior outside `:new_idea`.

## [2026-05-20T00:00:00Z] README rewritten with TUI-first framing

**Action:** Restructured `README.md` so the user-facing entry point is the `hive tui` dashboard, the second-tier entry point is "Drive Hive From Your Coding Agent" (folding in the existing install-prompt block plus day-to-day operate-via-agent guidance), and direct CLI use is demoted to a Power-User / Scripting CLI summary that links out to `docs/cli.md` instead of duplicating the per-command table. The hero now explains what Hive does and the folder-as-agent + compound-engineering mental model before any install line. The Documentation section replaces bare bullet links with 1–3 sentence prose descriptions per linked doc.

**Refreshed pages:**
- None — README sits outside `wiki/`. This entry logs the rewrite for traceability with the rest of the docs surface.

## [2026-05-19T23:51:41Z] review — reviewer prompts prefer origin/default as the compare ref

**Action:** Fixed a stale-local-main review failure mode: review prompts now compare against `origin/<default_branch>` when the remote-tracking ref exists, falling back to the configured/default local branch only when the remote ref is absent. This keeps long-lived operator checkouts from feeding reviewers `git diff main..HEAD` when local `main` is behind `origin/main`, which previously produced phantom findings for already-merged upstream changes.

**Refreshed pages:**
- [[stages/review]] — documents the remote-first compare ref used by reviewer prompts.

## [2026-05-19T23:35:54Z] rebase — conflict helper uses development-agent exit-code contract

**Action:** Fixed `Hive::Rebase` conflict-resolution spawns to keep using the configured development agent (`cfg.execute.agent`) while forcing `status_mode: :exit_code_only`. The helper's correctness signal is not a reviewer artifact file; it is the development agent exiting successfully followed by the orchestrator's existing checks for rebase state, conflict markers, and `git rebase --continue`. Without this override, Codex's profile default (`:output_file_exists`) could report `agent_failed` after a successful conflict-resolution attempt because the rebase helper intentionally does not pass `expected_output`. The failure path now also prints the agent error detail before the fail-soft abort/reset.

**Refreshed pages:**
- [[modules/rebase]] — conflict-resolution spawn now documents the `:exit_code_only` status contract for development agents.
- [[commands/run]] — auto-rebase conflict-agent bullets now include the status-mode override.

## [2026-05-19T23:20:28Z] tui — Ctrl+V also triggers composer image paste

**Action:** Documented that Ctrl+V in the `:new_idea` composer now runs the same image clipboard probe as an empty bracketed paste, covering terminals that send literal Ctrl+V instead of a bracketed-paste burst for image-only clipboards. The staging convention, `[imageN]` placeholders, and submit rewrite remain unchanged.

**Refreshed pages:**
- [[commands/tui]] — added Ctrl+V as an additional image-paste trigger in the new-idea composer.

## [2026-05-19T22:22:00Z] plan — missing output surfaces as error

**Action:** Documented the recovery hardening for `3-plan` rows whose agent is interrupted before producing `plan.md`. Markerless plan rows with a zero-byte `plan.md`, or a missing `plan.md` after a `plan-*.log` proves the plan run started, now classify as `Error` with `PLAN_MISSING_OUTPUT`, so the TUI does not open an empty editor buffer as if user input were required. Freshly promoted `3-plan` folders with no plan output yet remain runnable as `Needs your input`; `PLAN_MISSING_OUTPUT` recovery reruns `hive plan ... --from 3-plan` directly because there is no `ERROR` marker to clear.

**Refreshed pages:**
- [[stages/plan]] — explains the interrupted-plan missing-output state and rerun path.

## [2026-05-19T22:00:00Z] finalize — missing PR metadata surfaces as error

**Action:** Documented the recovery hardening for `7-finalize` rows missing `pr.md`. `Stages::Finalize` now records `ERROR reason=missing_pr_md` / `missing_pr_url` instead of exiting before the state file exists, and `TaskAction` classifies a markerless `7-finalize` folder without `pr.md` as `Error` so the TUI does not open an empty editor buffer.

Status also no longer treats any `7-finalize` `COMPLETE` marker as archive-ready. The marker must carry `is_draft=false` and a `pr_url` matching `pr.md` frontmatter; carried-over `5-open-pr` markers with `is_draft=true` stay ready to finalize, and missing/mismatched PR metadata becomes a red diagnostic.

**Refreshed pages:**
- [[stages/finalize]] — preconditions and marker-action table now mention missing PR metadata error markers.

## [2026-05-19T21:40:00Z] install — avoid remote-script pipe in bash channel

**Action:** Follow-up from review fix-guardrail inspection. `hive update` now downloads the pinned `install.sh` into a temporary directory and runs that file instead of using a remote-script pipe. The agent installer prompt and operating guide now show the same download-then-run flow for glibc Linux installs, while still pinning to the release tag.

**Refreshed pages:**
- [[operating]] — bash install channel example now uses a tempfile download before execution.

## [2026-05-19T19:15:00Z] init — prompt for Claude brainstorm runtime

**Action:** Documented the `hive init` prompt addition for `brainstorm.runtime`. Fresh projects now render the selected runtime into `.hive-state/config.yml`: `headless` by default, or `tmux_interactive` when the planning agent is Claude and the operator chooses the tmux path. If planning is not Claude, init keeps `headless` because the tmux runtime hardcodes the Claude binary.

**Refreshed pages:**
- [[commands/init]] — prompt order, non-TTY summary, runtime choices, and test coverage notes.
- [[stages/brainstorm]] — notes that runtime can be selected during init.

## [2026-05-19T18:30:00Z] brainstorm — harden tmux interactive live prompt path

**Action:** Documented the live-smoke fix for `brainstorm.runtime: tmux_interactive`. Hive now waits for Claude's interactive prompt before pasting, auto-confirms Claude's first-run folder-trust prompt for the task folder, launches interactive Claude with `--permission-mode bypassPermissions` plus `--allowedTools Read,Write,Edit,LS` so task-folder reads and `brainstorm.md` writes do not block on approval prompts while Bash stays unavailable, and uses a short paste-to-Enter delay so Claude Code's input box receives the prompt before submission. The defensive orphan sweep now uses `pgrep/pkill --` before a POSIX-compatible `--add-dir...` regex so process matching does not parse the pattern as an option.

**Refreshed pages:**
- [[stages/brainstorm]] — tmux runtime prompt-readiness, trust confirmation, bypass-permissions/read-write tool restriction, and paste-submit delay.

## [2026-05-19T16:00:00Z] status — surface legacy stage dirs in JSON + text + TUI (PR #93)

**Action:** `hive status` now detects task folders left behind by a stage rename in `Hive::Stages::DIRS` and surfaces them on every operator surface, instead of silently truncating them out of view. `Status#detect_legacy_stage_dirs` scans `<hive_state>/stages/` for directories outside `Hive::Stages::DIRS` containing slug-shaped subfolders (per the new `Hive::Stages.task_slug?` predicate — single source of truth shared with `Hive::Commands::Migrate`, so the count matches what `hive migrate` would actually move). The JSON payload's `Project` entry now always carries an additive `legacy_stage_dirs` array (`[]` when clean, otherwise `[{stage_dir, task_count}, ...]` sorted alphabetically). Text output prints a `⚠ N task(s) hidden in legacy stage dirs: ...` warning + `run hive migrate` hint under the project header; the TUI projects pane prefixes the affected project with `⚠` and a `legacy dirs — run hive migrate` hint by extending `ProjectView` with the new field. Schema `urn:hive:schema:status:v2` gains the optional `legacy_stage_dirs` property on `Project` without bumping `SCHEMA_VERSIONS["hive-status"]` (additive-optional policy in `lib/hive.rb`, precedent in PR #69's `rebase` block).

**Refreshed pages:**
- [[commands/status]] — new "Legacy stage directories" section documenting JSON shape, text warning, TUI hint, and the schema additive-field rationale.

## [2026-05-19T12:41:25Z] review — PR #84 follow-up contract hardening

**Action:** Documented the follow-up PR #84 fixes that tightened the red-status diagnostic contract after code review. Bot diagnose callbacks now carry `--stage`, refresh uses `--force`, and child completion replies render the `hive-status-diagnose` envelope instead of a generic completion message. `DiagnosisAgent` now validates worktree pointers before `chdir`, bounds inherited-stdio timeout hangs, redacts failed-agent stderr, and refuses custom execute profiles whose `generated_by` value is outside `Hive::Schemas::DIAGNOSTIC_GENERATORS`. `TaskAction` now rejects symlink-escaped diagnostic artifacts before tailing them.

**Refreshed pages:**
- [[commands/status]] — `generated_by` closed enum, validated diagnose cwd, and custom-profile rejection.
- [[modules/diagnosis_agent]] — validated cwd, schema-listed generators, and `--force` TUI refresh command.
- [[modules/task_action]] — artifact realpath containment and schema-listed generator trust.
- `docs/solutions/architecture-patterns/red-status-diagnose-then-act-2026-05-16.md` — generated_by trust rule.

## [2026-05-19T00:00:00Z] tui — keep All projects idea picker open while loading

**Action:** Documented the follow-up behavior that `n` from `★ All projects` enters the concrete project picker even before the first status snapshot arrives. The picker now uses a loading state instead of falling through to the title composer without a selected project.

**Refreshed pages:**
- [[commands/tui]] — clarified the picker loading state before projects are available.

## [2026-05-19T00:00:00Z] review — ce-code-review row fixes for PR #84

**Action:** Applied 14 rows from the post-merge ce-code-review. Highlights: redact-before-truncate ordering for diagnostic summary/detail (row 1, prevents boundary-straddling secrets escaping); SIGINT/SIGTERM trap inside `DiagnosisAgent#run_with_timeout` so Ctrl-C kills the child pgroup instead of orphaning the agent (row 3); `StaleMarker` and `DiagnosisInFlight` now override `exit_code` → `Hive::ExitCodes::TEMPFAIL` (75) so wrappers branch on retry (row 4); diagnose error envelope grows a separate `StatusDiagnoseErrorKind` enum with `stale_marker` / `in_flight` / `slug_not_found` / `ambiguous_slug`; background-thread terminate_process_group avoids blocking the main thread for 5s on every cancellation (row 6); R-press path now passes `--force` so the marker_signature short-circuit cannot silently skip the spawn (row 8); refresh-during-autofix now refuses with operator-visible flash (row 13); marker-rotation-to-`agent_working` mid-spawn aborts at the dispatch-time freshness gate (row 12); `marker_signature` lifted to `Hive::TaskAction.marker_signature` class method, `DiagnosisAgent` delegates instead of duplicating (row 16); `red_status_detail` footer drops [Enter] for `recover_execute` rows (row 25); bot recovery notification appends `diagnostic.summary` inline (row 23); bot show-details callback uses `hive status --diagnose <slug>` for bounded reply instead of full snapshot (row 24); schema tests pin cross-schema Diagnostic equivalence + `generated_by` enum agreement with `Hive::Schemas::DIAGNOSTIC_GENERATORS` (row 17).

## [2026-05-17T00:55:00Z] tui — require project choice for new ideas from All projects

**Action:** Updated the TUI new-idea behavior so `n` from `★ All projects` opens a concrete project picker before the title composer. The old implicit first-registered-project fallback could land ideas in the wrong repo while the header still read All projects. The chosen project is carried only for that new idea, so the dashboard can remain scoped to All while `hive new <project> "<title>"` targets the explicit selection.

**Refreshed pages:**
- [[commands/tui]] — documented the project picker and removed the old `★ All` first-project fallback wording.

## [2026-05-17T00:00:00Z] review — deferred-finding fixes for PR #84

**Action:** Resolved the 14 deferred findings from PR #84's multi-agent code review. P1s: gate `--write` on red-state tasks (#1), add cross-process flock in `Hive::DiagnosisAgent#run!` raising `DiagnosisInFlight` on contention (#2 + #11), extend `pem_private_key` regex to block-form `/m` and add `password_assignment` / `bearer_token` / `session_cookie` patterns (#3), coerce `tail_file` and `SecretPatterns.redact` to UTF-8 with invalid-byte replacement so one corrupt log byte no longer aborts `hive status --json` (#4). P2s/P3: added `tasks[].worktree_path` to v2 schema as an agent-callable primitive for the manual-fix path (#8); `recover_execute` rows now emit `suggested_next_action.kind = "manual_fix"` (#9) and open the TUI red-status detail view (#10); consolidated three near-identical max_passes-with-escalations predicates into `Hive::TaskAction.max_passes_review_stale_with_escalations?` (#17); split `marker_signature` into observed-vs-acknowledged so a second marker rotation between polls fires the flash again (#7); added `Hive::SecretPatterns.redact` shared helper replacing the two duplicate inline redactors in `TaskAction` and `DiagnosisAgent` (#13); added `--force` to `hive status --diagnose --write` for the idempotency short-circuit when a fresh artifact already covers the marker (#21).

Skipped per product direction: schema versioning #5 (product unreleased, in-place additions to v2 are policy-permitted). Deferred: subprocess timeout helper consolidation #18 (`DiagnosisAgent#run_with_timeout` vs `Hive::Tui::Subprocess#bounded_capture3` — they have legitimately different signatures (chdir, stdin_data), low-value cleanup for a separate change).

**Refreshed pages:**
- [[modules/secret_patterns]] — `redact` API, four new patterns, block-form PEM, binary-input coercion.

## [2026-05-16T00:00:00Z] review — red-status diagnostics wiki refresh

**Action:** Captured the new `Hive::DiagnosisAgent` module (lib/hive/diagnosis_agent.rb, ~307 lines) and `Hive::TaskAction#diagnostic` public surface from PR #84. Adds a dedicated wiki/modules/diagnosis_agent.md covering invariants (no marker writes, no task lock, ADR-019 nonce wrap, pgroup+SIGTERM cleanup, freshness gate, atomic write), the on-disk artifact contract, and consumers. Refreshes wiki/modules/task_action.md to document the new `#diagnostic` method, its bounded-extraction caps (`DIAGNOSTIC_SUMMARY_MAX=120`, `DIAGNOSTIC_DETAIL_MAX=4000`, `ARTIFACT_PATHS_MAX=20`), the `marker_signature` SHA256 freshness key shared with `DiagnosisAgent` and the TUI live-update gate, the `recover_execute` JSON-emission-without-TUI-detail-view rationale, and the `suggested_next_action` retry-recipe contract.

**Refreshed pages:**
- [[modules/diagnosis_agent]] — new page covering the headless diagnose-spawn module.
- [[modules/task_action]] — added `#diagnostic` to Public surface, new Red-status diagnostic section, backlinks to [[modules/diagnosis_agent]] / [[modules/secret_patterns]] / ADR-025 / ADR-027.
- [[index]] — page count 59 → 60, added [[modules/diagnosis_agent]] entry.
- [[cli]] — `hive status` command table row updated to document `--diagnose`, `--write`, `--force`, `--project`, `--stage` options.

## [2026-05-14T23:30:00Z] brainstorm — tmux interactive runtime (U1–U8)

**Action:** Documented the new interactive tmux runtime for 2-brainstorm. The stage can now spawn the agent inside a detached tmux session (U3) via the `Stages::BrainstormTmux` runner, with U2's interactive Claude wrapper, U4's stop-hook install, U5's tmux sentinel fallback, U7's hardened preflight/teardown, and U8's operator notes. `lib/hive/tmux_runner.rb` (U1) is the shared runtime primitive. Selection is gated by a per-project config flag (U6) surfaced through `templates/project_config.yml.erb`. `hive doctor` (U7) preflights `tmux` availability + version and reports stale brainstorm sessions; the brainstorm stage cleans them up on completion. Wiki refresh in b67096c updated the brainstorm stage, doctor command, and state-model pages.

**Refreshed pages:**
- [[stages/brainstorm]] — tmux runtime path, sentinel completion contract, and waiting reasons.
- [[commands/doctor]] — tmux preflight and stale-session reporting.
- [[state-model]] — `brainstorm.runtime` config flag.

## [2026-05-14T17:30:00Z] commands/init — managed llm-wiki bootstrap during project setup

**Action:** `hive init` now initializes managed llm-wiki project context directly. New `Hive::LlmWikiBootstrap` writes `.llm-wiki/config.json` with Codex as `headless_agent`, creates project wiki starter pages plus `raw/notes/`, writes managed LLM WIKI blocks into `AGENTS.md` and `CLAUDE.md`, and writes `.claude/settings.json` with a managed `SessionStart` hook that surfaces `wiki/index.md` and recent `wiki/log.md`. The refresh scripts are Codex-owned (`codex exec --add-dir <qmd-cache> -C <project>`), preserve qmd's GPU auto-detection, grant the maintenance agent qmd cache write access, and fall back to `.llm-wiki/qmd-cache` when the normal qmd cache is not writable. The post-commit hook is installed only after the bootstrap files are committed so init's own `chore: initialize llm-wiki` commit does not immediately launch a refresh. Linux init also writes daily user-systemd service/timer files and enables the timer symlink. Tests cover managed config shape, committed context files, scheduler files, hook preservation, qmd cache fallback, and no legacy `claude -p` refresh path.

**Refreshed pages:**
- [[commands/init]] — init steps now include managed llm-wiki files, the committed bootstrap context, runtime hook installation, and the doctor preflight.
- [[modules/git_ops]] — documents the `commit_llm_wiki_bootstrap!` project-setup commit and why it runs before post-commit hook installation.
- [[decisions]] — ADR-009 now distinguishes task-state commits from one-time project-setup commits required for feature worktrees to inherit wiki context.
- [[cli]], [[index]], and [[gaps]] — command/source summaries now note the llm-wiki initialization surface.

## [2026-05-14T17:17:00Z] review — clarify live review-pass config and stale recovery docs

**Action:** Follow-up from code review on the review/daemon default PR. Removed the stale top-level `max_review_passes` key from `Config::DEFAULTS`, the project config template, README, and wiki examples so `review.max_passes` is the only documented live review-loop cap. Replaced the README troubleshooting row that still described max review pass exhaustion as `EXECUTE_STALE` with the current `REVIEW_STALE` / `hive markers clear ... --name REVIEW_STALE` recovery flow. Clarified daemon docs that `max_concurrent_per_project` is a per-project burst cap; setting it below the global cap is what enforces cross-project fairness.

**Refreshed pages:**
- [[commands/daemon]] — concurrency table wording now matches the 5/5 default.
- [[modules/config]] and [[state-model]] — config examples only expose `review.max_passes`.

## [2026-05-14T16:45:00Z] plan — agent-aware llm-wiki planning defaults for Codex and Pi

**Action:** Changed 3-plan skill resolution from one literal default (`/plan`) to `Hive::Config.stage_skill`, which keeps Claude on the legacy `/plan` wiki-first alias while using llm-wiki's canonical `/llm-wiki:wiki-plan` skill for Codex and Pi. Pi's agent profile formats that to `/skill:wiki-plan`. Existing configs that still say `plan.skill: /plan` now map to `wiki-plan` for Codex/Pi, so switching `plan.agent` no longer requires a local Codex or Pi `plan` alias. Non-legacy stage overrides, such as `/compound-engineering:ce-plan`, still win. `hive doctor` now verifies the resolved agent-aware planning skill, and tests cover Codex defaults, Pi defaults, and the legacy alias mapping.

**Refreshed pages:**
- [[stages/plan]] — plan stage now documents `Hive::Config.stage_skill`, agent-aware llm-wiki defaults, task-folder-only isolation, and current plan budget/timeout defaults.
- [[commands/doctor]] — doctor rows now document the resolved Codex/Pi `wiki-plan` invocation instead of the old `/skill:plan` example.

## [2026-05-14T15:20:40Z] review — lower default review loop cap to 2 passes

**Action:** Changed the review loop default from four passes to two passes (`Config::DEFAULTS["review"]["max_passes"]`). The first pass still runs the configured reviewer set and triage; if triage marks auto-fixable findings, the fix phase runs and the second pass verifies the result. Additional review rounds remain available through per-project `review.max_passes` overrides, but fresh projects now default to one fix+verify cycle instead of repeated reviewer loops that often re-surface plan-answered or human-decision escalations. Updated the project config template, README config example, and review/state/config wiki references.

**Refreshed pages:**
- [[stages/review]] — pass-cap default now documents 2.
- [[state-model]] and [[modules/config]] — default config examples now show `review.max_passes: 2`.

## [2026-05-14T09:00:00Z] bot — Telegram mobile surface for human-input gates

**Action:** Added the `hive bot` command and `Hive::Bot::*` module docs for the Telegram operator surface. The bot long-polls Telegram, enforces `bot.chat_id_allowlist`, watches `hive status --json`, sends inline-keyboard notifications for waiting/recovery rows, writes brainstorm answers under the task lock, and dispatches existing `hive` commands for approvals, marker clears, findings toggles, and `/idea` capture. ADR-026 records the trust boundary: the bot is a subprocess caller, not a parallel approval layer; Path B writes operator text verbatim, while Path A Codex returns confirmed drafts that only the bot writes.

**Refreshed pages:**
- [[commands/bot]] — new Thor surface page with subcommands, Telegram commands, config, structured log, and exit-code table.
- [[modules/bot]] — new module map and wiring/trust-boundary page.
- [[architecture]] — new Telegram bot pipeline section.
- [[decisions]] — ADR-026.
- [[active-areas]], [[operating]], [[cli]], [[state-model]], [[templates]], [[dependencies]], [[index]] — bot command/module/config/autostart/index updates.

## [2026-05-14T00:30:00Z] run — auto-rebase pre-step (`Hive::Rebase`) closes the long-running-task drift loop

**Action:** Added a fail-soft auto-rebase pre-step to `hive run` that runs inside `Hive::Lock.with_task_lock` before the stage runner dispatches. Detects when the task's worktree branch is behind `origin/<default_branch>`, fetches with non-interactive env (`GIT_TERMINAL_PROMPT=0` + SSH `BatchMode=yes`), attempts `git rebase`, and dispatches the project's execute-stage agent (`cfg.execute.agent`, isolated to the worktree via `add_dirs: []`) to resolve conflicts. After a successful rebase, rewrites `worktree.yml`'s `execute_base_head` to the post-rebase HEAD so 4-execute continuation passes don't trip `EXECUTE_WAITING(reason=head_not_descendant)`. Any failure (agent non-zero exit, conflict markers remaining, max attempts exceeded, protected-files conflict, agent ran `git rebase --continue` itself against the prompt directive, network/fetch failure) triggers `git rebase --abort` followed by `git reset --hard ORIG_HEAD` to clean agent-created untracked files; the stage runner proceeds against the (stale) base with a stderr warning. Closes the failure mode where long-running tasks accumulated REVIEW_STALE because reviewers saw "phantom deletions" of code that landed on main after the branch was created (originating incidents: `i-want-to-be-able-260507-7682` REVIEW_STALE pass=4 after PRs #63-#68 merged; `create-proper-readme-md-for-260513-2ba1` from a different angle). New code: `lib/hive/rebase.rb` (orchestrator + `Hive::Rebase::Result` Data.define), `lib/hive/git_ops.rb` (rebase plumbing — `commits_behind`, `fetch_default_branch`, `dirty?`, `detached_head?`, `rebase_onto`, `rebase_continue`, `rebase_abort`, `rebase_in_progress?`, `staged_unmerged_files`, `reset_hard_orig_head`), `templates/rebase_conflict_resolution.md.erb`. New error class `Hive::RebaseConflict < Hive::GitError`. Config additions: `cfg.rebase.enabled` (default `true`), `cfg.rebase.conflict_resolution_timeout_sec` (default 2700, min 60). The `MAX_CONFLICT_RESOLUTIONS = 5` cap is a hardcoded Ruby constant (not configurable per S1 from doc-review). JSON envelope: `hive run --json` SuccessPayload gains a required `rebase` block (added to `schemas/hive-run.v1.json` explicitly with `additionalProperties: false` preserved — no schema-version bump). Plan: `docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md`.

**Refreshed pages:**
- [[commands/run]] — new "Auto-rebase pre-step" subsection documents the trigger, pre-rebase guards, conflict-resolution agent contract (`add_dirs: []` isolation + protected-files abort), fail-soft cleanup (`rebase --abort` + `reset --hard ORIG_HEAD`), `execute_base_head` rewrite, operator-visible stderr signals, per-project disable, and JSON envelope shape.

## [2026-05-14T00:00:00Z] no-op — test-only diff, no wiki refresh needed

**Action:** Hook fired on a working-tree change set that is entirely test additions/fixtures (new `test/unit/gh_test.rb`; expanded `test/fixtures/fake-gh`; PR-first hardening coverage in `run_open_pr_test.rb` / `run_finalize_test.rb`; migrate coverage in `migrate_test.rb`; smaller deltas in `github_publisher_test.rb`, `prompt_injection_test.rb`, `full_flow_test.rb`, `test_helper.rb`, and `full_pipeline_happy_path.yml`). No CLI command or stage runner source changed. The PR-first verbs (`open-pr`, `finalize`), `Stages::OpenPr` / `Stages::Finalize` auth+push contract, secret-scan-before-ready, marker validation, fetch-failure fail-loud, and migrate fixes were already documented in `wiki/cli.md`, `wiki/stages/open-pr.md`, `wiki/stages/finalize.md`, `wiki/stages/index.md`, and `wiki/commands/run.md` when those commits (`40ab090`, `4e48096`, `7d04aea`, `b0f9c18`) landed. No wiki pages refreshed.

## [2026-05-13T23:00:00Z] tui — `REVIEW_STALE pass=N` diagnostic + Enter opens focal escalations file

**Action:** Two small TUI improvements for max_passes-hit `REVIEW_STALE` rows (the genuine `:complete`-classification case in `pass_completion_status`, distinct from retryable `wall_clock` / incomplete-triage shapes). **U1:** `Views::TasksPane#review_recovery_status` now returns `"stale pass=N"` (using `attrs["pass"]`) when the marker is `review_stale` with no `reason` attr — preserves the existing `wall_clock` / `triage_failed` rendering. Operator sees WHY the row is stuck at a glance instead of the flat `REVIEW_STALE`. **U2:** `BubbleModel#recover_review` previously flash-refused max_passes-hit rows with a manual-recipe message ("edit/rename highest-pass review files, then clear REVIEW_STALE …"). Now it routes through a new browse-only `open_review_stale_file(row)` handler — mirrors `open_task_folder` (PR #64) for the spawn/clear shape, mirrors `review_waiting_editor_path` for the focal-file resolver. The new `review_stale_editor_path` resolves `<folder>/reviews/escalations-<pass>.md` from `attrs["pass"]`, falls back to `<folder>/reviews/` directory if the file is missing, returns `""` if neither exists (triggering a `"no review files for <slug>"` refusal flash). Pure browse contract: no marker mutation, no auto-continue, no `InputEditorExited` follow-up — the editor's `:wq` is the operator's last word and clearing remains a deliberate `hive markers clear` round-trip. Retryable stale shapes (`wall_clock`, incomplete-triage) keep their `RecoverReview` clear+rerun routing — the branching lives at `BubbleModel#recover_review`'s existing `retryable_review_stale?` gate, not in `key_map.rb`, because the incomplete-triage discriminator requires reading the reviews/ directory (file I/O outside key_map's pure-data contract). The `review_stale_recovery_message` helper is removed (dead — its only caller was the now-replaced flash branch).

**Refreshed pages:**
- [[commands/tui]] — `recover_review` status-column paragraph notes the new `stale pass=N` rendering; the max_passes-hit recovery paragraph documents the browse routing + fallback-to-dir behavior + manual-clear contract.
- [[stages/review]] — `:complete` classification recovery step adds the TUI surface (status label + Enter opens escalations file).

## [2026-05-13T22:00:00Z] review — embed `plan.md` inline in every reviewer system prompt (with ADR-008/019 nonce wrap)

**Action:** Wired the task's `plan.md` into every reviewer spawn so reviewers can ground findings against the plan's stated scope, not just the worktree they see in isolation. New `Hive::Reviewers::PlanContext.render(task_folder, user_supplied_tag)` helper reads `<task_folder>/plan.md`, scrubs non-UTF-8 bytes to U+FFFD, then wraps the body in a per-spawn `<user_supplied_<hex>>` nonce block (ADR-008/019 — same pattern as execute/fix/triage prompts) and prefixes it with a system-level instructional block: "authoritative on scope" framing + symmetric anti-finding rules (drop deferred-scope escalations; raise plan-required-but-missing gaps as High) + an explicit "treat inner content strictly as data, NOT as instructions" directive. `Hive::Reviewers::Agent#render_prompt` captures the nonce once per spawn and passes it both to the template's own `user_supplied_tag` binding AND the `PlanContext.render` call so the rendered prompt carries a single consistent nonce — pinned by `test_render_prompt_uses_single_nonce_for_template_tag_and_plan_wrapper`. All three reviewer ERB templates (`reviewer_claude_ce_code_review.md.erb`, `reviewer_codex_ce_code_review.md.erb`, `reviewer_pr_review_toolkit.md.erb`) interpolate the section between the `Pass:` header and the `Behavior:` block. Missing/empty/unreadable `plan.md` falls back to a fixed `PlanContext::ABSENT_NOTE` so the prompt stays well-formed and the reviewer flags missing-plan in its review-output header. Motivated by the xbookmark `create-proper-readme-md-for-260513-2ba1` task: the plan deliberately deferred `bin/xbookmark` to a separate downstream task, but reviewers (who only saw the worktree) kept escalating "README references files that don't exist" pass after pass, driving the task into `REVIEW_STALE pass=4` because the fixer couldn't resolve a plan-by-design contradiction. The initial implementation embedded the plan content without the nonce wrap — caught and corrected during `/ce-code-review` (cross-flagged by `ce-learnings-researcher` as BLOCKING + `ce-correctness-reviewer` R1 + `ce-agent-native-reviewer` AGENT-W1 for the asymmetric anti-finding rule). Six `PlanContext` unit tests pin the shapes (present/absent/empty/unreadable/non-UTF-8-bytes/trailing-whitespace-rstrip); three new agent tests pin the embed-in-all-three-templates contract + the single-nonce invariant + absent-note ordering.

**Refreshed pages:**
- [[stages/review]] — Phase 2 paragraph documents the plan-context embed: where it goes in the prompt, why it matters (without it, reviewers re-derive scope from worktree alone and escalate intentional gaps), and the absent-note fallback.

## [2026-05-13T21:30:00Z] wiki/log — REVERTED note for rolled-back PR #63 / #64 intermediate entries

**Action:** Pass-3 polish on the marker-finalize and `o`-browse work removed three intermediate log entries (timestamps 21:15, 22:00, 23:00) that had been written for in-flight versions of those features and superseded by the final landings. The removals were applied via direct edit rather than via an explicit `REVERTED` line, which contradicts this file's append-only contract. This entry records the deletion so the contract remains observable in the log itself. Reverted entries described intermediate design choices for marker-finalize ordering (build-dispatch-then-flip-marker landed in the final 18:30 entry) and `o`-browse early variants (final shape landed at 20:30). No content was lost — the surviving 18:30 and 20:30 entries are the authoritative record.

**Refreshed pages:** none (this entry is the refresh).

## [2026-05-13T21:15:00Z] execute — capture implementer output and pause no-change runs

**Action:** Hardened 4-execute's completion contract after the `now-we-run-claude-codex-260508-3b8f` investigation exposed a clean agent exit whose useful answer lived only in raw logs while `task.md` stayed empty. `Hive::Agent` now returns the final stream-json/plain-text message and tags whether it came from a structured agent event or plain output. `Stages::Execute` appends that message under `## Execute Output`, records the task branch's `execute_base_head` in `worktree.yml`, verifies the post-spawn HEAD is still on the expected branch and descends from that baseline, requires a clean worktree, and only writes `EXECUTE_COMPLETE` for a new baseline-descendant commit or explicit `execution_mode: research` plan with structured output. Clean no-commit exits now pause as `EXECUTE_WAITING reason=no_worktree_changes`; dirty exits pause as `reason=dirty_worktree`; detached/wrong-branch exits pause as `reason=branch_mismatch` / `head_not_descendant`; research plans without structured output pause as `reason=missing_research_output`. `Hive::ExecuteWaitingAction` now drives `hive run --json`, `hive status --json`, and TUI Enter behavior for these reasons so agents and humans do not blindly edit `task.md` when the repair belongs in the worktree, `plan.md`, or a rerun.

**Refreshed pages:**
- [[stages/execute]] — documents final-message capture, no-change / dirty-worktree waiting reasons, and `execution_mode: research`.
- [[state-model]] — restores `EXECUTE_WAITING` as a live implementation-output marker, narrows `EXECUTE_COMPLETE` semantics, and records `execute_base_head`.
- [[modules/agent]] — documents final-message capture and `final_message_source`.
- [[modules/git_ops]] — documents worktree HEAD/status/branch/ancestry helpers.
- [[modules/worktree]] — documents `execute_base_head` in `worktree.yml`.
- [[modules/markers]] — documents current `EXECUTE_WAITING` reason schemas.

## [2026-05-13T20:30:00Z] tui — `o` opens the focused task folder in `$EDITOR` (read-only browse)

**Action:** Added a single-keystroke browse gesture to the TUI. Lowercase `o` in grid mode opens the focused row's hive-state task folder (`row.folder`) in `$VISUAL` / `$EDITOR` / `vi` via the existing `foreground_takeover_command` machinery (same path `Enter`-on-`needs_input` uses). The gesture is purely additive: no marker mutation, no workflow-verb dispatch, no auto-continue plumbing on the editor's exit — the editor's `:wq` is the user's last word. Distinct from `Enter` (workflow-contextual: editor on `needs_input`, log tail on `agent_running`, recover+rerun on review/error rows) and the verb keys `b`/`p`/`d`/`r`/`P` (subprocess dispatch). Motivated by investigation-style tasks whose output is a markdown artifact (the user wants to *read* `plan.md` in `8-done` without dropping to a shell — origin: `now-we-run-claude-codex-260508-3b8f`). New `Hive::Tui::Messages::OpenTaskFolder = Data.define(:row)` mirrors `OpenInputEditor`'s shape; new `BubbleModel#open_task_folder` mirrors `open_input_editor` minus the mtime/hash/checkbox capture and `InputEditorExited` dispatch. Empty `row.folder` flashes `"no task folder for <slug>"` and refuses to spawn (defensive — should never fire for a well-formed row). Help-overlay entry added to `Hive::Tui::Help::BINDINGS` (mode `:grid`, action `:open_task_folder`). Footer hint deliberately NOT added: the current footer string is 69 chars, just below the 70-col budget — adding `[o] open` (10 chars including separator) would exceed it; `?` overlay handles discoverability. Pinned by a new `test_default_footer_hint_omits_o_at_70_col_budget` regression test so a future contributor doesn't silently break 70-col rendering by re-adding the hint without measuring.

**Refreshed pages:**
- [[commands/tui]] — keybinding table gains an `o` row; new prose paragraph after the `needs_input` editor section documents the Enter-vs-`o` distinction (workflow-contextual dispatch vs read-only browse) and the gesture's no-mutation / no-auto-continue contract.

## [2026-05-13T18:30:00Z] tui — auto-advance flips plan marker `:waiting → :complete` before dispatching `hive develop`

**Action:** Fixed a silent-failure bug in the TUI's plan-stage auto-continue path. When the user pressed Enter on a `:waiting` 3-plan row, edited (or just `:wq`-ed without changes), `Hive::Tui::BubbleModel#dispatch_develop_for` dispatched `hive develop` as a background subprocess. But `hive develop --from 3-plan` refuses to advance while the marker is `:waiting` (per `Hive::StageAction`'s requirement that the source stage be `:complete`), so the background subprocess failed silently — the marker stayed `:waiting`, the task stayed in `3-plan`, and the user saw "nothing happened" with no surface explanation. Diagnosed via the `i-want-to-be-able-260507-7682` / `now-we-run-claude-codex-260508-3b8f` bug report. Fix: `dispatch_develop_for` now calls `Hive::Markers.set(row.state_file, :complete)` before building the develop DispatchCommand. The "approve as-is" gesture (`:wq` with no edits) now correctly reflects on disk as `:complete` BEFORE `hive develop` is invoked. A typed `rescue SystemCallError, IOError` on the marker write surfaces a suppression flash (`couldn't finalize plan marker (<Errno::class>)`) so a real disk failure doesn't get silently absorbed and re-classified as "no auto-continue".

**Refreshed pages:**
- [[commands/tui]] — `needs_input` paragraph rewritten as three bulleted stages (2-brainstorm / 3-plan / 6-review) each describing their auto-continue gate. The 3-plan paragraph documents the build-dispatch-then-flip-marker order, the compare-and-set guard against marker races during edit, the `MarkerRaceError` flash, and the `:revise_plan` vs `:advance_to_develop` branching.

**Round-2 polish on PR #63** (pr-review-toolkit follow-up): reversed the order of `develop_command_from_plan` and `finalize_plan_marker` (build the dispatch FIRST, flip the marker SECOND — a malformed `suggested_command` no longer leaves the plan with `:complete` but no dispatch). Added a compare-and-set re-read in `finalize_plan_marker` that raises `MarkerRaceError` when the marker drifted between `plan_outcome`'s race check and the finalize write — narrowing the observable TOCTOU window from "duration of editor session" to "one read+rename". Surfaced races to the user as `plan marker changed during edit (<observed>)` instead of silently overwriting a newer marker. Two new regression tests pin both invariants (marker stays `:waiting` on malformed-command; no overwrite + flash on marker race).

## [2026-05-13T17:45:00Z] tui+new — image paste for new-idea composer

**Action:** Documented rich image input for `hive tui` new-idea capture. The composer now probes clipboard image bytes or drag-dropped image paths, stages each image as `[imageN]`, rewrites placeholders to `![](assets/bug-N.<ext>)` on submit, and persists files under `1-inbox/<slug>/assets/` through `Hive::Commands::New#call!`. The CLI `hive new PROJECT TEXT...` argv surface remains text-only.

**Refreshed pages:**
- [[commands/tui]] — added the image-paste subsection, placeholder validation behavior, staging lifecycle, and the `.jpg`/`.webp` extension preservation note. macOS clipboard image paste is currently inert (`pbpaste` only returns text); a Linux Wayland/X11 host with `wl-clipboard` or `xclip` is required for clipboard-bytes paste.
- [[commands/new]] — documented `call!`, `body_override:`, and `attachments:` for TUI-internal rich captures while noting that plain CLI captures still omit `assets/`. Attachment-filename failures now raise the dedicated `InvalidAttachmentError` instead of `InvalidSlugError`.

## [2026-05-13T13:00:00Z] review+tui+wiki — /pr-review-toolkit round-5 polish-tier sweep

**Action:** Cleared all polish-tier findings from rounds 1-4 in one pass. Code changes: (H3) `review_marker_still_open?` replaced with tri-state `review_marker_state` returning `:open | :drifted | :unreadable`; `:marker_unreadable` is a new outcome in `auto_continue_outcome` and `input_editor_exit_messages` so the user-facing flash names the real cause ("couldn't read marker — check task.md permissions") instead of misleading them with "marker changed". (H2 + #5) `read_checkbox_state` now returns a counts-Hash (`{checked: N, unchecked: M}`) instead of an order-sensitive Array — cut-paste of a `[x]` line no longer trips `:rerun_review`. ENOENT and EACCES are now distinct rescues with the latter logging via `Hive::Tui::Debug`. (H1+M4) `max_attempts_from_spec` warns to stderr on the defensive-fallback path; `TypeError` removed from the rescue list (dead with the nil-guard). (M1) `clear_reviewer_infra_errors` switched from `if File.exist? File.delete` to a try-delete + ENOENT-swallow pattern, closing a TOCTOU window; other SystemCallError raises a named `Hive::Error`. (M2) Two `File.delete(output_path)` sites in `Reviewers::Agent#run!` extracted to a single `clear_partial_output!(stage)` helper with the same typed-error pattern. (M3) Narrowed the `rescue ArgumentError` in `dispatch_rerun_review_for` to only wrap the `Shellwords.split` call so future `Flash.new` validation errors aren't mis-attributed. (code-reviewer #2) Added a typed `rescue Hive::ConfigError` before the generic `StandardError` in `Stages::Review.run!` so config errors land as `:review_error reason=config_error` instead of `runner_exception`. (#13) Dropped the dead `respond_to?` legacy fallbacks from `review_marker_state` (all production and test callers now pass a Row). Comment cleanup: `auto_continue_outcome` docstring lists `:rerun_review` + `:marker_unreadable` and explains `checkboxes_changed`; U5 "three checks before advancing" corrected to "two checks + entry guard"; deadline example values match defaults; `expected_matches:` comment names the orchestrator's hard-rejection path so the `nil` branch's role as test-only is explicit; pre-edit checkbox-capture comment no longer claims 6-review scope (the capture is unconditional); `wiki/commands/tui.md` mtime/checkbox conflation untangled; redundant "Indirected so tests can stub the wait" and "Idempotent: missing file is fine" comments removed. Tests added: deadline-aborts-on-past-deadline, deadline-clamps-spawn-timeout, no-deadline-uses-configured-timeout, output_path-cleared-on-every-retry, dispatch_rerun_review_for-rescue-emits-suppression-flash, input_editor_exit_messages-6-review-{happy / silent / unreadable}, `:marker_unreadable`-outcome on directory state_file, `read_checkbox_state` set-equivalence, `clear_reviewer_infra_errors` empty-specs case.

**Refreshed pages:**
- [[commands/tui]] — `needs_input` paragraph clarifies that mtime and checkbox-state are independent signals (mtime drives the `InputEditorExited(changed:)` flash; checkbox-count Hash drives the 6-review `:rerun_review` gate).

## [2026-05-13T12:00:00Z] review+wiki — /pr-review-toolkit round-4 hardening

**Action:** Folded a fourth review pass (pr-review-toolkit) into PR #62. Critical: pre-PR-A `REVIEW_WAITING reason=fix_guardrail` markers (including the xbookmark task) lack the new `head=` attribute introduced by round-3 P1 #1. Treating that absence as a HEAD-mismatch would auto-error every in-flight paused task on first resume after upgrade. The runner now skips the HEAD check (with a stderr notice) when `marker.attrs["head"]` is empty, so legacy markers proceed through the other gates (matches count, all-`[x]`, worktree-clean). Silent-failure-hunter critical: `record_reviewer_infra_error` now wraps the `errors-NN.md` write in `rescue SystemCallError` and re-raises as a named `Hive::Error` — disk failures (ENOSPC, EROFS, EACCES, EDQUOT) no longer get re-classified as generic `runner_exception` and no longer let a downstream `reviewer_partial_failure` pause silently miss its trigger because the file write was lost. `adapter.run!(deadline:)` dispatch now uses `Method#parameters` introspection to feature-detect the `deadline:` kwarg instead of `rescue ArgumentError` — closes the silent-bug case where a real `ArgumentError` from inside the adapter's body would be swallowed and retried no-kwarg. Six new integration tests added covering pause→approve→advance, partial-tick→stay-paused, HEAD-mismatch, dirty-worktree, malformed-matches, and legacy-marker.

**Refreshed pages:**
- [[stages/review]] — Approval-on-resume (U5) paragraph rewritten to enumerate all four gates (all-`[x]`, count match, HEAD match, worktree clean) plus the `pass==max_passes` Phase 5 break and the legacy-marker compatibility note.
- [[commands/run]] — `:review_waiting` row split by `marker.attrs["reason"]` (escalations-only / fix_guardrail / reviewer_partial_failure) to document the new `--json` envelope branches.
- [[modules/markers]] — `REVIEW_WAITING` schema row rewritten for the three `reason` shapes; `REVIEW_ERROR` schema row enumerates the round-3 `phase=resume reason=…` family.

## [2026-05-13T11:20:50Z] review+tui+config+commands — /ce-review round-3 hardening (PR-A polish)

**Action:** Folded a third /ce-review pass into PR #62 (commit ce7791f). Nine findings, all addressed:

1. **Fix-guardrail approval bound to guarded HEAD.** `REVIEW_WAITING reason=fix_guardrail` markers now record `head=<sha>` at trip-time; the approval-on-resume path verifies the current worktree HEAD still matches before honouring `[x]` ticks. Mismatch records `REVIEW_ERROR phase=resume reason=approval_head_mismatch` — closes a laundering path where the user could amend/rebase between trip and approval and advance a different diff than the one the guardrail flagged.
2. **`output_basename` path-escape validation.** `Hive::Config.validate_reviewers!` now rejects values containing `/`, `\`, NUL, `.`, or `..` segments. Without this, the retry-loop's `File.delete(output_path)` could escape `reviews/` via e.g. `output_basename: '../escape'`.
3. **Wall-clock-aware reviewer deadline.** `Hive::Reviewers::Agent#run!` now accepts `deadline:` (monotonic timestamp); `run_reviewers` derives it from `started_at + max_wall_clock_sec` and threads it through. Each spawn's effective timeout AND backoff sleep are clamped to `deadline - now`, so one reviewer's `max_attempts × timeout_sec` can no longer consume the entire wall-clock budget before the between-reviewer check fires. `ArgumentError` on the unknown kwarg falls back gracefully for custom adapters that don't accept `deadline`.
4. **Mixed reviewer success/failure pauses (no silent auto-complete).** In the all-clean branch, if `reviews/errors-NN.md` exists (at least one reviewer's adapter failed this pass), the runner now sets `REVIEW_WAITING reason=reviewer_partial_failure` and pauses for user decision (retry, accept partial coverage, or fix reviewer config). The all-clean signal from surviving reviewers is no longer mistaken for proof the worktree is clean.
5. **Resume-specific JSON envelope branching.** `hive run --json` now branches on `marker.attrs[reason]` for `REVIEW_WAITING`: `fix_guardrail` emits `target=reviews/fix-guardrail-NN.md` with explicit count + HEAD verification documented; `reviewer_partial_failure` emits `target=reviews/errors-NN.md` with retry-or-accept guidance; escalations-only keeps the legacy generic envelope. Agents consuming the JSON contract get resume-specific instructions instead of a generic "edit the task folder".
6. **`run_reviewers` rescue branch deletes orphan output.** The runner's rescue branch now deletes the failed adapter's `output_path` before recording the error, covering custom adapters that don't implement `Agent#run!`'s final-failure cleanup.
7. **TUI marker-pass+reason match on 6-review save.** `BubbleModel#review_marker_still_open?` now requires `marker.pass` AND `marker.attrs[reason]` to match the row snapshot taken on Enter. A stale editor session for pass 4 that saves AFTER a concurrent process advanced the task to pass 5 no longer dispatches.
8. **Malformed `marker.attrs[matches]` is a hard error.** Missing/non-integer `matches` on a `fix_guardrail` marker now records `REVIEW_ERROR phase=resume reason=malformed_marker_matches` instead of silently disabling the truncation defense by passing `expected_matches: nil`.
9. **`clear_reviewer_infra_errors(ctx)` runs before empty-spec early return.** A project that removes all reviewers between runs no longer leaves stale `errors-NN.md` on disk.

Full suite: 1733/1733 (+ 4 new round-3 regression tests).

**Refreshed pages:**
- [[stages/review]] — Phase 4 approval-on-resume sub-paragraph extended with HEAD-binding + malformed-matches semantics; Phase 2 paragraph notes the wall-clock-aware deadline threading and the new `reviewer_partial_failure` pause.
- [[commands/run]] — `:review_waiting` row in the next-hints table split by `reason` (fix_guardrail / reviewer_partial_failure / escalations-only) to document the new JSON envelope branches.
- [[commands/tui]] — 6-review auto-continue paragraph updated to mention the pass+reason match requirement on save.

## [2026-05-13T00:00:00Z] review+tui — /ce-review round-2 hardening (PR-A polish)

**Action:** Folded a second /ce-review pass into PR #62. Partial `[x]` ticks on `fix-guardrail-NN.md` now hold the pause instead of falling through to a fix-agent re-spawn (defends against laundering risky diffs past the guardrail via a clean retry). `Hive::Stages::Review.fix_guardrail_approved?` now accepts `expected_matches:` and rejects truncation-forged approvals where the user deletes findings they didn't want to read (count is compared against `marker.attrs["matches"]`). `Hive::Reviewers::Agent#run!` clears `output_path` before every retry AND on final failure so a partial file from a crashed attempt cannot satisfy the next attempt's `:output_file_exists` check, and so final failures never leave a stale reviewer file for triage to discover. `reviews/errors-NN.md` joined the Phase 4 `protected_set` (alongside `escalations-`, `fix-guardrail-`, `fix-success-`) so a fix agent cannot delete or rewrite the reviewer-failure record without tripping `fix_tampered`. `Hive::Config.validate_reviewers!` now rejects `output_basename` values that collide with the orchestrator's reserved prefixes (would otherwise be silently treated as orchestrator-owned and hidden from triage) and rejects non-positive-Integer / non-Integer `max_attempts` at config-load. [[commands/tui]] was updated to document the new focal-file open behaviour and the 6-review auto-continue gate (the earlier U6 log entry's "wiki/commands/tui.md update deferred" note is now resolved).

**Refreshed pages:**
- [[stages/review]] — Phase 4 `protected_set` list now includes `errors-NN.md`; partial-approval defense documented in the Approval-on-resume (U5) sub-paragraph.
- [[commands/tui]] — `needs_input` paragraph rewritten to describe the focal-file open for `reason=fix_guardrail` and the 6-review `:rerun_review` auto-continue gate (checkbox-set delta, not mtime).

## [2026-05-12T04:00:00Z] tui — auto-continue for 6-review needs_input rows (PR-A / U6)

**Action:** Extended `Hive::Tui::BubbleModel#auto_continue_outcome` to dispatch the `review` workflow verb automatically when the user saves a 6-review needs_input row — the same UX shape brainstorm (`:proceed`) and plan (`:revise_plan` / `:advance_to_develop`) already had. The new `review_outcome` is gated on the **checkbox-set delta** (captured pre-edit on Enter, compared post-edit) — NOT mtime-only. A bare `:wq` that ticks mtime without changing the `[x]/[ ]` set returns `:silent`, preventing the no-op runner round-trip where the user opens the file, hits `:wq` out of habit, and a multi-minute review verb dispatches with no useful work to do. The marker is re-read from `row.state_file` (NOT the editor path — post-U8 that will be `reviews/fix-guardrail-NN.md` or `escalations-NN.md`, neither of which carry the marker frontmatter) via a new `review_marker_still_open?` helper that accepts `:review_waiting`. On a clean `:rerun_review` outcome, a confirming flash (`"approved — starting next review pass for <slug>"`) accompanies the dispatch so the snappy save-and-continue gesture doesn't set up a wrong expectation for what is in fact a multi-minute job.

**Refreshed pages:**
- [[commands/tui]] — see the 2026-05-13 polish entry; `needs_input` paragraph updated to document the 6-review auto-continue behaviour and focal-file open.

## [2026-05-12T03:00:00Z] review — fix-guardrail [x]-approval semantic on resume (PR-A / U5)

**Action:** Gave `[x]` ticks in `reviews/fix-guardrail-NN.md` an actual runtime meaning. Previously the file was orchestrator-owned and inert — a user could tick all `[x]` and re-run, but the marker stayed `REVIEW_WAITING reason=fix_guardrail` and the loop never advanced. Added `Hive::Stages::Review.fix_guardrail_approved?(ctx)` which reads the file and returns `true` iff every checkbox line is `[x]` (case-insensitive on the `x`; header-only and absent both return false). The runner consults this on every loop iteration: when `resuming_from_waiting?(marker, pass)` AND `marker.attrs["reason"] == "fix_guardrail"` AND `fix_guardrail_approved?(ctx_pass)` all hold, Phase 2/3/4 are skipped for that pass — the prior pass's commits stand, `fix-success-NN.md` is written, marker resets to `:none`, and the loop advances. Approval is single-shot per pass (R11): a fresh `fix-guardrail-(NN+1).md` is written with `[ ]` lines if the next pass also trips. The new check fires BEFORE the `resume_no_findings` empty-reviewer-files guard so approval doesn't require live reviewer files. `reviews/fix-guardrail-NN.md` is also included in the Phase 4 `protected_set` (alongside escalations + fix-success) so a compromised fix agent cannot pre-write all-`[x]` lines to stage an approval token (the orchestrator's own legitimate write via `write_fix_guardrail_findings` runs AFTER the snapshot diff and is unaffected). Together with U6's TUI auto-continue (next), this closes the gap where ticking `[x]` did nothing and the TUI kept re-opening the same folder on every Enter.

**Refreshed pages:**
- [[stages/review]] — Phase 4 paragraph extended with a dedicated "Approval-on-resume (U5)" sub-paragraph documenting the `[x]` semantic, single-shot scope, and protected-files defence.

## [2026-05-12T02:00:00Z] review — orchestrator-owned errors-NN.md failure sink (PR-A / U2)

**Action:** Failed reviewer adapters no longer pollute `reviews/<output_basename>-NN.md` with stub `- [ ] reviewer "X" failed:` lines that triage promoted to escalations. The new failure sink is `reviews/errors-NN.md` — an orchestrator-owned file (added `"errors-"` to `ORCHESTRATOR_OWNED_PREFIXES` so `reviewer_file?`, `discover_reviewer_files`, `collect_accepted_findings`, and `pass_completion_status` all skip it consistently). One header + one line per failed reviewer per pass; multiple failures within a single `run_reviewers` invocation append to the same file with no duplicate header. The file is **truncated** at the first failure of each invocation (not appended-across-runs), so a marker-clear-and-rerun on the same pass produces clean errors-NN.md content rather than concatenated history. The all-failed safety net (`statuses.all?(:error) → :all_failed → REVIEW_ERROR phase=reviewers reason=all_failed`) is preserved unchanged. Together with U1 (adapter retry), this closes the upstream pollution where a single reviewer timeout produced 4 passes of carry-over `[ ]` stubs in `escalations-NN.md` the user had to manually distinguish from real architectural escalations.

**Refreshed pages:**
- [[stages/review]] — Phase 2 reviewers paragraph rewritten to describe the retry+sink behavior end-to-end (U1+U2 together) and to point at `errors-NN.md` as the failure-record file.

## [2026-05-12T01:00:00Z] review — reviewer adapter retry with exponential backoff (PR-A / U1)

**Action:** Added an adapter-local retry loop to `Hive::Reviewers::Agent#run!` so a reviewer spawn that times out or fails transiently is retried up to `max_attempts` times (default 2; configurable per reviewer via the optional `max_attempts` spec field; `1` disables retry). Backoff between failed attempts is exponential — 1s, 2s, 4s, 8s, 8s — capped at `Hive::Reviewers::REVIEWER_BACKOFF_CAP_SEC` (8s) so a high `max_attempts` doesn't introduce minute-scale waits. Each retry gets a `-retry<N>` suffix on its `log_label` so the per-pass log directory shows the retry history. The final `error_message` carries `after N attempt(s)` when `max_attempts > 1` and the original error-message shape otherwise. Non-Integer values reaching the adapter (config-load path bypassing `Hive::Config.validate_reviewers!`) fall back to the default rather than crashing inside `spawn_agent`. Closes the upstream problem where a single reviewer timeout produced a `- [ ] reviewer "X" failed:` stub the user had to triage as if it were a real finding.

**Refreshed pages:**
- [[stages/review]] — Phase 2 paragraph updated together with the U2 entry; see that entry for the rewrite.

## [2026-05-12T00:00:00Z] review — dotenv_edit template-suffix exclusion (PR-A / U4)

**Action:** Tightened the post-fix guardrail's `dotenv_edit` pattern in `lib/hive/stages/review/fix_guardrail/patterns.rb` so committed templates no longer trip the guardrail. The previous regex `\.env(?:\..+)?\z` matched every file whose name started with `.env`, including the canonical templates `.env.example`, `.env.sample`, `.env.template`, `.env.dist`, `.env.tmpl`, `.env.default`, `.env.defaults` — files that exist by design to be committed and contain no real credentials (12-factor, Rails, Next.js, Laravel convention). The new regex uses a negative lookahead that excludes those exact suffixes while preserving matches on real per-env files (`.env`, `.env.local`, `.env.production`, `.env.test`, `.env.staging`, `.env.development`) and the boundary case `.env.example.bak` (not the canonical template — an editor backup or derived file). Projects that genuinely keep secrets in `.env.example` can re-add strict matching via `review.fix.guardrail.patterns_override` with a custom `dotenv_template_edit` pattern. Originated from the xbookmark task `i-want-to-create-a-260504-1253` paused on `REVIEW_WAITING reason=fix_guardrail matches=2 pass=4` where both matches were `.env.example` edits.

**Refreshed pages:**
- [[stages/review]] — Phase 4 guardrail pattern table updated for `dotenv_edit` with the explicit excluded-template-suffix list and the `patterns_override` escape hatch.

## [2026-05-11T15:22:00Z] review — Protect fix-success sentinel from fix agents

**Action:** Hardened the fix-phase retry sentinel introduced in the previous review recovery follow-up. `reviews/fix-success-NN.md` is now part of the fix-agent protected snapshot for the current pass, so a fix agent cannot forge the sentinel and cause a later markerless run to treat a failed fix pass as complete. The TUI recovery path now reuses `Stages::Review.reviewer_file?` for reviewer-file classification, keeping `fix-success-` and future orchestrator-owned prefixes consistent across runner and TUI logic.

**Refreshed pages:**
- `wiki/stages/review.md`
- `wiki/state-model.md`

## [2026-05-08T21:02:58Z] doctor — pi package discovery follow-up: npm global root and project settings packages

**Action:** Refined the Pi verifier docs after the PR #54 follow-up review.

1. **Global npm package roots** — `Hive::SkillCheck::Pi.verify` now includes the path reported by `npm root -g`, matching Pi's documented npm package install model instead of assuming every npm package lives under `~/.pi/...`.

2. **Project settings package jailing** — `<project>/.pi/settings.json` `packages` entries are now jailed with `project_root` just like `skills` entries, so project-local packages such as `../local-package` resolve when the checkout is outside `$HOME`.

**Refreshed pages:** `README.md`, `lib/hive/cli.rb` long description, and `wiki/commands/doctor.md`.

**Coverage:** added regression tests for `npm root -g` package discovery and project `.pi/settings.json` package paths outside `$HOME`.

## [2026-05-08T15:00:00Z] review — Detect mid-pass fix failures + retry wall-clock REVIEW_STALE from TUI

**Action:** Self-review of the earlier review-recovery refinement found two scenarios still broken. Both fixed in this follow-up, with regression tests + sentinel introduction.

1. **Fix-failed pass was indistinguishable from completed pass.** `next_pass_for`'s `incomplete_triage_pass?` predicate only returned true when `escalations-NN.md` was missing. After triage wrote the escalations file but the fix phase failed (`REVIEW_ERROR phase=fix`) — or the runner was interrupted mid-fix — the predicate returned false and `next_pass_for` advanced to `NN+1`, abandoning the operator's `[x]` marks.

   Replaced with `pass_completion_status(folder, N) → :complete | :triage_incomplete | :fix_incomplete`. The new `:fix_incomplete` case (escalations present, neither fix-success sentinel nor pass-`N+1` reviewer files present) makes `next_pass_for` retry pass N AND signals the runner to skip Phase 2/3 on the first iteration — exactly the same `[x]`-preserving short-circuit a `REVIEW_WAITING` resume uses.

   Disambiguating signal: `Stages::Review` now writes `reviews/fix-success-NN.md` at the two "pass N is done, advance" decision points (post-guardrail-not-tripped, and the Phase 2 zero-findings short-circuit to Phase 5). `fix-success-` is added to `ORCHESTRATOR_OWNED_PREFIXES` so the new file is excluded from reviewer-file scanning. Pass-`N+1` reviewer files act as a back-compat fallback at non-topmost passes for legacy repos.

2. **Wall-clock REVIEW_STALE was misclassified as needing manual cleanup.** `Stages::Review.finalize_wall_clock_stale` can fire BEFORE any reviewer files exist (e.g. during Phase 1 CI-fix); the TUI's `retryable_incomplete_triage_pass?` gate required reviewer files to be present, so wall-clock stale fell into the manual-cleanup flash that told the operator to "edit/rename highest-pass review files" — files that don't exist.

   Added `wall_clock_stale?(row)` and a top-level `retryable_review_stale?` gate that ORs the two retryable shapes. Wall-clock REVIEW_STALE now clears + reruns regardless of reviewer-file presence; the operator's lever for "give it more time" is `review.max_wall_clock_sec`.

**Refreshed pages:**
- `wiki/state-model.md` — pass-derivation paragraph rewrites the completion classifier as a three-state (`:complete` / `:triage_incomplete` / `:fix_incomplete`) with the sentinel write points and the back-compat fallback.
- `wiki/commands/tui.md` — `recover_review` paragraph splits `REVIEW_STALE` retry into two named cases (wall_clock + incomplete-triage) and notes the wall-clock-without-files exception explicitly.

## [2026-05-08T13:00:00Z] daemon — PR #55 review feedback: schemas, atomicity, envelopes

**Action:** Hardened `hive daemon enable/disable` and `hive daemon reload` against three rounds of code-review feedback on PR #45 (the original enrol/autostart PR). Lands as a single follow-up commit on PR #55.

1. **JSON schema files for every `--json` daemon producer** — `schemas/hive-daemon-{status,stop,enroll,reload}.v1.json` now publish the closed contract for each subcommand. All four registered in `Hive::Schemas::SCHEMA_VERSIONS` and pinned by `test/unit/schema_files_test.rb` for required-key drift, error_kind enum drift, and per-kind round-trip validation. CLI subprocess output is also round-trip-validated against the published schemas in 4 representative integration tests.

2. **`EnrollErrorKind` closed enum + `Daemon::UsageError` + `EnvelopeEmitter`** — `hive daemon enable/disable --json` failures now emit a `hive-daemon-enroll` ErrorPayload on stdout (mirroring `hive forget`'s shape) instead of plain stderr text. The 7 error_kinds are `missing_project / unknown_project / project_and_all / not_initialised / no_projects / config / internal`; agents branch on `error_kind` deterministically.

3. **Surgical line-level YAML editor** — `upsert_daemon_enabled` replaces the `YAML.load → mutate → to_yaml` round-trip so operator comments and key order survive every enable/disable flip. Three branches: replace existing `enabled:` line, insert as first child of an existing `daemon:` block, or append a fresh block at EOF. `assert_surgical_edit_possible!` rejects inline-flow `daemon: { ... }`, CRLF line endings, and 4-space-indented children before any write — all three were silent-corruption-on-first-call paths.

4. **`flock(LOCK_EX) + fsync` atomic write** — `write_daemon_block` now holds an exclusive flock around the read+rewrite, calls `f.fsync` before `File.rename`, and ensure-cleans the tempfile on rename failure. `Errno::*` (ENOSPC / EROFS / EACCES / EXDEV / EDQUOT / ENOMEM / EIO / ENOENT) is rescued and re-raised as `Hive::ConfigError` (exit 78), matching `Hive::Config.write_global_config!`'s contract.

5. **Pre-flight `--all` transactionality** — `preflight_targets` validates every project's config.yml before any write, so `disable --all` cannot leave the registry half-flipped on a bad middle project. `parse_project_config` consolidates the YAML read + `Psych::Exception` rescue into a single helper used by every consumer.

6. **`next_action` block in success envelope** — `hive-daemon-enroll` SuccessPayload now carries `{kind: reload | no_op}` so an agent can decide whether to call `hive daemon reload` without parsing the bare-text "next:" paragraph. `kind: reload` carries `command` + `required: false` (per-tick cache picks up changes within `poll_interval_sec`); `kind: no_op` when every result was already at the requested state.

7. **`hive daemon reload --json` envelope** — new `hive-daemon-reload.v1` schema. Closed `reason` enum (`not_running / pid_dead / pid_reused / unverified`) on every refusal path. `compute_reload_outcome` separates the decision logic from emission, mirroring how `stop_envelope` is structured.

8. **`launchd` plist circuit-breaker** — `examples/launchd/hive-daemon.plist`'s `ProgramArguments` is now wrapped in `/bin/sh -c '[ -x "$0" ] || exit 0; exec "$0" "$@"'` — turns "binary not found / not executable" into a clean exit 0 so `KeepAlive { SuccessfulExit: false }` stops respawning. Real crashes still propagate non-zero through `exec` and respawn per `ThrottleInterval`. systemd unit gains `StartLimitBurst=3 + StartLimitIntervalSec=300` for the same purpose.

9. **CLI shape hardening** — bare `hive daemon`, `hive daemon enable PROJECT --all` (mutually exclusive), `hive daemon enable a b c` (multi-positional) all now exit 64 with a structured `hive-daemon-enroll` ErrorPayload under `--json`. Help text long_desc lists `--all`, `--json`, and the full exit-code set including 70 (SOFTWARE) and 78 (CONFIG). `do_set_enabled` renamed to `do_call` to match the convention used by every other command class.

**Refreshed pages:**
- `wiki/commands/daemon.md` — subcommand table updated for stop/reload/enable to mention `--json` envelopes; enable line documents the surgical editor + flock + preflight + envelope mechanics.
- `wiki/operating.md` — added a paragraph documenting the launchd `[ -x "$0" ] || exit 0` circuit-breaker rationale and "verify it actually started" steps.
- `wiki/index.md` — Pages count + `updated:` bumped.

**Coverage:** new tests pin surgical-edit shape rejections (inline-flow / CRLF / 4-space / tab), preflight `--all` atomicity, idempotency-on-no-op (bare-text + envelope), real disk-failure injection (EACCES) for the `Errno::* → ConfigError` chain, internal-envelope chain via stubbed collaborators, every reason value in `hive-daemon-reload` round-tripped through JSONSchemer, `next_action` kind transitions on flip and no-op.

## [2026-05-08T12:34:03Z] review — Retry incomplete triage passes instead of counting filenames as completion

**Action:** Refined review recovery after dogfooding showed `REVIEW_STALE pass=4` can be caused by partial reviewer artifacts rather than four completed review cycles. `Stages::Review.next_pass_for` now treats the highest pass as incomplete when reviewer-authored `*-NN.md` files exist without the matching `reviews/escalations-NN.md`; a markerless rerun retries that same pass instead of advancing to `NN+1` and immediately hitting `max_passes`. The TUI now auto-clears/reruns `REVIEW_STALE` only for that incomplete-triage shape; completed stale passes still require manual pass cleanup before clearing.

**Refreshed pages:**
- `wiki/commands/tui.md`
- `wiki/commands/run.md`
- `wiki/commands/markers.md`
- `wiki/modules/markers.md`
- `wiki/stages/review.md`
- `wiki/state-model.md`

## [2026-05-08T12:20:00Z] tui — Review stale recovery loop and split log locations

**Action:** Documented the dogfood fix for two related TUI recovery failures. Markerless `6-review` rows now classify as `Ready for review` instead of `Needs your input`, so a cleared recovery marker does not send Enter into the empty `task.md` editor path. `REVIEW_STALE` rows no longer auto-clear and rerun from the TUI because max-pass recovery requires manual pass cleanup first; Enter flashes that instruction and leaves the marker intact. Log-tail resolution now checks both canonical state logs (`.hive-state/logs/<slug>/`) and review-local task logs (`<task>/logs/`) so agent/error rows can tail the logs that actually exist for both stage families.

**Refreshed pages:**
- `wiki/commands/tui.md`
- `wiki/modules/task_action.md`

## [2026-05-07T23:30:00Z] doctor — pi verifier follow-ups (PR #54): discovery extensions, profile-aware skill formatting, glob-escape parity, path jailing

**Action:** Refreshed the doctor / skill-check documentation to match the second wave of verifier improvements landed in PR #54.

1. **`Hive::AgentProfile#format_skill_invocation`** — new public method that renders any configured skill name through the profile's `skill_syntax_format`, accepting both slash-prefixed stage form (`/plan`, `/plug:name`) and bare reviewer form (`ce-code-review`). Used uniformly by `Stages::Brainstorm`, `Stages::Plan`, `Reviewers::Agent`, `Stages::Review::BrowserTest`, and `Hive::Commands::Doctor` so the slash invocation that reaches the agent CLI matches doctor's verification target. For pi, this collapses `/<plug>:<name>` to `/skill:<name>` (pi has no plugin namespace).

2. **Pi discovery extensions** — `Hive::SkillCheck::Pi.verify` now also walks: ancestor `<dir>/.agents/skills/` directories up to the nearest `.git/`, recursive subdirectories of every skills root, root-level `<name>.md` skills (where applicable), `~/.pi/agent/settings.json` and `<project>/.pi/settings.json` `skills` / `packages` entries, `~/.pi/npm/node_modules/*/skills/`, `~/.pi/agent/git/<host>/<user>/<repo>/skills/` (bounded prefix), and `package.json#pi.skills` entries. The earlier wiki claim "pi has no slash-command resolver" was wrong; it's been replaced with a per-source listing.

3. **Glob-escape parity** — claude/codex bare-name plugin-fallback `Dir[...]` calls now escape user-controlled `<name>` segments via `Hive::SkillCheck.glob_escape`, matching the protection pi already had. This closes a false-positive where `/foo*` would silently match an unrelated `/foobar` plugin cache.

4. **Path jailing in pi `settings.json#skills` and `package.json#pi.skills` entries** — every entry is now strictly contained under an expected jail root (settings_dir / `$HOME` / project_root for settings; `package_root` for manifests). An entry that resolves *exactly to* a jail root (e.g., `~/`) is rejected, since recursive globbing from `home` is a DoS shape; `..`-traversal entries are caught via `File.expand_path` collapse.

5. **`hive-doctor.v1` envelope: new `configured_skill` field** — every `checks[]` row now carries both the raw config-supplied value (`configured_skill`) alongside the profile-aware formatted invocation (`skill`). Pi stage rows are the most affected case: configured `/plan` shows `configured_skill: "/plan"`, `skill: "/skill:plan"`. JSON consumers that need to round-trip back to the operator's config should read `configured_skill`. Schema name stays `v1` — fully additive, forward-compatible.

6. **`git_skill_candidates` and `git_package_roots` bounded** — replaced unbounded `**/skills/**/<name>` and `**/package.json` walks with fixed-depth (1–4 level) prefix globs that match pi's known git-cache layouts (`<host>/<repo>/`, `<host>/<user>/<repo>/`, with extra depth for nested mirrors). Every doctor run is now O(prefix_depth × repos) regardless of any single repo's tree size.

7. **JSON parse-error surfacing** — `Hive::SkillCheck::Pi.read_json` now collects parse failures and the `:missing` install_hint suffixes them, so a stray comment in `~/.pi/agent/settings.json` no longer silently disables every settings-derived skill.

**Refreshed pages:**
- `wiki/commands/doctor.md` — replaced the now-incorrect "Pi — always `:not_applicable`" line with the full per-source pi probe listing; added the `configured_skill` JSON envelope field.
- `wiki/modules/agent_profile.md` — added `verify_skill` and `format_skill_invocation` to the Key methods table.
- `wiki/modules/reviewers.md` — `skill_invocation` binding now formats via `profile.format_skill_invocation`, not `profile.skill_syntax_format`.
- `README.md` — pi description now lists every discovery source (settings, manifests, ancestor walk, git/npm package roots).

**Coverage:** new pi glob-metacharacter test (`/skill:foo*` vs `/skill:foobar`); `test/unit/stages/skill_invocation_format_test.rb` now requires `hive/config` so it runs in isolation. Existing pi/claude/codex tests still pass.


## [2026-05-07T22:45:00Z] tui — Review recovery hardening (off-thread, dedup, sanitize, narrow rescue, partial-failure flash)

**Action:** Hardened the Enter-driven review recovery handler in `lib/hive/tui/bubble_model.rb` based on `/ce-code-review` actionable findings. (1) The clear+rerun sequence now runs on a background worker thread mirroring `spawn_heal_thread`; the bubbletea update loop returns immediately with a `review recovery: clearing <detail>…` flash and the worker dispatches a follow-up `Messages::Flash` via `@dispatch` on completion. This removes the previously-blocking 30 s `run_quiet!` upper bound from the render loop. (2) Per-folder dedup via `@review_recovery_inflight` (Set, mutex-protected) refuses a second `Enter` while the first worker is in flight with an `already in progress` flash. (3) `Hive::Tui::Subprocess.dispatch_background` is wrapped in its own narrow rescue inside the worker so a failure AFTER the marker clear succeeded surfaces as `marker cleared, but \`hive run\` failed to start: <reason>; run \`hive run <folder>\` manually` — the operator sees a half-cleared state explicitly instead of the misleading old "review recovery failed" attribution. (4) The outer rescue narrows from `StandardError` to `SystemCallError | IOError | Hive::Tui::Subprocess::TimeoutError` so programmer errors (NoMethodError/NameError/ArgumentError) crash the worker thread loud instead of being silently captured into a flash. (5) Operator-supplied marker reasons are stripped of control bytes (0x00–0x1F + 0x7F) and ANSI CSI escapes via a new `Hive::Tui::Text.sanitize` helper before being rendered into the status column or the flash detail; previously a stdout-tail snippet stored in the marker could corrupt lipgloss column alignment.

**Punted:** `--match-attr` aliasing on `REVIEW_ERROR(phase=ci)` markers (the snapshot's `pass` attr is absent so the guard falls back to a lower-cardinality key). The synthesis listed two design options — extend `hive markers clear` to accept multiple `--match-attr` pairs, OR add a high-cardinality `created_at` attr to all `Hive::Markers.set(:review_*)` call sites in `lib/hive/stages/review.rb` (~13 sites). Both options touch surfaces beyond a single fixer pass and warrant explicit design input.

**Refreshed pages:**
- `wiki/commands/tui.md`

## [2026-05-07T22:00:00Z] doctor — pi gets a real skill verifier; pi's `skill_syntax_format` corrected

**Action:** Two related fixes for pi.

1. **Pi has a real skill discovery system, not the absence I previously claimed.** Per the `@mariozechner/pi-coding-agent` README and `dist/core/package-manager.js`, pi auto-discovers skills from `~/.pi/agent/skills/<name>/SKILL.md`, `~/.agents/skills/<name>/SKILL.md`, project-local `<cwd>/.pi/skills/<name>/SKILL.md` and `<cwd>/.agents/skills/<name>/SKILL.md` (walking up cwd to git root), and pi packages installed via `pi install <source>` (npm/git roots with `skills/` directories). `Hive::SkillCheck::Pi.verify` now probes all of these instead of returning a blanket `:not_applicable`.

2. **Pi resolves skills as `/skill:<name>`, not bare `/<name>`.** Hive's pi profile previously set `skill_syntax_format: "/%{skill}"`, which produced `/<name>` invocations — pi at runtime treats those as extension-command lookups, not skill lookups. Skills from the prompt would silently fail to resolve. Profile now sets `skill_syntax_format: "/skill:%{skill}"` so the formatted invocation matches pi's resolver. Behaviour change for pi-using configs; no projects in the registry currently use pi as a stage/reviewer agent, so the rename is safe to land.

The pi verifier accepts `/skill:<name>` (the canonical pi skill form) and probes the discovery paths. For invocations that aren't in `/skill:` form (e.g., a custom profile producing bare `/<name>`), it returns `:not_applicable` with a message explaining the form mismatch — pi can't resolve such an invocation as a skill.

Also restored `Hive::SkillCheck.glob_escape` (escapes `*`, `?`, `[`, `]`, `{`, `}`, `\` so a name or plugin segment is treated literally inside a `Dir[]` call) — used by pi/claude/codex `build_candidates` whenever the parsed invocation is interpolated into a glob pattern. Without it, an invocation like `/foo*` would silently match plugin caches whose name starts with `foo`.

**Coverage:** 10 new skill-check unit cases (pi happy paths for user/cross-agent/project/pi-package locations, install hint, non-skill-form returns N/A, malformed invocation), 1 doctor-test rename + 1 new doctor test for pi reviewer rows. Full suite: 1542 runs / 5068 assertions / 0 failures.

**Refreshed pages:**
- `README.md` — pi row in the skills table now describes pi's actual model (with `~/.pi/agent/skills/`, `~/.agents/skills/`, etc.) and the `/skill:<name>` invocation form.


## [2026-05-07T20:17:15Z] tui — Enter-driven review recovery

**Action:** Made `recover_review` rows actionable from the TUI. The status column now renders the exact observed recovery reason when the marker carries one (for example `triage_failed` from `REVIEW_ERROR phase=triage reason=triage_failed pass=2`) instead of the generic `Needs recovery` label. `Enter` on the row now clears the observed review recovery marker via `hive markers clear <folder> --name REVIEW_ERROR|REVIEW_STALE|REVIEW_CI_STALE`, includes one available `--match-attr` guard to avoid clearing a newer concurrent marker, and only then dispatches `hive run <folder>` through the existing background subprocess path. A failed marker clear flashes the captured error and does not rerun.

**Refreshed pages:**
- `wiki/commands/tui.md`


## [2026-05-07T17:30:00Z] doctor — probe `review.reviewers[]` + non-fatal init preflight

**Action:** Extended `hive doctor` (PR #48 / `cd70f39`) along the two lines the original PR explicitly left for follow-up:

1. **`review.reviewers[]` probing.** `Hive::Commands::Doctor#call` now walks `cfg.dig("review", "reviewers")` after the brainstorm/plan stage rows. Each reviewer entry's bare `skill` (e.g., `ce-code-review`, `pr-review-toolkit:review-pr`) is formatted through `profile.skill_syntax_format` to obtain the full invocation (`/ce-code-review`, `/pr-review-toolkit:review-pr`), then passed to `verify_skill` so the JSON envelope's `skill` field is uniformly a full invocation across stage and reviewer rows. The text-table row label uses `6-review/<reviewer-name>` (matches the user-facing `name:` field in config); the JSON envelope's `checks[]` entries gain a `kind` discriminator (`"stage"` or `"reviewer"`), a `label` field, and (for reviewer rows) a `name` field.

2. **Non-fatal preflight at end of `hive init`.** After `print_summary` returns, `Init#call` invokes `run_init_preflight!`, which loads the freshly-written config, constructs a discard-output `Doctor`, calls `#call`, and emits stderr warnings for any `:missing` rows in the format `[<row-label>/<agent>] <verifier message>`. Init's exit code is unaffected — install gaps surface but never block bootstrap. The rescue scope is `StandardError` (with a `Errno::EPIPE` micro-rescue around `warn`); `Interrupt` and `SystemExit` propagate, and unexpected verifier raises produce a "this may be a hive bug, please report" hint so silent swallow is mitigated.

**Implementation notes:**
- Non-`agent` reviewer kinds report `:not_applicable` with an explanatory message. `Hive::Config.validate_reviewers!` does NOT check the `kind` field — only `Hive::Reviewers.dispatch` does, at run-time. The doctor's N/A row is therefore the **only load-time signal** for non-agent kinds, not a redundant safety net.
- `Hive::Commands::Doctor` gained an `attr_reader :rows` so the init preflight can read probe results in-process without re-running the renderer or JSON encoder.
- The renderer reads `row[:label]` (added by U1) for the first-column display, so long reviewer names don't truncate the table.
- Schema name stays `hive-doctor.v1`. The `kind`/`label`/`name` additions are forward-compatible; consumers that ignore unknown fields continue to work.

**Test surface:**
- `test/unit/commands/doctor_test.rb` — 9 new cases covering reviewer happy path, mixed agents, empty/nil/absent reviewers, non-agent kinds, pi reviewer rows, JSON envelope shape, long-label width, and the `attr_reader :rows` exposure.
- `test/integration/init_doctor_preflight_test.rb` (new) — 6 cases covering all-green silence, single-missing stderr warning, multi-missing including a reviewer row, init exit-code unchanged, preflight crash → bug-hint warning, config-load error → bug-hint warning.

**Refreshed pages:**
- `README.md` — Required slash-commands / skills section now also lists the recommended reviewer set + documents the init-preflight behavior.


## [2026-05-07T15:30:00Z] config — `hive doctor` skill preflight + per-agent verifiers

**Action:** Added `hive doctor` — a CLI verb that walks brainstorm + plan stage configs and asks each stage's agent profile to verify its configured skill (`<stage>.skill`) actually resolves to an installed slash-command or skill on disk. Output is a status table; `--json` emits a `hive-doctor.v1` envelope. Exit codes: `0` (all present or N/A), `65` (at least one missing), `78` (config error).

Per-agent search rules encoded in `Hive::SkillCheck::{Claude,Codex,Pi}`:

- **Claude** — for `/<name>`: `<project>/.claude/commands/<name>.md`, `<project>/.claude/skills/<name>/SKILL.md`, `~/.claude/commands/<name>.md`, `~/.claude/skills/<name>/SKILL.md`. For `/<plug>:<name>`: cache layout `~/.claude/plugins/cache/<marketplace>/<plug>/<version>/skills/<name>/SKILL.md` AND marketplace source layout `~/.claude/plugins/marketplaces/<marketplace>/plugins/<plug>/skills/<name>/SKILL.md` (plus `commands/`).
- **Codex** — for `/<name>`: `~/.codex/skills/<name>/SKILL.md`, `~/.codex/skills/.system/<name>/SKILL.md`. For `/<plug>:<name>`: `~/.codex/plugins/cache/<marketplace>/<plug>/<version>/skills/<name>/SKILL.md`. Note that codex has no user-level slash-command directory like claude's `commands/` — if you need `/plan` on codex, install a SKILL.md.
- **Pi** — always `:not_applicable`. Pi has no slash-command resolver: a `/foo` token in the prompt is just text the model reads. The honest answer is N/A, not `:missing`.

`AgentProfile` gained a `skill_verifier:` constructor kwarg (defaulting to nil → `:not_applicable`), so adding a fourth profile in the future is "register a `Hive::SkillCheck::*` module and pass its `.method(:verify)`."

README install section updated with per-agent install pointers and the `hive doctor` invocation.

**Refreshed pages:**
- (none — `hive doctor` is a new CLI surface; existing wiki pages don't reference skill installation.)


## [2026-05-07T14:00:00Z] config — per-stage `skill` override + `/plan` becomes the shipped default

**Action:** Added `brainstorm.skill` and `plan.skill` keys to `Hive::Config::DEFAULTS`. The brainstorm and plan stage prompts now reference `<%= skill_invocation %>` so a per-project `config.yml` override redirects the agent to a different slash-command without touching `templates/`.

**Shipped defaults assume both llm-wiki and compound-engineering are installed alongside the agent CLI:**
- `plan` → `/plan` (llm-wiki's wiki-research-first wrapper that delegates into the CE planning workflow). This is the new default; the previous hardcoded `/compound-engineering:ce-plan` is now invoked transitively through `/plan`.
- `brainstorm` → `/compound-engineering:ce-brainstorm` (no llm-wiki equivalent today; flip the default if one lands).

`templates/project_config.yml.erb` rendered for fresh `hive init` includes the keys as commented-out hints. Existing projects pick up the new default on next stage run; the deep-merge resolves `cfg.dig("plan", "skill")` to the user's value when set, falls back to the new default otherwise.

The 6-review stage's per-role skills are unchanged in this pass (those flow through `profile.skill_syntax_format` per ADR-014); the override applies only to the two single-agent stages. A follow-up could lift the same pattern to review if needed.

**Refreshed pages:**
- (none — this is a config-surface addition. On-screen behavior changes only for the plan stage's skill name.)


## [2026-05-07T12:00:00Z] tui — auto-continue on plan stage (revise vs advance)

**Action:** Extended the editor-takeover auto-continue path from `2-brainstorm` to `3-plan`. The brainstorm path is unchanged. The plan path adds two outcomes the brainstorm flow does not have: `:revise_plan` (user added inline feedback in the editor — re-run `hive plan ... --from 3-plan`) and `:advance_to_develop` (user saved without changes — interpret as approval, dispatch `hive develop ... --from 3-plan` to start the next stage). Detection is content-hash-based (SHA1 of the file before vs. after the editor session) — mtime is too unreliable across editors for the "saved without edits" semantics.

The only safety gate on the plan path is a clean editor exit: `exit_code == 0`. SIGINT (`130`) and other non-zero exits stay manual. The on-disk marker is re-read after the editor exits; if a sibling actor flipped the marker to `:complete` / `:agent_working` / `:error` during a long edit, the row falls back to the manual path with a `Messages::Flash` saying `auto-continue skipped for <slug>: marker changed during edit`.

The `current_brainstorm_input_marker?` helper was renamed to `marker_still_open_for_input?` since both stages key off the same `:waiting` / `:none` test. The `auto_continue_outcome` predicate became a stage-dispatch (`brainstorm_outcome` / `plan_outcome` / fall-through `:silent`).

`develop_command_from_plan` builds the advance argv by swapping `plan` for `develop` in the row's `suggested_command`, preserving `--project` / `--from` flags so the develop spawn keeps the same idempotency lever.

Coverage: 6 new BubbleModel integration tests for the plan path (advance-on-unchanged, revise-on-edit, marker race to `:complete`, SIGINT abort stays manual, malformed `suggested_command` rescue branch, advance falls back when `suggested_command` is not `hive plan ...`). All 1479 tests pass; rubocop clean.

**Refreshed pages:**
- `wiki/commands/tui.md` — Subprocess dispatch section names the plan-stage auto-continue alongside brainstorm; Modes table notes "completed plans auto-advance, edited plans auto-revise."

## [2026-05-07T00:00:00Z] daemon — enrollment subcommands + macOS/Linux autostart guide

**Action:** Added `hive daemon enable PROJECT|--all` and `hive daemon disable` so existing projects (initialised before ADR-024 / PR #40) can be enrolled in the auto-advancing pipeline without hand-editing YAML. The toggle is an atomic write to `<project>/.hive-state/config.yml` (tempfile + rename) that preserves every other key, including pre-existing `daemon:` tunables (`poll_interval_sec`, `max_concurrent_runs`, etc.). `--all` iterates `Hive::Config.registered_projects`. Closed `--json` envelope (`hive-daemon-enroll.v1`) carries per-project `previous` and `current` values so scripted callers can diff. Exit 64 (`USAGE`) on missing/unknown target. The dispatcher's per-tick enable-cache invalidation (PR-40 follow-up #2) means the new flag takes effect within one `poll_interval_sec` automatically — `hive daemon reload` is optional. Closes the operator gap "I have existing projects, how do I enroll them?" without requiring a `hive init`-style re-bootstrap.

Also added the autostart install path for both supported platforms. New page [[operating]] is the day-2 guide: prerequisites (claude / gh / /proc-or-ps), per-project enrollment, the mandatory `--dry-run` shakedown with `jq` filters for inspecting `daemon.log`, autostart on Linux (systemd-user; sample unit at `examples/systemd/hive-daemon.service`) and macOS (launchd; sample plist at `examples/launchd/hive-daemon.plist`), tuning concurrency, cost-runaway response, and a troubleshooting block. The systemd unit declares `Type=simple` + `Restart=on-failure` + `KillMode=mixed` so SIGTERM forwards through the PGID and the daemon's own graceful drain (`shutdown_grace_sec`) runs. The launchd plist uses `KeepAlive` with `SuccessfulExit: false` so a clean `hive daemon stop` doesn't trigger a respawn.

Closes the dangling `wiki/operating.md once that page lands` reference flagged by the comment-analyzer review of PR #40.

**Refreshed pages:**
- New: [[operating]] — full install + autostart guide.
- New: `examples/systemd/hive-daemon.service`, `examples/launchd/hive-daemon.plist`.
- [[commands/daemon]] — added `enable`/`disable` rows to the subcommand table; replaced the dangling-reference paragraph with explicit links to the new examples + operating guide.
- [[cli]] — daemon command-table row mentions enable/disable + points at [[operating]].
- [[index]] — added [[operating]] under Top level; updated the [[commands/daemon]] one-liner.


## [2026-05-06T23:00:00Z] tui — surface auto-continue suppression reasons + tighten rescues

**Action:** Made the brainstorm auto-continue path observable instead of silently degrading to the generic post-save flash. `auto_continue_after_edit?` was replaced by `auto_continue_outcome`, which returns one of `:proceed`, `:silent`, `:empty_command`, or `:marker_changed`. The race / data-anomaly cases (`:empty_command`, `:marker_changed`, plus the rescue path on a malformed `suggested_command`) now dispatch a follow-up `Messages::Flash` like `auto-continue skipped for <slug>: brainstorm marker changed during edit`, so a user whose mental model is "I filled in answers, expected `hive brainstorm` to auto-fire" can actually see why it didn't. Expected-refusal cases (`exit_code != 0`, mtime unchanged, off-stage, parser says incomplete) stay silent — those are self-evident.

Also tightened the surrounding rescues:
- **`BrainstormAnswers.complete?`** extracted a private `read_lines(path)` helper that holds the only I/O rescue (`SystemCallError, EncodingError, IOError`) and `.scrub`s bytes so the parser body never sees garbled UTF-8. The parser body itself no longer has a method-level rescue; a real `ArgumentError` from a future refactor now surfaces as a crash during dev/test instead of silently turning into "auto-continue refuses to fire."
- **`current_brainstorm_input_marker?`** dropped `EncodingError` and `ArgumentError` from its rescue list. The remaining `SystemCallError, IOError` covers the legitimate I/O failure modes; a future marker-corruption `ArgumentError` from `Hive::Markers.parse_attrs` now propagates so state-file corruption doesn't mask itself as "auto-continue stopped working." Added a docstring explaining the race-protection rationale.
- **Editor callable mtime sample.** `before_mtime != after_mtime` was upgraded to `!before_mtime.nil? && !after_mtime.nil? && before_mtime != after_mtime`. A transient `ENOENT/EACCES` between samples no longer registers as a bogus `changed: true` (which would have produced a misleading "edited <slug>" flash even when the user saved nothing).

Coverage expanded: 5 new BubbleModel integration tests (marker race tested for `<!-- COMPLETE -->`, `<!-- AGENT_WORKING -->`, `<!-- ERROR -->`; empty `suggested_command`; nil `mtime` returns `changed: false`) plus 2 new parser tests (empty file, CRLF line endings via SMB / Windows editors). The pre-existing marker-race test was strengthened to set `marker: "complete"` on the row, proving the production code reads from disk via `Hive::Markers.current` and ignores the row attr.

**Refreshed pages:**
- (none — the on-screen guarantees in [[commands/tui]] are unchanged for the success path; the new failure-mode flashes are an additive UX improvement.)

## [2026-05-06T22:00:00Z] tui — extracted BrainstormAnswers + hardened the auto-continue parser

**Action:** Moved the brainstorm-completeness predicate and its five helper methods out of `BubbleModel` (already a 1240-line MVU class) into a standalone `Hive::Tui::BrainstormAnswers` module at `lib/hive/tui/brainstorm_answers.rb`, with one public entrypoint `BrainstormAnswers.complete?(path)`. While extracting, hardened the parser so the auto-continue gate cannot be tricked or accidentally fire:

- **Code-fence aware.** Lines inside ``` or ~~~ fenced blocks no longer count as live structure, so a pasted brainstorm template with `## Round 99` / `### Q1` / `### A1` inside a fence cannot dictate completeness while real Round 1 is still empty.
- **CommonMark-correct heading indent.** Heading regexes accept 0–3 leading spaces only; 4+ space indentation is treated as an indented code block per CommonMark, not as an ATX heading.
- **Latest round by N, not by file position.** Picks the round with the highest N (ties broken by later position). A stale duplicate `## Round 1` pasted below an in-progress `## Round 2` no longer hijacks the selection.
- **Refuses on duplicate Q/A numbers** within the same round. A typoed copy-paste that produces two `### Q1` headings keeps the row on the manual path instead of auto-firing on the surviving last occurrence.
- **HTML comment handling.** `<!-- WAITING -->` / `<!-- COMPLETE -->` / inline `<!-- thinking -->` comments are stripped from answer bodies before the emptiness check; comment lines no longer truncate body collection mid-answer.
- **Wider rescue + Debug.log.** `complete?` rescues `SystemCallError, EncodingError, IOError, ArgumentError` (covers `EISDIR` on a directory path, encoding errors on non-UTF-8 bytes, and the `ArgumentError: invalid byte sequence in UTF-8` from `String#match?`) and routes through `Hive::Tui::Debug.log` so a recurring permissions/encoding issue is diagnosable rather than silent.
- **Tighter rescue scope in `BubbleModel#input_editor_exit_messages`.** The `rescue ArgumentError` now narrowly wraps the `dispatch_command_for` call rather than the whole method, so future kwarg drift in `Hive::Tui::Messages::InputEditorExited` no longer gets caught and silently re-raised by the recovery branch.
- **Both messages dispatched on auto-continue.** Manual path: `[InputEditorExited]`. Auto path: `[InputEditorExited, DispatchCommand]`. Future observers added to `InputEditorExited` will fire on auto-fired editor closes too.

Coverage: 23-test unit suite directly against the new module (real fixtures on disk, including code-fence bypasses, tilde fences, indented headings, duplicate Q/A numbers, multi-round selection, WAITING-marker bodies, encoding errors, missing files, directory paths) plus four new BubbleModel integration tests (non-zero editor exit, mtime-unchanged with complete answers, malformed `suggested_command` rescue branch, real `File.mtime` end-to-end). All 4 actionable + 7 advisory follow-ups from issue #39 are now closed.

**Refreshed pages:**
- (none — the user-facing behavior in [[commands/tui]] is unchanged; this was a refactor + parser hardening for resilience.)

## [2026-05-06T20:49:00Z] tui — auto-continue rechecks the current marker

**Action:** Tightened the brainstorm auto-continue gate so the post-editor path re-reads the state-file marker before dispatching the suggested command. Auto-continue now only fires when the current marker is still `WAITING` / `none`; if another actor completes, starts, or errors the brainstorm while the editor is open, the stale row falls back to the manual `InputEditorExited` path instead of spawning an old `hive brainstorm ... --from 2-brainstorm` command.

**Refreshed pages:**
- [[commands/tui]] — documented the fresh marker re-check and stale-row manual fallback.

## [2026-05-06T17:30:00Z] tui — completed brainstorm answers auto-continue

**Action:** `Enter` on a `needs_input` brainstorm row still opens `brainstorm.md` in the user's editor, but saving a completed answer round now dispatches the row's existing `hive brainstorm <slug> --from 2-brainstorm` command automatically. The TUI only auto-continues when the editor exits 0, the file mtime changed, the row is in `2-brainstorm`, and the latest `## Round N` has every `### Qn` paired with a non-empty `### An`; partial answers and non-brainstorm input states keep the manual verb-key path. This preserves the marker contract (`brainstorm.md` stays `WAITING` / `none` until the brainstorm agent rewrites it) while removing the confusing "I saved answers but the row still says Needs your input" dead-end.

**Refreshed pages:**
- [[commands/tui]] — documented the completed-answer auto-continue behavior and the guardrails that keep partial answers manual.

## [2026-05-06T20:00:00Z] hive daemon — auto-advancing dispatcher (ADR-024)

**Action:** Shipped the auto-advancing daemon (plan `docs/plans/2026-05-06-001-feat-hive-daemon-dispatcher-plan.md`). New module `Hive::Daemon::*` (Policy, ConcurrencyController, ChildSupervisor, StatusConsumer, Dispatcher, Logger, PrMergeWatcher) plus `Hive::Commands::Daemon` Thor subcommand (`start --detach --dry-run`, `stop`, `status --json`, `reload`, `tail`). The daemon polls `hive status --json` every `daemon.poll_interval_sec` (30s default) and dispatches `tasks[].suggested_command` for rows the classifier marks safe (`ready_to_*` + mtime-debounced `needs_input` resumes). 7-finalize → 8-done transitions via `Hive::Daemon::PrMergeWatcher` polling `gh pr view --json state == MERGED`. Per-project enrollment via `daemon.enabled: true` in `<project>/.hive-state/config.yml`, asked at `hive init` (default Y, per ADR-023 prompt pattern); legacy projects fall back to `Config::DEFAULTS["daemon"]["enabled"] = false` (no silent legacy flip). Three concurrency caps (`max_concurrent_runs=5`, `max_concurrent_per_project=5`, `max_runs_per_day_per_project=50`) bound cost. Retry policy keys off `Hive::ExitCodes`: TEMPFAIL refunds daily slot; TASK_IN_ERROR clears running entry without quarantine (marker handles it via Policy upstream); CONFIG drops the project; transient codes back off through `60→120→300s` then quarantine. Structured JSON-line logging at `~/Dev/hive/logs/daemon.log` with closed event enum. Daemon adds NO new approval logic — forward-advance safety is inherited from `Hive::Commands::Approve::VALID_TERMINAL_MARKERS`. ADR-024 retires ADR-004's "per-task `mv` is approval" gate for daemon-enabled projects (approval is given once at enrollment time); ADR-004 stays valid for the manual-CLI surface.

**Refreshed pages:**
- New: [[commands/daemon]] — full operator surface, retry policy table, concurrency caps table, structured-log schema.
- New: [[modules/daemon]] — implementer surface for the seven daemon modules + the Thor subcommand.
- [[decisions]] — ADR-024 appended.
- [[cli]] — TLDR mentions the daemon; command table gets a `hive daemon` row.
- [[active-areas]] — daemon row moved out of "Phase 2/3 deferred" into "What exists"; remaining deferred items listed.

## [2026-05-06T10:00:00Z] forget / prune / TUI X-key — registry cleanup surfaces

**Action:** Three new registry-cleanup surfaces landed (`hive forget NAME`, `hive prune [--dry-run]`, TUI grid `X` keystroke), gated to safe targets. `hive prune` and the TUI X-key are idempotent (re-running on a clean registry / a row whose path is already gone is a no-op); `hive forget X` is **not** retry-idempotent today — a second invocation after a successful drop returns `unknown_project` / exit 64 (see [[commands/forget]] § Idempotency). Each CLI verb honours `--json` with a published schema (`hive-forget.v1.json` / `hive-prune.v1.json`); error envelopes route through `Hive::Schemas::ErrorEnvelope.build` and carry `error_class` like every other hive-* envelope. `Hive::Schemas::ForgetErrorKind` and `PruneErrorKind` modules pin the closed enums (`missing_name`, `unknown_project`, `usage`, `config`, `internal`); `schema_files_test.rb` enforces producer/schema parity. `Hive::Config.unregister_project` now uses index-based delete (Array#- subtraction would have cleared duplicate-content rows). `Hive::Config.registered_projects` tolerates malformed registry entries (non-Hash, missing `path`, nil values) by skipping them; `Hive::Config.prune_missing_projects!` reports them as droppable so the cleanup path is complete. `Psych::SyntaxError` on a malformed `config.yml` is rewrapped as `Hive::ConfigError` (exit 78) instead of leaking as `InternalError` (exit 70) — the TUI's narrow `Hive::ConfigError` rescue now catches malformed-YAML cases too. `unregister_project` and `prune_missing_projects!` validate `$HIVE_HOME` first so a typoed env var surfaces as `config` (exit 78) rather than masquerading as `unknown_project` (exit 64). The TUI all-unhealthy flash branches on the actual error mix instead of unconditionally pointing at X / `hive prune` (which are gated to `missing_project_path` rows only).

**Refreshed pages:**
- New: [[commands/forget]] — full surface, idempotency caveat, error_kind table.
- New: [[commands/prune]] — full surface, dry-run semantics, symlink note.
- [[cli]] — added `hive forget` and `hive prune` rows to the command table; updated the `--json` enumeration to include both new verbs and to mention `error_class` on error envelopes.
- [[commands/tui]] — added the grid-mode `X` keystroke row to the keybindings table with cross-links to forget/prune.
- [[index]] — bumped page count to 45; added forget/prune list entries.

## [2026-05-05T20:15:00Z] tui — review-waiting editor target correction

**Action:** Corrected the needs-input editor docs after review found that `reviews/escalations-NN.md` and `reviews/fix-guardrail-NN.md` are orchestrator-owned files, while the review resume path consumes `[x]` decisions from reviewer-authored files. `Enter` on `:review_waiting` now targets the single reviewer file for the pass when unambiguous, or the `reviews/` directory when multiple source files or a fix-guardrail inspection gate are involved.

**Refreshed pages:**
- [[commands/tui]] — updated the Input editor takeover section to describe reviewer-file / reviews-directory resolution instead of claiming the editor opens orchestrator gate files.

## [2026-05-05T20:00:00Z] tui — needs-input editor takeover (rescued from 2026-05-04 stash)

**Action:** Restored the lost editor-takeover behavior that was originally drafted on `feat/init-pretty-summary` on 2026-05-04 but stashed and dropped (only the new-idea-paste half of that stash made it into PR #25). `Enter` on a `needs_input` row no longer re-dispatches the suggested workflow verb — `KeyMap` now emits `Messages::OpenInputEditor` and `BubbleModel#open_input_editor` opens the row's input file in `$VISUAL` / `$EDITOR` / `vi` via the shared `Hive::Tui::Subprocess.foreground_takeover_command` wrapper introduced in PR #26. mtime is sampled either side of the spawn so the post-edit `Messages::InputEditorExited(slug:, exit_code:, changed:)` flash distinguishes a saved edit ("press the stage verb key to continue") from a no-op cancel. For `:review_waiting` rows the takeover targets the per-pass review gate file (`reviews/escalations-NN.md` or `reviews/fix-guardrail-NN.md`) instead of `task.md`, so the operator edits the file the reviewer/fix-guardrail actually wrote. Workflow verb keys (`b`/`p`/`d`/`r`/`P`) remain the explicit "rerun the stage" surface — the editor handler intentionally does NOT auto-dispatch. Footer hint flips from `[Enter] next` to `[Enter] open` to reflect the new surface. Help-overlay description for `Enter` enumerates the per-state contextual modes.

**Refreshed pages:**
- [[commands/tui]] — added Input editor mode row, updated the `Enter` keybinding description, footer hint diagram, and the Subprocess-dispatch section now documents the editor takeover path (state-file vs review-gate-file resolution, mtime change detection, no-auto-dispatch contract).

## [2026-05-05T18:50:00Z] tui/subprocess — shared foreground-takeover wrapper

**Action:** Extracted the Bubble Tea alt-screen handoff sequence — `exit_alt_screen`, then `Bubbletea.exec` on the callable, then `enter_alt_screen` — out of `Hive::Tui::Subprocess.takeover_command` into a sibling helper `Hive::Tui::Subprocess.foreground_takeover_command(callable)` (`@api private`). `takeover_command` still owns the closure that wraps `run_takeover_child_sync(argv)` plus the `Messages::SubprocessExited` dispatch and now delegates the `SequenceCommand` build to the new helper. Behavior is byte-identical for the existing call site; the wrapper exists so future tty-bound operations do not re-derive the alt-screen lifecycle at the call site. New integration test `test_foreground_takeover_command_wraps_callable_with_alt_screen_sequence` pins the returned shape (`SequenceCommand` wrapping `ExitAltScreenCommand` / `ExecCommand` / `EnterAltScreenCommand`) and verifies the captured callable runs. The same PR tightens `test_successful_spawn_deletes_its_capture_file` from `assert_equal before.size, after.size` to `assert_empty after - before` so the assertion stays correct when the BEGIN-time orphan-capture sweep fires during dispatch and changes the absolute file count — the new form expresses the actual contract documented in `docs/solutions/architecture-patterns/per-spawn-stdio-capture-correlation-id-2026-04-29.md` ("delete on `exit_code.zero?`").

**Refreshed pages:** none. `wiki/commands/tui.md` still describes `takeover_command` accurately as the public surface for `interactive: true` verbs; the new helper is an internal building block with one caller today and no immediate user-facing change to surface. Worth refreshing if/when a second caller lands (the `interactive: true` escape hatch is the most likely vector — a future interactive `gh pr create` prompt or a manual review verb), at which point `wiki/commands/tui.md`'s "Subprocess dispatch" section can name `foreground_takeover_command` as the shared primitive and `takeover_command` as one caller of it.

## [2026-05-04T20:00:00Z] state-model trigger fired on init/config polish — wiki note only

**Action:** Commit `93bcc18` (polish: comment drifts, validator coverage, construction guards) touched `lib/hive/commands/init.rb`, `lib/hive/commands/init/prompts.rb`, and `lib/hive/config.rb`. Reviewed every diff hunk: all changes are factual-accuracy comment fixes, table-driven validator-coverage tests, `Hash#fetch`-instead-of-`[]` defense-in-depth in `Prompts#default_budgets/timeouts`, and `Prompts#initialize` ArgumentError guards (empty registry / missing recommended defaults). The state-model surface (`Hive::Task`, `Hive::Markers`, `Hive::Config` schema/DEFAULTS, `Hive::Lock`, `Hive::Worktree`, `Hive::Metrics`) is unchanged — no marker added/removed, no DEFAULTS shape change, no validation rule change, no template field change.

One single propagation made: `lib/hive/config.rb:220` corrected a misattribution ("review.reviewers Array semantic per ADR-018" — ADR-018 is about per-CLI isolation, not array merge). The same misattribution appeared at `wiki/modules/config.md:90` and is now corrected to match the code comment.

**Refreshed pages:**
- `wiki/modules/config.md` — Recursive deep-merge bullet on Array semantics no longer cites ADR-018; rationale ("per-element merge has ambiguous semantics for ordered lists") matches the code comment verbatim.

## [2026-05-04T19:10:44Z] tui — new-idea editing and paste support

**Action:** Added cursor-aware editing to the `hive tui` new-idea prompt: Left/Right, Home/End, Ctrl+A/Ctrl+E, Backspace, Delete, insertion at cursor, wrapped cursor rendering, paste normalization, and a conservative 4 KiB title-buffer cap with a `title too long` flash. The terminal input path now uses a Hive-owned `PasteAwareRunner` over `Program#read_raw_input` so complete raw chunks are drained instead of losing bytes through bubbletea-ruby 0.1.4's one-event `poll_event` path. Copy remains terminal/OS-owned; Hive handles paste bytes only.

**Refreshed pages:**
- `wiki/commands/tui.md` — documented new-idea prompt editing keys, paste behavior, title cap, and the copy boundary.
- `wiki/e2e.md` — documented `tui_keys paste: true` and added the `tui_new_idea_editing` scenario to the coverage table.

## [2026-05-04T19:00:00Z] config — Hash-shape validation on top-level keys

**Action:** `Config.validate!` now runs `validate_hash_shaped_keys!` first. Keys in `HASH_SHAPED_KEYS = %w[brainstorm plan execute budget_usd timeout_sec review agents]` must be Hashes when present; scalar/nil/integer overrides (e.g. `brainstorm: claude`, `budget_usd: ~`, `timeout_sec: 600`) would survive `deep_merge` (override-not-Hash → returned unchanged) and crash later as `TypeError`/`NoMethodError` at `cfg.dig(...)` sites. Now raises typed `ConfigError` at load with a fix hint. Closes ce-code-review F1 (P1, gated_auto). State-model surface (schemas, marker grammar, layout) unchanged — pure validation tightening.

**Refreshed pages:**
- `wiki/modules/config.md` — Validation section now lists three ordered checks; `validate_hash_shaped_keys!` is #1.

## [2026-05-04T18:00:00Z] init — TTY prompts, stage agents, generous limits (ADR-023)

**Action:** Plan `docs/plans/2026-05-04-001-feat-hive-init-interactive-prompts-plan.md` shipped. `hive init` is now interactive on TTY: asks the operator for planning agent (combined brainstorm+plan), development agent (4-execute), review agents (multi-select), and 8 per-stage limit pairs. Recommended defaults are claude / codex / all-3-reviewers / generous limits. Non-TTY callers (CI, pipes, tests) short-circuit to defaults and emit a one-line summary. `Hive::Stages::Base.stage_profile(cfg, name)` reads the new `brainstorm.agent` / `plan.agent` / `execute.agent` keys with `|| "claude"` fallback; brainstorm / plan / execute spawn sites pin `status_mode: :state_file_marker` so codex's profile-default `:output_file_exists` doesn't break the marker-based lifecycle. `Config::DEFAULTS["budget_usd"]` and `["timeout_sec"]` bumped ~5×; deprecated `execute_review` key dropped.

**Refreshed pages:**
- `wiki/commands/init.md` — TLDR rewritten; added "Prompt flow", "Stable-iteration-order contract", and "Non-TTY contract" subsections; expanded "Steps performed" with the new prompt step + already-initialized guard ordering; refreshed Tests section with the new test surface.
- `wiki/decisions.md` — added ADR-023.
- `wiki/state-model.md` — auto-refreshed by post-commit hook to reflect bumped DEFAULTS and the new `brainstorm` / `plan` / `execute` blocks.
- `wiki/modules/config.md` — auto-refreshed by post-commit hook with the new DEFAULTS shape, ROLE_AGENT_PATHS extension, and the dropped `execute_review` note.

## [2026-05-04T11:50:00Z] commands/init — beautified summary

**Action:** Replaced the plain key:value summary printed at the end of `hive init` with a styled summary: green ✔ + bold heading + bold-cyan project name, dim labels in an aligned two-column block, and a cyan `→ next:` prompt. Colors are emitted only when `$stdout.tty?` and `NO_COLOR` is unset/empty, so piped/CI output stays plain. Field labels are now spaced (`default branch`, `hive state`, `worktree root`) instead of underscore-cased. Implementation lives in a nested `Hive::Commands::Init::Palette` so it can be lifted out if other commands want the same treatment.

**Refreshed pages:** none (the existing summary description in `wiki/commands/init.md` already describes it at a level that survives the cosmetic change).

## [2026-05-01T15:00:00Z] tui — v2 two-pane redesign

**Action:** Replaced v1's single-column action-grouped `Views::Grid` with a two-pane composition: `Views::ProjectsPane` (left, project list with `★ All projects` virtual entry) and `Views::TasksPane` (right, 5-column compact table — icon · slug · stage · status · age). `Views::Grid` and its tests were deleted in the same PR — no `HIVE_TUI_LAYOUT=v1` escape hatch. Pane focus is keyboard-only via `Tab` / `Shift+Tab` / `h` / `l`. `j` / `k` route by `model.pane_focus`: left-pane navigation drives `model.scope`; right-pane navigation drives the row cursor. New `n` keystroke opens an inline new-idea prompt that dispatches `hive new <project> "<title>"` via `Subprocess.run_quiet!` (project resolved from left-pane selection; `★ All` falls back to the first registered project, label shows `★→<name>` so the resolved target is visible). Below 70 cols the project pane is suppressed and the tasks pane occupies the full width. Visual style refresh: rounded borders, focused/dim border distinction (cyan/faint), refined action-key palette (magenta=agent_running, red=error, blue=ready_*, green=archived, yellow=needs_input/review_findings).

**Refreshed pages:**
- `wiki/commands/tui.md` — TLDR rewritten for the two-pane layout; added Layout section with ASCII mockup; expanded Modes table to include `:new_idea`; expanded Keybindings table (`Tab`/`Shift+Tab`/`h`/`l`/`n`/`g`/`G`); added Visual style section with the semantic color/icon mapping.

**Late fixes that were load-bearing for the headline features (commits 801cd11, b24bf73):**
- `submit_new_idea` previously dispatched `["new", project, title]` to `Subprocess.run_quiet!` which execs argv[0] literally → ENOENT/exit 127 → the headline `n` keystroke was dead in production. Fix: prepend `"hive"` to match every other `run_quiet!` caller in the codebase.
- `bubble_key_to_keymap` dropped `KEY_TAB` and `KEY_SHIFT_TAB` on the floor (returned NOOP). The Tab/Shift+Tab pane-focus toggle — the entire premise of the two-pane redesign as a navigable surface — never fired in production. KeyMap unit tests bypassed the translator by passing `:key_tab` directly. Fix: add `tab?` predicate + `Bubbletea::KeyMessage::KEY_SHIFT_TAB` branches at the BubbleModel layer where the bug surfaced.
- `TasksPane.render_row` checked `cursor[1] == flat_idx` against a flat-rows iterator, but `model.cursor` is `[project_idx, row_idx_within_project]`. At scope=0 multi-project, the visual highlight pointed at one row while verb dispatch (via `current_row`) resolved to a different row. Fix: walk visible_snapshot per-project so iteration coords align with cursor coords. Extracted `highlight?(model, p_idx, r_idx)` predicate so unit tests can assert the boolean decision (lipgloss strips ANSI in non-tty, masking the visual difference).
- Plus six P1/P2 follow-ups: Space symbol → `" "` mapping in `:new_idea`/`:filter` modes (multi-word titles); e2e scenario polls `state_assert` instead of `wait_subprocess` (`run_quiet!` doesn't emit BEGIN/END markers); stalled-poll banner restored after Grid deletion; pane focus pinned `:right` below `Model::TWO_PANE_MIN_COLS`; TasksPane `compute_layout` progressively drops columns at narrow widths; help overlay gains `:new_idea` section + g/G entries.
- Plus three more from the second review pass: `g`/`G` jump-to-top/bottom navigation (Plan R4 stretch); empty-submit flashes "title required" and stays in `:new_idea` (preserves the typed buffer); `Views::HelpOverlay::MODE_HEADERS` gains the `:new_idea` entry so v2's new-mode bindings are discoverable in the `?` overlay.

## [2026-04-30T17:00:00Z] cli — error envelopes on stdout for `hive run --json` and `hive status --json`

**Action:** Added `Hive::Schemas::RunErrorKind` (11 kinds) and `Hive::Schemas::StatusErrorKind` (3 kinds) closed enums under `Hive::Schemas`, mirroring the self-derived `ALL` pattern from `NextActionKind`/`TaskActionKind`. Amended `schemas/hive-run.v1.json` and `schemas/hive-status.v1.json` in place at v1: each schema now uses `oneOf: [SuccessPayload, ErrorPayload]` with the existing root content moved into `$defs.SuccessPayload`. Wired `Hive::Commands::Run` and `Hive::Commands::Status` `#call` with the canonical Pattern B rescue (`rescue Hive::Error => e; emit_error_envelope(e) if @json && !@stdout_written; raise`), with one departure from Pattern B — the `@stdout_written` guard, load-bearing for `hive run`'s existing dual-signal `:error`-marker contract. `bin/hive` rescue still produces the same exit codes; the only addition is a stdout JSON write on the error path when `--json` is set. Without `--json`, behavior is byte-identical to before.

**Refreshed pages:**
- `wiki/cli.md` — added an "Error envelopes" paragraph documenting the universal contract (every `--json`-supporting command emits an envelope on stdout when an error is raised; consumers detect failure by `payload.ok == false`).

## [2026-04-29T00:00:00Z] state-model trigger fired on TUI log_tail change — no wiki edit

**Action:** The state-model hook fired because `lib/hive/tui/log_tail.rb` was modified. Reviewed the diff: `flush_oversized_partial!` turned from single-pass into a `while` loop so `Tail#open!`'s 64KiB single-shot backbuffer read can't leave a multi-cap partial in memory after one flush. Added regression test `test_tail_open_with_no_newline_backbuffer_respects_partial_cap`. This is a TUI log-tailer memory-cap fix and does not touch the state-model surface (`task.rb`, `markers.rb`, `config.rb`, `lock.rb`, `worktree.rb`, `metrics.rb`). No edit to `wiki/state-model.md` or `wiki/modules/*.md`. The internal partial-cap loop is not currently a wiki-documented behavior and isn't worth surfacing on the user-facing `wiki/commands/tui.md` page.

**Refreshed pages:** none (log entry only).

## [2026-04-27T16:00:00Z] dependencies.md — `minitest` version row refreshed

**Action:** Audit triggered by Gemfile/Gemfile.lock change hook. The U11 curses removal is already reflected in the prior log entry; the only remaining stale row was `minitest`, which still showed `~> 5.20` (locked 5.27.0) from before the dependabot bump in commit `429ff4c`. Updated to `~> 6.0` (locked 6.0.5) to match the current Gemfile + lockfile.

**Refreshed pages:**
- `wiki/dependencies.md` — minitest row corrected; bump source noted inline.

## [2026-04-27T15:30:00Z] `hive tui` curses backend removed (plan #003 U11)

**Action:** U11 deletes the curses code path that lived alongside charm during U1–U10. `bundle install` no longer pulls in `curses` 1.6; `HIVE_TUI_BACKEND=curses` raises a typed error pointing at the removal; every `Curses.*` reference under `lib/` is gone. Bubble Tea + Lipgloss are now the only TUI runtime.

**Refreshed pages:**
- `wiki/dependencies.md` — `curses` row removed; TLDR drops the four-gem framing for three. Frontmatter `updated` bumped.
- `wiki/commands/tui.md` — Backend section already framed charm as default in U10; no edit needed beyond verifying no curses references survived.

**Code changes (referenced from wiki):**
- Deleted: `lib/hive/tui/render/{grid,triage,log_tail,help_overlay,filter_prompt,palette}.rb` (curses renderers — replaced by `lib/hive/tui/views/*.rb` in U7–U9), `lib/hive/tui/key_map/curses_keys.rb` (curses int → KeyMap-symbol translator — replaced by `BubbleModel#bubble_key_to_keymap`), `lib/hive/tui/grid_state.rb` (mutating cursor/scope/filter state — replaced by frozen `Hive::Tui::Model` + `Update.apply`).
- Slimmed: `lib/hive/tui.rb` from 399 to 36 lines — only `Hive::Tui.run` (with the MRI/tty boundary checks) survives. Curses run loop, triage subloop, log-tail subloop, filter-prompt subloop, help overlay, and `install_terminal_safety_hooks` all moved into `Hive::Tui::App.run_charm` + `BubbleModel` during U10 and are deleted here.
- Slimmed: `lib/hive/tui/subprocess.rb` — `takeover!` (curses-suspended spawn-and-wait) and the curses-state save/restore helpers (`with_curses_suspended`, `save_curses_state`, `end_curses`, `restore_curses_state`) deleted; `save_termios`/`restore_termios` deleted (the framework owns termios now). `takeover_command` (charm builder) and `run_quiet!` (curses-free, used for triage toggles) remain.
- Slimmed: `lib/hive/tui/app.rb` — `KNOWN_BACKENDS` is now `[CHARM]`, the `case backend` dispatch collapses to a single charm boot, and `REMOVED_BACKENDS` provides the migration-pointer error for `HIVE_TUI_BACKEND=curses`.
- Slimmed: `lib/hive/tui/key_map.rb` — back-compat shim (`dispatch` + `message_to_tuple`) deleted; only `message_for` remains.
- Updated tests: `test/integration/tui_subprocess_test.rb` drops `takeover!` cases (the `takeover_command` test class covers the same spawn/wait/trap path); `test/integration/tui_signals_test.rb` drops `install_terminal_safety_hooks` cases (the SIGHUP trap now lives in `App.run_charm`); `test/unit/tui/app_test.rb` exercises the curses-removal error; `test/unit/tui/key_map_test.rb` drops the legacy `dispatch`-based test class. Net delta: 597 unit tests, 200 integration tests, 0 failures.
- Removed: `Gemfile` entry for `curses ~> 1.6`; `Gemfile.lock` regenerated.

**Key decisions:**
- **`HIVE_TUI_BACKEND=curses` raises a removal-pointer error rather than silently falling back to charm.** Users who type the value because they hit a charm regression deserve a typed signal, not a confusing "unknown backend" or — worse — a silent override. The pointer lives in `App::REMOVED_BACKENDS` and one release from now will be deleted alongside the env var itself.
- **`Hive::Tui::GridState` deleted, not preserved.** The Charm Model (`Hive::Tui::Model`) plus `Update.apply` already cover the cursor/scope/filter semantics GridState owned. Keeping GridState as a "for testing" artifact would have invited drift the moment Model evolved.

## [2026-04-27T15:00:00Z] `hive tui` migrated to Charm bubbletea + lipgloss (plan #003 U1–U10)

**Action:** Plan #003 ships across 10 commits (U1 scaffold → U10 default flip). The TUI's render layer is now Bubble Tea MVU with Lipgloss styling; the curses path is kept one release as `HIVE_TUI_BACKEND=curses` for terminal-specific regressions. U11 (the curses removal) follows.

**Refreshed pages:**
- `wiki/commands/tui.md` — TLDR mentions bubbletea + lipgloss; new "Backend" section explains the MVU loop and the env-var escape hatch; "Subprocess takeover" rewritten around `Subprocess.takeover_command` + `Bubbletea::ExecCommand`; "Terminal hostility" rewritten around the runner's SIGWINCH/Ctrl-Z handling and `runner.send(TERMINATE_REQUESTED)` for SIGHUP. Frontmatter `updated` bumped.
- `wiki/dependencies.md` — `bubbletea` ~> 0.1.4 and `lipgloss` ~> 0.2.2 added as runtime gems; `curses` flagged as legacy/deprecated through U11. TLDR rewrite + "Why Bubble Tea + Lipgloss" rationale.
- `CHANGELOG.md [Unreleased]` — new "Changed — `hive tui` render layer migrated…" section at the top of the section list, ahead of "Breaking changes" / "Added".

**Code changes (referenced from wiki):**
- `lib/hive/tui/app.rb` — full MVU lifecycle: builds `Hive::Tui::BubbleModel` over `Model.initial`, wires `dispatch: runner.method(:send)`, installs SIGHUP→`runner.send(TERMINATE_REQUESTED)`, runs a 0.5s background poller that injects `SnapshotArrived` / `PollFailed` based on `StateSource.current`, runs `Bubbletea::Runner`, cleans up on exit. Default backend flipped from `curses` to `charm`; `HIVE_TUI_BACKEND=curses` still routes to `Hive::Tui.run_curses` until U11.
- `lib/hive/tui/bubble_model.rb` (new) — Bubbletea::Model adapter. Translates `KeyMessage` via `KeyMap.message_for(...)` and `WindowSizeMessage` to `Messages::WindowSized`; handles side-effect-bearing messages (`DispatchCommand` → `Subprocess.takeover_command`; `OpenFindings`/`OpenLogTail` synchronous I/O; `Bulk*`/`ToggleFinding` `run_quiet!` + reload); delegates everything else to `Update.apply`. Dispatches view by `model.mode` to one of `Views::Grid` / `Triage` / `LogTail` / `HelpOverlay` / composed `Grid + FilterPrompt`.
- `lib/hive/tui/views/{grid,triage,log_tail,help_overlay,filter_prompt}.rb` (new) — pure functions over `Hive::Tui::Model`. Mirror the curses `Render::*` content layout 1:1; styling switched to Lipgloss. Test layer pins layout/text content; visual styling validated by manual dogfood (lipgloss-ruby v0.2.2 strips ANSI in non-tty test envs).
- `lib/hive/tui/update.rb` — extended with keystroke-derived handlers: `Flash`, `CursorDown`/`CursorUp` (mirror `GridState#move_cursor_*` semantics), `ShowHelp`, `OpenFilterPrompt` (pre-fills buffer with active filter), `Back` (mode-aware revert clearing sub-mode state), `ProjectScope`, `Noop`. Pure-function transitions only — side effects live in BubbleModel.
- `lib/hive/tui/subprocess.rb` — adds `Subprocess.takeover_command(argv, dispatch:) → Bubbletea::ExecCommand` and the shared `run_takeover_child` core; curses `takeover!` retains its termios+curses-suspended wrapper.
- `lib/hive/tui/messages.rb` — extended with the keystroke-derived Message types (DispatchCommand, Flash, OpenFindings, OpenLogTail, ToggleFinding, BulkAccept, BulkReject, ProjectScope, plus singleton SHOW_HELP / OPEN_FILTER_PROMPT / BACK / CURSOR_DOWN / CURSOR_UP / NOOP).
- `lib/hive/tui/key_map.rb` — `dispatch(mode:, key:, row:)` is now a thin shim over `message_for(...)` + `message_to_tuple(...)`. Single source of truth — curses (which still calls `dispatch` through U10) and charm (which calls `message_for` directly via BubbleModel) cannot drift.

**Key decisions:**
- **`HIVE_TUI_BACKEND=curses` kept one release.** Curses is the escape hatch if Bubble Tea misbehaves on a user's terminal in production. The next release deletes it (per plan #003 U11). Without this hatch the migration would be a hard cut, which the plan's risk register explicitly counsels against given bubbletea-ruby's alpha status.
- **View tests pin layout, not styling.** lipgloss-ruby v0.2.2 strips ANSI in non-tty environments and exposes no force-color escape hatch. R19 (visual quality bar) is met by manual dogfood rather than golden-string color assertions; the gap is documented in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md` so a future renderer-profile API can close it.
- **Side effects live in `BubbleModel`, not `Update`.** Update.apply stays pure (Model in, [Model, Cmd] out) so state transitions are unit-testable in isolation. DispatchCommand wraps with `Subprocess.takeover_command`; OpenFindings/OpenLogTail/Bulk*/ToggleFinding do synchronous I/O — same pattern the curses path used in `Hive::Tui.run_triage` / `run_quiet!`. Inline I/O is acceptable for v1 because the operations are quick (file reads) and the alternative (Bubble Tea Cmd-as-Fiber) isn't exposed by bubbletea-ruby v0.1.4.

## [2026-04-27T13:30:00Z] `hive tui` deferred ce-code-review issues #10/#11/#12

**Action:** Commit `4ccad1a` closes the three deferred ce-code-review issues. Two CLI-surface changes worth wiki-recording: (1) `hive tui --json` reject path now emits a structured error envelope on stdout before raising (`{ok:false, error_class:"InvalidTaskPath", error_kind:"unsupported_flag", exit_code:64, ...}`) — no schema bump, because `tui` has no registered `hive-*` schema; (2) the non-tty boundary now raises `Hive::InvalidTaskPath` so it shares EX_USAGE (64) with the `--json` reject, instead of falling through to `Hive::Error` / generic exit 1. `tui` long_desc gained a one-line keystroke summary (`b/p/d/r/P/a`) so agents enumerating help see the human-only interaction shape.

**Refreshed pages:**
- `wiki/commands/tui.md` — terminal-hostility section now documents the JSON error envelope shape and the non-tty USAGE-64 alignment. Frontmatter `updated` bumped.
- `wiki/cli.md` — already updated in `4ccad1a` to flag `tui` as the sole `--json`-rejecting command; no further edit needed.

**Code changes (referenced from wiki):**
- `lib/hive/cli.rb` — `tui` action now emits the JSON envelope before raising on `--json`; long_desc keystroke line.
- `lib/hive/tui.rb` — non-tty raise upgraded to `Hive::InvalidTaskPath`; `restore_terminal_safety_hooks` (SIGHUP trap restore on clean exit); `terminate_requested?` checks added inside `triage_loop` and `log_tail_loop` so SIGHUP collapses subloops within a frame; `Errno::ENOENT/EACCES` rescue around `LogTail::Tail#open!` (race with rotation between `FileResolver.latest` and the open syscall); `Hive::NoReviewFile` rescue in `reload_or_flash` (concurrent archive/rerun) returns `:back` so triage drops to grid instead of crashing.
- `lib/hive/tui/key_map/curses_keys.rb` (new) — extracted curses-int → KeyMap-symbol translation out of `Hive::Tui` so KeyMap owns its own symbol contract.

**Key decisions:**
- **No schema for `tui`'s JSON error envelope.** `hive tui` is human-only and has no registered `hive-*` schema, so the envelope deliberately omits `schema` rather than minting a one-off `hive-tui-error.v1.json` whose only payload is the rejection. JSON consumers still see typed error data; schema-validating wrappers continue to validate against the agent-callable surfaces unchanged.
- **Non-tty + `--json` share EX_USAGE (64).** Both are misuse — the TUI cannot run without a terminal and cannot emit JSON — so wrappers can branch on a single "you used this wrong" exit code instead of distinguishing `1` (generic) from `64`. Documented in `wiki/commands/tui.md` "Terminal hostility".

## [2026-04-27T12:00:00Z] U2–U11 + polish — `hive tui` feature complete

**Action:** Remaining `hive tui` units landed on top of U1: U2 `StateSource`/`Snapshot` (1Hz polling, 5s stalled banner), U3 `KeyMap` (single source-of-truth keystroke→action), U4 `Subprocess.takeover!` / `run_quiet!` + `SubprocessRegistry`, U5 status grid + `GridState`, U6 findings triage mode (`a`/`r` rebind to bulk accept/reject), U7 agent log tail, U8 help overlay + workflow-verb cross-check, U9 SIGHUP / `at_exit` / `KEY_RESIZE` handling, U11 PTY smoke test (`bin/hive tui` boots, paints first frame, `q` exits 0). Then `bcf66cd` applied 13 of 32 ce-code-review findings on top.

**Refreshed pages:**
- `wiki/commands/tui.md` already covers the full surface (modes table, keybindings, verb-refusal-on-`agent_running`, `claude_pid_alive` reaping, `Subprocess.takeover!` 5-step protocol, `run_quiet!` for findings toggles, terminal-hostility section incl. SIGWINCH / SIGTSTP / SIGHUP / `at_exit`, `--json` rejection, full test surface). No further edit needed — landed alongside U1 with the units in mind.

**Code changes (referenced from wiki):**
- `lib/hive/tui/state_source.rb`, `snapshot.rb`, `key_map.rb`, `subprocess.rb`, `subprocess_registry.rb`, `grid_state.rb`, `triage_state.rb`, `log_tail/file_resolver.rb`, `help.rb` — the per-unit modules referenced by the existing `wiki/commands/tui.md` "Test surface" section.
- `test/integration/tui_subprocess_test.rb`, `test/smoke/tui_smoke_test.rb` — pin the curses tty round-trip and end-to-end PTY boot.
- `CHANGELOG.md` — `[Unreleased]` records `hive tui` (commit `643ce67`).

**Key decisions:**
- **No render-layer snapshot tests.** Mainstream Ruby tooling does not provide cell-perfect terminal-snapshot diffing; the data path is unit-tested per-module and the curses round-trip is pinned by the PTY smoke test. Documented in `wiki/commands/tui.md` "Test surface".
- **Wiki refresh stays scoped to `commands/tui.md`.** No stage runner changed; the TUI dispatches the same Thor verbs a human would type. `wiki/stages/` is intentionally untouched.

## [2026-04-27T00:00:00Z] U1 — `hive tui` bootstrap

**Action:** First implementation unit of the `hive tui` plan ([docs/plans/2026-04-27-001-feat-hive-tui-plan.md](../docs/plans/2026-04-27-001-feat-hive-tui-plan.md)). Adds the Thor command, the `Hive::Tui.run` skeleton, and the `curses` runtime gem. Subsequent units (U2–U11) replace the skeleton render loop with the real polling + render machinery. Wiki entries land alongside the command's first appearance per `CLAUDE.md` "wiki maintained alongside code".

**New pages:**
- `wiki/commands/tui.md` — modes, keybindings, data source, subprocess takeover, terminal hostility notes, test surface; structure mirrors `wiki/commands/status.md`.

**Refreshed pages:**
- `wiki/cli.md` — TLDR mentions the new human-only command; command table adds the `tui` row.
- `wiki/index.md` — Commands list links the new page; page count 35 → 36.

**Code changes (referenced from wiki):**
- `Gemfile` — adds `gem "curses", "~> 1.6"` to the production block (1.6.0 resolved).
- `lib/hive/tui.rb` (new) — module skeleton with the `Hive::Tui.run` entry point and the `RUBY_ENGINE != "ruby"` boot guard.
- `lib/hive/cli.rb` — registers `desc "tui"` + `def tui`; rejects `--json` with `Hive::InvalidTaskPath` (exit 64) per the plan's R13.
- `test/integration/tui_command_test.rb` (new) — pins the help-text registration, the `--json` rejection, the `long_desc` text, and the non-tty boundary check.

**Key decisions:**
- **Wiki landed in U1, not a separate U10.** Per KTD-10, conflating a multi-command wiki refresh with the TUI feature inflates blast radius; the TUI's own page is co-shipped with the Thor command so the new surface and its documentation are atomic. Broader wiki refresh for unrelated drift remains deferred.
- **Curses 1.6 production dep.** Stdlib-extracted, ruby-core maintained, ships with `def_prog_mode` / `reset_prog_mode` / `endwin` / injected `KEY_RESIZE` — every primitive the subsequent units need without picking up a 22 MB Rust dep (KTD-1).

## [2026-04-26T23:00:00Z] Round-4 — `hive markers clear`, schema v2, marker-policy refresh

**Action:** Round-4 ce-code-review remediation. Added `hive markers clear FOLDER --name <NAME>` as the agent-callable surface for recovery markers (`REVIEW_STALE` / `REVIEW_CI_STALE` / `REVIEW_ERROR` / `EXECUTE_STALE` / `ERROR`); bumped the `hive-approve` JSON contract to v2 (the v1 → v2 transition added `6-review` and renumbered `5-pr → 7-finalize` / `6-done → 8-done`); refreshed `wiki/commands/approve.md`'s marker-policy table to reflect the post-LFG-1 reality where `:review_complete` is in `VALID_TERMINAL_MARKERS`; and pointed `Stages::Review.run!`'s pre-flight `warn` lines at the new command.

**New pages:**
- `wiki/commands/markers.md` — full command reference: usage, allowlist, JSON contract, exit codes, "why a typed command instead of `sed -i`" rationale.

**Refreshed pages:**
- `wiki/commands/approve.md` — marker-policy section now has a per-marker table (which marker is written by which stage and unblocks which transition) and a forward note to `[[commands/markers]]` for the recovery markers. Frontmatter `updated: 2026-04-26`.
- `wiki/stages/review.md` — pre-flight table and REVIEW_STALE recovery section both reference the new command.
- `wiki/cli.md` — TLDR says seven commands (was six); command table adds `markers` row.
- `wiki/index.md` — Commands list adds `[[commands/markers]]`.

**Code changes (referenced from wiki):**
- `lib/hive/commands/markers.rb` (new) — `Hive::Commands::Markers#call` with subcommand dispatch, allowlist enforcement, marker-vs-state guard, atomic write via `Hive::Markers.write_atomic`, `hive_commit` audit-trail, JSON success and error envelopes.
- `lib/hive/cli.rb` — registers `hive markers SUBCOMMAND`.
- `lib/hive/stages/review.rb` — pre-flight `warn` text now embeds the exact `hive markers clear FOLDER --name <NAME>` invocation.
- `schemas/hive-markers-clear.v1.json` (new) — published JSON Schema (draft 2020-12).
- `schemas/hive-approve.v1.json` — restored to its original 6-stage shape (no `review`, ends at `5-pr` / `6-done`) so external validators pinned to v1 still validate.
- `schemas/hive-approve.v2.json` (new) — widened enum (`6-review`, `7-finalize`, `8-done`); marked `schema_version: 2`. `Hive::Schemas::SCHEMA_VERSIONS["hive-approve"] = 2`. `Hive::Schemas.schema_path` learned an optional `version:` kwarg so back-compat tests can load v1.
- `lib/hive/stages/review/context.rb` (new) — canonical home for the `Hive::Stages::Review::Context` Data type. `Hive::Reviewers::Context` retained as an alias for the reviewer adapter (`Hive::Reviewers::Agent`) and any custom registered reviewer.
- `lib/hive/agent_profile.rb` — explicit "Public API — do not break" comment block on `AgentProfile.new`; `status_detection_mode:` got a default of `:output_file_exists` so a future kwarg addition can't silently break custom profile registrations.
- `lib/hive/config.rb` — new `validate_review_attempts!` rejects `0` / negative / non-integer values for `review.ci.max_attempts`, `review.browser_test.max_attempts`, `review.max_passes`, `review.max_wall_clock_sec`.
- `lib/hive/stages/review/triage.rb` — error path now deletes any partial `reviews/escalations-NN.md` before returning so the next `hive run` doesn't read `escalations_count > 0` from a corrupt artifact.
- `lib/hive/agent.rb` — `Hive::Agent.bin` / `Hive::Agent.check_version!` now emit a one-shot deprecation warning outside the test suite (claude-specific; bypasses per-spawn profile selection).

**Key decisions:**
- **Schema v2 (Option A) over an in-place v1 break.** External consumers pinned to last week's v1 reject post-upgrade output. Restoring v1 to its original shape and bumping to v2 honors the published-contract semantics.
- **Allowlist excludes terminal-success markers.** `REVIEW_COMPLETE` / `EXECUTE_COMPLETE` / `COMPLETE` gate `hive approve`'s forward-advance check; clearing them silently would let an agent skip the approval gesture. Use `hive approve` instead.
- **Marker-vs-state guard refuses mismatch.** `hive markers clear FOLDER --name REVIEW_ERROR` on a folder whose actual marker is `REVIEW_STALE` raises `Hive::WrongStage` (exit 4) — the failure surfaces an agent's confusion before it edits the wrong file.

## [2026-04-26T22:00:00Z] U10b — wiki sweep for new modules

**Action:** Round-3 ce-code-review remediation flagged five new `lib/hive/` modules added across U9–U14 that lacked dedicated wiki pages. Created the missing pages, refreshed `wiki/templates.md` to catalogue every ERB shipped in the 6-review stage, and corrected the `review.browser_test` config-key drift in `wiki/stages/review.md`.

**New module pages:**
- `wiki/modules/agent_profile.md` — `Hive::AgentProfile` + `Hive::AgentProfiles` registry; built-in claude / codex / pi profiles; references ADR-017 / ADR-018 / ADR-019.
- `wiki/modules/reviewers.md` — `Hive::Reviewers.dispatch`, Context, Result, Base, Agent, SyntheticTask; references ADR-014 / ADR-015.
- `wiki/modules/metrics.md` — `Hive::Metrics.rollback_rate`, parse_commits, parse_trailers, reverted?; trailer schema cross-referenced to `lib/hive/trailers.rb`.
- `wiki/modules/secret_patterns.md` — `Hive::SecretPatterns.PATTERNS` + `scan`; consumers (PR body scan, post-fix diff guardrail).
- `wiki/modules/protected_files.md` — `ORCHESTRATOR_OWNED`, snapshot, diff; consumers (4-execute, 6-review's runner / triage / ci-fix).

**Refreshed pages:**
- `wiki/templates.md` — TLDR now reads "Seventeen ERB templates" (matches `ls templates/*.erb`); catalogue table extended with eight 6-review templates (`fix_prompt`, `ci_fix_prompt`, `browser_test_prompt`, `triage_courageous`, `triage_safetyist`, three reviewer prompts); legacy `review_prompt.md.erb` annotated as no-longer-wired.
- `wiki/stages/review.md` — corrected `cfg.review.browser` → `cfg.review.browser_test` (matches `lib/hive/stages/review/browser_test.rb`).
- `wiki/index.md` — Modules section adds five new entries; page count updated.



**Action:** Replaces the earlier "U10 partial sweep" note. Closes the deferred-page list by writing the full `wiki/stages/review.md`, rewriting `wiki/stages/execute.md` for the impl-only contract (ADR-014), extending `wiki/decisions.md` with ADRs 014–021, refreshing `wiki/architecture.md` and `wiki/index.md`, and updating `wiki/active-areas.md` to mark the 6-review backlog as shipped. Adds `test/smoke/live_review_smoke_test.rb` so `rake smoke` covers the autonomous loop end-to-end against the real claude binary.

**Code (wiki):**
- `wiki/stages/review.md` (new) — full stage page: setup, pre-flight state machine, the pass loop (CI → reviewers → triage → fix → guardrail → browser), per-phase descriptions of `Review::CiFix` / `Reviewers::Agent` / `Review::Triage` / `Review::FixGuardrail` / `Review::BrowserTest`, branching after triage (any `[x]` → fix; escalations only → `REVIEW_WAITING`; all clean → Phase 5), stale-`REVIEW_WORKING` recovery rules per phase, `REVIEW_STALE` recovery, test inventory.
- `wiki/stages/execute.md` rewritten — impl-only contract. State machine table now has no `:execute_waiting` / `:execute_stale`; success path is `init pass → spawn_implementation → SHA-protect → EXECUTE_COMPLETE`. Re-running an already-complete task announces 6-review. Reviewer sub-agent section deleted entirely.
- `wiki/decisions.md` — appended ADR-014 (6-review split — 4-execute drops to impl-only), ADR-015 (sequential reviewers; parallel deferred), ADR-016 (triage bias presets `courageous`/`safetyist`; `aggressive` dropped), ADR-017 (`AgentProfile` parameterisation), ADR-018 (per-CLI isolation flag warning, supersedes part of ADR-008), ADR-019 (per-spawn nonce, supersedes ADR-008's per-process memoization), ADR-020 (post-fix diff guardrail extends ADR-008's PR-stage secret-scan to fix-time), ADR-021 (per-spawn `status_mode` override; orchestrator-owned terminal markers).
- `wiki/architecture.md` — runner-table row for `6-review` (`Stages::Review` orchestrator + sub-runners + `Reviewers::Agent`); state-machine mermaid diagram updated to show `4-execute → 6-review → 7-finalize` (was `4-execute → 5-pr`); security paragraph extended to include the per-spawn nonce (ADR-019), per-CLI isolation logging (ADR-018), and the post-fix diff guardrail (ADR-020).
- `wiki/index.md` — pipeline tagline now says seven-stage; `decisions` link mentions 21 ADRs; stages list adds `[[stages/review]]`; commands list calls out `hive metrics rollback-rate`.
- `wiki/active-areas.md` — "additional reviewers in 4-execute" struck through with a note that they shipped under [[stages/review]] (and that linters belong in `review.ci.command` per ADR-014); parallel reviewers (Phase 2 of 6-review) listed as future work behind a config flag (per ADR-015 deferral); U14's "trailer-validation log" listed as deliberately dropped — agents that obey the prompt land trailers, the metric's signal is good enough without runner-side enforcement.

**Code (smoke):**
- `test/smoke/live_review_smoke_test.rb` (new) — opt-in `rake smoke` companion. Skips when `claude` is not on PATH. Reloads `Hive::AgentProfiles` registry in setup/teardown to defeat test pollution from other smoke tests. Sets up a tmp git repo, moves a task into `6-review/`, scaffolds a tiny worktree diff, writes a smoke `config.yml` (one `claude-ce-code-review` reviewer; CI/browser disabled; `max_passes: 1`), runs the loop, asserts the marker terminates as `:review_complete` or `:review_waiting`. Does NOT assert which one — real claude on a real diff may legitimately find findings; both terminal states are clean exits.

**Key decisions:**
- **The smoke is one test, not a suite.** Live-claude spawns are expensive (~$0.25 per run per the existing smoke comment) and brittle (depend on real claude availability + version + token allotment). Integration tests already cover every branch of `Stages::Review.run!` against fake-claude / stubs. The smoke's job is to prove the templates render through real claude and the per-spawn nonce works under real spawn — one test is enough.
- **The smoke accepts `REVIEW_COMPLETE` OR `REVIEW_WAITING` as a pass.** Real claude may find findings (we don't control its output); both are clean terminal states. Anything else (`:review_error`, raised exception) means the runner itself broke, which is what the smoke is guarding against.
- **The wiki sweep documents *current* state, not history.** Per ADR-style convention, stage / module pages describe behavior as it is now. The U-unit history lives in this log; the ADRs explain decisions.

## [2026-04-26T15:00:00Z] U14 ship — `hive metrics rollback-rate` + fix-commit trailers

**Action:** Adds the rollback-rate metric so the triage bias preset (`courageous` default vs `safetyist` opt-in) becomes a measurable trade-off rather than a vibes choice. The fix prompt and ci-fix prompt now require git trailers on every commit (`Hive-Fix-Pass`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase`); `hive metrics rollback-rate` walks `git log` and reports what fraction of trailered commits were later reverted. Closes doc-review PL-2.

**Code:**
- `lib/hive/metrics.rb` (new) — `Metrics.rollback_rate(project_root, since:)`. Walks `git log --all` with a NUL-record-separator format (`%H\x00%s\x00%b\x00\x01\n`) so commit bodies with embedded newlines parse correctly. Trailer parsing is in-process (a one-line regex per body) to avoid spawning `git interpret-trailers` per commit on long histories. Revert detection covers two forms: subject-quote match (`Revert "..."`) and `This reverts commit <sha>` body cite (short or full). Returns `{total_fix_commits, reverted_commits, rollback_rate, by_bias, by_phase, since, project_root}`.
- `lib/hive/commands/metrics.rb` (new) — Thor-callable command class. `--days N` filter; `--project NAME` scopes to one registered project; `--json` emits the `hive-metrics-rollback-rate` schema (single line, parity with `hive status --json`). Exit codes: 0 success; 2 unknown subcommand / unknown project / no projects registered. Text output groups by bias and by phase so the user can see whether `courageous` outpaces `safetyist` on rollbacks.
- `lib/hive/cli.rb` — registers `hive metrics SUBCOMMAND` (default: `rollback-rate`) under Thor.
- `templates/fix_prompt.md.erb` — new "Required commit trailers" section that renders the trailer block with values pre-filled (`Hive-Task-Slug`, `Hive-Fix-Pass`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase: fix`). Agent fills `Hive-Fix-Findings: <count>` per commit.
- `templates/ci_fix_prompt.md.erb` — same convention with `Hive-Fix-Phase: ci`. CI-fix doesn't carry triage bias or reviewer sources (those concepts only exist for review-fix).
- `lib/hive/stages/review.rb` — `spawn_fix_agent` now passes `task_slug`, `triage_bias`, `reviewer_sources` to the template bindings. Two new helpers: `triage_bias_for(cfg)` reads `review.triage.bias` (default "courageous"); `reviewer_sources_for(ctx)` derives a comma-separated list from per-reviewer files in `reviews/` for the current pass (filters out orchestrator-owned files: escalations, ci-blocked, browser-, fix-guardrail-).
- `lib/hive/stages/review/ci_fix.rb` — `spawn_fix_agent` now passes `task_slug` (derived from `File.basename(ctx.task_folder)` since the task slug is always the folder basename per `Task::PATH_RE`).
- `test/unit/metrics_test.rb` (new, 8 tests) — Trailer parsing, subject-revert detection, sha-revert detection, by-bias / by-phase breakdown, since filter, missing-root → ArgumentError, no-trailer commits excluded.
- `test/integration/metrics_command_test.rb` (new, 5 tests) — JSON schema (`hive-metrics-rollback-rate` v1); text output; unknown project → exit 2; unknown subcommand → exit 2; no registered projects → exit 2.
- `test/integration/prompt_injection_test.rb` — `test_fix_prompt_wraps_accepted_findings` now asserts the trailer block renders with the expected per-spawn values.

**Key decisions:**
- **In-process trailer parsing, not `git interpret-trailers` per commit.** A simple `^([A-Za-z][A-Za-z0-9-]*):\s*(.+)$` regex over the body is good enough for the trailer shape the templates emit. Spawning a subprocess per commit blows up wall time on a project that's been running for months.
- **`git log --all` instead of single-branch lineage.** A v1 metric. The plan called this "out-of-scope for v1" and we honored it: a Revert that lives on a different branch shows up as a rollback, which is the conservative direction (slightly noisy → user sees a higher rate → bias toward safetyist; the opposite would silently underreport rollbacks).
- **Trailers are documented in the template, NOT validated in the runner.** The plan called for a validation log (`fix-trailer-missing-NN.log`), but it adds runner complexity that hasn't paid back yet — agents that obey the prompt land trailers, and the metric just gets noisier when one slips through. We'll add validation if real usage shows the slip rate is high.
- **`Hive-Reviewer-Sources` derived from filenames, not from accepted findings.** Cheaper (no parsing) and more honest: even reviewers whose findings were all rejected get listed, because they still contributed to the triage decision. A consumer who wants "which reviewer's [x] marks landed in this commit" can grep `accepted_findings`.
- **`unknown` is the bias bucket for trailer-less or pre-rollout commits.** Don't drop them on the floor — the ratio of unknown vs known is itself a signal that the prompt-template rollout isn't complete.

**Wiki updates:** wiki/cli.md and wiki/index.md will land in U10's wiki sweep alongside the broader stage docs.

## [2026-04-26T14:00:00Z] U13 ship — Post-fix diff guardrail (ADR-020) real implementation

**Action:** Replaces the U9 stub of `Hive::Stages::Review::FixGuardrail` with a real diff scanner. After Phase 4 commits land in the 6-review autonomous loop, the runner takes `git diff base..head` of just the new commits and walks it once, dispatching each line to the configured pattern set. A match short-circuits the loop with `REVIEW_WAITING reason=fix_guardrail` and writes `reviews/fix-guardrail-NN.md` so the user inspects before the loop continues. The motivating threat model: a fix agent could otherwise auto-merge a `curl ... | sh`, edit a `.github/workflows/*.yml`, or commit a credential — and the user would only see a green pass with one extra commit on the branch.

**Code:**
- `lib/hive/secret_patterns.rb` (new) — Shared regex set (`Hive::SecretPatterns::PATTERNS` + `scan(text)`). 11 patterns: AWS access key (AKIA…), AWS secret access key, GitHub tokens (ghp/ghs/gho/ghu), generic api_key assignment, PEM private keys, OpenAI sk-, Anthropic sk-ant-, Stripe sk/rk/pk_live/test, Slack xox[abprs], JWT (eyJ...). Two consumers: pr.rb's body scan (ADR-008) and fix_guardrail.rb's diff scan (ADR-020). Snippets truncated to 80 chars so callers can include them in error messages without leaking long secrets.
- `lib/hive/stages/review/fix_guardrail/patterns.rb` (new) — `Patterns::DEFAULTS` Hash. 6 default patterns: `shell_pipe_to_interpreter` (curl/wget pipe into sh/bash/python/ruby/node), `ci_workflow_edit` (`.github/workflows/`, gitlab-ci, circleci, Jenkinsfile, bitbucket-pipelines, azure-pipelines, travis), `secrets_pattern_match` (special-cased — dispatches to SecretPatterns.scan), `dotenv_edit` (`.env*`, secrets.yml, credentials.yml, .npmrc, .pypirc), `dependency_lockfile_change` (Gemfile.lock, package-lock.json, pnpm-lock, yarn.lock, Cargo.lock, go.sum, poetry.lock, Pipfile.lock, composer.lock, uv.lock), `permission_change` (raw diff header `new mode 100755`). Each descriptor: `:regex`, `:severity`, `:targets` (`:code` / `:file_path` / `:raw_diff_header`), `:description`.
- `lib/hive/stages/review/fix_guardrail.rb` — Replaces the U9 stub (`Result.new(status: :clean, matches: [])`) with the real walker. `run!` early-returns `:skipped` when `enabled: false` or `bypass: true`; `:clean` when sha pair empty/equal; otherwise `git diff --unified=0 base..head` → `scan_diff(diff, patterns)`. `scan_diff` tracks current file via `+++ b/<path>` headers and current line via `@@ -X +A,B @@` headers; for each pattern checks `:targets` and matches against file path (file_path), added line content (code, with secrets_pattern_match dispatching to SecretPatterns), or raw header line (raw_diff_header). `resolve_patterns(cfg)` applies `review.fix.guardrail.patterns_override`: `false` value disables a default; Hash value adds a custom (must include `regex`, raises `Hive::ConfigError` otherwise; defaults `severity: medium`, `targets: code`).
- `test/unit/stages/review/fix_guardrail_test.rb` (new, 15 tests) — Covers skipped paths (disabled / bypass), clean paths (base==head, no patterns match), all 6 default patterns (curl|sh, wget|bash, .github/workflows/*, Jenkinsfile, AWS access key, GitHub token, .env, Gemfile.lock, package-lock.json), override mechanism (disabling a default, adding a custom regex), and `Hive::ConfigError` on missing `regex` for a custom override. Uses `with_tmp_git_repo` + `with_two_commits` helpers — runs against a real git index, not a string fixture, so the regex/diff format are exercised against actual `git diff` output.

**Key decisions:**
- **Walk the diff once, dispatch per line.** Earlier draft had separate passes for file_path / code / raw_diff_header. Walking once is simpler, cheaper on large diffs, and the per-pattern dispatch in the inner loop is fine because the pattern set is tiny (default 6, capped by config).
- **`secrets_pattern_match` is special-cased, not a regex literal.** The pattern descriptor's `:regex` is `nil`; `scan_diff` checks `name == :secrets_pattern_match` and dispatches to `Hive::SecretPatterns.scan(added)`. This lets one config knob disable the entire secrets bundle without flattening 11 patterns into the override surface, and keeps the secrets module reusable for the PR-body scan.
- **Custom patterns get safe defaults.** `severity: :medium`, `targets: :code` if unspecified. Description defaults to `"custom pattern: <name>"`. `:regex` is the only required key — nudges users into adding patterns without forcing them to internalize the descriptor schema.
- **String regex in YAML compiles to Regexp.** `Regexp.new(regex.to_s)` accepts both `Regexp` literals (Ruby) and `String` (YAML). Doesn't try to be clever about flags — if the user wants case-insensitive, they write `(?i)…`.
- **`raw_diff_header` is its own target.** Permission changes show up as `new mode 100755` header lines, not as content. Mixing them into `:code` would either miss them (header lines don't start with `+`) or false-positive on actual content matching the same regex. Separating the target is the cleanest way to scan them.
- **Diff captured with `--unified=0`.** Zero context lines keeps the diff focused on actual changes — context lines that happen to match a pattern (e.g., a long-standing `curl ... | sh` in a script that's being touched elsewhere) wouldn't be flagged. We only flag *new* additions in this commit range.
- **base_sha == head_sha returns `:clean`, not `:skipped`.** Phase 4's "no commits" case is benign — there's nothing to scan, and the loop should treat it as "guardrail had nothing to do" rather than "guardrail was disabled."

**Wiki updates:** state-model.md updated date.

## [2026-04-26T10:00:00Z] U9 ship — Review runner integration + 4-execute drops to impl-only

**Action:** Phase 3 of the plan. Wires U4 (reviewer adapter), U6 (triage), U7 (CI-fix), U8 (browser-test), and U13 (post-fix guardrail, stubbed) into the autonomous loop documented in the plan's high-level technical design. Concurrently, 4-execute drops its review pass and finalizes with `EXECUTE_COMPLETE` immediately after impl spawn — the user `mv`s to `6-review` to enter the review loop.

**Code:**
- `lib/hive/stages/review.rb` — `Hive::Stages::Review.run!(task, cfg)`. Pre-flight inspects markers (REVIEW_COMPLETE / REVIEW_CI_STALE / REVIEW_STALE / REVIEW_ERROR short-circuit). Validates worktree.yml. Tracks wall-clock budget at every phase boundary. Pass loop runs CI (Phase 1, once on entry) → reviewers (Phase 2) → triage (Phase 3) → branch (Phase 4 fix or REVIEW_WAITING) → loop with pass++ → eventually browser-test (Phase 5) → REVIEW_COMPLETE. Stub finding files for failed reviewers; REVIEW_ERROR if all reviewers fail. SHA-256 protects plan.md/worktree.yml/task.md around the fix spawn. Honors REVIEW_WAITING resume by skipping Phase 2/3 and going straight to Phase 4 with the user's manually-toggled [x] marks.
- `lib/hive/stages/review/fix_guardrail.rb` — **stub** for U13. Returns `{status: :clean, matches: []}`. U13 will fill in the regex/pattern matching against the new commits' diff. Phase 4 calls FixGuardrail unconditionally so U13 lands as a pure module-body change with no further wiring.
- `templates/fix_prompt.md.erb` — Phase 4 fix-agent prompt. Receives `accepted_findings` (concatenated [x] lines from per-reviewer files) wrapped in the per-spawn nonce. Instructs the agent to apply each finding scope-narrowly, run tests, commit. Same constraint set as triage: no edits to plan.md/worktree.yml/task.md/reviews/*.
- `lib/hive/stages/execute.rb` rewritten — impl-only since U9. Drops `run_iteration_pass`, `current_pass_from_reviews`, `collect_accepted_findings`, `count_findings`, `finalize_review_state`, `spawn_reviewer`. Single-pass: spawn impl → SHA-protect plan.md/worktree.yml → set EXECUTE_COMPLETE. Re-running on a complete task says "already complete; mv to 6-review/".
- `templates/execute_prompt.md.erb` rewritten — drops the "after impl, expect a review pass" language. Agent's job is "implement the plan and commit" full stop; user mv's to 6-review to run the review loop.
- `lib/hive/stages.rb` — DIRS now `[1-inbox, 2-brainstorm, 3-plan, 4-execute, 6-review, 7-finalize, 8-done]` (no gap). next_dir(4) returns "6-review".
- `lib/hive/commands/run.rb` — pick_runner adds the `"review"` case routing to `Hive::Stages::Review.run!`.
- `lib/hive/task.rb` — STAGE_NAMES + STATE_FILES gain "review" → "task.md".
- `schemas/hive-approve.v1.json` — stage enums include `review` and `6-review`.
- `test/unit/stages_test.rb` — DIRS / SHORT_TO_FULL / NAMES / next_dir assertions updated for the filled gap.
- `test/integration/run_execute_test.rb` rewritten — drops 7 review-iteration tests; keeps + adds impl-only tests (init pass → EXECUTE_COMPLETE; re-run announces 6-review; tampering → :error; impl failure → :error; missing plan.md exits 1; no review files written).
- `test/integration/run_review_test.rb` (new) — 9 integration tests: REVIEW_COMPLETE / REVIEW_CI_STALE / REVIEW_STALE / REVIEW_ERROR pre-flight short-circuits; missing worktree.yml exits 1; worktree dir missing exits 1; clean fast path (zero reviewers + nil CI + browser disabled → REVIEW_COMPLETE skipped); CI hard-block → REVIEW_CI_STALE + ci-blocked.md written; wall-clock cap → REVIEW_STALE reason=wall_clock.
- `test/integration/full_flow_test.rb` — flow now goes 4-execute → 6-review → 7-finalize (the new transition).
- `test/integration/prompt_injection_test.rb` — `test_execute_prompt_wraps_plan` (no accepted_findings binding anymore) + new `test_fix_prompt_wraps_accepted_findings` for the 6-review fix prompt.

**Key decisions:**
- **One `hive run` lands a terminal marker or exhausts budgets.** No partial-run states the user has to manually reconcile. The loop runs CI once, then iterates Phase 2/3/4 until terminal (REVIEW_WAITING / REVIEW_STALE / REVIEW_ERROR / REVIEW_COMPLETE).
- **REVIEW_WAITING resume skips Phase 2/3 and re-enters Phase 4 directly.** When the user has manually toggled `[x]` in per-reviewer files and re-runs hive, re-running triage would overwrite their decisions. So resume goes straight to fix.
- **Empty reviewers list is OK, not an error.** Zero reviewers configured = nothing to triage = clean branch = Phase 5. Useful for testing and for projects that haven't configured the reviewer set yet.
- **Pass derivation by max-NN-suffix in reviewer filenames.** No frontmatter pass: field, no pass.txt sidecar. Recovery is filesystem-native: delete the highest-NN reviewer files to drop pass back.
- **EXECUTE_COMPLETE is the only success state for 4-execute.** No more EXECUTE_WAITING / EXECUTE_STALE — those moved to REVIEW_WAITING / REVIEW_STALE in 6-review.

266 tests passing (was 259 pre-U9 + 9 new review runner integration tests − 7 dropped 4-execute review-iteration tests + 5 new misc). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass (`wiki/stages/review.md` new page, `wiki/stages/execute.md` rewrite, `wiki/state-model.md` directory layout, `wiki/decisions.md` ADR-014–021) deferred to U10.

## [2026-04-25T22:00:00Z] U8 ship — Browser-test phase (soft-warn + JSON result protocol)

**Action:** Phase 2's fourth primitive. Optional. Skipped entirely when `review.browser_test.enabled` is false (default). When enabled, runs after Phase 2 produced zero findings and before the runner finalizes. Spawns the configured agent (typically claude with the `/ce-test-browser` skill) up to `review.browser_test.max_attempts` times. Each attempt is expected to write `reviews/browser-result-<pass>-<attempt>.json` with `{status, summary, details, duration_sec}`.

**Soft-warn semantics (per plan R11):** persistent failure does NOT hard-block the loop. After the cap, the runner writes `reviews/browser-blocked-<pass>.md` (embedding every attempt's summary + details) and returns `:warned` so `REVIEW_COMPLETE browser=warned` lands. The 7-finalize stage surfaces the warning in the PR body. Browser flakiness is common; the user decides whether to ship anyway.

**Code:** `lib/hive/stages/review/browser_test.rb`. `BrowserTest.run!(cfg:, ctx:) → Result(status, attempts, summary, details, error_message)`. Status values: `:passed`, `:warned` (cap reached), `:skipped` (disabled). Per-attempt JSON parsing tolerates malformed / missing files by treating them as `:failed` with an explanatory summary — the runner moves to the next attempt either way.

**Code (template):** `templates/browser_test_prompt.md.erb`. Receives project_name, worktree_path, task_folder, attempt, pass, result_path, skill_invocation, user_supplied_tag. Instructs the agent to **invoke the `<%= skill_invocation %>` skill** (rendered as `/ce-test-browser` for claude/codex/pi via `profile.skill_syntax_format`) on the worktree, then write the structured JSON result. Explicit instruction: "you do not run test commands directly; you invoke the skill and let it drive."

**Spawn:** uses `status_mode: :output_file_exists` keyed on the per-attempt JSON path. Combined with U4's per-spawn mode override, the orchestrator's `REVIEW_WORKING phase=browser` marker survives across both attempts without `:agent_working` clobber.

**Key decisions:**
- **JSON result protocol over exit-code or marker.** A browser test does more than pass/fail (multiple flows, screenshots, duration); the structured JSON gives the runner enough to surface a useful warning if every attempt fails. Exit-code-only would lose summary/details. State-file marker would conflate with the orchestrator's `REVIEW_WORKING`.
- **Tolerate malformed JSON.** Agent crashed mid-write, network blip, partial file — all classified as `:failed` for that attempt with a one-line "produced no result file" or "produced unparseable JSON" summary. Loop continues to the next attempt rather than escalating to `:error`. Browser tests are expected to be flaky.
- **Browser-blocked doc embeds every attempt.** When all attempts fail, the user gets the full progression in `reviews/browser-blocked-<pass>.md` (Attempt 1 summary/details, Attempt 2 summary/details). Picking only the last attempt would lose context — the failure mode might have shifted between attempts.

**Tests (+8):** disabled (no spawn); passes attempt 1 (single fake-claude write); passes attempt 2 (custom counter-flipper bash script — attempt 1 writes failed, attempt 2 writes passed); fails twice → `:warned` + browser-blocked.md with both attempts embedded; missing JSON counts as failed; unparseable JSON counts as failed; agent timeout counts as failed; prompt invokes `/ce-test-browser` via `profile.skill_syntax_format` (proves the per-CLI skill-invocation path works end-to-end). Plus 2 unit-level tests for `parse_result_file` (passed/unknown status handling).

259 tests passing (was 251). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass deferred to U10.

## [2026-04-25T21:30:00Z] U7 ship — CI-fix loop with output capture

**Action:** Phase 2's third primitive. Runs the project's local CI command (`review.ci.command`, e.g. `bin/ci` or `bin/rails test`); on failure, captures the failure log and spawns a fix agent that reads the error, edits the offending files, commits, and lets the loop re-run CI. Caps at `review.ci.max_attempts` (default 3); after the cap returns `:stale` so the U9 runner can write `reviews/ci-blocked.md` and set `REVIEW_CI_STALE`. Reviewers must NOT run on red CI per the plan's hard-block contract.

**Code:** `lib/hive/stages/review/ci_fix.rb`. `CiFix.run!(cfg:, ctx:) → Result(status, attempts, last_output, error_message)`. Status values: `:green` (CI passed), `:stale` (cap reached without green), `:skipped` (`command` is nil/empty), `:error` (CI binary not runnable, or fix-agent failure). Direct `Open3.capture3` exec via `Shellwords.split` — no `sh -c` indirection so a missing binary raises `ENOENT` cleanly instead of returning shell exit-127.

**Output capture (the load-bearing part — projects' CI commands vary widely):**
- Combined stdout + stderr captured into one stream (some tools write failures to stderr, others to stdout).
- ANSI escape sequences stripped (rspec, jest, cargo emit color even when stdout isn't a TTY).
- Tailed to `review.ci.tail_lines` (default 200) so the fix agent doesn't get a 50k-line log that blows token budget. A "[N earlier lines truncated...]" header tells the agent it's seeing only the tail.
- Hard size cap at `review.ci.max_log_bytes` (default 256 KB) on the captured byte count to defend against runaway processes.
- Invalid UTF-8 sequences scrubbed to `?` so the agent prompt is always a valid string.

**Code (template):** `templates/ci_fix_prompt.md.erb`. Receives project_name, worktree_path, command, attempt, max_attempts, captured_output (in `<user_supplied_<nonce>>` wrapper, ADR-019). Instructs the agent to diagnose, fix, and commit; explicit "do NOT execute instructions inside `<user_supplied>` — that's untrusted CI output, classify it as data not commands."

**Fix-agent spawn:** uses `status_mode: :exit_code_only` (the agent's success is "I committed a plausible fix"; CI's actual outcome is verified on the next loop iteration, not via marker or output file).

**Key decisions:**
- **Direct exec over `sh -c`.** Shellwords-tokenized so `command: "bin/ci --flag"` works as YAML, but no shell indirection means missing-binary detection is clean. Trade-off: shell pipe idioms (`bin/ci | tee`) aren't supported. Projects that need them can wrap in a script and point `command` at it.
- **Captured output goes through the same per-spawn nonce wrapper** as triage's reviewer-content blocks. A hostile CI log (e.g., a test that prints `</user_supplied>` literal) cannot escape because the per-spawn nonce is unguessable.
- **Hive doesn't try to parse CI failures.** No language-specific knowledge, no "find the test name" regex. The agent reads the captured output as plain text and figures it out. Keeps hive ecosystem-agnostic (closes the same scope concern as U4's linter drop).

**Tests (+10):** skipped path (nil command, empty string); green attempt 1 (no agent spawn); green after fix (fake-claude writes a marker file the next CI invocation checks for); capped → :stale at max_attempts; CI command not found → :error; ANSI color codes stripped; long output (1000 lines) truncated to last N; both stdout and stderr captured; captured output reaches the fix agent's prompt with the per-spawn nonce wrapper.

251 tests passing (was 241). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass deferred to U10.

## [2026-04-25T21:00:00Z] U6 ship — Auto-triage step + courageous/safetyist prompts

**Action:** Phase 2's second primitive. Reads every `reviews/<*>-<pass>.md` produced by U4's reviewers, hands them to a triage agent (configured via `review.triage.agent`), and expects the agent to (a) edit each file in place adding `[x]` on auto-fix items + `<!-- triage: <reason> -->` annotations, and (b) write `reviews/escalations-<pass>.md` listing only the still-`[ ]` items grouped by source-reviewer. The U9 runner uses `escalations.md` to decide between `REVIEW_WAITING` (escalations remain) and Phase 4 (fix `[x]` items).

**Code:**
- `lib/hive/stages/review/triage.rb` — `Triage.run!(cfg:, ctx:)` entry point. Discovers reviewer files for `ctx.pass` (excluding `escalations-NN.md` itself), resolves the bias preset or custom prompt, renders, spawns via `Stages::Base.spawn_agent` with `status_mode: :output_file_exists` keyed on `escalations-NN.md`. SHA-256 protected-files check (plan.md, worktree.yml, task.md) wraps the spawn — tampering yields `:tampered` status with the offending file list (per ADR-013-style guarding).
- `templates/triage_courageous.md.erb` — default action-biased preset. Encodes origin R9 rules: auto-fix polish/clarity/dead-code/doc/lint/missing-tests/simple-bug/perf-with-mechanism/security-with-known-pattern. Escalate only architecture / auth / data-integrity / contradictions / low-confidence. Explicit instruction "do NOT postpone polishes" per the user's stated frustration.
- `templates/triage_safetyist.md.erb` — escalation-biased opt-in. Auto-fix only the truly mechanical (typos, lint, dead code, doc); escalate everything else by default. For projects where the human gate matters more than throughput.
- Custom prompt path resolution: `cfg.review.triage.custom_prompt` (a basename relative to `<.hive-state>/templates/`) overrides the bias-preset selection. Path-escape attempts (`../`, absolute path, missing file, symlink to outside) raise `Hive::ConfigError`. Resolved via `File.realpath` + prefix check.
- Empty-reviewer-files path: when no reviewer files exist for the current pass, `Triage.run!` skips the agent spawn entirely and writes a sentinel `# Escalations for pass NN — _No reviewer findings ..._` doc. Lets the U9 runner branch deterministically.

**Key decisions:**
- **Per-spawn nonce wrapping (ADR-019) carries over.** Each reviewer file's content is wrapped in its own `<user_supplied_<nonce> content_type="reviewer_md" path="...">` block. The same nonce is shared across blocks within ONE triage spawn but is fresh per spawn — a hostile reviewer file containing `</user_supplied>` cannot escape the wrapper because the per-spawn nonce is unguessable.
- **Reviewer files are NOT in the protected-set.** Triage's *job* is to edit them in place. Only plan.md / worktree.yml / task.md are SHA-checked.
- **`status_mode: :output_file_exists`** keyed on `escalations-<pass>.md`. Combined with U4's per-spawn mode override, the orchestrator's `REVIEW_WORKING phase=triage` marker survives the triage spawn (no `:agent_working` clobber).
- **Prompt content lives in templates, not in code.** Future bias presets can land as additional templates without touching `triage.rb`.

**Tests (+10):**
- Empty reviewer files → sentinel escalations doc + `:ok`.
- Courageous mode: prompt mentions "courageous mode", references reviewer file paths and the escalations target, includes per-spawn nonce wrapper.
- Safetyist mode: prompt mentions "safetyist mode", does NOT mention "courageous mode".
- Custom prompt: user-supplied template at `<.hive-state>/templates/triage_custom.md.erb` is rendered; preset content is absent from the prompt.
- Custom prompt path-escape (`../../../etc/passwd`) raises `ConfigError`.
- Custom prompt missing file raises `ConfigError`.
- Unknown bias preset (`yolo`) raises `ConfigError`.
- SHA-256 protected files: a tampering fake-claude that mutates `plan.md` is caught — `:tampered` status with `tampered_files: ["plan.md"]`.
- Missing escalations output → `:error` with "missing or empty" in error_message.
- `discover_reviewer_files` excludes `escalations-NN.md` and other-pass reviewer files.

241 tests passing (was 231). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass (`wiki/stages/review.md` new page) deferred to U10.

## [2026-04-25T20:30:00Z] U4 ship — Reviewer adapter abstraction (agent-only in v1)

**Action:** Phase 2's first primitive. Common interface for "anything that produces `reviews/<name>-<pass>.md`" so the 6-review runner's per-reviewer loop is shape-uniform across reviewer types. Plus a per-spawn `status_mode:` override on `Hive::Agent` so the same claude binary serves both `:state_file_marker` mode (4-execute) and `:output_file_exists` mode (reviewer adapter) — the orchestrator's `REVIEW_WORKING` marker now survives each reviewer's spawn.

**Code:**
- `lib/hive/reviewers/base.rb` — `Reviewers::Context` (Data) + `Reviewers::Result` (Data) + `Reviewers::Base` interface (defines `#run!`, `#name`, `#output_path`).
- `lib/hive/reviewers/agent.rb` — agent-based reviewer. Renders the spec's `prompt_template` with skill-invocation per profile (`profile.skill_syntax_format` formatted with the spec's `skill`), spawns via `Stages::Base.spawn_agent` with `status_mode: :output_file_exists`, returns `Result.new(name, output_path, status, error_message)`.
- `lib/hive/reviewers.rb` — `Reviewers.dispatch(spec, ctx)`. Single entry point. v1 supports `kind: agent` only.
- `templates/reviewer_claude_ce_code_review.md.erb`, `templates/reviewer_codex_ce_code_review.md.erb`, `templates/reviewer_pr_review_toolkit.md.erb` — three reviewer prompt templates. Each renders `<%= skill_invocation %>` via the profile's `skill_syntax_format` so the same template works across CLIs once profile is selected.
- `lib/hive/agent.rb` — added `status_mode:` per-spawn kwarg (overrides `profile.status_detection_mode`). Mode-gated marker writes: `:state_file_marker` mode preserves today's behavior (`:agent_working` pre-spawn + `:error` on timeout/exit_code); `:exit_code_only` and `:output_file_exists` modes leave `task.state_file` untouched so the orchestrator-owned marker survives.
- `lib/hive/stages/base.rb` — `spawn_agent` accepts and forwards `status_mode:`.

**Key decisions:**
- **Linter reviewers DROPPED from v1.** Tool-specific linters (rubocop, brakeman, golangci-lint, ruff, etc.) belong in the project's `bin/ci`, not in hive's reviewer set. Hardcoding linter knowledge would couple hive to one ecosystem (the plan originally had Ruby/Rails linters). The user's CI command is a clean per-language contract: hive's 6-review CI-fix phase (U7) shells out to `review.ci.command`, the project's linters run there. `Reviewers.dispatch` raises a helpful error if a config sets `kind: linter` ("not supported in v1; set `review.ci.command` to your linter driver instead"). **Future:** if community contributions arrive for cross-ecosystem CI/linter integration, a plugin pattern can grow then; v1 stays minimal.
- **`status_mode:` is per-spawn, not per-profile.** The same claude binary serves `:state_file_marker` (4-execute, brainstorm, plan, pr) and `:output_file_exists` (reviewer adapter). Mode is a property of the spawn's PURPOSE, not the CLI. Profile's `status_detection_mode` is the default; reviewer adapter overrides per spawn.
- **Reviewer Agent uses a synthetic task object.** `spawn_agent` expects task-shaped `folder`/`state_file`/`log_dir`/`stage_name`. The reviewer adapter receives a `Reviewers::Context` (paths only) and constructs a minimal facade for spawn — keeps the adapter independent of full `Hive::Task` parsing.

**Tests (+10):**
- `test/unit/reviewers_test.rb` (5): dispatcher kind=agent → Agent; kind defaults to agent when absent; kind=linter raises with helpful "not supported in v1" message; unknown kind raises; output_path uses output_basename + zero-padded pass.
- `test/unit/reviewers/agent_test.rb` (5): agent run returns ok when fake-claude writes expected output; error when expected output missing; error when exit non-zero; orchestrator REVIEW_WORKING survives the reviewer spawn (proves the per-spawn `status_mode: :output_file_exists` gating); rendered prompt invokes `/ce-code-review` against `git diff main..HEAD`.
- `test/unit/agent_profile_modes_test.rb` (+1): backward-compat regression for `:state_file_marker` mode still writing `:error` to task.state_file on non-zero exit.

231 tests passing (was 220 before U4). Rubocop clean.

**Wiki pages updated:** this entry. `wiki/modules/agent.md` U4 changes (status_mode kwarg, mode-gated marker writes) deferred to U10's wiki pass.

## [2026-04-25T20:00:00Z] U2 ship — review.* + agents.* config + recursive deep-merge

**Action:** Phase 1's config foundation for the 6-review autonomous loop. Replaced `Hive::Config.merge_defaults`'s single-level `Hash#merge` with a recursive deep-merge (closes doc-review F3 P0); added `agents.*` and `review.*` defaults trees; added load-time validation for reviewer uniqueness, agent-profile resolution, and reviewer entry shape. `templates/project_config.yml.erb` now scaffolds a live (not commented) `review:` block with the 3-entry recommended set (claude-ce-code-review + codex-ce-code-review + pr-review-toolkit), so a fresh `hive init` produces a working 6-review config out of the box.

**Code:** `lib/hive/config.rb` rewrite (deep-merge + validate! + new DEFAULTS keys + ROLE_AGENT_PATHS); `templates/project_config.yml.erb` (live review block); `test/unit/config_test.rb` (+10 cases for deep-merge / validation); `test/integration/init_test.rb` (+1 case for scaffold round-trip).

**Key decisions:**
- Recursive deep-merge with **wholesale-replace at `review.reviewers`** (per ADR-018 — Arrays replace, no per-element merge). All other paths under `review.*` and `agents.*` deep-merge by key.
- Validation runs at load time (`Config.load`) so a bad config fails fast at exit code 78 (`CONFIG`). Error messages enumerate the registered profile names so an agent reading the failure output learns the valid domain.
- `max_wall_clock_sec: 5400` (90 min) aggregate cap — closes doc-review ADV-4.
- New per-role budget/timeout keys (`review_ci`, `review_triage`, `review_fix`, `review_browser`) added to `budget_usd` / `timeout_sec` blocks.

**Code review (ce-code-review run `20260425-f58aa04b`):** 9 reviewer personas; 1 P0 + 5 P1 + 7 P2 + 2 P3 = 15 findings. LFG dispatch:

- **Applied (5 safe_auto fixes):**
  - **#1 P0:** `schemas/hive-approve.v1.json` integer maximum bumped from 6 to 7 (was rejecting valid `8-done` payloads).
  - **#9 P2:** Extracted shared `validate_agent_name!` helper used by both `validate_reviewers!` and `validate_role_agent_names!`.
  - **#11 P2:** Reject empty / whitespace-only `output_basename` (would have produced `reviews/-NN.md` filenames).
  - **#12 P2:** `reviewers:` (nil) now raises `ConfigError` with a clear message instead of silently early-returning into a downstream `NoMethodError`.
  - **#13 P2:** Validation errors now annotate "(defaults; no file present)" when the cited config path doesn't exist on disk.

- **Deferred (gated_auto, residual actionable):**
  - **#2 P1:** `deep_merge` defensive shape-check — adversarial reviewer reproduced 3 paths where bad user input (scalar/array/null at a Hash key) leaks raw `TypeError` / `NoMethodError` instead of typed `ConfigError`. Concrete fix exists (validate type compatibility before recursing) but folds into a follow-up since the architectural choice (raise vs warn vs coerce) deserves explicit treatment.
  - **#6 P1 partial:** `wiki/modules/config.md` rewrite (DEFAULTS block + deep-merge contract + validation rules). Folds into U10 wiki update pass per plan; this entry covers the wiki/log requirement.
  - **#6 P1 partial:** `wiki/decisions.md` ADR-011 amendment for the new review_ci/review_triage/review_fix/review_browser budget keys. Same — folds into U10.
  - **#7 P2:** Orphan `5-pr/` directory after pre-U1 upgrade — `Task.new` accepts the path, status hides it, approve raises misleading `FinalStageReached`. Concrete fix (validation arm in `Task.new` raising `InvalidTaskPath` with migration hint) deferred — needs UX design for the message and the auto-recovery flag.
  - **#8 P2:** Move `review_*` budget/timeout keys from flat `budget_usd.*` into each `review.<role>` block. Defers to U7/U8 when consumers wire up.
  - **#14 P3:** Strict-mode reviewer entry validation (reject unknown fields like `kind: lintr`). Defers to U4 reviewer adapter when the canonical entry shape locks in.

- **Skipped (deliberate, design decisions for later, not bugs):**
  - **#3 P1:** Schema-version bump for `hive-approve` (in-place enum mutation at v1 violates the documented bump policy). Decision: schema is pre-1.0 and has no external cached consumers; accept the in-place mutation. Revisit if hive ships a v1.0 release.
  - **#4 P1:** `Stages.next_dir(idx)` parameter semantics flipped — same signature, different behavior. Decision: internal helper, no external callers; accept.
  - **#5 P1:** `Config.load` raises `ConfigError` on previously-tolerated inputs. Decision: broader failure surface is the design (validation pass is the point of U2); existing wrappers either rescue `ConfigError` or accept the broader contract.
  - **#10 P2:** `config_version` field for the new `agents:`/`review:` keys. Decision: defer until first config-breaking change forces the conversation.
  - **#15 P3:** Mixed git-history search across the renumber — pre-existing commits won't change. Acceptable history split.

**Code:** 4 commits on `feat/6-review-stage` from this U2 work. 210 tests passing (was 206, +4 new tests for the validation paths). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass (`wiki/modules/config.md`, `wiki/decisions.md` ADR-011 amendment, ADRs 014–019) deferred to U10 per plan.

## [2026-04-25T19:30:00Z] CLI: status-first workflow verbs

**Action:** Added the human-facing command surface where `hive status` shows current slugs grouped by next action, and stage verbs (`hive brainstorm`, `hive plan`, `hive develop`, `hive pr`, `hive archive`) move-or-run tasks by slug.

**Key decisions:**
- Folder paths remain authoritative storage and recovery targets.
- `hive run TARGET` remains the lower-level dispatcher and now accepts slugs.
- Workflow verbs use `--from` for source-stage disambiguation; generic target commands use `--stage`.
- `hive brainstorm <slug>` is the only marker-bypass transition, and only for validated `1-inbox` to `2-brainstorm`.

**Pages updated:** `cli.md`, `commands/run.md`, `commands/status.md`, `commands/findings.md`, `modules/task_resolver.md`.

## [2026-04-25T19:31:00Z] U1 ship — renumber 5-pr → 7-finalize, 6-done → 8-done

**Action:** Reserved position 5 for the upcoming `6-review` stage by renaming `5-pr` → `7-finalize` and `6-done` → `8-done`. `6-review` is NOT yet present — `Hive::Stages::DIRS` has a numeric gap at position 5 that fills when U9 lands.

**Code:** `lib/hive/stages.rb` (`DIRS` updated; `next_dir` now does prefix-based lookup so non-contiguous numbering works — `next_dir(4) → 7-finalize`, `next_dir(6) → 8-done`, `next_dir(5) → nil`). Also touched: `commands/run.rb`, `stages/execute.rb`, `templates/pr_prompt.md.erb`, `schemas/hive-approve.v1.json`, README, CHANGELOG (with upgrade snippet for in-flight tasks).

**Wiki swept (16 pages):** `architecture.md`, `state-model.md`, `testing.md`, `index.md`, `active-areas.md`, `stages/{index,pr,done,inbox,execute}.md`, `commands/{init,approve,run,status}.md`, `modules/{stages,git_ops}.md`. The `5-pr → 7-finalize` literal in this log's prior brainstorm entry is intentionally preserved (describes the rename action).

**Tests:** 195 passing (was 194; +1 case for prefix-gap `next_dir(5)`). Rubocop clean.

## [2026-04-25T19:00:00Z] U11 + U12 ship — multi-CLI matrix + AgentProfile abstraction

**Action:** Phase 0 of the 6-review-stage plan landed on `feat/6-review-stage`. Two units shipped:

- **U11 (research spike):** Verified headless invocation contracts for `claude`, `codex`, `pi`, `opencode` across 13 dimensions. Output: `docs/notes/headless-agent-cli-matrix.md`. Outcome: claude + codex full-profile (in v1 default reviewer set); pi partial-profile-with-caveats (opt-in per project; no `--add-dir` equivalent → ADR-018 trust-model amendment pending); opencode dropped from v1 scope (no native CE plugin, per-spawn isolation requires temp-config writing).
- **U12 (Agent refactor):** Replaced `Hive::Agent`'s class-level claude singleton with per-spawn `AgentProfile` data object. Three v1 profiles registered (claude/codex/pi). Backward compat: existing 4-execute / brainstorm / plan / pr stages keep working unchanged via default `profile: nil → :claude` lookup.

**Key decisions:**
- **Skill name correction:** actual CE skill is `ce-code-review`, not `ce-review` (corrected throughout the plan).
- **Per-spawn nonce (ADR-019, pending wiki/decisions.md update):** each `Stages::Base.user_supplied_tag` call returns fresh `SecureRandom.hex(8)`. Closes ADR-008's per-process scope; SEC-1 attack surface (leaked nonce forging a sibling spawn's closing tag) is closed.
- **Three status_detection_modes:** `:state_file_marker` (claude — agent writes marker), `:exit_code_only` (CI-fix), `:output_file_exists` (reviewer/triage — exit 0 + named file present).
- **Pi profile is registered but flagged ADR-008-weakened:** no `--add-dir` equivalent, no permission gate. `Stages::Base.spawn_agent` writes `<task>/logs/isolation-warnings.log` when a profile without `add_dir_flag` is spawned with non-empty `add_dirs`. Hive's own default reviewer set ships claude + codex only.

**Code review (ce-code-review run `20260425-b80fcfc5`):** 9 reviewer personas; 1 P0 + 5 P1 + 6 P2 + 8 P3 = 20 findings. LFG dispatch applied 12 safe_auto fixes:
- Pi preflight robustness (#3): 3 failure paths tested; raw `Errno::*` and `ArgumentError` translate to `Hive::AgentError`.
- check_version! Open3.capture3 timeout (#4): 10s cap prevents hangs on credential-prompting wrappers.
- warn_isolation_reduced (#10): tests added; non-Array `add_dirs` raises `ArgumentError` (#20).
- spawn_agent direct tests (#11): default-profile, preflight-ordering, isolation-warning trigger.
- Cross-spawn nonce isolation property test (#12): asserts SEC-1 property, not just "different strings".
- prompt_injection_test cleanup (#18): dead `@user_supplied_tag` ivar manipulation removed.
- Maintainability: `DEFAULT_BIN` removed (#13), `extra_flags` folded into `output_format_flags` (#14), lazy-block registration path dropped (#16), dead nil-guards removed (#17).
- This wiki/log entry (#5).

**Deferred from review (residual actionable work for follow-up units):**
- #1 P0: Pi `--tools read,edit,write` allowlist for reviewer mode → lands with U2 (per-role config).
- #2 P1: stale `expected_output` invalidation → folds into U4 reviewer adapter.
- #6 P1: `wiki/modules/agent.md` rewrite → folds into U10 wiki update.
- #8 P2: `wiki/cli.md` stage + commit → small, lands with this wiki/log entry.

**Skipped (deliberate, not bugs):** #7 P2 stale version cache mid-binary-swap (accepted), #9 P2 `Hive::Agent.bin` BC shim policy (keep until callers routed), #15 P3 `skill_syntax_format` (will wire in U4), #19 P3 `reset_for_tests!` placement (fine under serial Minitest).

**Code:** `feat/6-review-stage` branch. 194 tests passing, rubocop clean.

**Wiki pages updated:** `wiki/cli.md` (AgentProfile-aware authentication line); this entry. Larger pass (`wiki/modules/agent.md`, `wiki/decisions.md` ADR-014–019, `wiki/architecture.md`) deferred to U10.

## [2026-04-25T18:00:00Z] brainstorm: 6-review stage

**Action:** Captured requirements for splitting 4-execute into impl-only + a new 6-review stage that runs CI-fix → multi-reviewer (parallel) → auto-triage → fix → browser-test as a fully autonomous loop. Renumbers pr/done.

**Key decisions:**
- Split execute → execute (impl) + 6-review (loop). Renumber 5-pr → 7-finalize, 6-done → 8-done.
- Fully autonomous run; user only enters at REVIEW_WAITING (escalations) or REVIEW_COMPLETE.
- Auto-triage with `liberal_auto_fix` preset (configurable: conservative / aggressive / custom prompt path).
- CI hard-blocks on cap; browser-test soft-warns.
- Multi-reviewer parallel: claude-ce-review, codex-ce-review, pr-review-toolkit, optional linters-as-reviewers.
- Triage edits per-reviewer files in place + writes consolidated `escalations-NN.md`.
- Workflow primitives stay CE skills (portable across Claude Code / Codex CLI / etc.).

**Doc:** `docs/brainstorms/hive-review-stage-requirements.md`.

**Supersedes:** F2 + R6/R7/R8 in `docs/brainstorms/hive-pipeline-requirements.md` (the original review-iteration requirements inside 4-execute).

**Wiki pages updated:** — (none yet; follow-up after `/ce-plan` and implementation will refresh `stages/execute.md`, add `stages/review.md`, update `stages/index.md`, `state-model.md`, `modules/config.md`, `decisions.md`.)

## [2026-04-25T00:00:00Z] bootstrap

**Action:** Initial wiki bootstrap from codebase (per `~/wikis/bootstrap-wiki.md` plan via gist `f53222b0d3ace9086be820d366b621e4`).

**Pages created:**
- Top level: `architecture.md`, `state-model.md`, `cli.md`, `dependencies.md`, `decisions.md`, `active-areas.md`, `gaps.md`, `templates.md`, `testing.md`, `index.md`, `log.md`.
- Commands: `commands/init.md`, `commands/new.md`, `commands/run.md`, `commands/status.md`.
- Stages: `stages/index.md`, `stages/inbox.md`, `stages/brainstorm.md`, `stages/plan.md`, `stages/execute.md`, `stages/pr.md`, `stages/done.md`.
- Modules: `modules/task.md`, `modules/markers.md`, `modules/lock.md`, `modules/worktree.md`, `modules/git_ops.md`, `modules/agent.md`, `modules/config.md`.

**Pages updated:** —

**Gaps found:**
1. No live `claude` v2.1.118 smoke-test recorded.
2. `hive init` not yet exercised against the pilot project.
3. `git config gc.reflogExpire never refs/heads/hive/state` not enforced in `Init#call`.
4. Pilot project's pre-commit hook interaction with `.hive-state/` commits unverified.
5. macOS PID-reuse fallback for stale-lock detection not implemented.

**Source:** Codebase read (`lib/`, `bin/`, `templates/`, `test/`) + author's local planning notes. No git history available — repository had no commits yet at the time of bootstrap.

## [2026-04-25T11:50:00Z] post-MVP-review hardening

**Driver:** /ce-code-review on the Phase 1 MVP commit surfaced 1 P0, 9 P1, ~20 P2/P3 findings plus wiki drift. This entry records the code/security/reliability changes; wiki pages were synced in the same change.

**Code changes (all behind passing tests; no regressions in 91-test suite):**

- **P0 worktree.yml hijack closed** (`lib/hive/stages/execute.rb`): `worktree_root` is now derived canonically from `cfg["worktree_root"] || ~/Dev/<project>.worktrees` instead of `File.dirname(worktree_path)`. The fallback was tautological — agent-rewritten pointer paths were validating against their own dirname. Plus: implementation pass is now wrapped in the same SHA-256 protection as the reviewer pass — both runs verify `plan.md` and `worktree.yml` haven't been mutated, with `:error reason=implementer_tampered` / `reviewer_tampered`.
- **Symlink escape closed** (`lib/hive/worktree.rb`): `validate_pointer_path` uses `File.realpath` so symlinks can't shadow the prefix check.
- **Prompt-injection nonce wrapper** (`lib/hive/stages/base.rb`, all 4 templates): `Stages::Base.user_supplied_tag` returns `user_supplied_<hex16>` rotated per process. Templates wrap user content with the nonce-tag so attacker `</user_supplied>` payloads cannot terminate the wrapper. Plan U11's mandated regression test is now in `test/integration/prompt_injection_test.rb`.
- **Brainstorm/plan add-dir narrowed** (`lib/hive/stages/{brainstorm,plan}.rb`): dropped `add_dirs: [task.project_root]`. Early-stage agents no longer have project-source write access via `--dangerously-skip-permissions`. Trade-off: the agent loses CLAUDE.md auto-discovery at brainstorm/plan; we accept that until a snapshot-mount approach is designed.
- **Pass counter from reviews/** (`lib/hive/stages/execute.rb`): `current_pass_from_reviews` counts `Dir[reviews/ce-review-*.md]` instead of parsing task.md frontmatter. Removes the agent-must-update-frontmatter contract that was contradicting the reviewer prompt's "do not edit task.md" rule.
- **Reviewer prompt rewritten** (`templates/review_prompt.md.erb`): step 4 was "do not edit task.md" while step 5 said "update pass: in task.md frontmatter". Reviewer now writes only the review file; the orchestrator's `finalize_review_state` owns the terminal marker.
- **Atomic Markers.set** (`lib/hive/markers.rb`): tempfile + `File.rename` instead of truncate+write. ENOSPC/crash mid-write no longer corrupts state. UTF-8 encoding pinned. Lock moved to a `.markers-lock` sidecar so reads of the data file don't see partial writes.
- **PR secret-scan** (`lib/hive/stages/pr.rb`): regex scan on `pr.md` + `gh pr view --json body` for api-key/AWS/GH-token/PEM patterns. Hit → marker `:error reason=secret_in_pr_body`, no commit. Implements the lint promised in plan KTD that was missed at MVP time.
- **Reliability batch** (`lib/hive/agent.rb`, `lib/hive/lock.rb`): reader thread sets `report_on_exception = true`; `Process.wait2` for atomic status capture (no `$?` race); `with_commit_lock` has a 30s deadline (`flock LOCK_NB` + sleep poll); `update_task_lock` writes via tempfile + rename; `process_start_time` falls back to `ps -o lstart=` on macOS; nil exit_code + `:none` marker now produces `:error reason=no_marker_no_exit_code` instead of silent OK.
- **Network timeouts** (`lib/hive/stages/pr.rb`): `gh auth status`, `git push -u origin`, and `gh pr list` all wrapped in `Timeout.timeout(60)` so a network drop can't hang the pipeline. `gh pr list` now queries `--state all` instead of `--state open` so a closed-then-retried PR doesn't create a duplicate.
- **hive_state_init pre-flight** (`lib/hive/git_ops.rb`): refuses init on a repo with zero commits (`git rev-parse --verify HEAD`) instead of failing mid-bootstrap.
- **hive_commit scope narrowed** (`lib/hive/git_ops.rb`): adds only `stages/<stage>/<slug>` + `logs/`, not the whole tree, so a crashed prior run's leftover staging cannot cross-contaminate.
- **Slug hygiene** (`lib/hive/commands/new.rb`): derived prefix capped at 51 chars so SLUG_RE always passes; reserved list grew to include `hive-state`/`hive_state`/`state` (worktree-vs-orphan-branch confusion); error message no longer mentions a non-existent `--slug` flag.
- **Status pid lookup** (`lib/hive/commands/status.rb`): reads `claude_pid` from the per-task `.lock` file (where `Hive::Agent` actually writes it) instead of marker attrs (where it never appears).

**Pages updated:**
- `wiki/modules/agent.md` — removed inode-tracking sections; documented `--verbose` requirement; updated `handle_exit` table for the nil-exit_code/`:none` case.
- `wiki/architecture.md` — security-boundary list rewritten (nonce wrapper, narrowed add-dir, two-pass SHA-256, PR secret-scan); `build_cmd` block adds `--verbose`; agent-loop step 6 no longer mentions inode comparison.
- `wiki/decisions.md` — ADR-008 amended with the post-MVP boundary set.
- `wiki/index.md`, `wiki/gaps.md` — line edits removing inode language.

**Tests added:**
- `test/integration/prompt_injection_test.rb` — 5 cases asserting nonce wrapping per template + per-process tag rotation; covers the plan U11 regression mandate.

**Tests:** 91 / 290 assertions, all green.

## [2026-04-25T14:50:00Z] CLI: --json + hive approve

**Driver:** Agent-callable contract work. `hive run` and `hive status` gained `--json` (commits 85439ee, predecessors); `hive approve TARGET` was added (32b0e8c) as the agent replacement for shell `mv <task> <next-stage>/`. Stable exit codes formalised in `Hive::ExitCodes`; schema versions pinned in `Hive::Schemas::SCHEMA_VERSIONS`.

**Code changes:**
- `lib/hive.rb` — `Hive::ExitCodes` constants (0/1/2/3/4/64/70/75/78); `Hive::Schemas::SCHEMA_VERSIONS` (`hive-status`, `hive-run`, `hive-approve` all v1) and closed `NextActionKind` enum. New typed exceptions `TaskInErrorState` (exit 3), `WrongStage` (exit 4), `AlreadyInitialized` (exit 2); existing exceptions now override `exit_code` to match the contract.
- `lib/hive/cli.rb` — `--json` is a `class_option` honoured by `status` and `run`; new `approve` subcommand with `--to`, `--project`, `--force`, `--json`.
- `lib/hive/commands/approve.rb` (new) — slug-or-folder resolution across registered projects, lowest-stage-wins disambiguation within a project, marker policy (forward auto needs `:complete`/`:execute_complete`, `--to` and `--force` bypass), `FileUtils.mv` + `git add -A` on both source and destination parent stage dirs, single hive/state commit per move.
- `lib/hive/commands/{run,status}.rb` — `--json` emit paths producing `hive-run` / `hive-status` documents.
- `lib/hive/commands/init.rb` — `warn`/`exit 2` replaced with `raise Hive::AlreadyInitialized`.
- `lib/hive/stages/inbox.rb` — inert `1-inbox` now `raise Hive::WrongStage` (exit 4) instead of warn/exit, so agent callers can branch without parsing stderr.

**Pages updated:**
- `wiki/cli.md` — command table grew `approve`; `--json` noted as `class_option`; full exit-code contract table.
- `wiki/commands/approve.md` (new) — usage, slug resolution rules, marker policy, JSON contract, exit codes.
- `wiki/commands/run.md`, `wiki/commands/status.md` — `--json` output shape and schema pin.
- `wiki/stages/inbox.md` — `WrongStage` raise + exit 4 documented.
- `wiki/active-areas.md`, `wiki/stages/execute.md` — refreshed (a2b9e05).
- `wiki/dependencies.md` — new dev gems (rubocop-rails-omakase, brakeman, bundler-audit; 7373114).
- `wiki/index.md` — `commands/approve` added; `--json` notes on `run` / `status`.

**Tests:** 11 new integration cases for `approve` (happy path, inbox needs `--force`, backward `--to`, short stage names, unknown stage, slug not found, cross-project ambiguity, destination collision, folder-path target, JSON schema, 8-done overflow). Suite: 115 / 417 assertions, all green. RuboCop clean.

## [2026-04-25T18:00:00Z] hive approve hardening — full ce-code-review remediation

**Driver:** /compound-engineering:ce-code-review against PR #4 (`feat/hive-approve`) ran 8 reviewer personas in parallel and surfaced ~50 findings, including 5 P1s. Two P1s (JSON-on-error silence; non-idempotent retry) were independently called out by three separate reviewers. This entry records the remediation; merge of PR #4 is gated on it.

**Cross-project context:** No prior pattern in `~/wikis/master/wiki/` for "agent-callable equivalents of shell verbs"; this is the first such command in the project, so its conventions (typed exceptions per failure mode, slug-scoped commits, JSON error envelope mirroring stdout/stderr dual-signal of `hive run --json`, idempotency via `--from STAGE`) set the precedent for future agent-callable subcommands.

**Code changes:**

- **JSON error envelope on every failure path** (`lib/hive/commands/approve.rb`): every `Hive::Error` raised inside `do_call` is caught, emitted as a `{schema, schema_version, ok: false, error_class, error_kind, exit_code, message, ...}` document on stdout (with structured fields per error class — `candidates` for `AmbiguousSlug`, `path` for `DestinationCollision`, `stage` for `FinalStageReached`), then re-raised so `bin/hive` produces the contract exit code. Mirrors `hive run --json`'s dual-signal pattern (run.rb:91-95).
- **`--from STAGE` idempotency assertion**: Thor option + `validate_from!` enforces "task is at expected stage" before advancing. Mismatch → `WrongStage` (exit 4). Closes the live-reproducible bug where `hive approve <slug> --force --json` twice in a row silently advanced two stages.
- **Slug-scoped git add** (`record_hive_commit`): `git add -A stages/<src>/<slug> stages/<dst>/<slug>` instead of `stages/<src> stages/<dst>` (parent dirs). Sibling-task changes no longer get swept into the approve commit message. Source side is added only if it has tracked files (`git ls-files` check) — `git add -A <pathspec>` errors on a missing-from-worktree pathspec with no tracked entries, the common case for an untracked source after a prior raw `mv`.
- **Atomic move + commit with rollback** (`perform_move_and_commit`, `record_commit_or_rollback!`): outermost `with_commit_lock(hive_state_path)` surfaces lock contention BEFORE any filesystem mutation; inner `with_task_lock(task.folder)` blocks concurrent `hive run` on the same task during the move; the orphan `.lock` file at the destination (carried by the move) is deleted before the commit so per-process metadata isn't tracked. If the commit fails, `FileUtils.mv` reverses the move and the original error is wrapped in `Hive::Error` so fs and git don't diverge.
- **Same-project multi-stage ambiguity raises** (`find_slug_across_projects` rewrite): silently picking the lowest stage was wrong for the partial-failure-recovery case where the lower stage is the stale leftover. Now raises `AmbiguousSlug` with structured `candidates` and demands an absolute folder path or `--to` to disambiguate.
- **Absolute-path TARGET + `--project` mismatch refused** (`validate_project_path_match!`): combining `--project foo` with `/path/to/bar/.hive-state/...` no longer silently operates on `bar`.
- **`--to <current-stage>` is a clean no-op**: emits `noop: true` in JSON (or `hive: noop —` text), no mv, no commit, exit 0. Previously triggered the destination-collision error.
- **Cwd collision shadow fixed**: bare slug always goes through cross-project search (`path_target?` requires `/` or `~`/`.`). Previously a `pwd` subdirectory matching the slug name took precedence and produced a confusing `InvalidTaskPath`.
- **`Hive::FinalStageReached` exit 4** instead of bare `Error` exit 1 for past-`8-done`. Pairs with the existing collision-stays-at-1 to give callers distinct codes for "no further stage" vs "recoverable collision".
- **`Hive::Stages` module** (`lib/hive/stages.rb`, new): single source of truth for stage list. `GitOps::STAGE_DIRS`, `Status::STAGE_ORDER`, `Run#next_stage_dir`, `Approve` resolution all delegate. Adding a 7th stage is a one-file change.
- **Thor `enum:` constraint** on `--to` / `--from`: invalid stage values fail at parse time with the valid set listed in `hive help approve`.
- **`bin/hive` `--help` flag interception**: `hive <cmd> --help` now works (Thor only honours `--help` before the subcommand name; `<cmd> --help` was being consumed as the next positional). 4-line rewrite in `bin/hive` benefits every subcommand.
- **`hive-approve` schema split**: `from_stage` (bare "brainstorm") + `from_stage_index` (2) + `from_stage_dir` ("2-brainstorm"), mirroring `hive-run`'s `stage` / `stage_index`. Added `ok`, `noop`, `direction`, `forced`, `from_marker`, `next_action` fields. Schema version stays at 1 (no consumers in the wild).
- **`NextActionKind::RUN`** added to the closed enum so `approve --json`'s `next_action.kind` can chain deterministically to `hive run`. Membership pinned in `test/unit/exit_codes_test.rb#test_next_action_kind_closed_enum_membership`.

**Pages updated:**
- `wiki/commands/approve.md` — full rewrite: new flags (`--from`), expanded JSON contract (success + error envelope), updated marker policy, locking-and-rollback section, slug resolution rules including same-project ambiguity, expanded exit-code table.
- `wiki/cli.md` — "five commands"; `--json` honoured by `status`, `run`, AND `approve`; `--help` interception note; expanded approve row in command table.
- `wiki/commands/run.md`, `wiki/commands/status.md`, `wiki/stages/index.md` — added `[[commands/approve]]` reciprocal backlinks.

**Tests:** 20 new integration cases (`run_approve_test.rb`) + 4 new unit assertions (`exit_codes_test.rb`) — coverage for: `--from` idempotency mismatch, all six short stage names, project-filter zero matches, cwd-shadow defence, `:error` marker forward refusal AND backward `--to` recovery, past-8-done exits 4, no-op same-stage in both text and JSON, JSON full key-set pin including new fields, JSON error envelopes for each typed error class (ambiguous, collision, final-stage), no-op next_action at final destination, slug-scoped commit (cross-contamination prevention), orphan `.lock` cleanup, plain-text stderr-hint placement, absolute-path + project mismatch, same-project multi-stage ambiguity. Suite: 135 / 507 assertions, all green.

**Findings dismissed (false positives):**
- `wiki commit_action` doc-vs-code mismatch (project-standards reviewer): verified `Hive::Task#stage_name` returns the bare suffix, so `"#{stage_index}-#{stage_name}"` correctly emits `"2-brainstorm"`. Doc and code agree.

**Findings deferred (P3, separate PRs):**
- Symlink TARGET hardening (adversarial #6) — `File.symlink?` defence at task construction.
- TOCTOU on destination check (adversarial #8) — covered indirectly by `with_task_lock` but not eliminated.
- Published JSON Schema files (api-contract #4) — `schemas/hive-approve.v1.json` for external consumers.
- Pre-existing `.lock` files committed by `hive run` — would need `.gitignore` inside `.hive-state/`.

## [2026-04-25T20:00:00Z] hive approve P3 follow-up — symlink, TOCTOU, schemas, .gitignore

**Driver:** Continuation of the ce-code-review PR #4 remediation: addressing the four P3 items deferred from the prior commit. All four turned out to be sub-day fixes; bundling them into the same PR keeps the work coherent.

**Code changes:**

- **Symlink hardening** (`lib/hive/commands/approve.rb`): `resolve_target` now `File.realpath`s the resolved folder for both the path-target and slug-search return paths. A slug-named symlink at `.hive-state/stages/<N>/<slug>` pointing to `/tmp/leaked` realpaths to `/tmp/leaked` and gets refused by `Hive::Task.new`'s PATH_RE check (real path doesn't match the `.hive-state/stages/` shape). Two integration tests pin both the path-target and slug-lookup branches.
- **TOCTOU robustness** (`move_task!`): switched from `FileUtils.mv` to direct `File.rename` wrapped in a `rescue Errno::ENOTEMPTY, EEXIST, EISDIR` that surfaces as typed `Hive::DestinationCollision`. The pre-check + commit-lock cover the hive-process-vs-hive-process race; the rescue covers the non-hive-process race (a stray `mkdir` between pre-check and rename). Cross-device fallback (rare; `.hive-state` lives under the project root) goes through `cp_r` + `rm_rf`. One integration test stubs `File.exist?` to bypass the pre-check and asserts the rescue produces a clean `DestinationCollision`.
- **NextActionKind::APPROVE** (`lib/hive.rb`, `lib/hive/commands/run.rb`): added to the closed enum (additive). `hive run --json` now emits `kind: "approve"` for `:complete` and `:execute_complete` markers (was `kind: "mv"`), with a new `command: "hive approve <slug> --from <stage>"` field that the agent can copy-paste-execute. Back-compat `from` / `to` fields are kept on the next_action object so old callers parsing the MV shape still get the data they need. `MV` stays in the closed enum per the additive-only policy. Test `test_run_json_on_complete_marker_returns_approve_next_action` (renamed from `_returns_mv_next_action`) pins the new shape; the closed-enum membership test covers both kinds.
- **Published JSON Schema** (`schemas/hive-approve.v1.json`): draft 2020-12 schema with `oneOf` over `SuccessPayload` and `ErrorPayload` definitions, per-stage enums, and the closed `NextAction.kind` enum. `Hive::Schemas.schema_dir` and `Hive::Schemas.schema_path(name)` helpers resolve the absolute path. `test/unit/schema_files_test.rb` pins the schema's required-key set, error_kind enum, and NextAction.kind enum against the producer's emission so a code-vs-schema drift fails at test time. External consumers (non-Ruby SDKs, CI validators) can validate emitted documents with any draft-2020-12 validator (ajv, json_schemer, etc.) without re-implementing the contract.
- **`.hive-state/.gitignore`** (`lib/hive/git_ops.rb`): `hive_state_init` now bootstraps a gitignore at the `.hive-state` root excluding per-task `.lock`, atomic-write `.lock.tmp.*`, per-marker `*.markers-lock`, and per-project `.commit-lock`. Pre-existing pre-bug: `Hive::GitOps#hive_commit` does `git add stages/<stage>/<slug>` which was tracking the per-task `.lock` files into hive/state on every `hive run` (committed PIDs and process_start_time values). Existing projects need to add the `.gitignore` manually; new projects get it via `init`.

**Tests:** 7 new integration / unit cases covering symlink-target rejection (path-target + slug-lookup), concurrent-mkdir collision rescue, schema file existence and key-set drift, schema error_kind drift, schema NextAction.kind drift. `test_run_json_on_complete_marker_returns_approve_next_action` renamed and rewritten. Suite: 142 / 529 assertions, all green. RuboCop clean.

**Wiki updates:**
- `wiki/commands/approve.md` — symlink hardening note in Steps section, TOCTOU rescue noted, JSON Schema file referenced under JSON contract.
- `wiki/cli.md` — `Hive::Schemas.schema_path("hive-approve")` mentioned for external consumers.

## [2026-04-25T22:00:00Z] hive approve round-3 review remediation

**Driver:** /pr-review-toolkit:review-pr final pass surfaced silent-failure (6), type-design (5), test-coverage (6), comment-rot (8), and project-standards (3) findings. All addressed in this commit.

**Code changes:**

- **JSON envelope on non-`Hive::Error` failures** (`approve.rb` `call`): added a second `rescue StandardError` that wraps in new `Hive::InternalError` (exit 70 / SOFTWARE) and emits the JSON envelope. An Errno::ENOSPC from `mkdir_p`, an Open3 fault, or a SystemCallError no longer escapes as a Ruby trace on stderr while a `--json` consumer reads EOF on stdout.
- **`record_commit_or_rollback!` rescue narrowed** from `StandardError` to `Hive::Error, SystemCallError`. The broad rescue was swallowing typed errors and rewrapping them as exit 1; typed errors (`Hive::GitError` exit 70) now re-raise unchanged after rollback.
- **`attempt_rollback!` extracted** with its own inner rescue around the rollback `FileUtils.mv`. If the rollback itself fails, original cause AND rollback failure both surface in one message.
- **`cross_device_move!` extracted** with cleanup on partial `cp_r` failure. ENOSPC mid-tree no longer leaves a half-copy + intact source.
- **`cleanup_orphan_task_lock` rescue narrowed** to `Errno::ENOENT` only. Other I/O errors propagate so rollback runs.
- **`source_has_tracked_files?` checks status**. A failed `git ls-files` was silently being read as "no tracked files," skipping the source-side add. Now raises `Hive::GitError`.
- **`Hive::Stages.parse` validates `DIRS.include?(dir)` first**. `parse("99-foo")` returns nil, not `[99, "foo"]`.
- **`Hive::Stages.next_dir` raises on out-of-range / non-integer**. Off-by-ones surface at the call site.
- **`GitOps::STAGE_DIRS` and `Status::STAGE_ORDER` aliases removed**. Both consumers reference `Hive::Stages::DIRS` directly. Closes the half-migration smell.
- **CLAUDE.md-violating comments fixed**: removed "now treated as", "silently picking the lowest stage was wrong for the partial-failure-recovery case", "Raised by `hive approve`", "APPROVE replaces the old MV emission" and similar transitional / caller-tying / contrast-with-old-behavior phrasings that rot. The structural WHY in each location was preserved or restated as a positive.
- **POSIX rename overclaim corrected** (`move_task!` comment): "silently REPLACE … POSIX rename(2) semantics" was libc-dependent, not portable; reworded to "implementations vary; the rescue covers all three errnos."
- **`--to disambiguates same-project ambiguity`** docstring claim corrected (it doesn't — `--to` selects destination, not source). Same fix in `wiki/commands/approve.md`.

**Wiki updates:**

- `wiki/modules/stages.md` (new) — module page per project convention. Covers DIRS / NAMES / SHORT_TO_FULL constants, `next_dir` / `resolve` / `parse` helpers, the consumer table, and the rationale for module-vs-class.
- `wiki/index.md` — adds `[[modules/stages]]` to the Modules list.
- `wiki/state-model.md` — points the canonical-stage-list claim at `Hive::Stages::DIRS` (was `Hive::GitOps::STAGE_DIRS`).
- `wiki/modules/git_ops.md` — removed the `STAGE_DIRS` constant entry; documents `HIVE_STATE_GITIGNORE` and points to [[modules/stages]] for the stage list.
- `wiki/commands/status.md` — `Hive::Stages::DIRS` reference instead of the deleted `STAGE_ORDER`.
- `wiki/commands/approve.md` — corrected `--to disambiguates` claim.

**Tests:** 7 new (149 / 576 green), RuboCop clean.

- `test/unit/stages_test.rb` (new) — validation semantics for `next_dir` (raises on bad index), `parse` (nil for unknown stages), `resolve`, and constant frozen-ness.

## [2026-04-25T23:00:00Z] hive findings / accept-finding / reject-finding (Phase 2 PR3)

**Driver:** Continuation of Phase 2 agent-callable contract work. `hive approve` (PR #4, merged) replaced shell `mv`; this commit replaces the second hand-edit step in the pipeline — ticking `[x]` on review findings in `reviews/ce-review-NN.md` to mark which findings the next implementation pass should address. The reviewer prompt writes all findings unchecked; the user (now an agent) flips a subset to accepted; `Hive::Stages::Execute#collect_accepted_findings` re-injects only the `[x]` lines into the next pass's prompt.

**Code changes:**

- **`Hive::Findings`** module (`lib/hive/findings.rb`, new) — parser + writer for review files. `Document.new(path)` reads the file, parses each `- [ ]` / `- [x]` line into a `Data.define` value object with `id` (1-based stable; document order), `severity` (lowercased heading), `accepted`, `title`, `justification`, `line_index`. `toggle!(id, accepted:)` flips a single checkbox character without touching surrounding bytes — verified by a unit test that asserts every non-target line is byte-identical after a write. `write!` uses tempfile + rename. `summary` returns total / accepted / by_severity. `Hive::Findings.review_path_for(task, pass:)` resolves the latest or named-pass review file.
- **`Hive::TaskResolver`** (`lib/hive/task_resolver.rb`, new) — extracted from `Hive::Commands::Approve#resolve_target` + `find_slug_across_projects` + `validate_project_path_match!`. ~80 LOC of slug-or-folder resolution now shared between four commands (`approve`, `findings`, `accept-finding`, `reject-finding`); `Approve#do_call` is one line shorter and the duplication that would have appeared in three new commands is collapsed at extraction time.
- **`Hive::Commands::Findings`** (`lib/hive/commands/findings.rb`, new) — read-only list. Resolves task via `TaskResolver`; loads document; emits text table or single-line `hive-findings` JSON. JSON includes per-finding `to_h` plus `summary` block.
- **`Hive::Commands::FindingToggle`** (`lib/hive/commands/finding_toggle.rb`, new) — shared accept/reject. Combines `ID...` positionals + `--severity <s>` + `--all` into a unioned ID list (empty union is an error). Validates every ID exists; flips checkboxes; atomic write; commits to `hive/state` (slug-scoped `git add` of the review file). Acquires `Hive::Lock.with_task_lock(task.folder)` so a concurrent `hive run` can't race against the toggle. Idempotent: already-correct entries are no-ops and excluded from the JSON `changes` array. `next_action` in the JSON points at `hive run <task.folder>` so an agent driving the pipeline knows the immediate next step.
- **CLI wiring** (`lib/hive/cli.rb`): three new Thor subcommands. `--severity` Thor `enum:` constraint against `%w[high medium low nit]`; `--pass` numeric; `--all` boolean; positional `IDs` is variadic (`*ids`).
- **Typed exceptions** (`lib/hive.rb`): `Hive::NoReviewFile` (exit 64), `Hive::UnknownFinding` (exit 64, carries `id`).
- **`Hive::Schemas::SCHEMA_VERSIONS["hive-findings"] = 1`** added.
- **`schemas/hive-findings.v1.json`** — draft 2020-12 schema with `oneOf` over `ListPayload`, `TogglePayload`, and `ErrorPayload`. Per-finding shape, summary, error-kind enum (`ambiguous_slug`, `no_review_file`, `unknown_finding`, `invalid_task_path`, `error`), and the closed `NextAction.kind` enum.

**Wiki updates:**

- `wiki/commands/findings.md` (new) — full page for the three commands. Data model, JSON contract for both list and toggle paths, error envelope, exit-code table, locking section, "why not just edit the file" rationale, backlinks.
- `wiki/cli.md` — TLDR updated to "eight commands"; command table grew three rows; `--json` honour list extended.
- `wiki/index.md` — new entry under Commands; page count bumped 27 → 29.
- `README.md` — daily-usage table grew three rows.

**Tests:** 27 new (176 / 699 green; was 149 / 576 on round-3-merged main). RuboCop clean.

- `test/unit/findings_test.rb` — 9 cases on the parser: severity/order/state pinning, missing-justification handling, summary counts, byte-for-byte round-trip preservation, idempotent toggle, unknown-id raises typed, missing-file raises typed, latest-pass resolution, named-pass missing.
- `test/integration/run_findings_test.rb` — 13 cases on the three commands: text output shape, full JSON-key-set pin, named-pass selection, no-review-file error envelope, accept by ID, accept --severity, accept --all (with no-op detection on already-accepted entries), idempotent re-accept, unknown-id typed error, no-selectors error, reject behaviour, reject idempotency, task-lock contention surfaces ConcurrentRunError (TEMPFAIL/75).
- `test/unit/schema_files_test.rb` — 4 new pins for hive-findings: file existence + draft, ListPayload required keys, TogglePayload required keys, error_kind enum drift.
- `test/unit/exit_codes_test.rb` — pinned `NoReviewFile` (64), `UnknownFinding` (64), `InternalError` (70) exit codes; pinned `hive-findings` schema-versions key.

**Refactor:**

- `Hive::Commands::Approve` was simplified to delegate to `Hive::TaskResolver`. ~80 LOC removed from `approve.rb`; one line in `do_call` (`task = Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve`). All 32 existing approve tests still pass.

## [2026-04-25T23:30:00Z] hive findings — round-2 ce-code-review remediation

**Driver:** /compound-engineering:ce-code-review on PR #5 ran 8 reviewer personas (cli-readiness ran out of tokens; the other 8 produced findings). 4 P1s + 8 P2s + a few P3s addressed in this commit. Two of the P1s were independently corroborated by 2 reviewers each.

**Code changes:**

- **Lock-order inversion fixed** (`finding_toggle.rb#do_call`): swapped to `with_commit_lock` outermost → `with_task_lock` inner, matching `Hive::Commands::Approve`. Closes the deadlock where concurrent `hive approve <slug>` + `hive accept-finding <slug>` would both wait 30s on each other's lock and surface as `ConcurrentRunError`.
- **Rollback false-failure message fixed** (`rollback_review_change!`): the previous shape used a method-level rescue that caught the intentional "rolled back" re-raise on the success path and falsely reported "rollback ALSO failed." Restructured to a flat `begin/rescue` where the rollback I/O is the rescued region; the success-path re-raise leaves the method without re-entering any rescue. The "rollback failed" branch is now reserved for actual rollback failures.
- **CRLF + no-trailing-newline byte-preservation** (`Hive::Findings::Document#toggle!`): captured the original line ending in a 4th regex group on `FINDING_RE` and reused it on rebuild. CRLF input round-trips as CRLF; a last line without `\n` stays without one. The earlier hardcoded `"…\n"` flattened CRLF and added a trailing newline. Pinned by two new unit tests asserting byte-exact round-trip.
- **Severity carry-over fixed** (`parse_lines`): any `## …` heading that doesn't match `KNOWN_SEVERITIES` (`high|medium|low|nit`) now clears `current_severity` to nil. Multi-word headings like `## Detailed Analysis` previously didn't match the heading regex at all (so subsequent findings inherited the prior severity); short non-severity headings like `## Notes` previously matched and set a fake severity. Both leak vectors closed.
- **`with_task_lock` collision in test helper** (`run_findings_test.rb`): the lock-serialisation test pre-acquires `with_task_lock(execute, …)` then calls toggle. With the new outer/inner lock order, toggle still surfaces `ConcurrentRunError` (TEMPFAIL/75) — the test's contract is preserved without modification.
- **Rollback `git reset` exit status checked** (`rollback_review_change!`): switched from `Open3.capture3` (status discarded) to `ops.run_git!` (raises on non-zero). A failed reset now propagates and the rollback message can't lie about the index state.
- **`Hive::Schemas::ErrorEnvelope.build` helper** added. `Findings#emit_error_envelope` and `FindingToggle#emit_error_envelope` collapsed from ~25 LOC each to ~7 LOC. Per-error structured fields (`candidates` / `id` / `path` / `stage`) are pulled from the typed exception automatically. `approve.rb` left intact (its envelope has different structured fields and the duplication risk is lower now).
- **`Hive::NoSelection` exception** added (exit 64 / USAGE). `select_target_ids` now raises this typed class instead of overloading `Hive::InvalidTaskPath`. `error_kind: "no_selection"` joins the `hive-findings` enum. Closes the agent-facing taxonomy issue where `error_kind: "invalid_task_path"` was being used for "argument set was empty."
- **Targeted no-selection messages**: when `--all` runs against an empty review file, the message names that. When `--severity X` matches nothing, the message lists the available severities.
- **`next_action` consistency**: both `kind: "run"` branches now carry a `reason` field. Previously the "nothing accepted yet" branch omitted `reason`; consumers that branched on its presence saw an inconsistent shape.
- **`pass_from_path` deduped**: moved to `Hive::Findings.pass_from_path(path)` module function. The two duplicate `pass_from_review_path` / `pass_from_path` private helpers in `findings.rb` and `finding_toggle.rb` are gone; both commands call the shared module function.
- **Module-level comment de-transitionalised** (`findings.rb`): "after this module, an agent ticks…" rewritten to "Ticking `[x]` flags a finding to address…" (no transitional reference). Per CLAUDE.md "don't reference the current task/fix" rule.

**Schema changes (`schemas/hive-findings.v1.json`):**

- `ErrorPayload.error_kind` enum gained `no_selection`.
- `ErrorPayload.candidates` items now require `{project, stage, folder}` — mirrors `hive-approve.v1.json` so consumers validating `AmbiguousSlug` across the two endpoints can share validation logic.
- Description added to `ErrorPayload` documenting that `operation` is present iff the error came from a toggle command.

**New wiki pages (round-2):**

- `wiki/modules/findings.md` — public surface of `Hive::Findings` (Document, toggle!, write!, summary, review_path_for, pass_from_path), parsing rules, round-trip guarantees pinned by unit tests, consumer table.
- `wiki/modules/task_resolver.md` — resolution rules (path-shaped vs slug, ambiguity classes, `--project` validation), public API, consumers.
- Reciprocal backlinks: `[[modules/findings]]` on `wiki/stages/execute.md` and `wiki/modules/lock.md`; `[[commands/findings]]` on `wiki/stages/execute.md` and `wiki/modules/lock.md`.
- `wiki/index.md` page count bumped 29 → 31.

**Tests:** 10 new (186 / 735 green; was 176 / 699 on round-1). RuboCop expected clean.

- `test_toggle_preserves_crlf_line_endings` — the `\r\n` round-trip pin.
- `test_toggle_preserves_missing_trailing_newline` — the no-trailing-newline pin.
- `test_non_severity_heading_resets_current_severity` — `## Detailed Analysis` and `## Notes` both clear severity.
- `test_pass_from_path_extracts_integer` — module function pin.
- `test_accept_finding_unions_severity_with_explicit_ids` — combinator behaviour pin.
- `test_accept_finding_with_no_selectors_errors` upgraded to assert `error_kind: "no_selection"` and `error_class: "NoSelection"`.
- `test_hive_findings_candidates_item_shape_pinned` — schema drift guard for the candidate item shape.
- `test_hive_findings_error_kinds_match_producer` updated to include `no_selection`.
- `test_error_subclasses_map_to_their_contract_code` updated to pin `Hive::NoSelection` exit code.

**Findings dismissed (false positives):**

- API-contract reviewer's "UnknownFinding can default to `id: nil`" — only theoretical; no current call site passes nil.
- Adversarial reviewer's `path_target?` containment concern — same behaviour as `approve.rb`'s, intentional.
- Maintainability reviewer's "premature TaskResolver extraction" framing — 4 consumers and the realpath/ambiguity rules are exactly the kind of thing that benefits from one source of truth.

## [2026-04-26T00:30:00Z] hive findings — P3 follow-ups (rollback abstraction, fence awareness, tempfile uniqueness)

**Driver:** Closing the three deferred P3 items from the round-2 review entry above. All three landed together so the rollback contract is consistent across approve and the finding commands.

**Code changes:**

- **`Hive::CommitOrRollback.attempt!` helper** (`lib/hive/commit_or_rollback.rb`, new): consolidates the dual-rescue rollback pattern shared by `Hive::Commands::Approve#attempt_rollback!` and `Hive::Commands::FindingToggle#rollback_review_change!`. The helper owns the rescue + re-raise contract: on undo success, it re-raises the original typed `Hive::Error` (preserving exit codes like `GitError → 70`) or wraps non-typed errors in a generic `Hive::Error`; on undo failure, it raises `Hive::RollbackFailed` carrying both the original cause and the rollback failure. Caller-specific concerns (approve's "source path now exists" precondition, the message templates) stay in the caller. ~30 LOC of duplication removed across the two callers.
- **`Hive::RollbackFailed`** (`lib/hive.rb`, new): typed exception (exit 1 / GENERIC) so the JSON envelope can surface `error_kind: "rollback_failed"`. Lets agents distinguish "commit failed but rollback succeeded → safe to retry" from "commit failed AND rollback failed → fs/git may be inconsistent." Both `hive-findings` and `hive-approve` schemas gained `rollback_failed` in the `error_kind` enum; both commands' `error_kind_for` map the new class.
- **Fenced-code-block awareness** (`Hive::Findings::Document#parse_lines`): triple-backtick / triple-tilde fence tracking. Lines inside a fenced block don't register as headings or findings, so an example finding-shaped line in a reviewer's justification block can't false-positive. Closes a latent bug that would surface as soon as the reviewer prompt template emits fenced examples.
- **Tempfile uniqueness** (`Hive::Findings::Document#write!`, `Hive::Lock.update_task_lock`): tempfile names now append `SecureRandom.hex(4)` to the `Process.pid` suffix. Defends against PID reuse-after-crash where a new process with the same PID would otherwise collide on a stale tempfile path.

**Refactors:**

- `Hive::Commands::Approve#attempt_rollback!` now delegates to the helper. The "source path now exists, can't roll back" precondition stays at the caller; the typed-vs-generic re-raise contract moves to the helper.
- `Hive::Commands::FindingToggle#rollback_review_change!` collapses to the same helper-call shape. Identical contract; only the on_undo block (binwrite + git reset) and message lambdas differ.

**Tests:** 5 new unit tests, 191/758 green (was 186/735). RuboCop clean.

- `test/unit/commit_or_rollback_test.rb` (new) — pins the three helper paths: typed re-raise on undo success, generic wrap on undo success with non-typed original, RollbackFailed on undo failure.
- `test_fenced_code_block_lines_are_ignored_by_parser` — backtick fences with `## High` and `- [ ] foo` content; asserts only real findings are parsed.
- `test_tilde_fenced_code_block_also_ignored` — `~~~` fences too.
- `test_error_subclasses_map_to_their_contract_code` updated to pin `RollbackFailed` exit code.
- Both `hive-findings` and `hive-approve` `test_*_error_kinds_match_producer*` tests updated to include `rollback_failed`.

**Wiki:** No new pages this round (the helper module is small and consumer-focused; documenting it inline in the source comment is sufficient). CHANGELOG covers the user-facing surface.
- `test_commit_failure_rolls_mv_back_to_source` — installs a real `pre-commit` hook that exits 1, asserts mv reverses, exit 70 (GitError), and source restored.
- `test_rollback_failure_surfaces_combined_error_message` — pre-commit hook recreates the source path so rollback can't proceed; asserts the combined "rollback NOT possible / manual recovery" message branch.
- `test_json_error_envelope_on_from_mismatch_carries_wrong_stage_kind` — exercises the JSON error envelope on a `--from` mismatch with `--json`.
- AmbiguousSlug envelope test now pins the full per-candidate key set (`folder`, `project`, `stage`).
- The tautological `test_to_accepts_every_short_stage_name` was deleted; the new `stages_test.rb` covers the constants directly.


## [2026-04-26T08:00:00Z] PR #6 status-workflow-verbs — review remediation (round 1)

**Driver:** /compound-engineering:ce-code-review on PR #6 plus an additional independent review surfaced 5 P1s + 8 P2s. Two P1s — "next-action commands drop --from/--project disambiguators" and "workflow verbs emit no JSON envelope" — were flagged by 4 independent reviewers each.

**Code changes:**

- **`Hive::Workflows`** (`lib/hive/workflows.rb`, new): SSOT for the verb→source/target stage map. `VERBS` hash + `verb_advancing_from(stage_dir)` + `verb_arriving_at(stage_dir)` reverse lookups. `StageAction`, `TaskAction`, `Approve#workflow_command_for`, and CLI Thor verbs all delegate. Renaming `develop` → `execute` is now a one-file change.
- **`Hive::Schemas::TaskActionKind`** (`lib/hive.rb`): self-derived closed enum mirroring `NextActionKind`. Constants for every TaskAction key (READY_TO_BRAINSTORM, READY_TO_PLAN, …, AGENT_RUNNING, ARCHIVED, ERROR). Adding a new bucket without updating ALL is impossible.
- **`Hive::TaskAction` carve-outs** (`lib/hive/task_action.rb`): `:agent_working` → `agent_running` action with `command: nil` (was: misclassified as "Needs your input" with a "rerun the verb" command, sending agents into ConcurrentRunError loops). `:execute_stale` → `recover_execute` with command `findings` (was: `develop`, which would refuse on the non-terminal marker and loop). Workflow-verb commands ALWAYS include `--from <stage>` (was: only when stage_collision was true) so status-suggested commands are retry-safe by default.
- **`Hive::Commands::StageAction`** rewrite:
  - Uses `Hive::Workflows::VERBS` instead of own ACTIONS.
  - `--from` retry-after-success rescue: on `InvalidTaskPath` from stage-filtered lookup, re-resolves without `stage_filter` so a retry after a successful advance raises `WrongStage` (4) instead of "no task folder" (64). Mirrors the pattern in Approve.
  - Archive idempotency at 6-done: detects already-archived state (current_stage=6-done with :complete marker) and emits a `noop` payload instead of re-running the Done agent.
  - Single JSON envelope: passes `quiet: @json` to inner Approve and Run; rescues Hive::Error and emits a unified `hive-stage-action` envelope. No more mixed Approve-prose-then-Run-JSON output under `--json`.
- **`quiet:` kwarg on Approve and Run**: when set, the inner command does its work but emits nothing to stdout/stderr. Errors still raise typed. Used by StageAction in JSON mode.
- **`Hive::Commands::Approve#json_next_action`**: at the final stage emits `{ kind: NO_OP, reason: "final_stage" }` instead of `kind: RUN` with `hive archive <slug>` (which would loop the Done agent on retry).
- **`workflow_command_for`** in Approve: now uses `Hive::Workflows.verb_arriving_at` so the post-advance `next_action.command` and text-mode `next:` hint name the verb-to-run-at-the-new-stage (e.g. `hive plan <slug> --from 3-plan` after advancing into 3-plan), not the verb-to-advance-out. The named verb hits StageAction's at-target branch and runs the stage's agent.
- **`Hive::Commands::FindingToggle`**: the `next_action.command` and text-mode `next:` hint now include `--from <stage>` for retry idempotency.
- **`schemas/hive-stage-action.v1.json`** (new): draft 2020-12 oneOf SuccessPayload/ErrorPayload. Phase enum `promoted_and_ran` / `ran` / `noop`. Error-kind enum mirrors hive-approve plus `rollback_failed`.

**Wiki updates:**

- `wiki/modules/task_action.md` (new) — public surface, action map, marker carve-outs, command emission rules.
- `wiki/modules/workflows.md` (new) — VERBS table, reverse-lookup helpers, design rationale.
- `wiki/commands/stage_action.md` (new) — Steps Performed + JSON contract + idempotency contract for the five workflow verbs.
- `wiki/index.md` page count bumped 31 → 34.
- `lib/hive/cli.rb` `class_option :json` comment refreshed to list all eight commands that honour the flag.

**Tests:** 227 / 884 green (was 196 / 768 pre-remediation). RuboCop and Brakeman clean.

- `test/unit/task_action_test.rb` (new) — pins the 13-action matrix, the `:agent_working` and `:execute_stale` carve-outs, and `--from <stage>` inclusion on every workflow-verb command.
- `test/unit/schema_files_test.rb` — 4 new pins for `hive-stage-action`: file existence + draft, SuccessPayload required keys, ErrorPayload error_kind enum, NextAction.kind enum.
- `test/integration/run_stage_action_test.rb` — coverage for the at-target branch, promote-and-run, archive idempotency no-op, `--from` retry-after-success rescue, and unified JSON envelope on each error path.
- 5 existing tests updated for the intentional behaviour changes (--from now always emitted; final-stage emits NO_OP not RUN; archive no-op).


## 2026-04-28 — TUI robustness pass

- **`Hive::Tui::Update.apply_snapshot_arrived`**: re-clamps `model.cursor` when a poll's new snapshot makes prior coords invalid (project_idx OOB or row_idx past the project's row count); preserves cursor when still valid so benign polls don't snap selection. New tests in `test/unit/tui/update_test.rb`.
- **`Hive::Tui::App.run_charm`**: setup (`StateSource.new/start`, `BubbleModel.new`, `Bubbletea::Runner.new`, HUP hook, snapshot poller) moved INSIDE the `begin` so a constructor raise still triggers the same ensure cleanup; `ensure` block nil-guards each handle. Pre-fix, a Bubbletea::Runner failure leaked the StateSource thread.
- **`Hive::Tui::Help::ENTRIES`**: filter-mode `Esc` action renamed `:clear_filter` → `:cancel_filter` with new semantics — discards the typed buffer but preserves any committed filter (was: nuked the committed filter too).
- **`Hive::Tui::Subprocess::SUBPROCESS_LOG_MAX_BYTES`**: comment honesty pass — rotation only fires synchronously with stamp writes, so a noisy child writing tens of MB of stderr between BEGIN and END can blow past the cap; the eventual rotation moves the oversized blob to `.1`. Cap is approximate, not absolute.

## 2026-04-29 — Agentic E2E suite

- Added `test/e2e/` with a real-subprocess harness, YAML scenarios, sample Ruby fixture, tmux TUI driver, JSON schema validator, artifact capture, repro script writer, and versioned `report.json`.
- Added `bin/hive-e2e` (`run`, `list`, `replay`, `clean`) and `rake e2e` / `rake e2e:lib_test`.
- Added published `schemas/hive-status.v1.json` and `schemas/hive-run.v1.json`, plus drift tests in `test/unit/schema_files_test.rb`.
- Added `hive version` / `hive --version` for binary smoke tests and e2e environment snapshots.
- Documented the layer in [[e2e]], updated [[testing]], [[dependencies]], [[cli]], and added ADR-022.

## 2026-04-30 — Asciinema e2e verification

- Verified `/usr/bin/asciinema` 3.2.0 is now visible on PATH and can create an asciicast v2 smoke file.
- Closed the local asciinema verification gap; `HIVE_ASCIINEMA_BIN` remains documented for non-PATH installs.

## [2026-04-29T00:00:00Z] e2e — second-pass fixer landed 12 deferred follow-ups

**Action:** Applied F#7/F#8/F#9/F#10/F#12/F#13/F#15/F#16/F#17/F#18/F#27/F#33 from PR #18's deferred queue. The user-visible surface changes: `bin/hive-e2e` learned `--json` for `list`, `run`, and `clean`; preflight failures now exit 78; `setup_failed` joins `passed`/`failed` as a third per-scenario status; failure artifacts now write `env-snapshot.json`, `<basename>.tail`, and `pane-before.txt`. `StepExecutor` was split across `string_expander.rb`, `scenario_context.rb`, `tmux_session_lifecycle.rb`. The dead `anchors.yml` and the unused `fake-claude-scripts/full-pipeline.sh` + `review-with-findings.sh` were removed. `repro.sh`'s `cd` traversal depth was corrected (six `..` to reach the repo root) and wrapped in `realpath` so a wrong depth surfaces visibly.

**Refreshed pages:**
- `wiki/e2e.md` — added Trust boundary subsection, Multi-stage fake-claude dispatch note, Scenario statuses (passed / failed / setup_failed), and updated the artifacts list (`env-snapshot.json`, `.tail` files, `pane-before.txt`).

## [2026-04-30T00:00:00Z] e2e — third-wave fixer landed 7 surviving follow-ups

**Action:** Applied seven survivor findings from the previous two waves on PR #18: (A) `bin/hive-e2e` `exit_on_failure?` regression test was already in place — verified; (B) `repro.sh` now replays setup-step kinds inline (`seed_state`, `write_file`, `register_project`, `ruby_block`, `state_assert`, `log_assert`) and explicitly skips live-tmux kinds (`tui_keys`, `tui_expect`, `wait_subprocess`, `editor_action`); (C) `Sandbox.cleanup_runs` now treats `status: complete` with `summary.failed > 0` as failed-retention (extracted to `retention_days_for`, with malformed report.json defaulting to `retain_failed_days`); (D) `Hive::Commands::Run` exposes `REQUIRED_PAYLOAD_KEYS` constant — the producer's `report_json` and the schema-drift test now both consume it (single source of truth); (E) `bundle lock --add-platform ruby` extended `Gemfile.lock` PLATFORMS; (F) `ArtifactCapture` now copies `<tmpdir>/hive-tui-spawn-*.log` plus the shared `hive-tui-subprocess.log` into `<scenario_dir>/tui-subprocess/` with `.tail` companions; (G) `tui_status_navigate_dispatch_plan` rebuilt around the TUI's verb-key dispatch path — `p` keystroke spawns `bin/hive plan`, `wait_subprocess` waits for the dispatched child, `state_assert` proves plan.md/COMPLETE landed.

**Refreshed pages:**
- `wiki/e2e.md` — `tui_status_navigate_dispatch_plan` description now reflects verb-key dispatch end-to-end coverage rather than the old "tmux-rendered grid" framing.

## [2026-04-30T17:30:00Z] e2e — PR #18 review fixes

**Action:** Fixed the follow-up ce-code-review findings on PR #18: `wait_subprocess` now observes run-scoped TUI subprocess END/ERRNO markers instead of tmux pane death; tmux sessions run commands through an env wrapper so PATH and `setup.tui_env` expansions reach `hive tui`; TUI subprocess logs are scoped per scenario; `repro.sh` expands args/env/cwd and preserves expected non-zero exits; report paths are run-relative; sample-project mutation now fails the scenario; `bin/hive-e2e` emits JSON error envelopes, handles `run --help`, and only preflights tmux for selected TUI scenarios; cleanup retention treats `setup_failed` as failed; the asciinema start guard is idempotent.

**Refreshed pages:**
- `wiki/e2e.md` — clarified run-relative report paths and run-scoped TUI subprocess artifacts.
- `wiki/commands/tui.md` — documented `HIVE_TUI_LOG_DIR` as the e2e-scoped subprocess log root.

## [2026-05-01T00:00:00Z] e2e — PR #18 review hardening

**Action:** Fixed the latest PR #18 review findings: scenario names and scenario-authored paths now validate/contain before filesystem writes; `hive-e2e replay` validates run/scenario components and uses no-shell exec; `hive-e2e clean` validates retention inputs, refuses unsafe roots, only deletes generated run directories, and can dry-run with per-run audit output; `repro.sh` uses the absolute repo root, validates setup paths, replays state/log/json assertions, and uses absolute `bin/hive` for `register_project`; e2e JSON contracts now have published schema files; stage-action/findings error schemas accept the shared structured lock and stage extras; TUI quiet subprocesses/timeouts and retained per-spawn captures are bounded.

**Refreshed pages:**
- `wiki/e2e.md` — added the `run_error_envelope` scenario to Current Scenarios.
- `wiki/testing.md` — updated the e2e starter scenario count to six.
- `wiki/commands/tui.md` — documented bounded quiet subprocesses and truncated retained spawn captures.

## [2026-05-15T00:00:00Z] release — v0.1.0 artifact workflow

**Action:** Added the v0.1.0 release artifact scaffold: `rake build:release[<target>]`, Tebako-backed `packaging/build/release.sh`, a spike helper under `packaging/spike/`, and a tag-triggered GitHub Actions workflow that builds tier-1 tarballs, writes `SHA256SUMS`, signs the checksum file with cosign keyless, and publishes the GitHub Release. Recorded ADR-027 in [[decisions]] so the chosen packager and fallback point are explicit.

**Refreshed pages:**
- `wiki/decisions.md` — ADR-027 (Tebako release artifact strategy).

## [2026-05-15T01:00:00Z] install — channels, XDG paths, prompt installer

**Action:** Added the user-facing install surface for v0.1.0: `install.sh`, `install.md`, Homebrew/AUR templates, XDG path docs, install-channel markers, `hive update`, `hive uninstall`, and the `hv` fallback entrypoint. `hive init` now writes the per-user daemon service unit and records whether the user chose to start it immediately.

**Refreshed pages:**
- `wiki/operating.md` — install channels, tier matrix, XDG layout, update/uninstall, skills marketplace command shapes.

## [2026-05-05T18:00:00Z] architecture — TUI/MVU pipeline

**Action:** Documented the TUI MVU pipeline (`BubbleModel ↔ Update ↔ KeyMap ↔ PasteAwareRunner ↔ InputDecoder`) in `wiki/architecture.md`, including the side-effect seam in `BubbleModel#handle_side_effect`, the paste-routing-by-mode contract for `RawTextInput`, decoder reset on cancel, and the GVL-yielding `YieldTick`. Hardened `InputDecoder` against unmapped C0 bytes (Ctrl+C now decodes to `KEY_CTRL_C`; other unmapped bytes are silently dropped), added 4 KiB `@pending` and 1 MiB `@paste_buffer` caps with truncation flashes, a 5 s paste-timeout flush, stray `\e[201~` consumption, ESC+CR/LF cancel-gesture absorption, and C0 stripping in `normalize_paste`. `PasteAwareRunner` now resets the decoder on transitions out of `:new_idea` / `:filter` and asserts `Bubbletea::VERSION == "0.1.4"` at load. Removed the dead `Messages::NewIdeaCharAppended` path; consolidated paste normalization on the decoder; switched the new-idea over-limit branch from drop-everything to partial-fit with a truncation flash; raised `input_timeout` from 1 ms to 5 ms to absorb fragmented paste markers; pinned bubbletea to `= 0.1.4` in the Gemfile.

**Refreshed pages:**
- `wiki/architecture.md` — added the TUI / MVU pipeline section.

## [2026-05-06T00:00:00Z] tui — arrow-key pane-focus shortcuts

**Action:** Added `Left` and `Right` arrow keys as explicit pane-focus shortcuts in grid mode (`lib/hive/tui/key_map.rb`, `lib/hive/tui/help.rb`), preserving the existing `Tab` / `Shift+Tab` toggle and `h` / `l` directional bindings. Behavior is grid-mode only — `:new_idea` keeps Left/Right cursor movement and `:filter` keeps Left/Right as no-ops. Help overlay and `wiki/commands/tui.md` updated; `tui_two_pane_navigate` e2e scenario extended to prove pane focus via follow-up `j` / `k` navigation rather than visibility alone.

**Refreshed pages:**
- `wiki/commands/tui.md` — documented `Left` / `Right` arrow keys alongside `h` / `l` and noted that left-pane focus shortcuts pin focus to the tasks pane below the two-pane breakpoint.

## [2026-05-11T00:00:00Z] tui — Enter-driven recovery for non-kill-class ERROR markers

**Action:** Added a `Hive::Tui::Messages::RecoverError` message and a `BubbleModel#recover_error` worker that mirrors the existing `recover_review` family. Enter on `error` rows now routes through `KeyMap.error_message`: kill-class signal kills (`130` / `137` / `143`) keep the existing `OpenLogTail` so they don't race the background auto-healer; every other exit_code (real failures the auto-healer deliberately leaves alone) clears the `<!-- ERROR -->` marker via `hive markers clear --name ERROR --match-attr exit_code=N` and re-dispatches `hive run <folder>` from a background worker thread. Per-folder dedup tracks on `@error_recovery_inflight`; partial-failure and programmer-error contracts match `recover_review`. The tasks-pane status column gained an enriched `ERROR exit_code=N` (or `ERROR <reason>` fallback) so operators read failure context without leaving the grid. Single source of truth for the kill-class exit-code list lives on `Hive::Markers::KILL_CLASS_EXIT_CODES`; the TUI's auto-healer and KeyMap's routing predicate both alias it so they cannot drift. The worker thread sets `Thread.report_on_exception = false` and logs programmer-error backtraces to `Hive::Tui::Debug.log` instead of letting them paint to the alt-screen; markers-clear timeouts (exit `124`) flash a specific recovery instruction (`retry shortly or run hive markers clear ... manually`) rather than a bare exit code.

**Refreshed pages:**
- `wiki/commands/tui.md` — Enter description updated for the dual error-row routing; new paragraph documenting the kill-class fallthrough, `--match-attr exit_code=N` discipline, status-column enrichment, and dedup behavior.

## [2026-05-14T12:00:00Z] rebase — PR #69 deferred-items follow-up + module/ADR docs

**Action:** Closed the deferred items from PR #69's `/ce-code-review` synthesis. Wrote `wiki/modules/rebase.md` (Public API, Result struct, internals, conflict-resolution loop, abort/cleanup, security boundaries, latency budget). Wrote `wiki/commands/rebase-status.md` documenting the read-only inspector verb (eight states, JSON envelope shape, why-no-fetch rationale). Updated `wiki/commands/run.md`: documented `--no-rebase` flag with `cli_override` reason; expanded the `rebase.reason` enum into a full table; documented `post_rebase_warnings`; added per-op timeout (`REBASE_OP_TIMEOUT_SEC = 300`) + bounded stderr capture (`GIT_CAPTURE_MAX_BYTES = 1 MiB`); added an explicit "Lock-window trade-off (accepted v1)" subsection covering the `MAX_CONFLICT_RESOLUTIONS × conflict_resolution_timeout_sec` worst case and the `--no-rebase` escape hatch; documented the B8 removal of the basename-match protected-files guard and replacement with `add_dirs: []` physical isolation; documented the B9 "agent-completed-the-rebase" exception that accepts the agent's work when the rebase finishes cleanly. Added ADR-025 to `wiki/decisions.md` ratifying the "additions are required and enums are closed" policy for `hive-run.v1` envelopes, with a comparison table justifying the choice against Hive's single-binary-no-third-party-consumer deployment model.

**Refreshed pages:**
- `wiki/modules/rebase.md` (new) — orchestrator module page.
- `wiki/commands/rebase-status.md` (new) — read-only inspector verb.
- `wiki/commands/run.md` — `--no-rebase` flag, expanded reason enum table, `post_rebase_warnings`, per-op timeouts, lock-window trade-off, basename-guard removal note, B9 exception.
- `wiki/decisions.md` — ADR-025 (additive-required + closed-enum JSON-envelope policy).
- `wiki/index.md` — registered `[[modules/rebase]]` and `[[commands/rebase-status]]`; bumped page count to 51 and ADR count to 25.

## [2026-05-14T13:00:00Z] tui — `r` is the in-TUI force-retry gesture for max_passes-hit REVIEW_STALE

**Action:** Added the missing in-TUI gesture pair for max_passes-hit REVIEW_STALE rows. Enter already opened the focal escalations file in `$EDITOR` for editing (per PR #66) but there was no in-TUI follow-up to clear the marker + rerun — operators had to shell out for `hive markers clear` + `hive run`. The `r` verb key was already in `VERB_KEYS` ("review") but on a max_passes-hit row it flashed "no action available" because `suggested_command` is nil for that row state. Repurposed: `r` on a `recover_review` row whose marker is `review_stale` now emits `Messages::RecoverReview.new(row:, force: true)`. The new `force:` field defaults to `false` (preserving Enter's browse-not-retry behavior) and, when true, bypasses `BubbleModel#recover_review`'s `retryable_review_stale?` gate so the row falls through to the same clear+rerun path the `wall_clock` / incomplete-triage shapes use. Scope-limited to the `r` key — other verbs (`b`/`p`/`d`/`P`) on a stale review row keep flashing "no action available" because dispatching them would be wrong, and `r` on a `review_error` row keeps its existing routing (Enter → `RecoverError`). Tests: +3 in `key_map_test.rb` (force-retry on REVIEW_STALE, other verbs still flash, `r` on review_error still flashes), +2 in `bubble_model_test.rb` (`force: true` clears + reruns; `force: false` default still routes to browse).

**Refreshed pages:**
- `wiki/commands/tui.md` — updated the "max_passes hit with completed passes" paragraph to document the Enter-vs-`r` gesture split and the `force:` flag's role in `BubbleModel#recover_review`.

## [2026-05-14T14:00:00Z] review — operator-edit detection retries pass N's fix when escalations-NN.md is edited after fix-success-NN.md

**Action:** Closed the recovery hole that made `r`-press on a max_passes-hit REVIEW_STALE row visually re-run hive but immediately re-write `REVIEW_STALE pass=N` without anything happening. Root cause: `Stages::Review#pass_completion_status` returned `:complete` whenever `fix-success-NN.md` existed, regardless of whether the operator had edited `escalations-NN.md` afterwards. `next_pass_for` then advanced to N+1, the loop body saw `pass > max_passes` and set REVIEW_STALE pass=N — same state, no progress. Fix: `pass_completion_status` now returns `:fix_incomplete` instead of `:complete` when `mtime(escalations-NN.md) > mtime(fix-success-NN.md)`, which keeps `next_pass_for` on pass N and routes the loop through the existing Phase-4-retry-only path (skips reviewers + triage, re-runs fix against the operator's current `[x]` marks). New helper `operator_edited_escalations_after_fix?` swallows `SystemCallError` / `IOError` so a transient stat failure fails-closed (no surprise retries). The comparison is strict `>` not `>=` so back-to-back same-second writes don't spuriously trigger retries. The TUI's `r` gesture from PR #72 is now actually useful for the max_passes-exhausted shape: Enter to open `escalations-NN.md`, edit, save, `r` to retry — Phase 4 re-runs with the edits as authoritative input, no max_passes bump required. Tests: +4 in `run_reviewers_test.rb` (post-fix newer-fix-success still :complete, operator edit flips to :fix_incomplete, equal mtimes stay :complete, stat failure fails closed) plus an end-to-end pin via `next_pass_for` returning N (not N+1) when escalations is newer.

**Refreshed pages:**
- `wiki/stages/review.md` — updated the `pass_completion_status` classification list to document the operator-edit detection branch and added a paragraph explaining how it composes with the TUI's `r` gesture (PR #72).

## [2026-05-14T15:00:00Z] worktree — new branches always start from origin/<default> after a quick fetch

**Action:** Closed the gap exposed by the agent-plugins-was-7-commits-behind incident. `Worktree#create!`'s new-branch path previously ran `git worktree add <path> -b <slug> <local_default>` — the new branch started wherever local `<default>` happened to be, which on a stale checkout was N commits behind `origin/<default>`. Reviewers in 5-review then surfaced every missing upstream commit as a phantom deletion (same failure mode as the i-want-to-be-able-260507-7682 incident PR #69 was built to handle, just at a different point in the pipeline). PR #69's auto-rebase pre-step keeps drift fresh in *existing* worktrees; this commit handles drift at *creation*. New private helper `freshest_base(default_branch)` returns `"origin/<default>"` after a successful `git fetch origin <default>` (non-interactive env, same shape as `GitOps#fetch_default_branch`); falls back to `default_branch` with a stderr warning when there is no `origin` remote or the fetch fails. Local `<default>` is never touched — any unpushed commits there are preserved. Tests: +3 in `worktree_test.rb` (origin-ahead-of-local case verifies worktree HEAD matches `origin/master` not local `master`; no-origin fallback still works; fetch-failure fallback emits a stderr warning AND still creates the worktree so offline operators are not blocked).

**Refreshed pages:**
- `wiki/modules/worktree.md` — added the `freshest_base` subsection under `create!`, naming the incident, citing PR #69 (drift in existing vs. new worktrees), and documenting the fetch env + fail-soft fallback.

## [2026-05-14T16:53:28Z] bootstrap

**Action:** Managed llm-wiki bootstrap from codebase and Hive registry.
**Pages created:** wiki/commands.md
**Pages updated:** wiki/index.md, wiki/log.md, wiki/gaps.md, .llm-wiki/config.json, AGENTS.md, CLAUDE.md, .claude/settings.json
**QMD:** qmd missing
**Scheduler:** files written; systemctl enable failed for llm-wiki-hive-e2088c70.timer
**Post-commit hook:** /home/asterio/Dev/hive/.git/hooks/post-commit
**Source:** Codebase read + git history

## [2026-05-14T17:26:52Z] llm-wiki validation

**Action:** Validated managed llm-wiki bootstrap and scheduled maintenance after Hive registry bootstrap.
**Headless agent:** Codex (`.llm-wiki/config.json` has `headless_agent: "codex"`).
**Context:** `AGENTS.md` and `CLAUDE.md` contain the managed LLM WIKI block; Claude `SessionStart` prints `wiki/index.md` and recent `wiki/log.md`.
**QMD:** `qmd 2.1.0` collection update, embed, and `qmd search` succeeded for this collection after the scheduled refresh test. Follow-up verification on 2026-05-15 confirmed `qmd status` uses Vulkan GPU offload on AMD Radeon 890M Graphics (RADV STRIX1), and `qmd query "llm wiki managed bootstrap" -c hive --no-rerank -n 3` completes with local GPU-backed generation.
**Scheduler:** `llm-wiki-hive-e2088c70.timer` is enabled and active under `systemctl --user`; next run is scheduled for 2026-05-15 18:03:41 BST.
**Maintenance scripts:** `.llm-wiki/refresh-wiki.sh` and `.llm-wiki/post-commit-refresh.sh` use bounded Codex and qmd timeouts and tell headless Codex not to run `qmd update` or `qmd embed` itself.
**Source:** `systemctl --user list-timers`, `qmd update`, `qmd embed`, and collection-scoped `qmd search`.

## [2026-05-13T00:00:00Z] stages — PR-first workflow

**Action:** Inserted `5-open-pr` before review, renumbered review/finalize/done to `6-review` / `7-finalize` / `8-done`, and repurposed the former PR stage as final wrap-up. Review comments are now mirrored to the open draft PR while local review files remain authoritative. Added `hive migrate` for explicit in-flight stage-folder renames.

**Refreshed pages:**
- `wiki/stages/index.md`, `wiki/stages/open-pr.md`, `wiki/stages/review.md`, `wiki/stages/finalize.md`, `wiki/state-model.md`, `wiki/architecture.md`, `wiki/commands/stage_action.md`, `wiki/commands/run.md`, `wiki/decisions.md`.

## [2026-05-15T15:55:00Z] daemon — plan WAITING rows auto-advance for daemon-enabled projects

**Action:** Fixed the daemon scheduler treating every `needs_input` row
as a user-edit wait. The symptom was a generated plan sitting in
`3-plan` with `<!-- WAITING -->` and "Needs your input" while the daemon
logged `skipped` every tick with `in_flight=0`; manually running
`hive run --json` flipped the marker to `complete`, after which the
daemon immediately dispatched `hive develop ... --from 3-plan`.
Root cause: `Hive::Daemon::Policy` only saw `action=needs_input`, so it
applied the mtime-baseline/debounce path meant for brainstorm answers,
execute questions, and review decisions. `Policy.decide` now accepts
the status row's `stage`; `3-plan` + `needs_input` dispatches
immediately because a plan WAITING marker is an approval pause, not a
Q&A file. Other `needs_input` stages keep the existing edit debounce.
Tests: added policy and dispatcher pins for first-sight plan WAITING
dispatch while preserving first-sight brainstorm baseline behavior.

**Refreshed pages:**
- `wiki/modules/daemon.md` — documents the stage-aware policy exception.
- `wiki/decisions.md` — ADR-024 now calls out `3-plan`/`:waiting` as
  daemon-auto-approved by `daemon.enabled: true`.

## [2026-05-16T00:00:00Z] red status — diagnose-then-act recovery details

**Action:** Added bounded red-row diagnostics to `hive status --json`, plus `hive status --diagnose <task>` for local inspection and `--write` for an agent-written `diagnostics/red-status.md` artifact. The TUI now opens a Q&A red-status detail view for ambiguous recovery/error rows, showing why the row is red, which artifacts were used, and explicit choices for autofix, manual worktree editing, or refreshed diagnosis.

**Refreshed pages:**
- `wiki/commands/status.md` — documented the required nullable `diagnostic` JSON field, diagnostic artifact selection, marker-signature freshness, and `--diagnose`.
- `wiki/commands/tui.md` — documented red-status detail mode, keybindings, snapshot refresh behavior, and preserved direct recovery exceptions.
- `wiki/decisions.md` — ADR-027 records the diagnose-then-act policy and its relationship to ADR-025.
- `wiki/index.md` — bumped refresh date.

## [2026-05-20T00:00:00Z] install — v0.1.0 release-surface review fixes

**Action:** Tightened the v0.1.0 install surface after review pass 2. The bash installer now keeps runtime dependency checks warn-only, writes prefix sidecars for `hive update`, pins cosign verification to the repository identity, and is covered by checksum, PATH-collision, and unsupported-platform smoke fixtures. `hive init` now passes the invoked Hive binary to daemon service registration; Homebrew macOS units resolve to the stable Homebrew `bin/hive` symlink. The AUR publisher remains deferred but the release workflow now fails loudly if its secret is configured before real publishing exists.

**Refreshed pages:**
- `wiki/operating.md` — documented prefix update behavior, tier-3 macOS x86_64 install.sh status, `--force-purge-state`, AUR `hv` caveat, and skills-package deferral.
- `wiki/decisions.md` — updated ADR-024 and ADR-027 for Homebrew stable daemon paths and release-workflow Tebako validation.
- `wiki/gaps.md` — added AUR publish, Rosetta/macOS x86_64, and skills-package follow-ups.

## [2026-05-15T16:03:12Z] tui — manual steering key

**Action:** Documented the `s` manual-steering gesture for `hive tui`. The key opens the focused task in the configured `execute.agent` inside the feature worktree, passes existing slug stage folders as add-dir context, marks the row `MANUAL_STEERING` so headless automation skips it, and archives the active folder under `.hive-state/stages/archived-manual/` after the interactive agent exits.

**Refreshed pages:**
- [[commands/tui]] — added keybinding, subprocess/manual-steering behavior, and status icon notes.
- [[operating]] — added the stuck-task manual takeover path for daemon operators.

## [2026-05-20T00:00:00Z] manual steering — run/status skip contracts

**Action:** Tightened the manual-steering escape hatch. `hive run` now stops before auto-rebase and stage dispatch when the state file carries `MANUAL_STEERING`, and `hive status` treats `.hive-state/stages/archived-manual/` as an intentional status-private sibling rather than a legacy stage directory.

**Refreshed pages:**
- [[commands/run]] — documented the manual-steering pre-run skip and JSON rebase reason.
- [[commands/status]] — documented status-private stage siblings for legacy-stage detection.

## [2026-05-20T14:00:00Z] daemon — env-hardened systemd unit, install --force, stale-AGENT_WORKING healer

**Action:** Unstuck the `hive daemon` failure mode where the systemd-user unit ticked forever with `status_failure ENOENT hive` because the daemon's `Open3.capture3({}, "hive", ...)` couldn't find the binary on a systemd-default PATH. Three coupled changes (PR #113):

- Baked `Environment=HIVE_BIN=<absolute-resolved-path>` and `Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin` into both `examples/systemd/hive-daemon.service` and `ServiceInstaller#render_systemd` substitution.
- Added `hive daemon install [--force]` for in-place unit upgrades. Atomic-write the new unit (tempfile + rename), rotate prior content to a timestamped `<path>.bak-YYYYMMDDTHHMMSSZ` (never overwrites a prior backup), and restart the running daemon on Linux / unload-then-load on macOS so new `Environment=` lines take effect.
- Added `Hive::Daemon::StaleAgentHealer` (tick-time): rewrites `AGENT_WORKING` markers whose backing agent isn't alive to `ERROR reason=agent_died` (dead pid) or `reason=agent_orphaned` (no pid, mtime past `daemon.agent_marker_grace_sec`, default 300s, mirrored from `Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC`). Skips in-flight controller slots and half-migrated projects. New daemon log events `marker_healed` / `marker_heal_failed` (registered in `Hive::Daemon::Logger::EVENTS`). `Hive::TaskAction` reads the same grace via threaded config so the synthetic classification (immediate, in-memory) and on-disk heal (next tick) agree.

**Refreshed pages:**
- `wiki/commands/daemon.md` — added `install [--force]` to the subcommands table.
- `wiki/modules/daemon.md` — corrected the load-bearing "daemon never writes markers" claim; documented the healer's narrow carve-out (heals, never advances) and the new log events.
- `wiki/modules/task_action.md` — updated the `:agent_working` carve-out to cover the new stale-classification branch and the synthetic diagnostic.

## [2026-05-22T13:30:00Z] release — packaging/verify-release.sh end-to-end behavior check

**Action:** Added `packaging/verify-release.sh` and a matching `verify-release` job in `install-smoke.yml`. The existing install-smoke jobs verify install SHAPE (binary lands, sidecar files written, `hive --version` works). The new script verifies BEHAVIOR — that the installed release artifact actually runs `init` / `status --json` / `daemon install --json` / `uninstall` and produces the right JSON envelopes (PR #118).

Key contracts:

- Isolates everything inside an XDG/HIVE_HOME/HOME tmp prefix. Captures `HOME_BEFORE` BEFORE overwriting `HOME` so the leak detector can scan the real user's home on macOS too (getent doesn't exist there).
- Sentinel file (`$PREFIX/.start-marker`) anchors `find -newer` for leak detection so the reference timestamp doesn't drift forward as the script writes child files into $PREFIX.
- Feature-detects post-`v0.1.0` subcommands (`daemon install`) by listing `VALID_SUBCOMMANDS` via the unknown-subcommand error path — robust against Thor's wrapped long_desc.
- Force-upgrade test plants a canary unit and asserts the `.bak-<timestamp>` rotation regardless of whether the service-manager call succeeded (the atomic write happens BEFORE systemctl/launchctl is invoked), so the .bak contract has CI coverage even on hosts without user systemd.
- `--report=json` flag emits a `hive-verify-release.v1` envelope on stdout (`{ok, version, prefix, passed, failed, steps[]}`) with human prose redirected to stderr, for programmatic consumption.
- Doctor crash discrimination keys off doctor's signature report header (`stage / agent / skill / status`), not arbitrary log content — tolerates rc=1/65/70 while still catching genuine Ruby uncaught-exception crashes.

**Refreshed pages:**
- `wiki/operating.md` — added a Release Verification section documenting the script's usage, exit codes, and JSON envelope.

## [2026-05-22T14:30:00Z] daemon — auto-detect Ruby manager shim in unit's PATH

**Action:** Fixed a release-blocking daemon failure on workstations running mise / rbenv / asdf to manage Ruby. PR #113 baked `Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin` into the unit, which is sufficient for system-Ruby hosts but causes `bin/hive`'s `#!/usr/bin/env ruby` shebang to resolve to `/usr/bin/ruby` — which has none of the gem's dependencies on a version-manager-driven workstation. The daemon then crashes on every restart with `cannot load such file -- thor (LoadError)` and systemd hits `StartLimitBurst=3 / Result=start-limit-hit`.

`ServiceInstaller#render_systemd` now detects the active Ruby interpreter via `which("ruby")`, walks the realpath against a known-manager set (mise's `~/.local/share/mise`, rbenv's `~/.rbenv`, asdf's `~/.asdf`), and prepends the matching `*/shims` directory to the unit's `Environment=PATH=` so `env ruby` resolves to the manager's shim → the right version with the right gemset. System-Ruby and "no ruby on PATH" cases fall through to the existing minimal PATH unchanged.

chruby and RVM are intentionally not handled — they modify PATH per-shell and don't expose a stable shim directory the unit can hard-code at install time.

**Why CI didn't catch it:** install-smoke's `full-smoke` job runs `hive --version` directly (not through systemd) using `ruby/setup-ruby@v1` which puts Ruby on PATH. `verify-release.sh` from PR #118 validates the install envelope but doesn't actually start the daemon and let it run a tick. Both pass against a release that crashes on the user's actual workstation. Worth a follow-up: integration coverage that exercises the daemon start path against multiple Ruby-manager fixtures.

**Refreshed pages:**
- `examples/systemd/hive-daemon.service` — extended the inline comment to explain why both `HIVE_BIN=` and `Environment=PATH=` are installer-managed (the PATH now carries Ruby-manager shim discovery on top of the minimal shell-out coverage).

## [2026-05-22T00:00:00Z] testing — merged subprocess coverage task

**Action:** Added `bundle exec rake coverage` as an opt-in coverage run using Ruby stdlib `Coverage`. The harness loads source files for honest zero-hit accounting, collects child Ruby subprocess coverage via `test/hive_coverage_boot.rb`, merges per-process result files under `coverage/.resultset/`, and writes `coverage/coverage.json` with line and branch summaries. `with_tmp_global_config(home: nil)` now isolates both `HIVE_HOME` and `HOME` by default while still allowing fake HOME fixtures to be passed explicitly.

**Refreshed pages:**
- [[testing]] — documents the coverage task and helper HOME semantics.

## [2026-05-24T00:00:00Z] testing — coverage report hardening

**Action:** Hardened `bundle exec rake coverage` into the CI coverage-report path. The harness now records per-run subprocess result directories, fails on unreadable result files, counts unloaded executable source files as uncovered, exposes an `ok` flag plus diagnostics in `coverage/coverage.json`, and supports an optional `HIVE_COVERAGE_MIN_LINE` threshold for line-coverage enforcement.

**Refreshed pages:**
- [[testing]] — documented the configurable line coverage threshold, per-run resultset directory, and unloaded/result-error failure modes.

## [2026-05-24T13:30:00Z] testing — CI coverage report stabilization

**Action:** Stabilized the merged coverage CI path after PR #121 exposed CI-only failures. Bot start tests now force foreground execution so `CI=true bundle exec rake coverage` cannot daemonize before the Minitest coverage reporter writes `coverage/coverage.json`. Stale TUI triage-mode assertions from the coverage branch were removed or updated to the current red-status detail contract, and `DropErrorKind::ALL` now follows the reload-safe self-derived enum pattern used by the other schema enums.

**Refreshed pages:**
- [[testing]] — documented the CI foreground/daemonization coverage pitfall and reload-safe enum caveat.

## [2026-05-22T00:00:00Z] artifacts-stage — runner and docs follow-up

**Action:** Closed the 7-artifacts workflow gap from PR #120 review. Added `hive artifacts` as a Thor command, wired `Hive::Stages::Artifacts` into `hive run`, made markerless `7-artifacts` rows dispatch artifact collection instead of finalize, and refreshed the live stage docs to the current `7-artifacts` / `8-finalize` / `9-done` tail.

**Refreshed pages:**
- [[state-model]]
- [[commands/stage_action]]
- [[commands/daemon]]
- [[modules/workflows]]
- [[modules/stages]]
- [[stages/artifacts]]
- [[stages/index]]

## [2026-05-22T18:01:31Z] e2e — fake Codex execute path

**Action:** Updated the e2e sandbox so `HIVE_CODEX_BIN` points at the same fake agent fixture as `HIVE_CLAUDE_BIN`. Extended `test/fixtures/fake-claude` with an opt-in commit hook so CLI-only scenarios can exercise the default Codex-backed `4-execute` path without spawning a live Codex agent.

**Docs:** Refreshed [[testing]] with the fake-agent contract and the requirement that execute scenarios create a real worktree commit to reach `EXECUTE_COMPLETE`.

## [2026-05-22T22:10:00Z] claude-mode — global tmux/headless launcher

**Action:** Added project-global `claude.mode` for every Claude-backed stage, moved the brainstorm tmux runtime into shared launcher docs, documented sequential shared tmux sessions for Claude reviewers, and kept `brainstorm.runtime` as a deprecated brainstorm-only fallback.

**Refreshed pages:**
- [[commands/init]]
- [[commands/doctor]]
- [[modules/config]]
- [[stages/brainstorm]]
- [[stages/index]]
- [[modules/reviewers]]
- [[templates]]
- [[decisions]]

## [2026-05-22T22:35:00Z] artifacts-stage — claude mode integration

**Action:** Updated `7-artifacts` from the placeholder no-agent marker stamp into an agent-backed collection stage. The configured `artifacts.agent` now writes `artifact.md`, and Claude-backed artifact collection uses the project-global `claude.mode` launcher.

**Refreshed pages:**
- [[stages/artifacts]]
- [[state-model]]
- [[decisions]]

## [2026-05-24T21:05:40Z] status — marker attrs and live task locks

**Action:** Fixed status classification for two runtime edge cases: marker parsing now tolerates Git stderr attrs containing `>` such as `branch -> branch`, and status treats a live per-task `.lock` as `Agent running` even before a working marker is written. This prevents finalize errors from appearing as "Needs your input" and prevents pre-review rebase work from appearing as runnable review work.

**Refreshed pages:**
- [[modules/markers]]
- [[modules/task_action]]
- [[commands/status]]

## [2026-05-25T07:34:24Z] tui — compact token footer

**Action:** Updated the grid-mode token footer to show only `today`, `7d`, and `all`, with the `tokens` label at the end of the compact legend instead of the beginning. The full `T` token matrix still exposes `30d`.

**Refreshed pages:**
- [[token-usage]]

## [2026-05-25T08:18:06Z] review follow-up — marker parsing and open-pr recovery

**Action:** Tightened marker parsing around marker-name boundaries and nested comment starts, clarified live-lock status rendering before a Claude PID is attached, and made 5-open-pr merged-PR recovery require a `headRefOid` match with the current local worktree HEAD.

**Refreshed pages:**
- [[modules/markers]]
- [[commands/status]]
- [[stages/open-pr]]

## [2026-05-25T15:45:00Z] bot — human-readable recovery alerts

**Action:** Replaced bot recovery push alerts with a short human-readable template and a single Autofix button, moved alert dedupe to a persistent status-driven store, added one 8 h reminder per unchanged recovery fingerprint, and made `/status [project]` render clean `Title… — Stage` lines without inline buttons.

**Refreshed pages:**
- [[modules/bot]]
- [[commands/bot]]

## [2026-05-25T16:40:00Z] bot — guarded Autofix alert lifecycle

**Action:** Guarded recovery Autofix behind retry diagnostics, carried marker match attributes into Telegram retry callbacks, reset persisted alert state before retry dispatch, treated same-task recovery fingerprint changes as superseded instead of recovered, and hardened alert-store/fanout failure handling.

**Refreshed pages:**
- [[modules/bot]]
- [[commands/bot]]
- [[state-model]]

## [2026-05-25T18:40:00Z] review — auto-commit successful fix-agent edits

**Action:** Changed Phase 4 review recovery so a successful fix agent that leaves dirty worktree files is auto-committed by Hive with the rollback-rate trailers before fix guardrails run, instead of landing repeated `fix_dirty_worktree` errors.

**Refreshed pages:**
- [[stages/review]]

## [2026-05-25T18:55:00Z] review/daemon — longer review timeout, lower daemon concurrency

**Action:** Changed the default per-reviewer timeout from 600 seconds to 3600 seconds in both the reviewer adapter fallback and fresh-project reviewer template, and lowered daemon default parallel task caps from 5 to 3 globally/per project.

**Refreshed pages:**
- [[modules/reviewers]]
- [[commands/daemon]]
- [[operating]]

## [2026-05-25T19:06:41Z] refresh - architecture, daemon liveness, gaps

**Action:** Refreshed the project wiki after reading `.llm-wiki/config.json`, agent instructions, the current wiki index/gaps/log, the configured cross-project wiki at `/home/asterio/wikis/master/wiki`, recent git history, and the dirty working-tree source changes. Documented PR #151's `live_task_lock` daemon path, updated stale architecture/active-area stage and AgentProfile descriptions, recorded the uncommitted `claude.permission_mode` surface in adjacent module/ADR pages, and made the gaps page explicit that source coverage is a representative domain map rather than an automated one-file audit.

**Refreshed pages:**
- [[architecture]]
- [[active-areas]]
- [[modules/daemon]]
- [[commands/daemon]]
- [[modules/agent]]
- [[modules/agent_profile]]
- [[decisions]]
- [[gaps]]
- [[index]]

## [2026-05-25T19:30:41Z] review — reject pre-existing dirty fix worktrees

**Action:** Tightened the Phase 4 auto-commit path so Hive refuses worktrees that are already dirty before the fix agent runs. Auto-commit now only captures edits introduced by a successful fix-agent spawn from a clean tree, preventing unrelated manual changes from being bundled into rollback-rate trailered fix commits.

**Refreshed pages:**
- [[stages/review]]

## [2026-05-26T22:10:00Z] babysitter — document out-of-band state layout

**Action:** Recorded the experimental PR-repair daemon's on-disk state in the state model: `<project>/.hive-state/babysitter/` (`events.jsonl`, `status.md`, ephemeral `worktrees/<pr>/`), plus `$HIVE_HOME/.babysitter.pid` and `$HIVE_HOME/logs/babysitter.log`. Confirmed paths against `status_writer.rb`, `events.rb`, `worktree.rb`. Noted the daemon has no marker grammar, stage `mv`, or `worktree.yml` — worktrees are recreated from the PR head each tick. Added a reciprocal `[[state-model]]` backlink to the babysitter module page.

**Refreshed pages:**
- [[state-model]]
- [[modules/babysitter]]

## [2026-05-26T10:05:02Z] bot — load ~/.config/hive/.env on bot start

**Action:** Added `Hive::EnvFile.load!` and wired it into `hive bot start` so operators can drop `HIVE_TELEGRAM_BOT_TOKEN=...` into `~/.config/hive/.env` instead of shell rc files. Existing env vars take precedence; `#` comments and outer single/double quotes are honored; missing/unreadable files are silently skipped. `hive bot reload` does NOT re-read the file — operators must restart after rotating secrets.

**Refreshed pages:**
- [[commands/bot]]

## [2026-05-26T10:36:10Z] review — inherit signing for fallback fix commits

**Action:** Changed Phase 4 fallback auto-commits to inherit the worktree's normal `commit.gpgsign` policy by default instead of forcing `commit.gpgsign=false`. Added `review.fix.auto_commit.sign_policy` with `inherit`, `bypass`, and `fail` modes so signed repositories can sign Hive fallback commits and operators can still opt into unsigned automation or a clear pause.

**Refreshed pages:**
- [[stages/review]]
- [[modules/config]]
- [[state-model]]

## [2026-05-26T10:52:00Z] review — keep user-answer checkboxes out of finding counts

**Action:** Changed answered escalation body and answer prose in Phase 4 accepted findings to use `[source] >>> ...` context lines. User-provided markdown checkboxes still reach the fix agent as context, but no longer match the accepted-finding counter that fills `Hive-Fix-Findings`.

**Refreshed pages:**
- [[stages/review]]
- [[state-model]]
- [[modules/metrics]]

## [2026-05-26T12:46:42Z] tui — spawn-failure recovery flash

**Action:** Refined `Hive::Tui::Subprocess.dispatch_background` so immediate spawn failures return a `false` sentinel after dispatching `SubprocessExited(exit_code: 127)`, and recovery workers now treat that sentinel like a failed rerun start instead of flashing that `hive run` is running after the marker was cleared.

**Refreshed pages:**
- [[commands/tui]]

## [2026-05-26T13:07:56Z] tui — align kill-class error predicates

**Action:** Aligned TUI kill-class routing with auto-heal semantics: only `ERROR reason=exit_code exit_code=130|137|143` is treated as auto-healed/log-tail-only. Markers with the same numeric code but another reason now remain recoverable through red-status detail and `RecoverError`. `hive markers clear --match-attr` now accepts comma-separated attr pairs, and the TUI uses both `reason` and `exit_code` when present so stale auto-heal/recovery workers cannot erase same-code/different-reason markers.

**Refreshed pages:**
- [[commands/tui]]
- [[commands/markers]]
- [[modules/markers]]
## [2026-06-05T16:04:21Z] e2e — refresh `bin/hive-e2e` usage exit-code coverage

**Action:** Refreshed executable-entrypoint wiki coverage after commit `d51455e6` changed `bin/hive-e2e` so Thor usage failures always re-raise through the outer rescue and exit `64`, including human unknown-command and missing-required-argument paths. Verified the committed diff plus `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[e2e]], [[testing]], [[cli]], and relevant [[gaps]] entries. Documented the e2e binary's success/failure/usage/config exit-code contract, the `hive-e2e-error` JSON envelope behavior, the focused executable tests, and the remaining lack of installed-binary smoke evidence. Page coverage count did not change. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[e2e]]
- [[testing]]
- [[gaps]]

## [2026-06-05T16:25:44Z] wiki/e2e — audit residual e2e wiki refresh commit

**Action:** Audited commit `654e25cd` after it committed residual wiki refresh changes for the `bin/hive-e2e` usage-exit contract. Read `AGENTS.md`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "bin/hive-e2e usage exit-code e2e testing gaps"` returned no indexed hits, so verification used the committed wiki diff plus direct reads of `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[e2e]], and [[testing]]. Confirmed page coverage did not change, kept [[index]] unchanged, and added the current human-mode stderr prefix expectation (`hive-e2e:`). Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[e2e]]
- [[testing]]
- [[log]]

## [2026-06-05T16:38:55Z] wiki/e2e — audit residual e2e wiki commit and scenario coverage

**Action:** Audited commit `02717784` after it committed residual e2e wiki refresh changes. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "bin/hive-e2e usage exit-code e2e testing gaps"` returned no indexed hits. Verified the committed wiki diff plus current `bin/hive-e2e`, `test/e2e/lib/hive_e2e_binary_test.rb`, and the scenario files under `test/e2e/scenarios/`. Kept [[index]] unchanged, preserved both archive-listing and e2e usage-exit gap entries while resolving the wiki merge state, and refreshed [[e2e]] / [[testing]] so scenario coverage no longer refers to the old seven/six-scenario inventory. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[e2e]]
- [[testing]]
- [[gaps]]
- [[log]]
  
## [2026-05-26T13:42:13Z] tui — guard ERROR recovery with marker_id

**Action:** Added generated `marker_id` attrs to new `ERROR` markers and changed TUI error recovery / kill-class auto-heal to clear by `--match-attr marker_id=...` when available. This closes the same-exit-code aliasing window where a stale recovery worker could clear a fresh `ERROR reason=exit_code exit_code=1` marker that the operator never reviewed. Legacy rows without `marker_id` fall back to observed `reason` and `exit_code` attrs when present.

**Refreshed pages:**
- [[modules/markers]]
- [[modules/agent]]
- [[commands/tui]]
- [[commands/markers]]
- [[state-model]]
- [[modules/task_action]]
- [[modules/bot]]
- [[commands/bot]]

## [2026-05-26T14:06:06Z] prune — detect relinked symlink registry entries

**Action:** `Hive::Config.register_project` now stores a private `real_path` when the registered path resolves, and `prune_missing_projects!` drops rows whose current realpath no longer matches that stored target. This catches a registered symlink that was retargeted to a different directory after the original project disappeared while preserving legacy rows without `real_path`.

**Refreshed pages:**
- [[modules/config]]
- [[commands/prune]]
- [[state-model]]

## [2026-05-26T14:39:00Z] config — lock and atomically rewrite global registry

**Action:** `Hive::Config.update_global_config!` now serializes global config read-modify-write operations on the sibling `config.yml.lock`, and `write_global_config!` writes through tempfile + fsync + atomic rename while preserving mode bits. `register_project`, `unregister_project`, `prune_missing_projects!`, and init daemon-autostart recording use the locked path so concurrent shells cannot lose registry updates or expose torn YAML.

**Refreshed pages:**
- [[modules/config]]
- [[state-model]]
- [[dependencies]]

## [2026-06-03T12:09:00Z] brainstorm — fail fast when tmux session disappears before marker

**Action:** `Hive::ClaudeLauncher.wait_for_terminal_marker` now verifies that the managed tmux session still exists while a Claude-backed stage is waiting on an `AGENT_WORKING` marker. If the session disappears before Claude writes `WAITING`, `COMPLETE`, or `ERROR`, Hive stamps `ERROR reason=tmux_session_terminated` immediately instead of polling until the full brainstorm timeout.

**Tests/docs:** Added a unit regression for an `AGENT_WORKING` state with a missing tmux session. Refreshed [[stages/brainstorm]].

## [2026-05-26T15:08:00Z] forget — add retry-safe --if-exists

**Action:** `hive forget NAME --if-exists` now exits 0 when the registry row is already absent, while the default `hive forget NAME` path still returns `unknown_project` / exit 64 for typo detection. The `hive-forget` success envelope now carries `removed: true` for actual removals and `removed: false` for `--if-exists` no-ops.

**Refreshed pages:**
- [[commands/forget]]
- [[cli]]

## [2026-05-27T10:39:00Z] release — document AUR SSH host-key CI TOFU

**Action:** Clarified that the AUR publish job uses `StrictHostKeyChecking=accept-new` only for non-interactive host-key first contact. Host identity checking remains enabled and later host-key changes still fail closed; `AUR_SSH_PRIVATE_KEY` remains the separate write-authorization gate.

**Refreshed pages:**
- [[decisions]]

## [2026-05-27T13:30:00Z] bot — acknowledge successful /idea capture

**Action:** Fixed the `/idea` project picker appearing to do nothing on tap. `Supervisor#child_completion_text` returned nil for every exit-0 child, so a successful `hive new` (idea capture) sent no confirmation; the picker token was already consumed, so a confused re-tap reported "idea picker expired." `child_completion_text` now confirms a successful `hive new` (keyed on the verb at `argv[1]`, since `normalize_hive_bin` rewrites `argv[0]`). Audit found `/approve` and `/done` share the silent-success shape but degrade gracefully (downstream notification + WRONG_STAGE on re-tap), so they were left as-is.

**Refreshed pages:**
- [[commands/bot]]

## [2026-05-30T15:21:04Z] review — auto-commit scoped pre-fix residue

**Action:** Updated 6-review Phase 4 so in-scope residue found before the fix agent is committed through the shared CleanExit/AutoCommit path with `Hive-Auto-Commit-Reason: pre_fix_dirty_worktree`, then rechecked before spawning the fix agent. Out-of-scope residue still lands `REVIEW_ERROR phase=fix reason=fix_dirty_worktree`. The clean-exit event type is now accepted so these commits are visible in `events.jsonl`.

**Refreshed pages:**
- [[stages/review]]

## [2026-05-30T19:55:00Z] recovery — make Git-status-check failures manual-only

**Action:** `REVIEW_ERROR phase=fix reason=fix_status_check_failed` now emits `suggested_next_action.kind=manual_fix`, bot recovery refuses `/autofix`, and TUI red-status Enter refuses instead of clearing and rerunning. The same TUI guard covers manual-only `ERROR` reasons such as `ensure_clean_on_exit_failed` so unreadable or dirty worktrees are repaired by an operator before retry.

**Refreshed pages:**
- [[stages/review]]
- [[commands/tui]]

## [2026-06-01T20:15:56Z] cli — refresh daemon queue wiki coverage

**Action:** Refreshed the wiki after commit `b175abf7` added `hive daemon queue` to the CLI index. Verified the docs claim against `lib/hive/cli.rb`, `lib/hive/commands/daemon.rb`, `lib/hive/daemon/dispatch_request_queue.rb`, `schemas/hive-daemon-queue.v1.json`, [[commands/daemon]], and [[modules/daemon]]. Updated the CLI JSON-support summary to include daemon `install` and `queue`, aligned daemon module metadata with the current command surface, refreshed the index date, and recorded the local git-index uncertainty that prevented a normal `git status` check. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[index]]
- [[gaps]]

## [2026-06-03T00:57:00Z] daemon/bot — refresh queue error and dispatch-result coverage

**Action:** Refreshed command/API wiki coverage after commit `b3193bd4` changed the daemon queue command, daemon request/result queues, dispatcher completion handling, Telegram bot dispatch-result relay, and the `hive-daemon-queue.v1` schema. Verified the committed diff and relevant source files. Added bot-side coverage for retry-safe dispatch-result draining, stale notice dropping, overflow summaries, and nil exit-code rendering; made the daemon queue JSON `ErrorPayload` arm explicit in CLI/daemon command coverage; refreshed page dates and recorded verification scope in [[gaps]]. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[modules/bot]]
- [[index]]
- [[gaps]]

## [2026-06-03T11:10:53Z] bot/wiki - refresh suppress-while-answering coverage after commit b293c7a3

**Action:** Refreshed wiki coverage after commit `b293c7a3` changed `ConversationStore`, `NotificationDispatcher`, `Supervisor` wiring, and the focused bot tests for suppressing proactive `needs_input` pushes while an operator is actively answering a slug. Verified the committed diff and relevant source/test files, confirmed [[modules/bot]] already described the dispatcher contract, expanded the `ConversationStore` module-map row with the prune-aware `active_for_slug?` role, and recorded the remaining live Telegram/daemon WAITING-flap smoke uncertainty in [[gaps]]. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/bot]]

## [2026-06-03T12:35:00Z] wiki — refresh tmux-session loss coverage

**Action:** Follow-up wiki refresh for commit `71db09c7`. Verified the committed diff against `lib/hive/claude_launcher.rb` and `test/unit/claude_launcher_test.rb`; broadened shared stage coverage to note that marker-owned Claude tmux launches fail fast with `ERROR reason=tmux_session_terminated`, added `claude_launcher_test.rb` to the testing coverage map, and recorded the remaining live-smoke uncertainty for killing a real managed tmux session mid-stage. Page coverage count did not change, so [[index]] needed no structural update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[stages/index]]
- [[testing]]
- [[gaps]]

## [2026-06-03T12:00:00Z] bot — support Telegram idea attachments

**Action:** Added Telegram photo/document idea capture to the bot. `/idea`
now creates a per-chat draft, project selection enters attachment
collection, Done/Skip finalizes through `Hive::Commands::New#call!`, and
accepted media is staged in a temp dir before being copied into inbox
`assets/`. Documented the new `stage_attachment`/`commit_idea` supervisor
actions, allowlisted file types, 20 MiB / 10 attachment defaults, and draft
TTL config.

**Refreshed pages:**
- [[architecture]]
- [[commands/bot]]
- [[modules/bot]]
- [[modules/config]]
- [[gaps]]

## [2026-06-03T10:58:00Z] bot — refresh idea attachment routing coverage

**Action:** Refreshed command/API wiki coverage after commit `af183c0b` routed Telegram idea attachment composition through the bot router and handlers. Verified the committed diff plus `lib/hive/bot/router.rb`, slash/callback handlers, `IdeaDraftStore`, `IdeaAttachmentPolicy`, `Supervisor` attachment staging/commit handling, `Telegram` media/download support, `Hive::Commands::New`, and the focused router/callback/S4 idea tests. Documented `/idea` text-first, no-text, captioned-media, file-first, project-pick, Done/Skip, attachment-type, size, count, staging, and final `Hive::Commands::New#call!` behavior. Recorded that no live Telegram download smoke artifact was found. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[modules/bot]]
- [[commands/bot]]
- [[gaps]]

## [2026-06-03T13:27:55Z] cli/install — refresh hv fallback entrypoint coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after the `hv` fallback change updated `bin/hv` and added `test/unit/hv_test.rb`. Verified the committed diff plus the current `bin/hv`, install/README references, packaging references, [[cli]], [[operating]], and [[testing]]. Documented that `hv` probes only `HIVE_BIN_OVERRIDE`, XDG, Homebrew, and `/usr/local/bin` candidates and intentionally no longer falls through to `/usr/bin/hive` or `/opt/hive/bin/hive`; added unit-test coverage for the override path and recorded the missing live Apache Hive collision smoke evidence. Page coverage count did not change. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[operating]]
- [[testing]]
- [[index]]
- [[gaps]]

## [2026-06-05T00:00:00Z] daemon/tui — reduce perceived stage-transition latency

**Action:** Refreshed wiki coverage after removing the SUCCESS inter-stage cooldown, adding the daemon's 1s cheap fast-poll probe, and mtime-gating TUI status reparses. `daemon.poll_interval_sec` remains the 30s full-scan backstop, while `daemon.fast_poll_sec` drives child reap and state-file/stage-dir mtime probes. SUCCESS exits now allow immediate follow-on dispatch; WRONG_STAGE keeps a 60s protective backoff. The TUI still polls at 1 Hz and redraws only on changed snapshots, and now skips `Status#json_payload` when its mtime fingerprint is unchanged.

**Refreshed pages:**
- [[commands/daemon]]
- [[modules/daemon]]
- [[commands/tui]]
- [[index]]

## [2026-06-05T15:00:47Z] tui resize — document app-level SIGWINCH dispatch

**Action:** Fixed and documented `hive tui` resize handling after a terminal-grow report showed the two-pane dashboard retaining stale dimensions. `App.run_charm` now seeds the model from `STDOUT.winsize` and installs a Hive-owned `SIGWINCH` hook that dispatches `Messages::WindowSized`; Bubble Tea still owns renderer resizing and chains back through Hive's hook. Added unit coverage for terminal-size mapping, unavailable tty handling, resize-hook dispatch, and restore failure handling, plus a PTY integration regression that resizes a running `hive tui` process from 120 to 150 columns, sends `SIGWINCH`, and asserts the next frame expands. Refreshed the Charm bubbletea API-gaps solution note so it no longer claims Hive has no WINCH hook.

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-05T16:30:00Z] wiki — audit TUI resize refresh coverage

**Action:** Audited commit `50a2a010` after it updated the TUI resize implementation and initial docs. Read `AGENTS.md`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "tui resize SIGWINCH bubbletea WindowSized"` found the updated TUI command page and prior Charm backend context. Verified the committed diff plus `lib/hive/tui/app.rb`, `test/unit/tui/app_test.rb`, `test/integration/tui_smoke_charm_test.rb`, `wiki/commands/tui.md`, and `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`. Confirmed the command page and solution note match the app-owned WINCH hook, added focused `tui/app_test.rb` coverage to [[testing]], and added a PTY resize integration smoke so the live resize path is no longer only unit-pinned. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]

## [2026-06-05T10:09:45Z] wiki — audit daemon/tui latency refresh coverage

**Action:** Audited commit `68d9245f` after it refreshed daemon/TUI latency wiki pages. Read `AGENTS.md`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search` had no indexed hits for this exact latency work, so verification used the committed diff plus direct source reads. Checked commits `0f4d9373`, `c1a63370`, and `7375c51d` against `lib/hive/daemon/concurrency_controller.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/config.rb`, `lib/hive/tui/state_source.rb`, and focused tests. Confirmed existing daemon/TUI pages matched the code and added the missing live-smoke uncertainty to [[gaps]]. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]

## [2026-06-03T12:35:51Z] new/display-name/resolver — refresh task identity command coverage

**Action:** Refreshed command/API wiki coverage across commits `df87abe5` (`hive new` task-id capture), `c86a74b8` (`hive generate-name` display-name generation), and `41d10785` (numeric task-id target resolution). Verified the committed diffs, `lib/hive/commands/new.rb`, `lib/hive/commands/generate_name.rb`, `lib/hive/display_name/*`, `lib/hive/agent/message_extractor.rb`, `lib/hive/task_meta.rb`, `lib/hive/task_counter.rb`, `lib/hive/task.rb`, `lib/hive/task_resolver.rb`, `lib/hive/cli.rb`, and the new integration/unit tests. Documented the sidecar/counter state model, the display-name command pipeline, and path/slug/id target resolution. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/new]]
- [[commands/generate-name]]
- [[state-model]]
- [[modules/task]]
- [[modules/task_resolver]]
- [[cli]]
- [[stages/inbox]]
- [[index]]
- [[gaps]]

## [2026-06-05T16:05:00Z] tui — document display-cell formatting for task rows

**Action:** Documented the TUI formatter's direct `unicode-display_width` dependency after task-pane icon alignment work. `Hive::Tui::Views::Format` now owns display-cell truncation and padding so emoji status icons and other wide glyphs do not shift fixed columns. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[dependencies]]

## [2026-06-05T16:25:00Z] patrol/status — review-task idea context and archive age filtering

**Action:** Documented two dogfood fixes: patrol review handoff now writes `idea.md` from the original patrol finding so the TUI idea preview has context, and archive hiding now uses row `mtime` rather than mutable `folder_mtime` so sidecar edits do not make old archived tasks reappear in daily views. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/patrol]]
- [[commands/status]]
- [[commands/tui]]
- [[testing]]

## [2026-06-03T13:20:00Z] task identity surfaces — document status, TUI, bot, and migration backfill

**Action:** Extended the task-identity wiki refresh through commits `457c2f16` (`hive status` id/display_name schema v3), `d76be350` (TUI id/name columns), `5daa08c9` (Telegram display titles), and `1a4922c4` (`hive migrate` id backfill). Documented human rendering fallbacks, preserved slug-based callbacks/commands, diagnose schema v2, and migration counter seeding/idempotency. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[commands/migrate]]
- [[modules/bot]]
- [[state-model]]

## [2026-06-05T15:14:59Z] babysitter — refresh dry-run git stub write guard coverage

**Action:** Refreshed command/API and executable-stub wiki coverage after commit `29532639` changed `bin/hive-babysitter-stub-git`. Verified the committed diff plus the current git/gh dry-run stubs, `test/unit/babysitter/dry_run_env_test.rb`, `lib/hive/cli.rb`, `lib/hive/commands/babysit.rb`, [[commands/babysit]], [[modules/babysitter]], and [[gaps]]. Documented that otherwise read-only `git` commands now skip when they include `--output` / `--output=...`, while plain read forms such as `git diff --name-only` still pass through. Recorded that the change is unit-pinned but still lacks a live `hive babysit --once PROJECT --dry-run` agent smoke artifact. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[gaps]]

## [2026-06-05T16:45:15Z] wiki — audit babysitter dry-run refresh coverage

**Action:** Audited residual wiki commit `e4d6fdab` after it committed the babysitter dry-run documentation refresh. Read `AGENTS.md`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run git output residual worktree"` only surfaced earlier babysitter wiki history, so verification used the committed diff plus direct source reads. Checked source commit `29532639` against `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, `lib/hive/commands/babysit.rb`, and `lib/hive/babysitter/`. Confirmed existing [[commands/babysit]], [[modules/babysitter]], and [[gaps]] coverage matches the code: broad read-only `git` commands skip `--output` / `--output=...`, `git diff --name-only` still passes through, and live `hive babysit --once PROJECT --dry-run` agent smoke evidence remains absent. Page coverage count stayed 74, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[log]]

## [2026-06-05T18:52:58+01:00] babysitter — refresh dry-run git exec/env stub coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `f748deed` changed `bin/hive-babysitter-stub-git` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run git exec env bypass grep output pager config-env"` had no exact indexed hits, so verification used the committed diff plus direct source reads. Documented that dry-run git screening is now structurally scoped: config injection is screened only in global options, `--exec-path` is a global exec screen, `--output` is exact so `--output-indicator-*` passes, and grep pager execution includes bundled short flags such as `-nO...`; also documented scrubbing of `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `GIT_SSH`, `GIT_SSH_COMMAND`, and `GIT_CONFIG*`, plus the exit-127 diagnostic for invalid `HIVE_BABYSITTER_REAL_GIT`. The live `hive babysit --once PROJECT --dry-run` agent-smoke gap remains open. Page coverage count stayed 74, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[gaps]]
- [[log]]

## [2026-06-05T17:26:02Z] wiki — audit patrol handoff residual log coverage

**Action:** Audited residual wiki commit `a94719a0`, which only appended the previous babysitter dry-run audit entry to [[log]]. Read `AGENTS.md`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "patrol review handoff opened PR residual wiki"` surfaced the existing patrol handoff coverage. Verified the residual commit diff directly, then checked the underlying patrol PR #312 source commit `598fd191` against `lib/hive/patrol/review_handoff.rb`, `lib/hive/patrol/pr_opener.rb`, `lib/hive/commands/patrol.rb`, `lib/hive/daemon/patrol_scheduler.rb`, `lib/hive/config.rb`, `templates/project_config.yml.erb`, and the focused patrol/config tests. Confirmed current [[commands/patrol]], [[modules/patrol]], [[modules/config]], [[stages/review]], [[state-model]], [[testing]], and [[gaps]] already match the code: patrol handoff is defaulted through `patrol.review_prs: true`, synthetic review slugs are globally unique across stages, handoff failures are retryable and surfaced in `review_handoff_errors`, successful handoff keeps the patrol worktree for `6-review`, and `patrol.trigger` is now `continuous` by default. No page-list or gap changes were needed. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[log]]

## [2026-06-05T18:00:00Z] babysit — dry-run git stub screens exec/write options across argv

**Action:** Hardened `bin/hive-babysitter-stub-git` after a review pass found that the read-only allowlist plus the original-`argv` `exec` let several non-mutating-looking commands run arbitrary code via real git: `-c diff.external=<cmd>`/`*.textconv`/`core.pager` config injection (silently stripped by `stripped_global_options` yet preserved in the exec argv), `git grep -O<cmd>` / `--open-files-in-pager=<cmd>` pager exec, and global-position `--output`. Replaced the one-entry `no_write_options?` (`--output` only, on the stripped `rest`) with `dangerous_option?` + `no_exec_or_write_options?` that screen the entire invocation — `-c`, `--config-env`, `--output`, `-O`, `--open-files-in-pager` — before exec, so the guard no longer trusts the stripped subcommand alone. Also guarded `stripped_global_options` against `shift(2)` on a trailing valueless option and made `log_skip` warn instead of silently swallowing `SystemCallError`. Added regression tests in `test/unit/babysitter/dry_run_env_test.rb` for each exec/write vector plus a passing `git grep needle`, and updated [[commands/babysit]] to document the broadened screening.

**Refreshed pages:**
- [[commands/babysit]]
- [[log]]

## [2026-06-05T18:30:39+01:00] wiki — refresh babysitter dry-run executable coverage after argv-wide guard

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `b5f53f98` hardened `bin/hive-babysitter-stub-git`. Read `AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run git stub dangerous option output pager config"` surfaced prior babysitter dry-run history, so verification used the committed diff plus direct source reads. Checked `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], and [[modules/babysitter]]. Updated [[commands/babysit]], [[modules/babysitter]], and [[gaps]] so command tests, module/boundary coverage, and live-smoke uncertainty mention `-c`, `--config-env`, `-O`, `--open-files-in-pager`, and `--output` screening across the original argv. Page coverage count stayed 74, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]
- [[gaps]]
- [[log]]

## [2026-06-05T18:45:40+01:00] wiki — audit residual babysitter dry-run coverage commit

**Action:** Audited residual wiki commit `557e6ef4`, which committed the previous babysitter dry-run documentation refresh as 6-review residue. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run git stub dangerous option output pager config residual"` surfaced prior babysitter dry-run history. Verified the committed diff, then checked `bin/hive-babysitter-stub-git`, `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], and [[modules/babysitter]]. Confirmed the current pages already match the code and tests: dry-run git allowlisted read subcommands still pass through only after argv-wide screening for config-injection, pager-exec, and output-file vectors; the live `hive babysit --once PROJECT --dry-run` agent-smoke gap remains recorded in [[gaps]]. Page coverage count stayed 74, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[log]]
## [2026-06-05T14:22:45Z] cli/status — refresh no-target archive listing coverage

**Action:** Refreshed command/API wiki coverage after commit `93fb45fb` changed `hive archive` from a target-required workflow-only command into a split surface: no target lists archived tasks through `Hive::Commands::Status.new(archive: true)`, while `hive archive <target>` still runs the `StageAction` promote-or-run workflow verb. Read `AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "archive status command"` found existing workflow/archive wiki context. Verified the committed diff plus current `lib/hive/cli.rb`, `lib/hive/commands/status.rb`, `lib/hive/archive_filter.rb`, and focused CLI/status tests. Documented no-target text and JSON archive listing, empty archive output, and the CLI overlay boundary. Recorded that live registered-project archive workflow evidence is still missing. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands/status]]
- [[commands/stage_action]]
- [[commands/tui]]
- [[state-model]]
- [[testing]]
- [[gaps]]

## [2026-06-04T21:38:00Z] status/tui — archive hiding and archive views

**Action:** Refreshed command/API wiki coverage after commits `6d10e386` through `bfa4b590` added `tasks[].folder_mtime`, `Hive::ArchiveFilter`, default text/TUI hiding for clean old `9-done` rows, an unfiltered TUI Archive pane, and no-arg `hive archive` listing. Verified the committed diffs plus current `lib/hive/commands/status.rb`, `lib/hive/archive_filter.rb`, `lib/hive/tui/snapshot.rb`, `lib/hive/tui/views/archive_pane.rb`, `lib/hive/cli.rb`, the status schema, and focused status/TUI/CLI tests. Documented the distinction between state-file `mtime` and task-folder `folder_mtime`, the 3-day resolved-marker-only hide policy, the JSON boundary that keeps default `hive status --json` unfiltered, the explicit archive views, and the missing live registered-project smoke evidence. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[state-model]]
- [[testing]]
- [[index]]
- [[gaps]]

## [2026-06-05T17:42:09Z] migrate — backfill legacy display names for all task sources

**Action:** Extended `hive migrate` beyond task-id repair so it also scans every canonical task folder with a missing/null `display_name` and runs `Hive::DisplayName::Generator` with commits disabled, then records successful name writes in a separate `.hive-state` commit. This uses the same agent-backed naming pipeline as `hive generate-name`, preserves existing names (including patrol handoff names), and leaves failed generations retryable. Added focused migration and generator tests and updated command/state docs.

**Refreshed pages:**
- [[commands/migrate]]
- [[state-model]]
- [[stages/inbox]]

## [2026-06-05T18:02:00Z] patrol — allocate task ids for review handoff tasks

**Action:** Changed `Hive::Patrol::ReviewHandoff` so synthetic `6-review/patrol-.../` tasks allocate a normal `Hive::TaskCounter` id instead of writing `id: nil` unconditionally. The fail-soft behavior now matches `hive new`: counter lock contention leaves the id null, but the task is still enqueued and `hive migrate` can repair it later. Added patrol handoff/opener coverage and corrected the task sidecar docs.

**Refreshed pages:**
- [[state-model]]

## [2026-06-05T20:05:00Z] tui — vertical resize viewport and reduced dashboard chrome

**Action:** Made the grid composer height-aware: it subtracts footer/stalled-banner rows from `model.rows`, passes the remaining budget into `ProjectsPane` and `TasksPane`, and each pane clips/pads with a cursor-following viewport. Removed the persistent grid metadata strip and hidden-archive footer prefix so the first frame prioritizes panes and the footer stays visible under vertical terminal resize. Added focused pane viewport tests plus a PTY Charm smoke that performs a real vertical `winsize` + `SIGWINCH` resize and verifies the footer remains visible.

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-05T22:45:00Z] bot — refresh voice idea command/API coverage

**Action:** Refreshed command/API wiki coverage after the voice-idea implementation series (`e96e024b`, `1e61c1ff`, `9a79198a`, `a740bab7`, `21813bb2`, `b09a18db`, `6f7aa97b`, `89937845`) added Telegram voice metadata parsing, an OpenAI-compatible transcriber, transcription config validation, transcript-confirm draft state, router/callback confirm-edit-discard handling, supervisor transcription execution, transcript-only capture integration coverage, fallback audio retention, fake Telegram voice injection, and opt-in live Telegram voice E2E hooks. Read `AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "telegram voice idea confirmation bot router callback slash handlers"` returned no indexed hits, so verification used direct wiki/source reads. Inspected the committed diffs plus `lib/hive/bot/router.rb`, `lib/hive/bot/handlers/slash_handlers.rb`, `lib/hive/bot/handlers/callback_handlers.rb`, `lib/hive/bot/supervisor.rb`, `lib/hive/bot/transcriber.rb`, `lib/hive/bot/telegram.rb`, `lib/hive/bot/idea_draft_store.rb`, `lib/hive/config.rb`, `test/integration/bot/scenarios/s6_voice_idea_test.rb`, `test/eval/support/fake_telegram.rb`, and `test/e2e/tg/drive_idea.py`. Documented bare voice-note idea capture, transcript confirm/discard/edit/re-record callbacks, immediate commit after project selection for voice-only drafts, failed-transcription audio fallback, transcription config validation, Faraday multipart usage, env-only `HIVE_WHISPER_API_KEY`, and secret-gated E2E behavior. Recorded that live Telegram download and live OpenAI transcription smoke evidence is still missing unless the opt-in E2E is run with a real fixture/key. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bot]]
- [[modules/bot]]
- [[modules/config]]
- [[architecture]]
- [[dependencies]]
## [2026-06-05T21:27:50Z] claude-launcher — fail fast on dead tmux expected-output waits

**Action:** Fixed `Hive::ClaudeLauncher.wait_for_expected_output` so Claude/tmux reviewer waits observe tmux session liveness even before the expected artifact exists. A disappeared session now returns `status: :error` with `tmux_session_terminated...` instead of holding `REVIEW_WORKING` until the full reviewer timeout; a non-empty artifact is accepted after session death only when Claude's Stop hook already wrote `.done`, so partial reviewer files are retried instead of promoted. Added bounded daemon auto-recovery for no-live-lock `REVIEW_ERROR reason=review_agent_died` rows and for `REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure` rows whose `reviews/errors-NN.md` contains only this tmux expected-output session-death shape, so common Claude/tmux crashes retry without an operator clicking autofix while repeated identical failures stay red after the default 3 clears. Added unit regressions for missing-output fast-fail, partial-output rejection, done-signaled preservation, auto-clear, retry-budget exhaustion, live-lock skip, and mixed-error non-clear, and refreshed agent/daemon/state/testing docs.

**Refreshed pages:**
- [[modules/agent]]
- [[modules/daemon]]
- [[state-model]]
- [[testing]]

## [2026-06-05T23:20:00Z] tui — seed first snapshot before Bubbletea loop

**Action:** Investigated slow `hive tui` startup. `hive status --json` and
`StateSource` were fast in isolation, but a PTY probe showed the background
`StateSource#refresh_once` entering before the first frame and then being
starved by the Bubbletea render/input loop, leaving the UI on the loading grid.
Added synchronous `StateSource#refresh_now` and seeded the initial TUI model with
that snapshot before starting the runner. Local PTY first useful paint improved
to about 0.24s and the smoke tests now assert seeded projects appear within 2s.

**Verified:**
- `bundle exec ruby -Itest test/unit/tui/state_source_test.rb test/integration/tui_smoke_test.rb test/integration/tui_smoke_charm_test.rb`
- `bundle exec rubocop --format simple lib/hive/tui/app.rb lib/hive/tui/state_source.rb test/unit/tui/state_source_test.rb test/integration/tui_smoke_test.rb test/integration/tui_smoke_charm_test.rb`

**Refreshed pages:**
- [[commands/tui]]
## [2026-06-07T10:45:00Z] agent — classify provider limits before generic agent failures

**Action:** Added `Hive::AgentLimit` and wired it into headless `Hive::Agent#handle_exit` plus Claude tmux readiness, terminal-marker, and expected-output waits. Provider quota/rate-limit text and Claude's usage-credit menu now surface as `limits reached for <agent>:` / `ERROR reason=limits_reached` before generic `exit_code`, `timeout`, `tmux_session_terminated`, or "interactive prompt did not become ready" failures. Checked the current red Hive rows: `patrol-command-bin-hive-e2e-effc81e9` and `patrol-command-bin-hive-e2e-bb21a633` had the exact Claude "Stop and wait for limit to reset" / "Add funds to continue with usage credits" menu behind `triage_failed` / `timeout`; other apparent matches were historical `[stream]` log lines containing source line numbers or review text, not provider-limit evidence. Added focused regressions in `agent_limit_test.rb`, `agent_test.rb`, and `claude_launcher_test.rb`.

**Refreshed pages:**
- [[modules/agent]]
- [[stages/index]]
- [[state-model]]
- [[testing]]

## [2026-06-06T10:14:41Z] patrol — scoped review reviewers for patrol PR handoff

**Action:** Added a separate `patrol.review.reviewers` config list for synthetic `Patrol: ...` review tasks. Fresh `hive init` now asks for patrol PR reviewers separately from normal `review.reviewers`, defaults patrol PR review to `codex-ce-code-review` only, and lets operators opt into `claude-ce-code-review`; `pr-review-toolkit` is intentionally excluded from the patrol prompt. The 6-review runner selects `patrol.review.reviewers` when `task.md` frontmatter has `source: patrol`, while normal tasks continue using `review.reviewers`. Updated [[commands/init]], [[commands/patrol]], [[modules/config]], and [[stages/review]].

## [2026-06-06T10:45:00Z] wiki — audit scoped patrol reviewer command/API coverage

**Action:** Audited commit `464b64a9` after it touched CLI help, init prompts, config defaults/validation, the 6-review reviewer selector, the `hive-init.v1` schema, the project config template, and public architecture docs. Read `AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "patrol review reviewers config init"` found existing config/index/gaps context. Verified the committed diff plus `lib/hive/commands/init.rb`, `lib/hive/commands/init/prompts.rb`, `lib/hive/config.rb`, `lib/hive/stages/review.rb`, `templates/project_config.yml.erb`, `schemas/hive-init.v1.json`, and focused init/config/schema/review tests. Refreshed command/API coverage for the new `patrol_reviewers` init payload field, `patrol.review.reviewers` config surface, and patrol-sourced reviewer selection; recorded that the scoped patrol reviewer path is still not live-smoked through a real patrol PR plus daemon/TUI pickup. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[index]]
- [[architecture]]
- [[commands/init]]
- [[commands/patrol]]
- [[modules/config]]
- [[stages/review]]
- [[testing]]
- [[gaps]]

## [2026-06-06T19:45:07Z] openclaw — guided Hive setup through umbrella skill

**Action:** Updated the OpenClaw skill model so the umbrella `/hive` skill is the first-use setup path instead of hard-failing when the Hive CLI is missing. The umbrella skill is now always visible, declares macOS Homebrew installer metadata, detects strict Hive CLI versions via `hive` or `hv`, guides confirmed platform install commands, runs `hive daemon install`, and optionally initializes the current project. Shortcut skills remain gated on the `hive` binary so workflow shortcuts only appear after setup. Refreshed the OpenClaw README, top-level README, [[operating]], and [[gaps]] to distinguish ClawHub skill installation from guided setup.

**Follow-up:** During ClawHub preflight, `clawhub inspect hive` showed the naked `hive` slug is already owned by another publisher and describes a different integration. Updated the intended umbrella ClawHub slug to `hive-cli`; the installed skill still exposes `/hive`, and shortcut listings remain `hive-*`.

**Refreshed pages:**
- [[operating]]
- [[gaps]]

## [2026-06-07T10:42:24Z] wiki — post-commit agent-limit coverage audit

**Action:** Refreshed wiki planning/documentation coverage after commit `d22caf37` added `Hive::AgentLimit` and already touched [[modules/agent]], [[stages/index]], [[state-model]], [[testing]], and [[log]]. Read `AGENTS.md`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "agent limit provider quota rate limit claude usage credits"` returned no indexed hits, so verification used direct source/wiki search plus the configured master wiki path (no relevant hit). Inspected the committed diff and current `lib/hive/agent_limit.rb`, `lib/hive/agent.rb`, `lib/hive/claude_launcher.rb`, focused unit tests, and the touched wiki pages. Updated [[modules/agent]] to map the new classifier source file, refreshed [[architecture]] to remove stale inode-based concurrent-edit wording and document limit precedence in headless/tmux paths, updated [[gaps]] with the new source-coverage row and missing post-fix live-smoke evidence, and bumped [[index]] because page coverage metadata changed. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/agent]]
- [[architecture]]
- [[gaps]]
- [[index]]

## [2026-06-07T14:20:00Z] babysitter — prioritize dirty PRs and snapshot pre-fix residue

**Action:** Investigated why babysitter skipped PR #341 even though it was `DIRTY`. The project had a large open-PR backlog and `ProjectTick` selected only the oldest updated PRs before `PrFixer` could inspect merge state, so newer conflicted PRs could starve behind neutral rows. Updated the selection contract to request `mergeStateStatus` from `gh pr list` and sort actionable states ahead of age before applying `babysitter.max_concurrent_prs`.

**Action:** Changed 6-review pre-fix dirty-worktree cleanup to auto-commit all existing residue with `Hive-Auto-Commit-Reason: pre_fix_dirty_worktree`. Normal clean-exit and finalize backstop scope checks remain strict; the permissive path only snapshots pre-existing residue before the fix agent starts so `fix_dirty_worktree` does not block routine recovery.

**Refreshed pages:**
- [[modules/babysitter]]
- [[stages/review]]

## [2026-06-07T14:35:00Z] wiki — audit babysitter dirty-priority refresh coverage

**Action:** Refreshed wiki planning/documentation coverage after the dirty-priority branch already touched [[modules/babysitter]], [[stages/review]], and [[log]]. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dirty priority pre fix dirty worktree review residue"` returned no indexed hits, and the configured master wiki path had no matching context. Inspected the committed diff and current `lib/hive/babysitter/project_tick.rb`, `lib/hive/gh.rb`, `lib/hive/stages/clean_exit.rb`, `lib/hive/stages/review.rb`, plus focused babysitter/GitHub/review tests. Updated [[decisions]] because ADR-034 still described the old pre-fix dirty guard, corrected the stale Phase 4 text in [[stages/review]], and recorded the missing live-smoke evidence for dirty-priority selection and out-of-scope pre-fix snapshots in [[gaps]]. Page count stayed 74, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[decisions]]
- [[stages/review]]
- [[gaps]]

## [2026-06-07T15:05:00Z] wiki — audit archive filter marker-agnostic coverage

**Action:** Refreshed command/API wiki coverage after the archive-filter cleanup removed the unused `marker_name` parameter from `Hive::ArchiveFilter.hide?` and both Status/TUI callers. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "ArchiveFilter hide archive status TUI folder_mtime"` found the existing status/archive coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/archive_filter.rb`, `lib/hive/commands/status.rb`, `lib/hive/tui/snapshot.rb`, `test/unit/archive_filter_test.rb`, and relevant status/TUI/testing wiki pages. Corrected stale text that described archive hiding as clean-marker-only, documented the marker-agnostic and no-timestamp fail-open contract, and carried the same uncertainty forward: no in-tree live registered-project artifact proves the full archive workflow after aged done folders exist. Page count stayed 74, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[testing]]
- [[gaps]]
