---
title: Architectural Decisions
type: decisions
source: code + author's local planning notes (not committed)
created: 2026-04-25
updated: 2026-04-29
tags: [decisions, adr]
---

**TLDR**: ADRs below were authored alongside implementation work. ADRs 014–021 cover the 5-review stage; ADR-022 covers the agentic e2e test layer.

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
**Decision:** All hive commits go to `hive/state` (the orphan branch). Only one hive-driven commit ever lands on master: the initial `chore: ignore .hive-state worktree` from `hive init`. Master's CI workflows trigger on `master`/`main` pushes only, so `hive/state` commits never trigger CI; no `[skip ci]` flag needed.
**Consequences:** `git log master` is clean. Feature worktrees branch from master and contain no hive artefacts. User can `git pull` master without conflicts.

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

## ADR-014: 5-review is its own stage; 4-execute drops to impl-only

**Status:** Active (shipped in feat/5-review-stage; U1 + U9)
**Context:** Pre-U9 the review pass was an iteration loop inside `4-execute`. As soon as we wanted multiple reviewers, a triage pass, a CI-fix loop, a fix-guardrail, and a browser-test phase, the iteration loop became the dominant mass of `Stages::Execute` and obscured what the stage was for. The user owns the "implementation done" → "review starts" transition by `mv`-ing the folder.
**Decision:** Add `5-review/` to `Hive::Stages::DIRS`. `Stages::Execute` becomes impl-only — runs `spawn_implementation`, SHA-protects `plan.md`/`worktree.yml`, sets `EXECUTE_COMPLETE`, exits. The user `mv`s the task to `5-review/`, which runs the new `Hive::Stages::Review.run!` autonomous loop (CI → reviewers → triage → fix → guardrail → browser → REVIEW_COMPLETE). One `hive run` lands a terminal marker or exhausts budgets; no partial-run states.
**Consequences:** Stage runners stay shape-uniform — each stage is one phase. The `mv` is the explicit gate between "agent wrote code" and "agents review code" — important because the review loop has different cost / safety properties (multiple agents, fix-guardrail, etc.). Cost: a dedicated stage means more files to maintain (review.rb is 450+ lines), but the alternative (re-cramming everything into 4-execute) was already untenable.

## ADR-015: Sequential reviewers; parallel deferred

**Status:** Active
**Context:** Phase 2 of the 5-review loop runs every configured reviewer adapter. The plan considered running them in parallel (each in its own thread / subprocess) versus sequentially.
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
**Context:** Pre-U12 `Hive::Agent` hardcoded `claude -p` invocation. The 5-review reviewer set wanted to spawn codex and pi alongside claude with the same lifecycle (per-spawn nonce, status detection, budget capture). Per-CLI behavior differs: codex emits status to stdout, pi exits non-zero on internal-server errors but cleanly on success, claude's `--dangerously-skip-permissions` flag has no codex equivalent.
**Decision:** Introduce `AgentProfile` (a frozen value object with `name`, `binary`, `args_format`, `add_dir_flag`, `skill_syntax_format`, `status_detection_mode`, `version_check`, `preflight!`) and a registry (`Hive::AgentProfiles`). `Hive::Agent.run!` takes a `profile:` kwarg per spawn (defaults to the configured `agent_profile` or `claude`). Three profiles ship in v1: `claude`, `codex`, `pi`. `opencode` was scoped out — see [[active-areas]].
**Consequences:** Per-spawn `<user_supplied>` nonce (ADR-019) is profile-independent. CE skills are invoked via `profile.skill_syntax_format` (e.g., `/ce-code-review` for claude/codex, `/run-skill ce-code-review` for pi).

## ADR-018: Amended trust model when isolation flag varies per CLI; supersedes part of ADR-008

**Status:** Active (supersedes part of ADR-008)
**Context:** ADR-008 baselined `--dangerously-skip-permissions` as the sole permission gate, secured by the `<user_supplied>` nonce wrapper. Codex has no equivalent flag (its sandbox has different semantics); pi runs with explicit per-tool grants. Treating "no isolation flag" as silently identical to claude's flag would be a security regression.
**Decision:** Each `AgentProfile` declares `add_dir_flag` (the `--add-dir` equivalent for filesystem isolation). When a profile's `add_dir_flag` is `nil`, the runner emits a one-line warning to `<task>/logs/isolation-warnings.log` ("ADR-008 filesystem-isolation boundary is reduced for this spawn") and proceeds. The CE skill prompt's `Constraints` section is the user-facing safety boundary in this case.
**Consequences:** A reviewer spawning codex without `--add-dir` is observable in logs. The `<user_supplied>` nonce still bounds prompt-injection-as-command. The trust model is "claude has filesystem isolation + nonce; codex has nonce + prompt-level constraint."

