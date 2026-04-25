# Hive

[![CI](https://github.com/ivankuznetsov/hive/actions/workflows/ci.yml/badge.svg)](https://github.com/ivankuznetsov/hive/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-3.4-red.svg)](.ruby-version)

Hive is a local, folder-based pipeline for taking a software idea from rough note to pull request. Each task is a directory, and the directory's location is the task's stage:

```text
1-inbox -> 2-brainstorm -> 3-plan -> 4-execute -> 6-pr -> 7-done
```

Stage agents run as `claude -p` subprocesses. They read the task folder, write their result back into that folder, and exit. You stay in control at each stage by approving the next move.

No daemon. No web UI. No tracker. The filesystem is the queue, markdown is the source of truth, and the CLI is a small wrapper around ordinary folder moves and git commits.

**Status:** local single-user pilot. The original `mv` workflow still works, but the current CLI also includes agent-callable commands for the common handoff points:

- `hive status` shows current slugs grouped by the next useful action.
- `hive brainstorm`, `hive plan`, `hive develop`, `hive pr`, and `hive archive` move-or-run tasks by slug.
- `hive approve` remains the lower-level move command with marker checks, locking, retries, and JSON output.
- `hive findings`, `hive accept-finding`, and `hive reject-finding` replace hand-editing review checkboxes.
- `hive run`, `hive status`, `hive approve`, and findings commands have stable machine-readable contracts for agent callers.

## Install

```bash
git clone <this repo> ~/Dev/hive
cd ~/Dev/hive
bundle install
ln -s ~/Dev/hive/bin/hive ~/.local/bin/hive   # or add bin/ to PATH
```

### Requirements

| Tool | Min version | Why |
|------|-------------|-----|
| Ruby | 3.4 | the runtime |
| `claude` CLI | 2.1.118 | every active stage; verified at runtime |
| `gh` CLI | recent | `6-pr` stage (`gh pr create`); must be authenticated |
| `git` | 2.40 | worktrees, orphan branches |

Optional: [`qmd`](https://qmd.dev) for semantic search over `wiki/` (ripgrep works as fallback).

## Quickstart

```bash
cd ~/Dev/your-project
hive init .                                     # bootstrap orphan hive/state branch + .hive-state worktree
hive new your-project 'add tag autocomplete'    # task lands in 1-inbox/<slug>/
hive status                                     # shows slugs grouped by next action

# start brainstorm
hive brainstorm <slug>

# answer questions inline in brainstorm.md, save, re-run
hive brainstorm <slug>

# plan
hive plan <slug>

# develop
hive develop <slug>

# review findings, accept the ones to fix, then re-run execute
hive findings <slug>
hive accept-finding <slug> 1 3                  # or --severity high / --all
hive develop <slug>

# open/update PR
hive pr <slug>

# after the PR merges: archive
hive archive <slug>                             # prints worktree-cleanup commands
```

You can still move folders by hand when you want the lowest-level control. The CLI commands exist so agents and scripts can do the same work with predictable errors and JSON output.

## Daily usage

| Command | What it does |
|---------|--------------|
| `hive new <project> '<text>'` | Capture an idea in `1-inbox/<slug>/idea.md` and commit it on `hive/state`. |
| `hive status` | Show current slugs grouped by next action, with suggested commands. Read-only. |
| `hive brainstorm <slug>` | Move an inbox task into brainstorm, or re-run an existing brainstorm task. |
| `hive plan <slug>` | Move a completed brainstorm into plan, or re-run an existing plan task. |
| `hive develop <slug>` | Move a completed plan into execute, or re-run an existing execute task. |
| `hive pr <slug>` | Move a completed execute task into PR, or re-run an existing PR task. |
| `hive archive <slug>` | Move a completed PR task into done, or re-run an existing done task. |
| `hive run <target>` | Lower-level dispatcher for a slug or task folder. Safe to re-run. |
| `hive approve <slug>` | Move a task to the next stage and commit the move on `hive/state`. Use `--from <stage>` for retry-safe automation, `--to <stage>` for explicit moves or recovery, `--force` when you intentionally bypass a marker check, and `--json` for agents. |
| `hive findings <slug>` | List review findings from the latest `reviews/ce-review-NN.md`. Use `--pass N` for an older pass and `--json` for agents. |
| `hive accept-finding <slug> ID...` | Mark selected findings as accepted (`[x]`) so the next execute pass fixes them. Select by IDs, `--severity high`, or `--all`. |
| `hive reject-finding <slug> ID...` | Clear selected accepted findings back to unchecked (`[ ]`). Same selectors as `accept-finding`. |
| `mv` between stage folders | The original low-level approval gesture. Still supported. |

## How it stays out of the way

Your default branch (`master` or `main`) never receives `.hive-state/` content. The `.hive-state/` directory is a worktree of an orphan branch `hive/state` — its commits don't pollute the code branch, don't trigger CI, and aren't pushed by default. Feature worktrees branch from the default branch and contain no hive artefacts. `git log` on the default branch stays code-only.

## Stage cheat sheet

| Stage | State file | Writes code? | Marker outcomes |
|-------|------------|--------------|-----------------|
| `1-inbox` | `idea.md` | no — `hive run` is inert here | — |
| `2-brainstorm` | `brainstorm.md` | no | `WAITING` (your turn) / `COMPLETE` |
| `3-plan` | `plan.md` | no | `WAITING` / `COMPLETE` |
| `4-execute` | `task.md` (+ `reviews/`, `worktree.yml`) | yes — in the feature worktree | `EXECUTE_WAITING` / `EXECUTE_COMPLETE` / `EXECUTE_STALE` |
| `6-pr` | `pr.md` | only `git push` + `gh pr create` | `COMPLETE` |
| `7-done` | `task.md` | no — prints cleanup commands | `COMPLETE` |

Markers are HTML comments at end-of-file; the last one wins. The full vocabulary: `<!-- WAITING -->`, `<!-- COMPLETE -->`, `<!-- AGENT_WORKING pid=… started=… -->` (set while `claude -p` is running, replaced on exit), `<!-- ERROR reason=… -->`, plus the `4-execute`-only `EXECUTE_WAITING` / `EXECUTE_COMPLETE` / `EXECUTE_STALE`. `hive status` renders 🤖 on a live `AGENT_WORKING`, ⚠ on a stale one.

## Configuration

### Global: `~/Dev/hive/config.yml`

Auto-managed by `hive init`. Tracks the registry of installed projects:

```yaml
registered_projects:
  - name: your-project
    path: /home/you/Dev/your-project
    hive_state_path: /home/you/Dev/your-project/.hive-state
```

`HIVE_HOME` env var overrides the default `~/Dev/hive` location.

A starter shape is committed at `config.example.yml` for reference.

### Per-project: `<project>/.hive-state/config.yml`

Created by `hive init` from `templates/project_config.yml.erb`:

```yaml
project_name: your-project
default_branch: master            # detected at init
worktree_root: /home/you/Dev/your-project.worktrees
hive_state_path: .hive-state
max_review_passes: 4
budget_usd:
  brainstorm: 10
  plan: 20
  execute_implementation: 100
  execute_review: 50
  pr: 10
timeout_sec:
  brainstorm: 300
  plan: 600
  execute_implementation: 2700
  execute_review: 600
  pr: 300
```

Override individual keys; deep-merge keeps the rest at defaults. Budgets are sanity caps for runaway agents, not cost control.

## Troubleshooting

- **`already initialized`** — `hive/state` branch already exists for this project. Skip `hive init`. (Exit code 2.)
- **`not a git repository`** — run `git init` first.
- **`uncommitted modifications to tracked files`** at init — commit/stash tracked changes, or pass `hive init --force`. Untracked files alone don't block init.
- **`plan.md missing`** in 4-execute — task didn't pass through `3-plan/`. Move it back, run plan, then forward again.
- **`no worktree pointer`** in 6-pr — task didn't pass through `4-execute/`. Move it back through execute first.
- **`worktree pointer present but worktree missing`** — `git -C <project> worktree prune`, delete `worktree.yml`, then re-run.
- **`slug ... is ambiguous`** — the same slug exists in multiple projects or stages. Pass `--project <name>` for cross-project ambiguity, `--from <stage>` on workflow verbs, `--stage <stage>` on `run`/`findings`, or a full task folder path.
- **`no finding with id=...`** — run `hive findings <slug>` again and use the IDs from the current review file. IDs are assigned by document order.
- **`no findings selected`** — `accept-finding` / `reject-finding` need at least one selector: explicit IDs, `--severity <name>`, or `--all`.
- **Stale `.lock`** — auto-cleared on next `hive run` when the recorded PID is dead. PID-reuse false positives are defended against by cross-checking `/proc/<pid>/stat` start time (Linux only).
- **`EXECUTE_STALE`** in `task.md` — max review passes (default 4) hit. Edit `reviews/*.md` manually, decrement `pass:` in `task.md` frontmatter, remove the `<!-- EXECUTE_STALE … -->` marker, then `hive run` again.
- **`reviewer_tampered`** in `task.md` — the reviewer agent edited `plan.md` or `worktree.yml` (it shouldn't). SHA-256 mismatch detected. Inspect the worktree, restore from git, re-run.
- **Concurrent `hive run`** — `ConcurrentRunError`. Per-task `.lock` is held for the entire run. Wait or kill the other process first.

## Layout

```
~/Dev/hive/
├── bin/hive                          # executable entry
├── lib/hive/                         # library code (CLI, commands, stages, modules)
├── templates/                        # ERB prompt + config templates
├── test/                             # minitest unit + integration suites
├── docs/                             # planning docs (brainstorms, plans)
├── wiki/                             # LLM-maintained knowledge base — start here
├── config.example.yml                # global-config schema reference
├── Gemfile / Gemfile.lock / Rakefile # standard Ruby project bones
└── .rubocop.yml
```

In a project after `hive init`:

```
~/Dev/your-project/
├── .gitignore                        # contains /.hive-state/
└── .hive-state/                      # worktree of orphan branch hive/state
    ├── config.yml                    # per-project config
    ├── stages/                       # task folders, organised by stage
    └── logs/<slug>/<stage>-<ts>.log  # per-agent invocation logs
```

Plus a feature worktree per active execute task at `~/Dev/your-project.worktrees/<slug>/` (sibling of the main checkout).

## Documentation

- **`wiki/index.md`** — start here. Catalog of every wiki page.
- **`wiki/architecture.md`** — layer cake, process model, agent contract.
- **`wiki/state-model.md`** — directory layout, marker grammar, config schemas.
- **`wiki/cli.md`** — full command surface.
- **`wiki/decisions.md`** — 13 ADRs (orphan branch, two-level locking, prompt-injection policy, etc).
- **`wiki/stages/`** — one page per pipeline stage.
- **`wiki/modules/`** — one page per Ruby module/class.
- **`wiki/gaps.md`** — known gaps and open questions.

If `qmd` is installed:

```bash
qmd query 'EXECUTE_STALE recovery' --collection hive
qmd search 'worktree pointer' --collection hive
```

The wiki is auto-refreshed by `.git/hooks/post-commit` when relevant files change (state-model, CLI, stages, dependencies, docs).

## Development

```bash
bundle exec rake test          # run all unit + integration tests (Minitest)
bundle exec rubocop            # lint
bundle exec rubocop -a         # autocorrect
```

`HIVE_CLAUDE_BIN` env var overrides the `claude` binary — used by tests with `test/fixtures/fake-claude` and `test/fixtures/fake-gh` to avoid spending real budget.

`HIVE_HOME` env var overrides the global config location — used by `test/test_helper.rb#with_tmp_global_config` so tests never touch the real registry.
