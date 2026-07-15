---
title: hive Wiki
type: index
source: wiki/**/*.md
created: 2026-05-14
updated: 2026-07-15
tags: [index, wiki]
---


**TLDR**: Catalog of the LLM-maintained wiki for `hive`.

Page count: 88
Updated: 2026-07-15

Folder-as-agent workflow engine: a Ruby 3.4 / Thor CLI control plane where descriptor-backed workflows move task folders through filesystem stages, stage agents run via configurable AgentProfile CLIs (`claude` default, `codex`, `pi`, `grok`), and `mv` between directories remains the approval primitive. The built-in `coding` workflow drives the nine-stage PR pipeline (`1-inbox` → `2-brainstorm` → `3-plan` → `4-execute` → `5-open-pr` → `6-review` → `7-artifacts` → `8-finalize` → `9-done`), while the built-in `content` and `bench` workflows and project-authored workflows share the same generic runner/status/action machinery. The public release surface is the `hive-cli` rubygem installed through Homebrew, AUR, or `install.sh`, with `hv` as the Apache Hive collision fallback entrypoint, plus the hivebox GHCR Docker image and one-command `hivecli.sh/box` shell / `hivecli.sh/box.ps1` PowerShell installers; `hive web`/hivebox, `hive init` workflow selection and normal-vs-patrol reviewer split, project-global Claude model/effort pins, `hive connect screenote` for OAuth-backed Screenote MCP uploads, `hive patrol` handoff into `6-review`, `hive babysit`, `hive bench submit` for hive-bench corpus submissions, `hive digest` for the daily shipped digest, and the single ClawHub `hive-cli` listing that installs the OpenClaw `/hive` skill are covered by dedicated command/module pages.

## Pages

