---
title: Architectural Decisions
type: decisions
source: code + author's local planning notes (not committed)
created: 2026-04-25
updated: 2026-05-22
tags: [decisions, adr]
---

**TLDR**: ADRs below were authored alongside implementation work. ADR-024 records both the PR-first workflow/stage renumbering and daemon autonomy; ADR-026 covers the Telegram bot mobile surface; ADR-027 records the diagnose-then-act surface for red status rows; ADR-029 records the 7-artifacts stage insertion.

## ADR-027: Release artifacts are Tebako-packed binaries

**Status:** Active
**Context:** The v0.1.0 install plan requires tier-1 channel installers to consume a self-contained `hive` artifact rather than asking end users to install Ruby and run from a clone. The high-risk gems are the TUI bindings (`bubbletea` 0.1.4 and `lipgloss` 0.2.x), because they use native components and `Hive::Tui::PasteAwareRunner` depends on private Bubble Tea runner state.
**Decision:** Release artifacts are built by `packaging/build/release.sh`, called via `rake build:release[<target>]`, and the GitHub tag workflow installs Tebako before producing `hive-<version>-<target>.tar.gz` for `darwin-arm64`, `linux-x86_64-gnu`, and `linux-aarch64-gnu`. Local Tebako packageability validation is deferred to the release workflow; no local CI-equivalent Tebako run exists for this worktree yet. The `v0.1.0-rc.0` release workflow run is required before cutting the real `v0.1.0` release.
**Consequences:** Install channels share one artifact shape and one checksum file. A failed Tebako build fails the release before any channel metadata is published. If Tebako cannot support the pinned native gems in CI, the replacement point is `packaging/build/release.sh`; installers and update/uninstall behavior remain unchanged because they only depend on the tarball contract.

**Known gap — release-tag trust:** `gh release create --verify-tag` only checks the tag *format*, not its cryptographic provenance. We sign `SHA256SUMS` keyless via cosign + Fulcio, which protects the artifacts users download, but the underlying git tag itself is not signed. An attacker who pushes a malicious tag to the release branch could trigger the workflow and have it mint a signed artifact under their tag. Mitigation today is GitHub branch protection on the release branch and a maintainer-only allowlist for tag pushes; a future hardening pass should add `git tag --verify` against a published maintainer key before the build step runs.

## ADR-024: PR-first workflow, finalize rename, and daemon autonomy

**Status:** Active
**Context:** Opening the GitHub PR only after autonomous review made human intervention awkward: a person had to find the task under `.hive-state/stages/6-review/` and edit local files instead of using `gh pr checkout`. At the same time, the daemon needed a deterministic install surface — manual launchd/systemd cp+edit recipes drift across platforms and become stale doc the moment `hive init` learns to install a unit on its own.
**Decision:** Insert `5-open-pr` between execute and review. It pushes the branch and opens a draft PR. Rename the old PR stage to `7-finalize`; it now verifies the reviewed branch is pushed, refreshes the PR description, writes `summary.md`, and flips the PR from draft to ready-for-review. The stage order from that decision was `1-inbox → 2-brainstorm → 3-plan → 4-execute → 5-open-pr → 6-review → 7-finalize → 8-done`; ADR-029 supersedes the tail with `7-artifacts → 8-finalize → 9-done`. In parallel, `hive init` now installs the platform daemon unit on disk by default via `Hive::Commands::Daemon::ServiceInstaller`: the unit (launchd plist on macOS, systemd-user service on Linux) is written unconditionally, while `launchctl load` / `systemctl --user enable --now` are only invoked when the user opts in at the `daemon_autostart` prompt. Drifted/customised units are detected by content hash and left untouched.
**Consequences:** Review runs against an already-open draft PR. Reviewer files remain authoritative locally, but the review orchestrator mirrors each reviewer/escalation file to the PR as a comment for human visibility. Existing in-flight tasks on old stage names require explicit `hive migrate`; hive does not silently rename task folders. For daemon registration: users who previously hand-installed a service unit see the "already exists; leaving user-customized file untouched" warning instead of a silent overwrite. Homebrew-installed macOS units point at the stable `${HOMEBREW_PREFIX}/bin/hive` symlink rather than a versioned Cellar realpath, so `brew upgrade hive` keeps the daemon binary path current; customized drifted plists still require explicit removal and `hive init` re-registration.

## ADR-001: Folder-as-task, not single markdown file

**Status:** Active
**Context:** Task artefacts accumulate over time — `idea.md`, `brainstorm.md`, `plan.md`, multiple `reviews/ce-review-NN.md`, `task.md`, `pr.md`, `worktree.yml`, logs. A single Markdown file would balloon and obscure structure.
**Decision:** Each task is a folder. Stage = which directory the folder is in. `mv` between directories is approval.
**Consequences:** Easy human inspection (file system tools work), atomic stage transitions via rename, cleanup is `rm -rf`, but no single "ticket file" view.

## ADR-002: Per-project `.hive-state/` over centralised hive

**Status:** Active
**Context:** A single `~/Dev/hive/state/` would route work by project name → path lookup. Per-project state lets each project's own `CLAUDE.md` / `.claude/` / hooks apply automatically (claude picks them up from `cwd`).
**Decision:** Each project owns `<project>/.hive-state/` plus a registration entry in `~/Dev/hive/config.yml`. `~/Dev/hive/` is a thin control plane (CLI + global config + shared logs only).
**Consequences:** Routing is free (project name = path). Per-project tooling works without magic. Failure in one project doesn't infect others. Cost: duplicate config knobs per project (acceptable; defaults cover most cases).

## ADR-003: Orphan branch `hive/state` checked out as a separate worktree

