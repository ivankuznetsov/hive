# Architecture

Hive is a Ruby CLI around filesystem state, agent subprocesses, and git worktrees. This page explains the user-facing architecture; the deep reference remains in [wiki/architecture.md](../wiki/architecture.md).

## The Three Trees

```text
~/Dev/your-project/
|-- app files...
`-- .hive-state/                    # worktree of orphan branch hive/state
    |-- config.yml
    |-- stages/
    `-- logs/

~/Dev/your-project.worktrees/
`-- <slug>/                         # feature worktree created by 4-execute
    `-- app files...

~/Dev/hive/
|-- bin/hive
|-- lib/hive/
`-- config.yml                      # global registry
```

The project checkout holds code. `.hive-state/` holds durable Hive state on the separate `hive/state` branch. The feature worktree holds code changes for one task branch.

## Storage Layout

`hive init .` creates the per-project storage tree:

```text
<project>/.hive-state/
|-- config.yml
|-- .commit-lock
|-- stages/
|   |-- 1-inbox/<slug>/
|   |-- 2-brainstorm/<slug>/
|   |-- 3-plan/<slug>/
|   |-- 4-execute/<slug>/
|   |-- 5-open-pr/<slug>/
|   |-- 6-review/<slug>/
|   |-- 7-finalize/<slug>/
|   `-- 8-done/<slug>/
`-- logs/<slug>/<stage>-<UTC-ts>.log
```

Each stage has one state file: `idea.md`, `brainstorm.md`, `plan.md`, `task.md`, or `pr.md`. `worktree.yml` points from Hive state to the feature worktree created during execute. The xbookmark walkthrough shows a finished tree in [docs/assets/xbookmark-state-tree.txt](assets/xbookmark-state-tree.txt).

## Agents

Hive has built-in agent profiles for `claude`, `codex`, and `pi`. A profile defines the binary, version check, prompt flag, add-dir behavior, skill invocation syntax, and status-detection mode. Stage runners look up the configured profile before spawning the subprocess.

Default new-project setup uses `claude` for planning, `codex` for execute, and a reviewer set that can include Claude, Codex, and PR review toolkit agents. The profile details live in [wiki/modules/agent_profile.md](../wiki/modules/agent_profile.md).

## Required Skills Per Stage

Hive's prompts invoke skills inside the chosen agent. `hive doctor` checks the configured rows and reports missing installs.

| Stage | Default invocation | Claude install target | Codex install target |
|---|---|---|---|
| `2-brainstorm` | `/compound-engineering:ce-brainstorm` | compound-engineering plugin or matching Claude skill | compound-engineering plugin or matching Codex skill |
| `3-plan` | `/plan` | user slash command, commonly provided by llm-wiki | `~/.codex/skills/plan/SKILL.md` or plugin equivalent |

| Reviewer | Default skill | Agent |
|---|---|---|
| `claude-ce-code-review` | `/ce-code-review` | `claude` |
| `codex-ce-code-review` | `/ce-code-review` | `codex` |
| `pr-review-toolkit` | `/pr-review-toolkit:review-pr` | `claude` |

Run:

```bash
hive doctor
hive doctor --json
```

## Config Schema

Global registry lives at `~/Dev/hive/config.yml`:

```yaml
registered_projects:
  - name: your-project
    path: /home/you/Dev/your-project
    hive_state_path: /home/you/Dev/your-project/.hive-state
```

Per-project config lives at `<project>/.hive-state/config.yml`:

```yaml
project_name: your-project
default_branch: main
worktree_root: /home/you/Dev/your-project.worktrees
hive_state_path: .hive-state

brainstorm:
  agent: claude
plan:
  agent: claude
execute:
  agent: codex
open_pr:
  agent: claude
finalize:
  agent: claude

budget_usd:
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

review:
  max_passes: 2
  max_wall_clock_sec: 5400
  reviewers: []

daemon:
  enabled: true
```

`HIVE_HOME` changes where Hive reads the global registry. `HIVE_CLAUDE_BIN`, `HIVE_CODEX_BIN`, and `HIVE_PI_BIN` override agent binaries for tests or local shims.

## Locking

Hive uses two locks. A per-task `.lock` stays held for the full stage run, so two processes do not mutate the same task. A per-project `.commit-lock` serializes short commits on the `hive/state` branch while different tasks can still run in parallel.

## Markers And Idempotency

Stage commands are safe to retry because they inspect the task folder, current stage, and terminal marker before moving anything. The `--from <stage>` flag is the retry-safety assertion for agents: if a previous attempt already advanced the task, the retry returns `WRONG_STAGE` instead of advancing again.

## Deeper Engineering Reference

- [wiki/architecture.md](../wiki/architecture.md)
- [wiki/decisions.md](../wiki/decisions.md)
- [wiki/state-model.md](../wiki/state-model.md)
- [wiki/operating.md](../wiki/operating.md)
- [wiki/templates.md](../wiki/templates.md)
