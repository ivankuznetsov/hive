# Hive

Folder-as-agent pipeline for moving tasks through `1-inbox/` → `2-brainstorm/` → `3-plan/` → `4-execute/` → `5-pr/` → `6-done/`. Each stage is a directory; `mv` between directories is the only approval gesture. Stage agents run via `claude -p` and write back into the task folder.

Phase 1 MVP: pilot on a single project (writero), no daemon, single reviewer (`/compound-engineering:ce-review`), manual `hive run <folder>` per stage.

## Install

```bash
git clone <this repo> ~/Dev/hive
cd ~/Dev/hive
bundle install
ln -s ~/Dev/hive/bin/hive ~/.local/bin/hive   # or add bin/ to PATH
```

Requires:

- Ruby 3.4+
- `claude` CLI ≥ 2.1.118
- `gh` CLI authenticated (`gh auth status`)
- `git` 2.40+

## Quickstart (writero)

```bash
cd ~/Dev/writero
hive init .                                   # bootstrap orphan hive/state branch
hive new writero 'add tag autocomplete'       # task lands in 1-inbox/

# approve to start brainstorm
mv .hive-state/stages/1-inbox/<slug> .hive-state/stages/2-brainstorm/
hive run .hive-state/stages/2-brainstorm/<slug>

# answer questions inline in brainstorm.md, then re-run
hive run .hive-state/stages/2-brainstorm/<slug>

# approve brainstorm → plan
mv .hive-state/stages/2-brainstorm/<slug> .hive-state/stages/3-plan/
hive run .hive-state/stages/3-plan/<slug>

# approve plan → execute (worktree spawned)
mv .hive-state/stages/3-plan/<slug> .hive-state/stages/4-execute/
hive run .hive-state/stages/4-execute/<slug>

# review findings: tick `[x]` in reviews/*.md, re-run for next pass
hive run .hive-state/stages/4-execute/<slug>

# approve code → PR
mv .hive-state/stages/4-execute/<slug> .hive-state/stages/5-pr/
hive run .hive-state/stages/5-pr/<slug>

# after merge: archive
mv .hive-state/stages/5-pr/<slug> .hive-state/stages/6-done/
hive run .hive-state/stages/6-done/<slug>     # prints worktree-cleanup commands
```

## Daily usage

- `hive status` — table of active tasks per project.
- `hive new <project> '<text>'` — capture an idea.
- `mv` between stage folders — the only approval gesture.
- `hive run <folder>` — run the agent for a task's current stage.

`master` of the project never receives `.hive-state/` content; `.hive-state/` lives on an orphan branch `hive/state` checked out as a separate worktree, so the project's CI is untouched and feature worktrees stay clean of hive artefacts.

## Troubleshooting

- **"already initialized"** — `hive/state` branch already exists. Skip `hive init` for this project.
- **"plan.md missing"** in 4-execute — the task did not pass through `3-plan/`. Move it back, run plan, then move forward.
- **"no worktree pointer"** in 5-pr — the task did not pass through `4-execute/`. Move it back through execute first.
- **Stale `.lock`** — auto-cleared on next `hive run` when the recorded PID is dead. Hive cross-checks process start time to avoid PID-reuse false positives.
- **`EXECUTE_STALE`** in `task.md` — max review passes (default 4) reached. Edit `reviews/*.md` manually, decrement `pass:` in `task.md` frontmatter, remove the stale marker, then `hive run` again.

## Layout

- `bin/hive` — executable.
- `lib/hive/` — library code.
- `templates/` — ERB prompt templates and config scaffolds.
- `test/` — minitest suites.
- `~/Dev/hive/config.yml` — global config (registered projects).
- `<project>/.hive-state/config.yml` — per-project config (default branch, budgets, timeouts).
