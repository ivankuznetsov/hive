# Wiki Changelog

Append-only log of all wiki operations.

## [2026-05-23T11:30:00Z] drop — pass-1 + pass-2 review-finding fixes hardened hard-delete

**Action:** Recorded the two follow-up fix passes against `hive drop` after the initial feat/U1+U3 commit. Pass-1 (24 findings) and pass-2 (48 findings) tightened idempotency, PID-reuse safety, locale-stable git stderr parsing, worktree-pointer root validation, malformed-YAML rescue in `Worktree.read_pointer`, daemon-row `folder_missing_nil` distinction, and a closed `commit_action` enum on the drop schema. The `9-done` refusal prose in [[commands/drop]] was folded into the refusals-table caption. [[cli]] is already in sync (drop row + exit-code/`--json` envelope row). Schema enum + `holder`/`lock_path` extras were aligned with `DropErrorKind` during pass-1.

**Refreshed pages:**
- [[commands/drop]] — refusal prose tightened around the table; no surface change to flags, exits, or JSON keys (those were correct from feat commit).

## [2026-05-23T09:45:00Z] readme - add daemon-first TUI getting started

**Action:** Reworked the README quickstart into a five-minute TUI getting-started path before the Telegram section. The happy path now explains that the daemon advances ready tasks automatically while the TUI is for watching the queue, capturing a rough idea, and answering waiting prompts. Manual stage keys are framed as power-user controls, not the day-one flow.

**Refreshed pages:** None - README-only user-facing onboarding change; existing [[commands/tui]] and [[commands/daemon]] remain the deep references.

## [2026-05-23T09:20:00Z] bot - default start backgrounds for manual use

**Action:** Simplified Telegram onboarding by making `hive bot start` background the bot by default. `--foreground` is now the explicit mode for systemd, launchd, and terminal debugging; legacy `--detach` remains accepted as a no-op compatibility flag because backgrounding is already the default. README now includes a short BotFather -> numeric chat id -> allowlist -> `hive bot start` path based on the OpenClaw-style quick onboarding pattern.

**Refreshed pages:** [[commands/bot]], [[modules/bot]], [[operating]], [[state-model]].

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

## [2026-05-24T00:00:00Z] testing — coverage gate hardening

**Action:** Hardened `bundle exec rake coverage` from an opt-in report into the CI gate. The harness now records per-run subprocess result directories, fails on unreadable result files, counts unloaded executable source files as uncovered, and exposes an `ok` flag plus gate diagnostics in `coverage/coverage.json`.

**Refreshed pages:**
- [[testing]] — documented the 100% line coverage gate, per-run resultset directory, and unloaded/result-error failure modes.
