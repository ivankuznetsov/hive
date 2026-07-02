---
title: hive init
type: command
source: lib/hive/commands/init.rb
created: 2026-04-25
updated: 2026-07-02
tags: [command, bootstrap, git, prompts, llm-wiki]
---

**TLDR**: `hive init [PATH]` bootstraps a project for hive and `--json` emits the resolved bootstrap contract: creates the orphan `hive/state` branch, attaches it as a worktree at `<project>/.hive-state/`, scaffolds stage folders, optionally selects a project default workflow via `--workflow NAME` or a TTY `Workflow:` prompt, or uses `--new-workflow ID` / the prompt's inline authoring entry to scaffold a project-authored descriptor and bind it as the default in the same bootstrap, asks the operator (on TTY) which agents to use for planning / development / normal review / patrol PR review, which `patrol.mode` frequency dial to write, which project-global Claude launch mode (`claude.mode`), permission mode (`claude.permission_mode`), model pin (`claude.model`), and effort tier (`claude.effort`) to use, whether ad-hoc PR reviews should enter the auto-fix loop, what budget+timeout sanity caps to set, whether this project should be enrolled for daemon dispatch, whether this project should be enrolled for the experimental PR babysitter, and whether daemon autostart should be enabled, scaffolds `config.yml` from those answers, ignores `.hive-state/` in master, initializes managed llm-wiki context with Codex as the headless wiki refresher, registers the project globally, and idempotently ensures the global per-user daemon service unit exists.

## Usage

```
hive init [PROJECT_PATH] [--force] [--json] [--workflow NAME]
hive init --new-workflow ID [PROJECT_PATH]
```

`PROJECT_PATH` defaults to `Dir.pwd`. `--force` skips the clean-tree check. `--json` emits a single `hive-init.v1` success document on stdout with project metadata and the resolved prompt answers. `--workflow NAME` selects the project default workflow and is validated against `Hive::Workflows::Registry`; unknown names fail before disk writes and list valid names.

`--new-workflow ID` is for custom, project-authored workflows that do not exist yet. It reuses [[commands/workflow]] scaffolding to create `<hive_state_path>/workflows/ID.yml` and `<hive_state_path>/workflows/ID/work.md`, writes `default_workflow: "ID"` (quoted so YAML.safe_load cannot coerce keyword-like ids), and prints both paths plus the next `hive new <project> '<idea>'` hint. The descriptor and the `config.yml` binding are committed together on `hive/state` on **both** the fresh and already-initialized paths, so the bound default survives a hive-state `reset --hard`/`clean` (a plain `hive init` without `--new-workflow` still leaves `config.yml` uncommitted). It is mutually exclusive with `--workflow`; built-in ids such as `coding` and `content` are rejected by the same reserved-id path as `hive workflow new`. On an already-initialized project, the init half is a no-op: Hive attaches the existing `.hive-state` worktree, refuses descriptor collisions before writing, then commits the descriptor and `config.yml` rebind together. A commit failure after staging resets the `.hive-state` index for those pathspecs so a half-rolled-back rebind cannot ride a later unrelated commit.

## Preconditions

1. Path must be a git repository — `git -C <path> rev-parse --git-common-dir` must succeed.
2. Path must be the **main checkout**, not a worktree. The check compares git's common-dir against `<path>/.git`. Running inside an existing worktree exits 1 with `"target appears to be inside a worktree"`.
3. Working tree must be clean unless `--force` is passed; otherwise exit 1 with `"uncommitted changes"`.
4. `hive/state` branch must not already exist for a plain init; if it does, a no-workflow re-run prints `"already initialized"` and exits 2. A re-run with an explicit workflow or TTY workflow selection instead updates the existing project's `default_workflow` in config and re-registers the project.

## Steps performed