**Status:** Active (revised from origin)
**Context:** Original brainstorm proposed committing `.hive/` directly to `main`. Plan-stage feasibility review revealed two problems: (1) `git pull` in feature worktrees would lose `skip-worktree` flags; (2) master's `git log` would be polluted with hive commits.
**Decision:** Create an orphan branch `hive/state` at `hive init`. Check it out as a worktree at `<project>/.hive-state/`. Master ignores `.hive-state/` via `.gitignore`. Feature worktrees branch from master and never see hive artefacts.
**Consequences:** `git log master` stays code-only. No `[skip ci]` needed because CI binds to master/main, not `hive/state`. Risk: orphan branch is unreachable from default refs; plan recommends `git config --add gc.reflogExpire never refs/heads/hive/state` and periodic backup. Branch is not pushed by default (no upstream refspec).

## ADR-004: Stage = directory location; `mv` = approval

**Status:** Active
**Context:** Status could be tracked in frontmatter, a state file, a database, or via location. Folder location is observable by any tool, atomic via `rename(2)`, and self-documenting.
**Decision:** Stage is determined solely by which `stages/<N>-<name>/` subdirectory the task folder is in. `mv` between stage directories is the only approval primitive — no separate "approve" command.
**Consequences:** Linux-way ergonomics; user can use any file manager / `mv` on the command line. State machine is unforgeable (can't desync from disk). Cost: re-running a stage means the runner must inspect the existing state file and decide whether to refine vs initial-pass.

## ADR-005: HTML-comment markers in the stage's state file

**Status:** Active
**Context:** Need a way for the agent to signal "I want human input" / "I'm done" / "I errored" that survives editor saves and is parseable.
**Decision:** Each stage has exactly one state file (idea/brainstorm/plan/task/pr.md). Markers are HTML comments at the bottom (`<!-- WAITING -->`, `<!-- COMPLETE -->`, `<!-- AGENT_WORKING pid=… -->`, `<!-- ERROR reason=… -->`, plus `EXECUTE_*` variants for `4-execute`). The *last* marker is current.
**Consequences:** Markers are invisible in rendered Markdown but greppable. Attribute syntax allows structured payloads. `Markers.set` writes atomically via tempfile + `File.rename` under a `.markers-lock` sidecar so multi-process writes and torn-write recovery are both safe. The orchestrator owns the terminal marker after every stage; the reviewer template explicitly does not write `task.md`.

## ADR-006: `claude -p` subprocess instead of Claude Agent SDK

**Status:** Active
**Context:** Could embed Claude via the Agent SDK (programmatic loading of skills/agents/settings) or shell out to the CLI.
**Decision:** Shell out to `claude -p` per stage. The CLI auto-discovers `CLAUDE.md`, `.claude/skills/`, `.claude/agents/`, `.claude/settings.json` from `cwd` — exactly the integration we want, with zero extra wiring.
**Consequences:** No need to maintain SDK glue. Each stage prompt is rendered from an ERB template. Cost: heavy reliance on a specific CLI version (pinned to ≥ 2.1.118; verified at runtime by `Agent.check_version!`).

## ADR-007: Two-level lock model (per-task + per-project)

**Status:** Active
**Context:** Original design used one `.hive/.lock` per project, but execute pass takes ~45 minutes — that would block all other tasks. Need finer locking.
**Decision:**
- **Per-task lock** `<task folder>/.lock` — held for the entire `hive run`, allowing parallel runs on *different* tasks.
- **Per-project commit lock** `<.hive-state>/.commit-lock` — short-lived flock around `git add && git commit` in the hive-state worktree.
- PID-reuse defence: the lock payload includes `process_start_time` from `/proc/<pid>/stat` field 22; stale-check compares.
**Consequences:** Multiple long-running stage agents on the same project can run concurrently; only the brief commit window is serialised.

## ADR-008: `--dangerously-skip-permissions` everywhere, secured by other means

**Status:** Active (single-developer trust model)
**Context:** `claude -p` permission flags (`--allowed-tools "Bash(bin/* …)"`) showed unverified parse behaviour for multi-glob patterns in v2.1.118; even if they worked, `.env` is already on disk and reachable via `Read`. Permission scoping doesn't actually close the leak path.
**Decision:** Use `--dangerously-skip-permissions` on every active stage. Substitute three other boundaries:
1. **Prompt-injection wrapping with a per-run random nonce** — every user-supplied content blob is wrapped in `<user_supplied_<hex16>>…</user_supplied_<hex16>>`. The nonce is generated once per process by `Stages::Base.user_supplied_tag`, so attacker-supplied closing tags inside content (`</user_supplied>`) cannot terminate the wrapper.
2. **Physical isolation** — every stage's `add-dir` is narrowed to `task.folder` only. Brainstorm and plan stages deliberately do NOT add the project root, so prompt-injected idea/brainstorm content cannot reach project source. Only the execute stage's worktree spawn gives the agent code-edit access, and that's confined to a feature branch in a sibling directory.
3. **Post-run integrity checks** — SHA-256 pre/post on `plan.md` and `worktree.yml` around **both** the implementation and reviewer passes; either-agent tampering yields `<!-- ERROR reason=implementer_tampered|reviewer_tampered -->`. The PR stage runs an additional regex secret-scan on the published body and refuses to commit on api-key/AWS/GH-token hits. Inode-based concurrent-edit detection was tried and dropped because claude's atomic `Edit`/`Write` rotates inodes on every legitimate write.
**Consequences:** Acceptable for a single local user; explicitly NOT acceptable for multi-user or CI deploys. Re-design required for Phase 2+.

## ADR-009: Hive state never modifies master

**Status:** Active
**Context:** Hive commits on every `hive run` shouldn't pollute master's history or trigger CI.
**Decision:** All task-state commits go to `hive/state` (the orphan branch). `hive init` may make project-setup commits on master/default branch: `chore: ignore .hive-state worktree` and `chore: initialize llm-wiki`. Runtime task movement, agent outputs, reviews, and markers stay on `hive/state`, so normal `hive run` activity never triggers master/main CI workflows.
**Consequences:** Feature worktrees branch from master and inherit tracked project context such as `AGENTS.md`, `CLAUDE.md`, `.llm-wiki/`, and `wiki/`, while mutable Hive task state remains isolated on `hive/state`. User can `git pull` master without task-state conflicts.

## ADR-010: One commit per `hive run`, skipped if diff is empty

**Status:** Active
**Context:** Per-event commits would multiply quickly (round-N brainstorm, every review pass).
**Decision:** Each `hive run` produces at most one commit on `hive/state`, with message `hive: <stage>/<slug> <action>` (e.g., `hive: 4-execute/add-cache review_pass_02_waiting`). `Hive::GitOps#hive_commit` checks `git diff --cached --quiet` and skips if there's nothing to commit.
**Consequences:** Audit trail is dense but readable. Each run produces exactly one log entry per task per command.

## ADR-011: Per-stage budgets and timeouts (separate config sections)

**Status:** Active
**Context:** A single 30-minute timeout is wrong for both ends — 5 minutes is too long for a Q&A round, 30 is too short for a Rails refactor.
**Decision:** Two parallel YAML sections in `config.yml`: `budget_usd` and `timeout_sec`, each keyed by stage. Defaults: brainstorm 10 / plan 20 / execute_implementation 100 / execute_review 50 / pr 10 USD; 5 / 10 / 45 / 10 / 5 minutes respectively.
**Consequences:** Stage runners always pass explicit budget+timeout to `Hive::Agent#new` (no global default). Sanity-cap from runaway agents, not cost control (Ivan uses Claude max plan).

## ADR-012: Slug allowlist regex + reserved tokens + array-form subprocess

**Status:** Active
**Context:** Slugs become git branch names, directory names, and CLI args. Path traversal or git-reserved tokens would corrupt state.
**Decision:** Strict regex `^[a-z][a-z0-9-]{0,62}[a-z0-9]$`. Reject `head`, `fetch_head`, `orig_head`, `merge_head`, `master`, `main`, `origin`, `hive`. Reject `..`, `/`, `@`. All git/gh subprocess calls use `Open3.capture3` array-form so slug isn't shell-interpolated even if validation slips.
**Consequences:** No shell-injection surface. Cyrillic/non-ASCII inputs fall back to `task-<YYMMDD>-<hex>` because NFD + ASCII-strip leaves them empty. Real transliteration deferred (would need a stringex-style gem).

## ADR-013: Reviewer agent must not edit code; protected files SHA-256 checked

**Status:** Active
**Context:** Reviewer is invoked with the same `--dangerously-skip-permissions` as the implementation agent. Convention says "don't write code"; convention alone is not enforcement.
**Decision:** Before reviewer spawn, hash `plan.md` and `worktree.yml` (the two files the reviewer must absolutely not touch). After spawn, re-hash; mismatch → `<!-- ERROR reason=reviewer_tampered files=… -->`. `task.md` is intentionally **not** in the protected set because the reviewer legitimately writes the marker there. Extended in U6/U9 to also protect during triage and fix spawns (`plan.md` + `worktree.yml` + `task.md`).

**Consequences:** Reviewer mistakes (or prompt injections) that touch the wrong files surface as errors instead of silent corruption. Cost: one extra hash pair per review pass (negligible).

## ADR-014: 6-review is its own stage; 4-execute drops to impl-only

**Status:** Active (shipped in feat/6-review-stage; U1 + U9)
**Context:** Pre-U9 the review pass was an iteration loop inside `4-execute`. As soon as we wanted multiple reviewers, a triage pass, a CI-fix loop, a fix-guardrail, and a browser-test phase, the iteration loop became the dominant mass of `Stages::Execute` and obscured what the stage was for. The user owns the "implementation done" → "review starts" transition by `mv`-ing the folder.
**Decision:** Add `6-review/` to `Hive::Stages::DIRS`. `Stages::Execute` becomes impl-only — runs `spawn_implementation`, SHA-protects `plan.md`/`worktree.yml`, sets `EXECUTE_COMPLETE`, exits. The user `mv`s the task to `6-review/`, which runs the new `Hive::Stages::Review.run!` autonomous loop (CI → reviewers → triage → fix → guardrail → browser → REVIEW_COMPLETE). One `hive run` lands a terminal marker or exhausts budgets; no partial-run states.
**Consequences:** Stage runners stay shape-uniform — each stage is one phase. The `mv` is the explicit gate between "agent wrote code" and "agents review code" — important because the review loop has different cost / safety properties (multiple agents, fix-guardrail, etc.). Cost: a dedicated stage means more files to maintain (review.rb is 450+ lines), but the alternative (re-cramming everything into 4-execute) was already untenable.

## ADR-015: Sequential reviewers; parallel deferred

**Status:** Active
**Context:** Phase 2 of the 6-review loop runs every configured reviewer adapter. The plan considered running them in parallel (each in its own thread / subprocess) versus sequentially.
**Decision:** Sequential by default. The reviewers we ship (claude `/ce-code-review`, codex `/ce-code-review`, `pr-review-toolkit`) overlap heavily on findings — running them in parallel mostly produces near-duplicate `[x]` marks for triage to dedupe, at the cost of more concurrent agent processes (subprocess management, OOM risk, harder logs).
**Consequences:** Phase 2 wall-clock is the sum of per-reviewer durations. With three reviewers averaging ~3 minutes each, that's ~9 minutes per pass — fits well inside `review.max_wall_clock_sec` (default 5400). Parallel execution can be added behind a config flag if the wall-clock cost becomes painful.

## ADR-016: Triage bias presets — `courageous` default, `safetyist` opt-in

**Status:** Active
**Context:** The triage agent decides which findings to auto-fix and which to escalate. The bias is the single biggest knob on whether the autonomous loop is worth running. Three labels were considered: `aggressive`, `liberal_auto_fix`, `conservative`.
**Decision:** Two presets ship: `courageous` (default — apply max review fixes in automatic mode; escalate only sketchy / architecture-level findings) and `safetyist` (opt-in — escalate when in doubt). `review.triage.custom_prompt` overrides both with a path under `templates/`. The `aggressive` preset was dropped — the gap from `courageous` is small enough that the third label was net confusion.

`hive metrics rollback-rate` (U14) gives the user data to revisit the choice — a high rate signals `courageous` is too courageous for the project; a low rate validates the trade.

**Consequences:** Default lands fixes most users want without prompting; safety-conscious users opt into `safetyist`. The `Hive-Triage-Bias` commit trailer threads the choice into `git log` so the metric can break down by preset.

## ADR-017: Agent CLI profile abstraction (`Hive::Agent` parameterized over `AgentProfile`)

**Status:** Active
**Context:** Pre-U12 `Hive::Agent` hardcoded `claude -p` invocation. The 6-review reviewer set wanted to spawn codex and pi alongside claude with the same lifecycle (per-spawn nonce, status detection, budget capture). Per-CLI behavior differs: codex emits status to stdout, pi exits non-zero on internal-server errors but cleanly on success, claude's `--dangerously-skip-permissions` flag has no codex equivalent.
**Decision:** Introduce `AgentProfile` (a frozen value object with `name`, `binary`, `args_format`, `add_dir_flag`, `skill_syntax_format`, `status_detection_mode`, `version_check`, `preflight!`) and a registry (`Hive::AgentProfiles`). `Hive::Agent.run!` takes a `profile:` kwarg per spawn (defaults to the configured `agent_profile` or `claude`). Three profiles ship in v1: `claude`, `codex`, `pi`. `opencode` was scoped out — see [[active-areas]].
**Consequences:** Per-spawn `<user_supplied>` nonce (ADR-019) is profile-independent. CE skills are invoked via `profile.skill_syntax_format` (e.g., `/ce-code-review` for claude/codex, `/run-skill ce-code-review` for pi).

## ADR-018: Amended trust model when isolation flag varies per CLI; supersedes part of ADR-008

**Status:** Active (supersedes part of ADR-008)
**Context:** ADR-008 baselined `--dangerously-skip-permissions` as the sole permission gate, secured by the `<user_supplied>` nonce wrapper. Codex has no equivalent flag (its sandbox has different semantics); pi runs with explicit per-tool grants. Treating "no isolation flag" as silently identical to claude's flag would be a security regression.
**Decision:** Each `AgentProfile` declares `add_dir_flag` (the `--add-dir` equivalent for filesystem isolation). When a profile's `add_dir_flag` is `nil`, the runner emits a one-line warning to `<task>/logs/isolation-warnings.log` ("ADR-008 filesystem-isolation boundary is reduced for this spawn") and proceeds. The CE skill prompt's `Constraints` section is the user-facing safety boundary in this case.
**Consequences:** A reviewer spawning codex without `--add-dir` is observable in logs. The `<user_supplied>` nonce still bounds prompt-injection-as-command. The trust model is "claude has filesystem isolation + nonce; codex has nonce + prompt-level constraint."

## ADR-019: Per-spawn `<user_supplied>` nonce; supersedes per-process memoization in ADR-008

**Status:** Active (supersedes ADR-008's per-process nonce)
**Context:** ADR-008 set the `<user_supplied>` wrapper nonce once per Ruby process. The 6-review pass spawns multiple agents (CI-fix, several reviewers, triage, fix, browser) in a single run; if every spawn shares the nonce, a hostile reviewer output saved verbatim into `accepted_findings` could escape its wrapper in the *next* spawn. The nonce must be fresh per spawn.
**Decision:** `Hive::Stages::Base.user_supplied_tag` returns a fresh `<user_supplied_<hex>>` value on every call. `Stages::Base.spawn_agent` calls it once per spawn and threads the value into the rendered template. The runner never memoizes the tag at the stage level.
**Consequences:** Nonce collision risk is now per-spawn (negligible). One `Stages::Review.run!` invocation that runs 4 passes with 3 reviewers, 1 triage, 1 fix, 1 guardrail-pass, 1 browser-test produces ~24 distinct nonces — all isolated.

## ADR-020: Post-fix diff guardrail (extends ADR-008's secret-scan to fix-time diffs)

**Status:** Active (shipped U13)
**Context:** The fix agent has commit access to the worktree under `--dangerously-skip-permissions` (or codex's equivalent). A maliciously-crafted reviewer finding could in principle steer it into committing a `curl ... | sh`, editing `.github/workflows/`, or pasting a credential — and the user would only see a green review pass with one extra commit.
**Decision:** After every Phase 4 fix spawn, before looping to Phase 2, `Hive::Stages::Review::FixGuardrail` takes `git diff base..head` of the new commits and walks it once. Default pattern set: `shell_pipe_to_interpreter`, `ci_workflow_edit`, `secrets_pattern_match` (dispatches to `Hive::SecretPatterns`), `dotenv_edit`, `dependency_lockfile_change`, `permission_change`. Hit → `REVIEW_WAITING reason=fix_guardrail` + `reviews/fix-guardrail-NN.md` so the user inspects before the loop continues.
**Consequences:** The fix agent's blast radius is bounded by an explicit, project-overridable list. `Hive::SecretPatterns` is shared with the PR-stage body scan (extends, doesn't duplicate, the ADR-008 idea). Per-project override (`review.fix.guardrail.patterns_override`) lets users disable a default (e.g., a project that legitimately commits lockfiles in fix passes) or add custom patterns (e.g., `no_pdb` for Python projects).

## ADR-021: Per-spawn `status_mode` override; orchestrator-owned terminal markers

**Status:** Active
**Context:** The 6-review orchestrator owns the terminal `REVIEW_*` marker. Sub-agents spawned during a phase (reviewer / triage / fix / browser) must NOT write to `task.state_file`, or they'd race the orchestrator's marker. Pre-U4 every `spawn_agent` call wrote the agent's state to `task.state_file` unconditionally.
**Decision:** `Stages::Base.spawn_agent` takes a `status_mode:` kwarg per spawn. Three values: `:state_file_marker` (legacy default — agent writes its own state to `task.state_file`), `:exit_code_only` (for sub-spawns inside an orchestrator — runner judges success purely by exit code; agent's task.md writes are no-ops via mode-gating), `:output_file_exists` (for cases where a side-effect file is the truth). 6-review uses `:exit_code_only` for every sub-spawn; `:state_file_marker` is reserved for stages where the agent IS the orchestrator (today: 2-brainstorm, 3-plan, 4-execute, 8-finalize).
**Consequences:** No marker collision between orchestrator and sub-spawns. The runner's mark/finalize logic stays simple — every sub-spawn returns `{status:, error_message:}` from `Hive::Agent.run!`, and the orchestrator decides what to write to disk.

## ADR-022: Agentic E2E test layer with structured failure artifacts

**Status:** Active
**Context:** The unit and integration suites load Ruby objects in-process. They catch command semantics, but not packaging/shebang/Thor wiring failures, real `bin/hive` subprocess behaviour, tmux-rendered TUI output, or cross-command choreography as an agent sees it. TUI rendering has no headless Bubble Tea tester in the Ruby binding, so terminal-level coverage needs a real pty surface.
**Decision:** Add `test/e2e/` as an opt-in outer layer. Scenarios are YAML with a small locked vocabulary plus `ruby_block` for irreducible setup. The harness copies `test/e2e/sample-project/` per scenario, sets run-local `HIVE_HOME`, drives real `bin/hive`, validates JSON against published schemas via `json_schemer`, and drives `hive tui` through tmux private sockets. Each run writes `report.json` (`schema_version: 1`) and failure bundles with pane snapshots, state/log copies, repro scripts, manifests, and environment snapshots.
**Consequences:** The new layer catches bug classes the in-process suite cannot, especially binary packaging, schema drift, subprocess environment leakage, and TUI render/input regressions. Cost: a second test convention and test-time dependencies (`tmux`, optional `asciinema`). Mitigation: `rake test` remains unchanged; e2e is opt-in via `bin/hive-e2e`/`rake e2e`, and `wiki/e2e.md` documents the artifact contract.

## ADR-023: TTY-prompted `hive init`; stage-level agent keys; generous limits

**Status:** Active (shipped with plan `docs/plans/2026-05-04-001-feat-hive-init-interactive-prompts-plan.md`)
**Context:** Pre-2026-05-04 `hive init` was fully non-interactive — it scaffolded `.hive-state/config.yml` from a static template with claude hardcoded everywhere and conservative budgets (~$305 per-task aggregate cap). Operators only discovered the agent-selection knob after hitting a cap or wanting a different model, and brainstorm/plan/execute spawn sites still hardcoded the `:claude` profile (the per-role pattern from ADR-017 hadn't extended upstream of 6-review).
**Decision:** Three changes behind one plan:
  1. **Stage-level agent keys.** Add `brainstorm.agent`, `plan.agent`, `execute.agent` to `Config::DEFAULTS` (default `"claude"`) and `ROLE_AGENT_PATHS` (validated by `validate_role_agent_names!`). Stage runners read `cfg.dig("<stage>", "agent")` via the new `Hive::Stages::Base.stage_profile` helper. Brainstorm / plan / execute spawn sites pin `status_mode: :state_file_marker` so swapping in codex (whose profile defaults to `:output_file_exists`) doesn't break the marker-based lifecycle these stages own.
  2. **TTY-prompted onboarding at `hive init`.** New `Hive::Commands::Init::Prompts` class asks for planning agent (combined brainstorm+plan), development agent, reviewer multi-select, and 8 per-stage limit pairs. Recommended defaults live at the **template** layer: claude / codex / all-3-reviewers / generous limits. They intentionally do NOT live in `Config::DEFAULTS["execute"]["agent"]` to avoid silently flipping the implementer for legacy projects. Non-TTY streams short-circuit to defaults and emit a one-line summary on stdout (machine-parseable for scripted callers), with prompt UI routed to stderr to keep `$(hive init)` capture clean. Aborting the prompt (`n` at confirmation) exits 64 (`Hive::ExitCodes::USAGE`) with zero disk side effects — placement immediately before `ops.hive_state_init` is load-bearing.
  3. **Bumped-generous limit defaults.** `budget_usd` / `timeout_sec` bumped ~5×: per-task aggregate cap rises from ~$305 to ~$1475. Caps are sanity caps for runaway agents, not cost targets. The deprecated `execute_review` key (orphaned by ADR-014 — 6-review owns reviewer budgets) is dropped from `DEFAULTS` and the rendered template; existing project configs that still set it survive deep-merge.
**Consequences:** First-time `hive init` is self-documenting — every knob is visible at the prompt. Scripted automation gets a stable contract: agent and reviewer prompts accept **names** in addition to indices, and the iteration orders of `Hive::AgentProfiles.registered_names` and `Prompts::DEFAULT_REVIEWER_NAMES` are documented stability contracts. Trade-off: codex's `:output_file_exists` status mode would treat brainstorm/plan/execute spawns (which write a state-file marker, not an output file) as `:error`, so those three stage runners explicitly pin `status_mode: :state_file_marker` regardless of which profile is selected — this preserves the marker-based lifecycle independent of the operator's agent choice. Test surface added: 29 unit tests for the prompt module plus 7 new integration tests for the rendered template and the piped-input / abort / re-run guard flows. Deferred: a future `hive config edit` subcommand for tightening / loosening settings on already-initialized projects.

## ADR-024: Hive daemon — automation-first; the only gate is "user input required"; supersedes ADR-004 for daemon-enabled projects

**Status:** Active (shipped with plan `docs/plans/2026-05-06-001-feat-hive-daemon-dispatcher-plan.md`)

**Context:** ADR-004 established `mv` between stage directories as the single human approval gesture. That was the right gate during the prototype phase: every transition was an explicit human "yes, the previous stage's output looks good, advance." Once the system was used in anger and trusted, the gate became wasteful — the user typed `mv` (or `hive plan` / `hive develop` / etc.) on every transition for every task across 40 projects, mostly because nothing went wrong, defeating the original `hive-pipeline-requirements.md` success criterion (`Ivan закидывает идею в 1-inbox/ и к утру следующего дня видит ... brainstorm + plan + execute с findings`).

Meanwhile the system grew its own load-bearing safety net: `hive approve` (`wiki/commands/approve.md`) enforces a closed terminal-marker set (`Hive::Commands::Approve::VALID_TERMINAL_MARKERS = %i[complete execute_complete review_complete]`). Forward-advance on any non-terminal marker raises `Hive::WrongStage` (exit 4). The promote-or-run workflow verbs (`wiki/commands/stage_action.md`) inherit this check. Every safety property the prototype-era `mv` gesture protected (don't advance past WAITING, don't skip review, don't merge a STALE task forward) is now codified in a closed enum + a unit-tested marker check.

**Decision:** For daemon-enabled projects, the daemon does maximum work autonomously. Stage transitions, in-stage re-runs, and the post-merge archive are all daemon-driven. The ONLY gates that stop the daemon are points where the system literally cannot proceed without human input:

  1. **Q&A waits** (`:waiting`, `:execute_waiting`) — agent asked questions, user answers in the file.
  2. **Triage waits** (`:review_waiting`, including `reason=fix_guardrail`) — user ticks `[x]` on accepted findings or removes rogue commits.
  3. **Recovery waits** (`:execute_stale`, `:review_stale`, `:review_ci_stale`, `:review_error`, `:error`) — these markers EXIST to demand human intervention; skipping them is correct.
  4. **External-state waits** — 8-finalize/`:complete` whose PR is open on GitHub. Daemon polls `gh pr view --json state` and auto-archives on `MERGED`. The merge itself remains a human gesture (the green button on GitHub); the daemon detects the merge and removes the bookkeeping burden.

`3-plan`/`:waiting` is not a Q&A wait. It is the plan-approval pause
used by the manual TUI/editor flow. For daemon-enabled projects,
`daemon.enabled: true` is already the durable approval gesture, so the
daemon auto-dispatches the row's `hive develop ... --from 3-plan`
command instead of waiting for an editor open/close or mtime change.

The human approval gesture for the daemon is **enabling it at `hive init`** (TTY prompt, default `Y`, per ADR-023 onboarding pattern). Per-project `daemon.enabled: true` is the explicit, durable consent. Legacy projects already on disk (configs without the `daemon:` key) fall back to `Config::DEFAULTS`'s per-project default of `false` — same "don't silently flip legacy" pattern ADR-023 used for stage agents.

**Relationship to ADR-004:**
  - ADR-004 stays valid for the manual-CLI surface (operators who never enable the daemon, or who run `hive run` / workflow verbs directly). The marker check still governs every advance.
  - For daemon-enabled projects, ADR-024 supersedes ADR-004's "per-task `mv` is approval" framing. Approval is given once per project at enrollment time. The closed `VALID_TERMINAL_MARKERS` set still does the per-task safety check — just enforced inside `hive approve` (called by the workflow verbs the daemon dispatches), not by a human typing `mv`.

**Consequences:**
  - Origin's "next morning" success criterion becomes achievable end-to-end: idea → brainstorm answers (human) → plan → execute → review → PR opened → PR merged on GitHub (human) → auto-archived. Human touchpoints reduce to: `hive new`, brainstorm Q&A, optional review-escalation triage, GitHub merge button.
  - Trust boundary unchanged from ADR-008/018: daemon spawns the same `hive run` / workflow verbs the user already runs. No new permission grants.
  - ADR-020 (fix-guardrail) and ADR-021 (orchestrator-owned markers) invariants preserved automatically — both manifest as `kind: edit` or `agent_running` rows the daemon never advances past.
  - Cost ceiling under daemon load: `max_concurrent_runs × per-task-budget-cap` (ADR-023) ≈ ~$4425 worst-case in-flight at default `max_concurrent_runs=3`. First per-project rollout requires `--dry-run` validation.
  - For operators who want the prototype-era manual-`mv` model, the answer is `daemon.enabled: false` (or no daemon running). The CLI surface is unchanged; the daemon is purely additive.

## ADR-025: JSON envelope additions are required, not optional; closed-enum reasons

**Status:** Active (shipped with PR #69 — feat: hive auto-rebase stale-worktree)

**Context:** PR #69 added the `rebase` block to `hive-run.v1`'s `SuccessPayload`. The reviewer raised an API-contract question: should new fields land as `required` (forcing every producer to emit them) or as optional/additive (so legacy producers stay valid)? A related question: should `rebase.reason` be a free-form `string` or a closed enum?

Hive's JSON envelopes are consumed by:
1. The daemon (`Hive::Daemon::StatusConsumer`) — same Ruby process as the producer; version always matches.
2. Agent tooling (subagent scripts, CE skills, `gh pr view --json` callers) — typically running against the same `hive` binary that wrote the envelope.
3. The e2e harness, which validates every emitted envelope against `schemas/hive-run.v1.json` via `json_schemer`.

There is no third-party consumer that pins to a different `hive` version. The producer and the schema move together by construction: a `schema_version: 1` envelope from version `X` is read by tooling on the same version `X`.

**Decision:**
1. **New fields are added as `required` from the moment they ship.** No "opt-in" phase. The schema lists every field every producer must emit; missing-field bugs are caught at e2e validation time, not deferred to runtime parsing in consumers.
2. **`additionalProperties: false` on every object.** Typos in field names fail schema validation immediately rather than being silently ignored by consumers.
3. **Enums are closed.** `rebase.reason`, `marker`, `next_action.kind`, `error_kind`, etc. all enumerate every allowed value. Adding a new value is a deliberate code change (new enum entry + new producer code + new docstring) — not an accidental drift where the producer emits `"foo_failed"` while consumers never learn about it.
4. **Bumping the major version is the escape hatch.** If a future change must drop a required field or break consumer parsing, the right move is `hive-run.v2.json` with `schema_version: 2` — not loosening v1's required list.

**Why required-and-closed beats optional-and-open:**

| Property | required + closed | optional + open |
|----------|-------------------|-----------------|
| Missing field at runtime | Caught at e2e validation | Silent `nil` in consumer; bug surfaces later |
| Typo'd field name | Caught at e2e validation | Silently dropped; consumer sees `nil` |
| Producer adds a new reason | Schema diff makes it reviewable | Producer drift goes unnoticed until consumer logic breaks |
| Cost to add a new field | One schema edit + one test fixture update | Free in the short term, costly in debug time later |
| Cost to make required when "more callers exist" | Doesn't apply — required from day one | Hard: every consumer that already special-cased the absence has to be touched |

Hive's deployment model (single binary, no third-party consumers on different versions) makes the "but legacy consumers!" cost — the usual reason to start fields as optional — irrelevant. The closure-by-default rule pays dividends every time a producer evolves and a typo or missing branch would have shipped silently.

**Consequences:**
- Every `Hive::Rebase::Result.reason` symbol is mirrored 1:1 in `schemas/hive-run.v1.json#/$defs/SuccessPayload/properties/rebase/properties/reason/enum`. PR #69 enforces this — the `unexpected_io_error` symbol replaces an earlier dynamic `:"unexpected_error:#{e.class}"` precisely because the dynamic form could not be expressed in a closed enum.
- `test/schema_files_test.rb` verifies the schema file is parseable and that the SuccessPayload-side rebase enum is locked.
- Future fields: when adding a new field to `SuccessPayload`, the producer change and the schema change land in the same commit. The e2e suite catches the omission before merge.
- This ADR does **not** apply retroactively to `ErrorPayload`'s per-error-class fields (`candidates`, `id`, `path`, `holder`, `lock_path`). Those are conditional on `error_kind` and intentionally listed as optional in the schema's per-kind properties — they're documented as "present only on the matching error_kind." That conditional-presence shape is a different contract than the unconditional `rebase` block.

## ADR-026: Telegram bot mediates human-input gates; subprocess caller, no parallel approval logic

**Status:** Active (shipped with plan `feat: hive Telegram bot — fully usable mobile interface`)

**Context:** ADR-024 made the daemon the default way to advance tasks once a project is enrolled. The remaining stalls are intentional human-input gates: brainstorm questions, review triage, recovery markers, and stage approvals in non-daemon scenarios. Those gates previously required a terminal, so the daemon could park a task at `WAITING` while the operator was away from the laptop.

**Decision:** Add `hive bot` as a long-running Telegram process. It long-polls Telegram, authenticates by a global `bot.chat_id_allowlist`, watches the same `hive status --json` stream as the daemon, and turns waiting/recovery rows into mobile interactions. The bot is a subprocess caller:

1. Stage approvals dispatch workflow verbs (`hive plan` / `develop` / `review` / `pr` / `archive`) with `--from <stage> --project <project> --json`.
2. Recovery buttons dispatch `hive markers clear` and then the appropriate workflow verb when safe.
3. Review triage buttons dispatch `hive accept-finding` / `hive reject-finding`.
4. `/idea` dispatches `hive new`.
5. `/status` and `/queue` render the status rows; they do not scan task folders directly.

The one direct write is brainstorm answering. The bot writes literal answer text into `brainstorm.md` under `Hive::Lock.with_task_lock`, after re-parsing the file and confirming the target `### A<N>.` slot is still empty. First-write-wins across multiple Telegram devices is the concurrency contract.

Path B is the default: the operator reads the question and replies in Telegram; the text is written verbatim. Path A exists for long brainstorm rounds: the bot spawns Codex for a short conversational turn, Codex returns a draft, and the bot writes only the literal draft the operator confirms. Codex never receives permission to edit `brainstorm.md` directly.

**Relationship to ADR-024:** ADR-024 says approval is given once per project when the daemon is enabled. ADR-026 adds a mobile input surface for the gates the daemon deliberately cannot cross. Tapping Approve in Telegram is the same approval gesture as running the workflow verb in a terminal; safety still lives in `Hive::Commands::Approve::VALID_TERMINAL_MARKERS`, `Hive::TaskAction`, marker clear allowlists, and the existing command contracts.

**Consequences:**
- The mobile phone becomes a complete surface for the daemon's human-input gaps: answer brainstorm questions, clear/retry recoverable errors, triage findings, approve transitions, capture ideas, and read the cross-project queue.
- Telegram session compromise has the same blast radius as the operator's terminal session for bot-supported actions. MVP deliberately has no per-action PIN, read-only mode, team ACLs, or audit attribution beyond JSON logs.
- No new persistence sidecar is introduced for conversations. `brainstorm.md` is the source of truth; after a bot restart, parsing the file identifies the next unanswered question.
- The bot token is environment-only (`HIVE_TELEGRAM_BOT_TOKEN`); it is never stored in config or logged.
- Cloud relay/webhook mode is deferred. The same long-poll process can run on the laptop or on an always-on host.

## ADR-027: Red status rows use diagnose-then-act, not checkbox-gated escalation

**Status:** Active (shipped with plan `docs/plans/2026-05-16-001-feat-red-status-diagnostics-and-actions-plan.md`)

**Context:** Review/recovery rows were technically actionable but operationally opaque. A row could say `Needs recovery` or `ERROR exit_code=1`, while the real explanation lived in a review artifact, a log tail, or the marker attrs. The user had to infer whether Enter would retry, whether manual work was needed, or whether the system should already have enough context to fix itself. Checkbox-only escalations made that worse: a checked or unchecked line did not explain which question was being asked, which context was already available, or why automation stopped.

**Decision:** Red rows expose a Q&A-shaped diagnostic surface before user choice. `hive status --json` carries a required nullable `diagnostic` field on every task row; ordinary rows emit `null`, while `recover_execute`, `recover_review`, and `error` rows emit a bounded, redacted diagnostic built by `Hive::TaskAction`. `hive status --diagnose <task>` reads that same local diagnosis, and `--write` asks the configured development agent to write `diagnostics/red-status.md`. Status only trusts that artifact when `generated_by` is an allowed local/profile name and `marker_signature` matches the current marker.

The TUI applies "auto-fix first, manual only when needed." Grid Enter opens red-status detail for ambiguous review recovery rows and non-kill-class errors. The detail view answers:

1. Why is this red?
2. What can Hive do next?

Then it offers a unified two-action contract: `Enter` runs hive's automated recovery for the task and closes the screen (rows without an auto-recovery recipe surface a refusal flash naming `Open in agent` as the manual fallback and still close so the operator's binary gesture never strands them on a stale view), and `o` opens the task in the project's configured development agent (same path as grid `s`) and closes the screen as the TUI suspends. `q` / `Esc` returns to the grid. Existing deterministic paths stay direct: wall-clock review stale retries, max-passes review stale with an escalations file opens that file for browse/edit, and kill-class errors open the log tail while auto-heal runs. The previous `f` / `R` bindings (manual worktree editor + headless diagnosis refresh) were removed alongside `RedStatusDetailState#marker_signature` — refreshing a diagnosis is a `hive status --diagnose <slug> --write` shell affordance now.

**Consequences:**
- Operators see the concrete artifact/log/marker explanation before retrying.
- Agents and bots can consume the same `diagnostic` payload instead of scraping TUI text.
- The schema follows ADR-025: `diagnostic` is required and nullable rather than optional.
- A stale `diagnostics/red-status.md` cannot explain a new marker because the marker signature must match.
- The diagnosis agent is intentionally outside the workflow lock/marker lifecycle; it writes one artifact and does not claim, clear, or advance the task.

## ADR-028: Remove `review_findings` from `hive-status` enum in place after TUI triage removal

**Status:** Active (shipped with PR #122 + follow-up commit)

**Context:** PR #122 removed the TUI `:triage` sub-mode and its support code after audit showed the chain `EXECUTE_WAITING findings_count>0` → `:execute_findings` action → `REVIEW_FINDINGS` action key → `KeyMap` Enter dispatch → `Messages::OpenFindings` → triage view was unreachable: no producer in the live pipeline writes `findings_count=` on `EXECUTE_WAITING` markers. The `lib/hive.rb` comment for `TaskActionKind` says "renaming or removing a value bumps SCHEMA_VERSIONS["hive-status"]", which forced an explicit decision on whether to bump the schema or keep the dead value as vestigial back-compat.

**Decision:** Edit `schemas/hive-status.v2.json` and `schemas/hive-stage-action.v2.json` in place — drop the `review_findings` enum value. Drop `Hive::Schemas::TaskActionKind::REVIEW_FINDINGS`. Do **not** bump `SCHEMA_VERSIONS["hive-status"]` (still 2). Rationale: hive has no external consumers in production yet, so the published-schema-stability invariant has no real downstream cost; an in-place removal is cleaner than maintaining a vestigial enum. The umbrella enum comment at `lib/hive.rb` reverts to its original "renaming or removing a value bumps SCHEMA_VERSIONS" form — the rule still holds, the exception is now unnecessary.

Keep `lib/hive/findings.rb` and the `hive findings` / `accept-finding` / `reject-finding` CLI commands. They operate on `reviews/*.md` files directly and remain the agent-callable triage surface (the bot's review-triage Accept-all/Reject-all buttons still call into them).

Historical schemas (`schemas/hive-status.v1.json`, `schemas/hive-stage-action.v1.json`) are left untouched — they remain the frozen record of what the v1 producer emitted.

**Consequences:**
- `hive-status.v2.json` no longer advertises `review_findings` as a valid emittable action. Schema-validating consumers receive a sharper contract.
- Producer-side semantic remap: `EXECUTE_WAITING + findings_count>0` markers now route to `recover_execute` instead of `review_findings`. Same input → different output, but still a human recovery gate with a `hive findings` command rather than generic edit guidance. A canary producer-sweep test pins the non-emission invariant so a future revert / parallel branch re-introducing a writer is caught at unit-test time.
- `test_unknown_action_skips` in `test/unit/daemon/policy_test.rb` continues to use the string `"review_findings"` as a synthetic-unknown fixture: it now pins forward-compat (`:skip` for any unknown action) rather than back-compat.
- If hive ever gains external schema consumers pinned to v2, this decision becomes more expensive to make again. Treat the in-place edit pattern as a pre-1.0 affordance, not a permanent convention.

## ADR-029: 7-artifacts separates review completion from PR finalization

**Status:** Active

**Context:** Review completion now needs a stable artifact-collection slot before PR finalization. Without a real `artifacts` runner, the workflow metadata could advertise `hive artifacts` while Thor rejected the command, and markerless `7-artifacts` rows could be shown as ready to finalize even though `StageAction` correctly refuses to advance rows without a terminal marker.

**Decision:** Insert `7-artifacts` between `6-review` and `8-finalize`, making the current stage order `1-inbox → 2-brainstorm → 3-plan → 4-execute → 5-open-pr → 6-review → 7-artifacts → 8-finalize → 9-done`. The `hive artifacts` workflow verb is a first-class Thor command. `Hive::Stages::Artifacts` is a no-agent runner that creates `artifact.md` and stamps `COMPLETE`, so the existing terminal-marker gate remains intact before `hive finalize` can promote to `8-finalize`.

**Consequences:** Daemon, bot, TUI, status JSON, and humans see `ready_to_artifacts` after `REVIEW_COMPLETE`, then `ready_to_finalize` only after `artifact.md` carries `COMPLETE`. `hive migrate` maps both the pre-open-pr layout and the previous canonical `7-finalize` / `8-done` directories to the current names. Future artifact packaging work has a dedicated stage without overloading finalize.

## Source

Once `git log` accumulates real history, future updates should add ADRs from substantive merge commits or refactor messages.

## Backlinks

- [[architecture]]
- [[state-model]]
- [[e2e]]
- [[stages/execute]]
- [[commands/bot]] · [[modules/bot]]
- [[commands/findings]] · [[modules/task_action]]
