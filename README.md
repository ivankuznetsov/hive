<p align="center">
  <img src="docs/assets/logo.svg" alt="Hive" width="96" height="96">
</p>

# Hive

Hive is a multi-agent orchestrator that ships software ideas from rough note to pull request through a folder-as-agent pipeline.

Each task is a directory. The directory's stage folder is the task state, so moving a folder forward is the approval gesture and every artefact stays inspectable with normal filesystem tools. Compound engineering is the practice of making each step's output strong enough for the next step to run autonomously: brainstorm fixes the requirements, plan fixes the approach, execute writes code, review hardens it, and PR stages ship it.

```text
1-inbox  ->  2-brainstorm  ->  3-plan  ->  4-execute  ->  5-open-pr  ->  6-review  ->  7-finalize  ->  8-done
capture       refine           design      build          draft PR       harden        publish         archive
```

Read the model in depth in [docs/concepts.md](docs/concepts.md).

## Install

Tier-1 installs use the same signed GitHub Release artifacts:

| Platform | Recommended channel |
|----------|---------------------|
| macOS arm64 | `brew install ivankuznetsov/hive/hive` |
| Arch Linux x86_64/aarch64 | `yay -S hive-bin` |
| Ubuntu 22.04+ x86_64/aarch64 | `curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh \| bash` |

Agent-assisted install prompt: [install.md](install.md).