1. **Validate** — `validate_git_repo!` then `validate_clean_tree!` (skipped under `--force`).
2. **Resolve workflow default** — explicit `--workflow NAME` wins. Without a flag, TTY init prompts with a `Workflow:` step when more than one workflow is registered, using `coding` as the fresh default and the project's current `default_workflow` as the re-init default; non-TTY init silently selects `coding`. The prompt lists raw workflow ids and an extra `author a new workflow` entry. Selecting that entry asks for a new id, re-prompts on invalid/reserved/colliding ids, then routes through the same `--new-workflow` scaffold/bind path before any disk write. The selected default is validated through [[modules/workflows]]. `--new-workflow ID` bypasses registry selection because the descriptor is created later in the same flow; the id is normalized and validated before any disk write.
3. **Already-initialized handling** — if `hive/state` exists and no workflow was explicitly selected, raise `Hive::AlreadyInitialized` (exit 2). If a workflow was selected, attach/validate the existing state worktree, update `<project>/.hive-state/config.yml`, and warn when changing the default would re-resolve in-flight field-less tasks. If `--new-workflow` was selected, attach the state worktree, scaffold the descriptor, update `default_workflow`, and commit those hive-state changes together.
4. **Collect prompt answers** — `Hive::Commands::Init::Prompts.new(input: $stdin, output: $stderr, summary_io: $stdout).collect`. Prompt UI (intro / menus / re-prompts / confirmation) goes to **stderr**; the non-TTY one-line summary goes to **stdout** so scripted callers can `summary=$(hive init)` cleanly. On TTY this opens the interactive flow described below; on non-TTY (CI, pipes, test harness) it short-circuits to recommended defaults. Two abort paths exit **64** (`Hive::ExitCodes::USAGE`, distinct from generic crashes at 1) with **zero disk side effects** — no orphan branch, no worktree, no master gitignore commit:
   - Operator answers `n` at the final confirmation prompt.
   - Input stream closes mid-flow (Ctrl-D / EOF / disconnected pipe). `Prompts#read_line` distinguishes `nil` (closed stream) from `""` (blank line for default) and raises `Aborted`. Treating EOF as a blank confirmation would silently write disk state with whatever was already collected.
5. **Validate/render config content in memory** from `templates/project_config.yml.erb`, threading the answers hash from step 4 through `ProjectConfigBinding` before any disk side effects. `ProjectConfigBinding` bare-fetches every key from `Prompts#collect` (`planning_agent`, `claude_mode`, `claude_permission_mode`, `claude_model`, `claude_effort`, `development_agent`, `enabled_reviewers`, `patrol_reviewers`, `patrol_mode`, `triage_bias`, `adhoc_auto_fix`, `budgets`, `timeouts`, `daemon_enabled`, `babysitter_enabled`, `daemon_autostart`) and every nested budget/timeout `LIMIT_KEYS` entry so prompt-refactor drift fails fast instead of leaving a partial `.hive-state` worktree. The rendered config includes `default_workflow: "NAME"` (quoted so YAML.safe_load cannot coerce keyword-like ids such as `yes`/`on`/`null` to booleans/nil) only when the selected default is non-coding; coding defaults stay field-less for byte-identical init output.
6. **Create orphan worktree** via `Hive::GitOps#hive_state_init` (`lib/hive/git_ops.rb:65`):
   - `git worktree add --no-checkout --detach <path>/.hive-state <default_branch>`
   - `git -C .hive-state checkout --orphan hive/state`
   - `git rm -rf .` plus glob cleanup of any leftover dotfiles (preserving `.git`).
   - Create `stages/{1-inbox,2-brainstorm,3-plan,4-execute,5-open-pr,6-review,7-artifacts,8-finalize,9-done}/` with `.gitkeep` markers and `logs/.gitkeep`.
   - Initial commit `hive: bootstrap` on `hive/state`.
7. **Write `<path>/.hive-state/config.yml`** using the already-rendered content from step 5. Skipped if the file already exists.
8. **Ignore `.hive-state/` on master** via `GitOps#add_hive_state_to_master_gitignore!`: appends `/.hive-state/` to `.gitignore` (idempotent), then commits `chore: ignore .hive-state worktree` on master.
9. **Bootstrap managed llm-wiki files** via `Hive::LlmWikiBootstrap.install!(post_commit_hook: false, scheduler: false)`:
   - `.llm-wiki/config.json` with `headless_agent: "codex"`, `context_agents: ["claude", "codex", "pi"]`, `created_by: "hive"`, and a detected `main_wiki_path` when one exists.
   - `.llm-wiki/refresh-wiki.sh` and `.llm-wiki/post-commit-refresh.sh`, both Codex-owned and run with `codex exec --add-dir <qmd-cache> -C <project>`. Both scripts keep qmd's normal GPU auto-detection, fall back to `.llm-wiki/qmd-cache` when the normal qmd cache is not writable, and discover QMD through `HIVE_QMD_BIN`, PATH, or Hive's managed `${XDG_DATA_HOME:-~/.local/share}/hive/qmd/bin/qmd` install path (including `install-prefix` installs). Nested Codex and QMD calls run with Git hook-local environment variables unset so `GIT_INDEX_FILE`, `GIT_DIR`, and `GIT_WORK_TREE` cannot leak into plugin marketplace or indexing checkouts.
   - `wiki/index.md`, `wiki/log.md`, `wiki/gaps.md`, `wiki/architecture.md`, `wiki/decisions.md`, `wiki/dependencies.md`, and `raw/notes/.gitkeep`.
   - Managed LLM WIKI blocks in `AGENTS.md` and `CLAUDE.md`, plus `.claude/settings.json` with a managed `SessionStart` hook that prints `wiki/index.md` and recent `wiki/log.md`.