- [[active-areas]] — `wiki/active-areas.md`
- [[architecture]] — `wiki/architecture.md`
- [[cli]] — `wiki/cli.md`
- [[commands]] — `wiki/commands.md`
- [[commands/approve]] — `wiki/commands/approve.md`
- [[commands/babysit]] — `wiki/commands/babysit.md`
- [[commands/bench-submit]] — `wiki/commands/bench-submit.md`
- [[commands/bot]] — `wiki/commands/bot.md`
- [[commands/daemon]] — `wiki/commands/daemon.md`
- [[commands/digest]] — `wiki/commands/digest.md`
- [[commands/doctor]] — `wiki/commands/doctor.md`
- [[commands/drop]] — `wiki/commands/drop.md`
- [[commands/findings]] — `wiki/commands/findings.md`
- [[commands/forget]] — `wiki/commands/forget.md`
- [[commands/generate-name]] — `wiki/commands/generate-name.md`
- [[commands/init]] — `wiki/commands/init.md`
- [[commands/markers]] — `wiki/commands/markers.md`
- [[commands/metrics]] — `wiki/commands/metrics.md`
- [[commands/migrate]] — `wiki/commands/migrate.md`
- [[commands/new]] — `wiki/commands/new.md`
- [[commands/patrol]] — `wiki/commands/patrol.md`
- [[commands/pairing]] — `wiki/commands/pairing.md`
- [[commands/prune]] — `wiki/commands/prune.md`
- [[commands/rebase-status]] — `wiki/commands/rebase-status.md`
- [[commands/refactor-patrol]] — `wiki/commands/refactor-patrol.md`
- [[commands/run]] — `wiki/commands/run.md`
- [[commands/screenote]] — `wiki/commands/screenote.md`
- [[commands/setup]] — `wiki/commands/setup.md`
- [[commands/stage_action]] — `wiki/commands/stage_action.md`
- [[commands/status]] — `wiki/commands/status.md`
- [[commands/tui]] — `wiki/commands/tui.md`
- [[commands/uninstall]] — `wiki/commands/uninstall.md`
- [[commands/update]] — `wiki/commands/update.md`
- [[commands/web]] — `wiki/commands/web.md`
- [[commands/wiki]] — `wiki/commands/wiki.md`
- [[commands/workflow]] — `wiki/commands/workflow.md`
- [[decisions]] — `wiki/decisions.md`
- [[dependencies]] — `wiki/dependencies.md`
- [[e2e]] — `wiki/e2e.md`
- [[gaps]] — `wiki/gaps.md`
- [[update-flow]] — `wiki/update-flow.md`
- [[index]] — `wiki/index.md`
- [[log]] — `wiki/log.md`
- [[modules/agent]] — `wiki/modules/agent.md`
- [[modules/agent_profile]] — `wiki/modules/agent_profile.md`
- [[modules/babysitter]] — `wiki/modules/babysitter.md`
- [[modules/bot]] — `wiki/modules/bot.md`
- [[modules/config]] — `wiki/modules/config.md`
- [[modules/daemon]] — `wiki/modules/daemon.md`
- [[modules/diagnosis_agent]] — `wiki/modules/diagnosis_agent.md`
- [[modules/digest]] — `wiki/modules/digest.md`
- [[modules/events]] — `wiki/modules/events.md`
- [[modules/execute_waiting_action]] — `wiki/modules/execute_waiting_action.md`
- [[modules/findings]] — `wiki/modules/findings.md`
- [[modules/gh]] — `wiki/modules/gh.md`
- [[modules/git_ops]] — `wiki/modules/git_ops.md`
- [[modules/honeycomb]] — `wiki/modules/honeycomb.md`
- [[modules/lock]] — `wiki/modules/lock.md`
- [[modules/markers]] — `wiki/modules/markers.md`
- [[modules/metrics]] — `wiki/modules/metrics.md`
- [[modules/patrol]] — `wiki/modules/patrol.md`
- [[modules/pr]] — `wiki/modules/pr.md`
- [[modules/protected_files]] — `wiki/modules/protected_files.md`
- [[modules/rebase]] — `wiki/modules/rebase.md`
- [[modules/reviewers]] — `wiki/modules/reviewers.md`
- [[modules/secret_patterns]] — `wiki/modules/secret_patterns.md`
- [[modules/stages]] — `wiki/modules/stages.md`
- [[modules/task]] — `wiki/modules/task.md`
- [[modules/task_action]] — `wiki/modules/task_action.md`
- [[modules/task_dependencies]] — `wiki/modules/task_dependencies.md`
- [[modules/task_resolver]] — `wiki/modules/task_resolver.md`
- [[modules/workflows]] — `wiki/modules/workflows.md`
- [[modules/worktree]] — `wiki/modules/worktree.md`
- [[operating]] — `wiki/operating.md`
- [[stages/agent]] — `wiki/stages/agent.md`
- [[stages/artifacts]] — `wiki/stages/artifacts.md`
- [[stages/brainstorm]] — `wiki/stages/brainstorm.md`
- [[stages/council]] — `wiki/stages/council.md`
- [[stages/done]] — `wiki/stages/done.md`
- [[stages/execute]] — `wiki/stages/execute.md`
- [[stages/finalize]] — `wiki/stages/finalize.md`
- [[stages/inbox]] — `wiki/stages/inbox.md`
- [[stages/index]] — `wiki/stages/index.md`
- [[stages/open-pr]] — `wiki/stages/open-pr.md`
- [[stages/plan]] — `wiki/stages/plan.md`
- [[stages/review]] — `wiki/stages/review.md`
- [[state-model]] — `wiki/state-model.md`
- [[templates]] — `wiki/templates.md`
- [[testing]] — `wiki/testing.md`
- [[token-usage]] — `wiki/token-usage.md`

## Maintenance

- Managed config: `.llm-wiki/config.json`
- Headless refresh: `.llm-wiki/refresh-wiki.sh`
- Post-commit refresh: `.llm-wiki/post-commit-refresh.sh`
