---
title: hive init
type: command
source: lib/hive/commands/init.rb
created: 2026-04-25
updated: 2026-05-19
tags: [command, bootstrap, git, prompts]
---

**TLDR**: `hive init [PATH]` bootstraps a project for hive: creates the orphan `hive/state` branch, attaches it as a worktree at `<project>/.hive-state/`, scaffolds stage folders, asks the operator (on TTY) which agents to use for planning / development / review, which Claude brainstorm runtime to use, and what budget+timeout sanity caps to set, scaffolds `config.yml` from those answers, ignores `.hive-state/` in master, and registers the project globally.

## Usage

```
hive init [PROJECT_PATH] [--force]
```

`PROJECT_PATH` defaults to `Dir.pwd`. `--force` skips the clean-tree check.

## Preconditions

1. Path must be a git repository — `git -C <path> rev-parse --git-common-dir` must succeed.
2. Path must be the **main checkout**, not a worktree. The check compares git's common-dir against `<path>/.git`. Running inside an existing worktree exits 1 with `"target appears to be inside a worktree"`.
3. Working tree must be clean unless `--force` is passed; otherwise exit 1 with `"uncommitted changes"`.
4. `hive/state` branch must not already exist; if it does, prints `"already initialized"` and exits 2 (idempotent).

## Steps performed

1. **Validate** — `validate_git_repo!` then `validate_clean_tree!` (skipped under `--force`).
2. **Already-initialized guard** — if `hive/state` exists, raise `Hive::AlreadyInitialized` (exit 2). Runs **before** the prompt so a re-run never asks the user anything.
3. **Collect prompt answers** — `Hive::Commands::Init::Prompts.new(input: $stdin, output: $stderr, summary_io: $stdout).collect`. Prompt UI (intro / menus / re-prompts / confirmation) goes to **stderr**; the non-TTY one-line summary goes to **stdout** so scripted callers can `summary=$(hive init)` cleanly. On TTY this opens the interactive flow described below; on non-TTY (CI, pipes, test harness) it short-circuits to recommended defaults. Two abort paths exit **64** (`Hive::ExitCodes::USAGE`, distinct from generic crashes at 1) with **zero disk side effects** — no orphan branch, no worktree, no master gitignore commit:
   - Operator answers `n` at the final confirmation prompt.
   - Input stream closes mid-flow (Ctrl-D / EOF / disconnected pipe). `Prompts#read_line` distinguishes `nil` (closed stream) from `""` (blank line for default) and raises `Aborted`. Treating EOF as a blank confirmation would silently write disk state with whatever was already collected.
4. **Create orphan worktree** via `Hive::GitOps#hive_state_init` (`lib/hive/git_ops.rb:34`):
   - `git worktree add --no-checkout --detach <path>/.hive-state <default_branch>`
   - `git -C .hive-state checkout --orphan hive/state`
   - `git rm -rf .` plus glob cleanup of any leftover dotfiles (preserving `.git`).
   - Create `stages/{1-inbox,2-brainstorm,3-plan,4-execute,7-finalize,8-done}/` with `.gitkeep` markers and `logs/.gitkeep`.
   - Initial commit `hive: bootstrap` on `hive/state`.
5. **Render `<path>/.hive-state/config.yml`** from `templates/project_config.yml.erb`, threading the answers hash from step 3 through `ProjectConfigBinding`. Skipped if the file already exists.
6. **Ignore `.hive-state/` on master** via `GitOps#add_hive_state_to_master_gitignore!`: appends `/.hive-state/` to `.gitignore` (idempotent), then commits `chore: ignore .hive-state worktree` on master.
7. **Register globally** via `Hive::Config.register_project(name: basename(path), path: path)`, writing into `~/Dev/hive/config.yml`.
8. Print summary: project name, default branch, hive-state path, worktree root, and a `next:` line with the `hive new ...` invocation.

## Prompt flow (ADR-023)

On TTY input streams the prompt walks the operator through five sections in order:

1. **Planning agent** (`brainstorm.agent` + `plan.agent`): one combined choice; the answer maps to both keys. Recommended default `claude`.
2. **Brainstorm runtime** (`brainstorm.runtime`): shown only when the planning agent resolves to `claude`. `headless` keeps the existing non-interactive `claude -p` path; `tmux_interactive` runs Claude in an attachable tmux pane using the logged-in Claude session. If planning is not `claude`, init renders `headless` because `tmux_interactive` hardcodes the Claude binary.
3. **Development agent** (`execute.agent`): the implementer in `4-execute`. Recommended default `codex` (its edit-mode is more efficient for implementation work). Codex's status-detection mode is `:output_file_exists`, but the execute spawn pins `status_mode: :state_file_marker` because the stage's lifecycle contract is the marker the agent writes — the pin keeps that contract independent of the chosen profile.
4. **Review agents** (`review.reviewers[]`): multi-select over the three default reviewers (claude-ce-code-review, codex-ce-code-review, pr-review-toolkit). Disabled entries are omitted from the rendered array.
5. **Per-stage limits**: budget+timeout for each of 9 effective keys (`brainstorm`, `plan`, `execute_implementation`, `open_pr`, `finalize`, `review_ci`, `review_triage`, `review_fix`, `review_browser`). Defaults are generous sanity caps — most tasks finish well within them.

Each agent and reviewer prompt accepts **either a name or a 1-based index** (e.g., `codex` or `2`; `claude-ce-code-review,pr-review-toolkit` or `1,3`). The brainstorm runtime prompt follows the same rule (`headless` / `tmux_interactive` or `1` / `2`). Name strings are the recommended path for scripted automation since they're stable across template-default reordering.

### Stable-iteration-order contract

The prompt's choice list is rendered in a documented stable order:
- **Agent profiles**: `claude`, `codex`, `pi` — the order in which `lib/hive/agent_profiles.rb` requires them at boot. `Hive::AgentProfiles.registered_names` returns them in this order.
- **Default reviewers**: `claude-ce-code-review`, `codex-ce-code-review`, `pr-review-toolkit` — the order shipped in `templates/project_config.yml.erb` and surfaced via `Hive::Commands::Init::Prompts::DEFAULT_REVIEWER_NAMES`.

Reordering either is a **breaking change for scripted automation** that uses index answers — index `1` would silently shift to a different value. Prefer names in scripts.

### Non-TTY contract

When `$stdin.tty?` is false the prompt module skips every question and emits exactly one line to `$stdout`:

```
hive: using defaults — planning=claude, brainstorm_runtime=headless, dev=codex, reviewers=all3, triage=courageous, limits=defaults, daemon=enabled
```

Piped input is **not** consumed — `printf 'codex\n...' | hive init` ignores the piped data and uses defaults. Document this contract for any automation that wants to set non-default values: use `--force` plus an explicitly-edited YAML rather than expecting heredoc piping to populate answers.

## Default-branch detection

`GitOps#detect_default_branch` (`lib/hive/git_ops.rb:92`) tries:

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

## Tests

- `test/integration/init_test.rb` covers all five preconditions, the `--force` path, the idempotent double-init, the rendered template's stage-agent/runtime blocks, the bumped-generous limits, the dropped `execute_review` key, and the U5 piped-input + abort + already-initialized-guard scenarios.
- `test/unit/commands/init/prompts_test.rb` covers the prompt module in isolation: happy paths, edge re-prompts, the Claude-only brainstorm runtime prompt, the non-TTY summary contract, and the testability invariant.

## Backlinks

- [[cli]] · [[commands/run]]
- [[modules/git_ops]] · [[modules/config]] · [[modules/agent_profile]]
- [[state-model]] · [[decisions]] (ADR-023)