10. **Commit llm-wiki bootstrap files** via `GitOps#commit_llm_wiki_bootstrap!`, committing tracked project context as `chore: initialize llm-wiki` so future Hive worktrees inherit wiki context.
11. **Install runtime wiki hooks** via `Hive::LlmWikiBootstrap.install_runtime_hooks!`: adds/replaces only the managed block in `.git/hooks/post-commit`, writes Linux user systemd service/timer files for daily refresh, and enables the timer through `timers.target.wants`.
12. **Register globally** via `Hive::Config.register_project(name: basename(path), path: path)`, writing into the XDG global config path (`~/.config/hive/config.yml`, or `HIVE_HOME/config.yml`).
13. Print a human summary, or with `--json` emit `hive-init.v1`: `schema`, `schema_version`, `ok`, `project`, `path`, `default_branch`, `hive_state_path`, `workflow`, `hints`, `worktree_root`, `answers`, plus top-level `planning_agent`, `claude_mode`, `development_agent`, `enabled_reviewers`, `patrol_reviewers`, `patrol_mode`, `triage_bias`, `adhoc_auto_fix`, `budgets`, `timeouts`, `daemon_enabled`, `babysitter_enabled`, and `daemon_autostart_requested`. Fresh coding-default projects with no project-authored workflow descriptors get one custom-workflow authoring hint; non-coding defaults or existing descriptors get `hints: []`. `--new-workflow` also includes optional `descriptor_path` and `instruction_path` fields and sets `workflow` to the newly bound id. The nested `answers` object is the full prompt contract and includes `claude_permission_mode`, `claude_model`, and `claude_effort`; those are not duplicated at top level. In JSON mode the non-TTY defaults line is suppressed so stdout remains one JSON document.
14. Ensure the global daemon service unit exists via `Hive::Commands::Daemon::ServiceInstaller`, recording `daemon.autostart` from the prompt answer in the global config and enabling/starting the platform service only when requested. This is global infrastructure; it does not override the per-project `daemon.enabled` answer.
15. Run the non-fatal `hive doctor` skill preflight; missing skills warn on stderr without failing init.

If any step from orphan-state creation through global registration raises, init attempts partial rollback before surfacing the failure: delete `.hive-state/config.yml` if present, `git worktree remove --force <project>/.hive-state`, `git branch -D hive/state`, reset init-created main-checkout commits to the pre-init head, and restore/remove init-owned files such as `.gitignore`, `.llm-wiki/`, wiki scaffolding, runtime hooks, scheduler units, and the global registry file. Non-Hive exceptions are wrapped as `Hive::InternalError` (exit 70) so `bin/hive` does not leak a Ruby stack trace. If rollback itself cannot converge, stderr includes the rollback error plus a one-line recovery command so re-running init is not trapped behind an orphan `hive/state` branch.

## Prompt flow (ADR-023)

On TTY input streams the prompt walks the operator through the following sections in order:

