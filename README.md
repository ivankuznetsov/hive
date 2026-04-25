# Hive

[![CI](https://github.com/ivankuznetsov/hive/actions/workflows/ci.yml/badge.svg)](https://github.com/ivankuznetsov/hive/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-3.4-red.svg)](.ruby-version)

Folder-as-agent pipeline for software work. Each task lives in a directory; the directory's location *is* its stage (`1-inbox/` → `2-brainstorm/` → `3-plan/` → `4-execute/` → `5-pr/` → `6-done/`). `mv` between stage folders is the only approval gesture. Stage agents run as `claude -p` subprocesses, read from / write to the task folder, and exit.

No daemon. No web UI. No tracker. The filesystem is the queue, markdown is the source of truth, and `mv` is the API.

**Status: Phase 1 MVP.** Single project pilot, single reviewer (`/compound-engineering:ce-review`), manual `hive run <folder>` per stage — multi-project daemon, observability probes, and Telegram bot are deferred.

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
| `gh` CLI | recent | `5-pr` stage (`gh pr create`); must be authenticated |
| `git` | 2.40 | worktrees, orphan branches |

Optional: [`qmd`](https://qmd.dev) for semantic search over `wiki/` (ripgrep works as fallback).

## Quickstart

```bash
cd ~/Dev/your-project
hive init .                                     # bootstrap orphan hive/state branch + .hive-state worktree
hive new your-project 'add tag autocomplete'         # task lands in 1-inbox/<slug>/

# approve to start brainstorm
mv .hive-state/stages/1-inbox/<slug> .hive-state/stages/2-brainstorm/
hive run .hive-state/stages/2-brainstorm/<slug>

# answer questions inline in brainstorm.md, save, re-run
hive run .hive-state/stages/2-brainstorm/<slug>

# approve → plan
mv .hive-state/stages/2-brainstorm/<slug> .hive-state/stages/3-plan/
hive run .hive-state/stages/3-plan/<slug>

# approve → execute (feature worktree spawned at ~/Dev/your-project.worktrees/<slug>)
mv .hive-state/stages/3-plan/<slug> .hive-state/stages/4-execute/
hive run .hive-state/stages/4-execute/<slug>

# tick [x] on findings in reviews/ce-review-NN.md, re-run for next pass
hive run .hive-state/stages/4-execute/<slug>

# approve → PR
mv .hive-state/stages/4-execute/<slug> .hive-state/stages/5-pr/
hive run .hive-state/stages/5-pr/<slug>

# after the PR merges: archive
mv .hive-state/stages/5-pr/<slug> .hive-state/stages/6-done/
hive run .hive-state/stages/6-done/<slug>       # prints worktree-cleanup commands
```

## Daily usage

| Command | What it does |
|---------|--------------|
| `hive new <project> '<text>'` | Capture an idea — writes `.hive-state/stages/1-inbox/<slug>/idea.md` and commits on `hive/state`. |
| `mv` between stage folders | The original approval gesture. Still works; `hive approve` is the agent-callable equivalent. |
| `hive approve <slug>` | Move a task to the next stage and record a hive/state commit. Use `--to <stage>` for explicit destinations (including backward recovery), `--from <stage>` to assert the current stage on retry, `--force` to bypass the terminal-marker check, `--json` for machine-readable output. Agent-callable equivalent of shell `mv`. |
| `hive run <task-folder>` | Run the stage agent for the task at its current location. Idempotent; safe to re-run. |
| `hive status` | Tabular view of every active task across all registered projects. Read-only. |
| `hive findings <slug>` | List GFM-checkbox findings in the latest `reviews/ce-review-NN.md`. `--pass N` for a specific pass; `--json` for machine-readable. |
| `hive accept-finding <slug> ID...` | Tick `[ ]` → `[x]` on review findings so they're re-injected into the next implementation pass. `--severity high` for all of one severity; `--all` for everything. |
| `hive reject-finding <slug> ID...` | Inverse: tick `[x]` → `[ ]`. Same selectors. |

## How it stays out of the way

Your default branch (`master` or `main`) never receives `.hive-state/` content. The `.hive-state/` directory is a worktree of an orphan branch `hive/state` — its commits don't pollute the code branch, don't trigger CI, and aren't pushed by default. Feature worktrees branch from the default branch and contain no hive artefacts. `git log` on the default branch stays code-only.

## Stage cheat sheet

| Stage | State file | Writes code? | Marker outcomes |
|-------|------------|--------------|-----------------|
| `1-inbox` | `idea.md` | no — `hive run` is inert here | — |
| `2-brainstorm` | `brainstorm.md` | no | `WAITING` (your turn) / `COMPLETE` |
| `3-plan` | `plan.md` | no | `WAITING` / `COMPLETE` |
| `4-execute` | `task.md` (+ `reviews/`, `worktree.yml`) | yes — in the feature worktree | `EXECUTE_WAITING` / `EXECUTE_COMPLETE` / `EXECUTE_STALE` |
| `5-pr` | `pr.md` | only `git push` + `gh pr create` | `COMPLETE` |
| `6-done` | `task.md` | no — prints cleanup commands | `COMPLETE` |

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
- **`no worktree pointer`** in 5-pr — task didn't pass through `4-execute/`. Move it back through execute first.
- **`worktree pointer present but worktree missing`** — `git -C <project> worktree prune`, delete `worktree.yml`, then re-run.
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