Full install matrix, XDG paths, Apache Hive collision behavior, update, and uninstall details live in [wiki/operating.md](wiki/operating.md#install).

Development from a clone still works:

```bash
git clone https://github.com/ivankuznetsov/hive ~/Dev/hive && cd ~/Dev/hive && bundle install && mkdir -p ~/.local/bin && ln -sf ~/Dev/hive/bin/hive ~/.local/bin/hive
```

If `~/.local/bin` is not on `PATH`, put the symlink in a directory that is. The `-sf` form will overwrite an existing `hive` at the target path; run `command -v hive` first if you already have one installed and don't want to clobber it.

Requires Ruby 3.4, git >= 2.40, `claude` >= 2.1.118, `codex` >= 0.125.0 for the default execute agent, and authenticated `gh`. See [docs/getting-started.md](docs/getting-started.md) for the first run.

## Install As A Prompt

Paste this into Claude Code or Codex when you want the agent to install Hive for you:

```text
Install Hive from the canonical GitHub source into ~/Dev/hive and put the hive binary on PATH.

Before changing anything:
- If ~/Dev/hive already exists, stop and ask whether to reuse it, pull it, or choose another directory.
- If `claude` is missing or `claude --version` is older than 2.1.118, stop and report the missing prerequisite.
- If `codex` is missing or `codex --version` is older than 0.125.0, stop and report that the default execute agent will not work until Codex is installed.
- If `gh auth status` fails, stop and ask the user to authenticate GitHub CLI.
- If ~/.local/bin is not on PATH, stop and ask which PATH directory should receive the symlink, then substitute that directory for ~/.local/bin in the link command below.
- If <bin-dir>/hive already exists (file, symlink, or another checkout's binary), stop and ask whether to overwrite it or pick a different bin directory before running the link command below.

Run these commands in order (replace <bin-dir> with the chosen PATH directory; default is ~/.local/bin):

git clone https://github.com/ivankuznetsov/hive ~/Dev/hive
cd ~/Dev/hive
bundle install
mkdir -p <bin-dir>
ln -sf ~/Dev/hive/bin/hive <bin-dir>/hive
hive --version

Report the installed version and the path returned by `command -v hive`.
```

## Quickstart

Replace `your-project` with the registry name you pick at `hive init`. `hive new` prints the slug to use in the next commands; `hive status` also lists it.

```bash
cd ~/Dev/your-project
hive init .                                      # attach .hive-state to this repo
hive new your-project "add tag autocomplete"     # create 1-inbox/<slug>/idea.md (prints <slug>)
hive status                                      # see the next useful action
hive brainstorm <slug>                           # write brainstorm.md, then answer questions inline
hive plan <slug>                                 # write or refine plan.md
hive develop <slug>                              # create the feature worktree and implementation commit
hive open-pr <slug>                              # push the branch and open a draft PR
hive review <slug>                               # run CI, reviewers, triage, fixes, and browser test
hive finalize <slug>                             # refresh the PR body and mark it ready
hive archive <slug>                              # after 7-finalize completes, move the task to 8-done
```

Walk through the same shape on a fresh project in [docs/getting-started.md](docs/getting-started.md), or read the replay of the completed xbookmark task in [docs/recipes.md#xbookmark-end-to-end](docs/recipes.md#xbookmark-end-to-end).

You can still move folders by hand when you want the lowest-level control. The CLI commands exist so agents and scripts can do the same work with predictable errors and JSON output.

## Daily usage

| Command | What it does |
|---------|--------------|
| `hive new <project> '<text>'` | Capture an idea in `1-inbox/<slug>/idea.md` and commit it on `hive/state`. |
| `hive status` | Show current slugs grouped by next action, with suggested commands. Read-only. |
| `hive brainstorm <slug>` | Move an inbox task into brainstorm, or re-run an existing brainstorm task. |
| `hive plan <slug>` | Move a completed brainstorm into plan, or re-run an existing plan task. |
| `hive develop <slug>` | Move a completed plan into execute, or re-run an existing execute task. |
| `hive open-pr <slug>` | Move a completed execute task into draft-PR creation, or re-run an existing open-pr task. |
| `hive review <slug>` | Move an opened draft PR into autonomous review, or re-run an existing review task. |
| `hive finalize <slug>` | Move a completed review into final PR wrap-up, or re-run an existing finalize task. |
| `hive archive <slug>` | Move a finalized PR task into done, or re-run an existing done task. |
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
| `5-open-pr` | `pr.md` | no code edits — pushes branch + opens a draft PR | `COMPLETE` / `ERROR` |
| `6-review` | `task.md` (+ `reviews/`) | yes — review fixes in the feature worktree | `REVIEW_WAITING` / `REVIEW_COMPLETE` / recovery markers |
| `7-finalize` | `pr.md`, `summary.md` | no code edits — refreshes PR body + marks ready | `COMPLETE` |
| `8-done` | `task.md` | no — prints cleanup commands | `COMPLETE` |

Markers are HTML comments at end-of-file; the last one wins. The common vocabulary: `<!-- WAITING -->`, `<!-- COMPLETE -->`, `<!-- AGENT_WORKING pid=… started=… -->` (set while `claude -p` is running, replaced on exit), `<!-- ERROR reason=… -->`, plus execute/review-specific markers such as `EXECUTE_COMPLETE` and `REVIEW_COMPLETE`. `hive status` renders 🤖 on a live `AGENT_WORKING`, ⚠ on a stale one.

## Configuration

### Global: `~/.config/hive/config.yml`

Auto-managed by `hive init`. Tracks the registry of installed projects:

```yaml
registered_projects:
  - name: your-project
    path: /home/you/Dev/your-project
    hive_state_path: /home/you/Dev/your-project/.hive-state
```

`HIVE_HOME` env var remains a legacy/test override. Fresh installs use XDG paths:
`~/.config/hive`, `~/.local/share/hive`, `~/.local/state/hive`, and `~/.cache/hive`.

A starter shape is committed at `config.example.yml` for reference.

### Per-project: `<project>/.hive-state/config.yml`

Created by `hive init` from `templates/project_config.yml.erb`. On TTY `hive init` opens an interactive prompt for the per-stage agents and limits; on non-TTY (CI, pipes, scripted callers) it falls through to recommended defaults (`claude` for planning, `codex` for development, all three default reviewers, generous limits). See `wiki/commands/init.md` for the full prompt flow.

```yaml
project_name: your-project
default_branch: master            # detected at init
worktree_root: /home/you/Dev/your-project.worktrees
hive_state_path: .hive-state

# Stage-level agents — each value must be one of: claude, codex, pi.
# Hand-edit any of these later to override what you picked at init.
brainstorm:
  agent: claude
plan:
  agent: claude
execute:
  agent: codex                    # rendered template recommends codex; runtime fallback is claude
open_pr:
  agent: claude
finalize:
  agent: claude

budget_usd:                       # generous sanity caps, NOT cost targets — bumped ~5x in ADR-023
  brainstorm: 50
  plan: 100
  execute_implementation: 500
  open_pr: 50
  finalize: 50
  review_ci: 100
  review_triage: 75
  review_fix: 500
  review_browser: 100
timeout_sec:
  brainstorm: 1800
  plan: 3600
  execute_implementation: 14400
  open_pr: 1800
  finalize: 1800
  review_ci: 3600
  review_triage: 1800
  review_fix: 14400
  review_browser: 3600
```

Override individual keys; deep-merge keeps the rest at defaults. The deprecated `execute_review` key was dropped in ADR-023 — 6-review owns reviewer budgets now (`review_ci`, `review_triage`, `review_fix`, `review_browser`).

## Troubleshooting

- **`already initialized`** — `hive/state` branch already exists for this project. Skip `hive init`. (Exit code 2.)
- **`not a git repository`** — run `git init` first.
- **`uncommitted modifications to tracked files`** at init — commit/stash tracked changes, or pass `hive init --force`. Untracked files alone don't block init.
- **`plan.md missing`** in 4-execute — task didn't pass through `3-plan/`. Move it back, run plan, then forward again.
- **`no worktree pointer`** in 5-open-pr or 7-finalize — task didn't pass through `4-execute/`. Move it back through execute first.
- **`worktree pointer present but worktree missing`** — `git -C <project> worktree prune`, delete `worktree.yml`, then re-run.
- **`slug ... is ambiguous`** — the same slug exists in multiple projects or stages. Pass `--project <name>` for cross-project ambiguity, `--from <stage>` on workflow verbs, `--stage <stage>` on `run`/`findings`, or a full task folder path.
- **`no finding with id=...`** — run `hive findings <slug>` again and use the IDs from the current review file. IDs are assigned by document order.
- **`no findings selected`** — `accept-finding` / `reject-finding` need at least one selector: explicit IDs, `--severity <name>`, or `--all`.
- **Stale `.lock`** — auto-cleared on next `hive run` when the recorded PID is dead. PID-reuse false positives are defended against by cross-checking `/proc/<pid>/stat` start time (Linux only).
- **`REVIEW_STALE`** in `task.md` — max review passes (default 2) hit. Inspect/edit the highest-pass review or `reviews/escalations-NN.md`, clear it with `hive markers clear <folder> --name REVIEW_STALE`, then `hive run` again.
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

Core docs:

- [docs/getting-started.md](docs/getting-started.md): five-minute first run against a real project.
- [docs/concepts.md](docs/concepts.md): folder-as-agent, the eight stages, and compound engineering.
- [docs/architecture.md](docs/architecture.md): how stages, agents, files, config, and worktrees compose.
- [docs/cli.md](docs/cli.md): current command surface from `bin/hive`.
- [docs/recipes.md](docs/recipes.md): concrete workflows, including the xbookmark dogfood replay.
- [docs/faq.md](docs/faq.md): troubleshooting and design questions.

Wiki reference:

- [wiki/index.md](wiki/index.md): start here. Catalog of every wiki page.
- [wiki/architecture.md](wiki/architecture.md): layer cake, process model, agent contract.
- [wiki/state-model.md](wiki/state-model.md): directory layout, marker grammar, config schemas.
- [wiki/cli.md](wiki/cli.md): full command surface.
- [wiki/decisions.md](wiki/decisions.md): ADRs covering the orphan branch, two-level locking, prompt-injection policy, install channels, daemon autonomy, and other architectural decisions.
- [wiki/stages/](wiki/stages/): one page per pipeline stage.
- [wiki/modules/](wiki/modules/): one page per Ruby module/class.
- [wiki/gaps.md](wiki/gaps.md): known gaps and open questions.

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