0. **Workflow** (`default_workflow`): when more than one workflow exists, a `Workflow:` menu lists built-ins first (`coding`, `content`) followed by active project workflows on re-init, plus `author a new workflow`. Bare Enter keeps `coding` on fresh init or the current project default on re-init. Choosing the author entry prompts for an id and reuses the `--new-workflow` scaffolder, then continues into the remaining setup questionnaire. EOF at this step raises `Prompts::Aborted` before any disk side effects.
1. **Planning agent** (`brainstorm.agent` + `plan.agent`): one combined choice; the answer maps to both keys. Recommended default `claude`.
2. **Claude launch mode** (`claude.mode`): `tmux` (default) runs every Claude-backed stage in an attachable tmux pane using the logged-in Claude session; `headless` keeps the non-interactive `claude -p` path. The setting is global for Claude only — Codex/Pi stages remain on their normal headless profile path.
3. **Claude permission mode** (`claude.permission_mode`): applies to every Claude-backed stage, in both tmux and headless mode. Recommended default `bypassPermissions` skips Claude Code permission prompts for dogfood runs (maps to `--dangerously-skip-permissions`); `auto` uses Claude Code auto-mode rules. The same prompt also accepts `default`, `acceptEdits`, `dontAsk`, and `plan`.
4. **Claude model** (`claude.model`): default `default` writes Claude Code's live recommended-model alias so hive-launched Claude sessions stop inheriting the operator's interactive model choice. `inherit` restores the old behavior by omitting `--model`; any other alias or full model name is written verbatim.
5. **Claude effort** (`claude.effort`): default `default` keeps Claude Code's own reasoning-effort tier by omitting `--effort`. Explicit choices are `low`, `medium`, and `high`; the prompt accepts either names or 1-based indexes.
6. **Development agent** (`execute.agent`): the implementer in `4-execute`. Recommended default `codex` (its edit-mode is more efficient for implementation work). Codex's status-detection mode is `:output_file_exists`, but the execute spawn pins `status_mode: :state_file_marker` because the stage's lifecycle contract is the marker the agent writes — the pin keeps that contract independent of the chosen profile.
7. **Review agents** (`review.reviewers[]`): multi-select over the three default reviewers (claude-ce-code-review, codex-ce-code-review, pr-review-toolkit). Disabled entries are omitted from the rendered array.
8. **Patrol PR review agents** (`patrol.review.reviewers[]`): multi-select over the narrow patrol set (codex-ce-code-review, optionally claude-ce-code-review). Blank/default renders Codex only; PR review toolkit is intentionally not offered for patrol PRs.
9. **Patrol mode** (`patrol.mode`): `ultrapatrol`, `high`, `medium` (default), `low`, or `off`. Fresh config writes this single key and omits explicit `enabled`/`trigger`/`poll_interval_sec` so [[modules/config]] derives the scheduler knobs.
10. **Triage bias** (`review.triage.bias`): `courageous` (default) or `safetyist`. Picks the bias preset used by the 6-review autonomous loop.
11. **Ad-hoc PR auto-fix** (`review.adhoc.fix`): whether `hive review --pr` should enter the fix loop for existing GitHub PRs. Default no keeps the workflow review-only: Hive publishes reviewer/escalation comments to GitHub when `review.github_publish.enabled` is true, but does not prepare local fix commits for someone else's PR. Answer `y` only when accepted ad-hoc findings should be eligible for local fix commits.
12. **Per-stage limits**: budget+timeout for each of 10 effective keys (`brainstorm`, `plan`, `execute_implementation`, `open_pr`, `artifacts`, `finalize`, `review_ci`, `review_triage`, `review_fix`, `review_browser`). Defaults are generous sanity caps — most tasks finish well within them.
13. **Daemon enrollment** (`daemon.enabled`): whether to opt this project into the auto-advance daemon (default yes).
14. **Babysitter enrollment** (`babysitter.enabled`): whether to opt this project into the experimental open-PR babysitter (default yes). It is a separate process from `hive daemon`; start it with `hive babysit start`.
15. **Daemon autostart** (`daemon.autostart` in the global config): whether to enable+start the per-user service unit now (default no — the unit is always written, but autostart is opt-in).

Each agent and reviewer prompt accepts **either a name or a 1-based index** (e.g., `codex` or `2`; `claude-ce-code-review,pr-review-toolkit` or `1,3`). Agent names are resolved before numeric indexes, so a future digit-only profile name such as `42` remains addressable by name. The Claude mode, permission-mode, and effort prompts follow the same rule (`tmux` / `headless` or `1` / `2`; `bypassPermissions` / `auto` / etc. or `1` / `2` / ...; `medium` or `3`). The model prompt is free-form because aliases/full model names are pass-through. Name strings are the recommended path for scripted automation since they're stable across template-default reordering.

### Stable-iteration-order contract

The prompt's choice list is rendered in a documented stable order:
- **Agent profiles**: `claude`, `codex`, `pi` — the order in which `lib/hive/agent_profiles.rb` requires them at boot. `Hive::AgentProfiles.registered_names` returns them in this order.
- **Default reviewers**: `claude-ce-code-review`, `codex-ce-code-review`, `pr-review-toolkit` — the order shipped in `templates/project_config.yml.erb` and surfaced via `Hive::Commands::Init::Prompts::DEFAULT_REVIEWER_NAMES`.
- **Patrol reviewers**: `codex-native-review`, `codex-ce-code-review`, `claude-ce-code-review` — native Codex review is index 1 and the blank/default; the CE reviewers are optional broader patrol reviewers.