## ADR-019: Per-spawn `<user_supplied>` nonce; supersedes per-process memoization in ADR-008

**Status:** Active (supersedes ADR-008's per-process nonce)
**Context:** ADR-008 set the `<user_supplied>` wrapper nonce once per Ruby process. The 5-review pass spawns multiple agents (CI-fix, several reviewers, triage, fix, browser) in a single run; if every spawn shares the nonce, a hostile reviewer output saved verbatim into `accepted_findings` could escape its wrapper in the *next* spawn. The nonce must be fresh per spawn.
**Decision:** `Hive::Stages::Base.user_supplied_tag` returns a fresh `<user_supplied_<hex>>` value on every call. `Stages::Base.spawn_agent` calls it once per spawn and threads the value into the rendered template. The runner never memoizes the tag at the stage level.
**Consequences:** Nonce collision risk is now per-spawn (negligible). One `Stages::Review.run!` invocation that runs 4 passes with 3 reviewers, 1 triage, 1 fix, 1 guardrail-pass, 1 browser-test produces ~24 distinct nonces — all isolated.

## ADR-020: Post-fix diff guardrail (extends ADR-008's secret-scan to fix-time diffs)

**Status:** Active (shipped U13)
**Context:** The fix agent has commit access to the worktree under `--dangerously-skip-permissions` (or codex's equivalent). A maliciously-crafted reviewer finding could in principle steer it into committing a `curl ... | sh`, editing `.github/workflows/`, or pasting a credential — and the user would only see a green review pass with one extra commit.
**Decision:** After every Phase 4 fix spawn, before looping to Phase 2, `Hive::Stages::Review::FixGuardrail` takes `git diff base..head` of the new commits and walks it once. Default pattern set: `shell_pipe_to_interpreter`, `ci_workflow_edit`, `secrets_pattern_match` (dispatches to `Hive::SecretPatterns`), `dotenv_edit`, `dependency_lockfile_change`, `permission_change`. Hit → `REVIEW_WAITING reason=fix_guardrail` + `reviews/fix-guardrail-NN.md` so the user inspects before the loop continues.
**Consequences:** The fix agent's blast radius is bounded by an explicit, project-overridable list. `Hive::SecretPatterns` is shared with the PR-stage body scan (extends, doesn't duplicate, the ADR-008 idea). Per-project override (`review.fix.guardrail.patterns_override`) lets users disable a default (e.g., a project that legitimately commits lockfiles in fix passes) or add custom patterns (e.g., `no_pdb` for Python projects).

## ADR-021: Per-spawn `status_mode` override; orchestrator-owned terminal markers

**Status:** Active
**Context:** The 5-review orchestrator owns the terminal `REVIEW_*` marker. Sub-agents spawned during a phase (reviewer / triage / fix / browser) must NOT write to `task.state_file`, or they'd race the orchestrator's marker. Pre-U4 every `spawn_agent` call wrote the agent's state to `task.state_file` unconditionally.
**Decision:** `Stages::Base.spawn_agent` takes a `status_mode:` kwarg per spawn. Three values: `:state_file_marker` (legacy default — agent writes its own state to `task.state_file`), `:exit_code_only` (for sub-spawns inside an orchestrator — runner judges success purely by exit code; agent's task.md writes are no-ops via mode-gating), `:output_file_exists` (for cases where a side-effect file is the truth). 5-review uses `:exit_code_only` for every sub-spawn; `:state_file_marker` is reserved for stages where the agent IS the orchestrator (today: 2-brainstorm, 3-plan, 4-execute, 6-pr).
**Consequences:** No marker collision between orchestrator and sub-spawns. The runner's mark/finalize logic stays simple — every sub-spawn returns `{status:, error_message:}` from `Hive::Agent.run!`, and the orchestrator decides what to write to disk.

## ADR-022: Agentic E2E test layer with structured failure artifacts

**Status:** Active
**Context:** The unit and integration suites load Ruby objects in-process. They catch command semantics, but not packaging/shebang/Thor wiring failures, real `bin/hive` subprocess behaviour, tmux-rendered TUI output, or cross-command choreography as an agent sees it. TUI rendering has no headless Bubble Tea tester in the Ruby binding, so terminal-level coverage needs a real pty surface.
**Decision:** Add `test/e2e/` as an opt-in outer layer. Scenarios are YAML with a small locked vocabulary plus `ruby_block` for irreducible setup. The harness copies `test/e2e/sample-project/` per scenario, sets run-local `HIVE_HOME`, drives real `bin/hive`, validates JSON against published schemas via `json_schemer`, and drives `hive tui` through tmux private sockets. Each run writes `report.json` (`schema_version: 1`) and failure bundles with pane snapshots, state/log copies, repro scripts, manifests, and environment snapshots.
**Consequences:** The new layer catches bug classes the in-process suite cannot, especially binary packaging, schema drift, subprocess environment leakage, and TUI render/input regressions. Cost: a second test convention and test-time dependencies (`tmux`, optional `asciinema`). Mitigation: `rake test` remains unchanged; e2e is opt-in via `bin/hive-e2e`/`rake e2e`, and `wiki/e2e.md` documents the artifact contract.

## ADR-023: TTY-prompted `hive init`; stage-level agent keys; generous limits

**Status:** Active (shipped with plan `docs/plans/2026-05-04-001-feat-hive-init-interactive-prompts-plan.md`)
**Context:** Pre-2026-05-04 `hive init` was fully non-interactive — it scaffolded `.hive-state/config.yml` from a static template with claude hardcoded everywhere and conservative budgets (~$305 per-task aggregate cap). Operators only discovered the agent-selection knob after hitting a cap or wanting a different model, and brainstorm/plan/execute spawn sites still hardcoded the `:claude` profile (the per-role pattern from ADR-017 hadn't extended upstream of 5-review).
**Decision:** Three changes behind one plan:
  1. **Stage-level agent keys.** Add `brainstorm.agent`, `plan.agent`, `execute.agent` to `Config::DEFAULTS` (default `"claude"`) and `ROLE_AGENT_PATHS` (validated by `validate_role_agent_names!`). Stage runners read `cfg.dig("<stage>", "agent")` via the new `Hive::Stages::Base.stage_profile` helper. Brainstorm / plan / execute spawn sites pin `status_mode: :state_file_marker` so swapping in codex (whose profile defaults to `:output_file_exists`) doesn't break the marker-based lifecycle these stages own.
  2. **TTY-prompted onboarding at `hive init`.** New `Hive::Commands::Init::Prompts` class asks for planning agent (combined brainstorm+plan), development agent, reviewer multi-select, and 8 per-stage limit pairs. Recommended defaults live at the **template** layer: claude / codex / all-3-reviewers / generous limits. They intentionally do NOT live in `Config::DEFAULTS["execute"]["agent"]` to avoid silently flipping the implementer for legacy projects. Non-TTY streams short-circuit to defaults and emit a one-line summary on stdout (machine-parseable for scripted callers), with prompt UI routed to stderr to keep `$(hive init)` capture clean. Aborting the prompt (`n` at confirmation) exits 64 (`Hive::ExitCodes::USAGE`) with zero disk side effects — placement immediately before `ops.hive_state_init` is load-bearing.
  3. **Bumped-generous limit defaults.** `budget_usd` / `timeout_sec` bumped ~5×: per-task aggregate cap rises from ~$305 to ~$1475. Caps are sanity caps for runaway agents, not cost targets. The deprecated `execute_review` key (orphaned by ADR-014 — 5-review owns reviewer budgets) is dropped from `DEFAULTS` and the rendered template; existing project configs that still set it survive deep-merge.
**Consequences:** First-time `hive init` is self-documenting — every knob is visible at the prompt. Scripted automation gets a stable contract: agent and reviewer prompts accept **names** in addition to indices, and the iteration orders of `Hive::AgentProfiles.registered_names` and `Prompts::DEFAULT_REVIEWER_NAMES` are documented stability contracts. Trade-off: codex's `:output_file_exists` status mode would treat brainstorm/plan/execute spawns (which write a state-file marker, not an output file) as `:error`, so those three stage runners explicitly pin `status_mode: :state_file_marker` regardless of which profile is selected — this preserves the marker-based lifecycle independent of the operator's agent choice. Test surface added: 29 unit tests for the prompt module plus 7 new integration tests for the rendered template and the piped-input / abort / re-run guard flows. Deferred: a future `hive config edit` subcommand for tightening / loosening settings on already-initialized projects.

## Source

Once `git log` accumulates real history, future updates should add ADRs from substantive merge commits or refactor messages.

## Backlinks

- [[architecture]]
- [[state-model]]
- [[e2e]]
- [[stages/execute]]