Reordering either is a **breaking change for scripted automation** that uses index answers — index `1` would silently shift to a different value. Prefer names in scripts.

### Non-TTY contract

When `$stdin.tty?` is false the prompt module skips every question and emits exactly one line to `$stdout`:

```
hive: using defaults — planning=claude, claude_mode=tmux, claude_permission_mode=bypassPermissions, claude_model=default, claude_effort=default, dev=codex, reviewers=all3, patrol_reviewers=codex, patrol_mode=medium, triage=courageous, adhoc_auto_fix=disabled, limits=defaults, daemon=enabled, babysitter=enabled, daemon_autostart=disabled
```

Piped input is **not** consumed — `printf 'codex\n...' | hive init` ignores the piped data and uses defaults. Document this contract for any automation that wants to set non-default values: use `--force` plus an explicitly-edited YAML rather than expecting heredoc piping to populate answers.

Limit prompts accept `<budget>,<timeout>` pairs. Blank input keeps both defaults. A leading empty budget such as `,900` keeps the default budget and overrides only timeout. A trailing empty timeout such as `10,` is rejected and re-prompts; budget-only overrides must be explicit as `<budget>,<timeout>` so typoed commas do not silently keep a default timeout.

## Default-branch detection

`GitOps#detect_default_branch` (`lib/hive/git_ops.rb:269`) tries:

1. `git symbolic-ref refs/remotes/origin/HEAD` → strip `refs/remotes/origin/` prefix.
2. Fallback: `git rev-parse --abbrev-ref HEAD` (if not detached).
3. Fallback: `git config init.defaultBranch`.
4. Final fallback: literal `"master"`.

This branch is what the orphan worktree is initially based on, and what feature worktrees are branched from.

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `not a git repository` | path isn't a git repo | `git init` first |
| `target appears to be inside a worktree` | running from a feature worktree | run on main checkout |
| `uncommitted changes` | dirty working tree | commit/stash, or pass `--force` |
| `already initialized` (exit 2) | `hive/state` already exists | nothing to do |
| `partial init failed` warning | disk-side-effect step raised after orphan-state creation | rerun after automatic rollback; if rollback was incomplete, inspect stderr and run the printed `git worktree remove ... && git branch -D hive/state` recovery command |

## Tests

- `test/integration/init_test.rb` covers all five preconditions, the `--force` path, `--json` success payload validation including workflow-authoring `hints`, non-default answer mirroring, and legacy precondition failures, partial-init rollback after orphan-state creation and later main-checkout side effects, the idempotent double-init, the rendered template's stage-agent/runtime blocks, Claude model/effort defaults in the answer/template path, normal and patrol reviewer rendering, mode-only patrol scheduling config, daemon and babysitter enrollment defaults, the bumped-generous limits, the dropped `execute_review` key, managed llm-wiki bootstrap/scheduler/hooks, incomplete prompt-answer failure before disk side effects, workflow prompt selection/default/non-TTY/abort behavior, and inline workflow authoring including reserved-id, invalid-format, and scaffold-collision re-prompts.
- `test/unit/commands/init_test.rb` covers small init collaborators, including the `ProjectConfigBinding` complete-answer path, top-level and nested missing-key fail-fast contracts, rollback helper behavior, daemon-registration warning paths, and JSON summary EPIPE handling.
- `test/unit/commands/init/prompts_test.rb` covers the prompt module in isolation: happy paths, digit-only agent names, normal reviewer and patrol reviewer multi-select parsing, rejection of `pr-review-toolkit` for patrol reviewers, patrol mode selection by name/index/default, limit-pair edge re-prompts, the Claude mode, permission-mode, model, and effort prompts, daemon/babysitter/autostart prompts, the non-TTY summary contract, and the testability invariant. `test/unit/schema_files_test.rb` pins `schemas/hive-init.v1.json` to the producer's success payload, including the required `hints`, `patrol_reviewers`, `patrol_mode`, `claude_model`, and `claude_effort` answer keys.

## Backlinks

- [[cli]] · [[commands/run]]
- [[modules/git_ops]] · [[modules/config]] · [[modules/agent_profile]] · [[modules/babysitter]]
- [[state-model]] · [[decisions]] (ADR-023)
