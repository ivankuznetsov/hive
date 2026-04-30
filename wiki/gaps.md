---
title: Gaps
type: gaps
source: wiki/* vs lib/, templates/, test/
created: 2026-04-25
updated: 2026-04-29
tags: [gap, todo]
---

**TLDR**: Bootstrap is complete for every source file in `lib/` and every CLI command. Remaining gaps are around live behavioural verification, not codebase coverage.

## Source-file coverage (✓ = page exists)

| File | Page |
|------|------|
| `bin/hive` | ✓ [[cli]] |
| `lib/hive.rb` | ✓ [[cli]] (constants/errors), [[architecture]] (version pin) |
| `lib/hive/cli.rb` | ✓ [[cli]] |
| `lib/hive/config.rb` | ✓ [[modules/config]] |
| `lib/hive/task.rb` | ✓ [[modules/task]] |
| `lib/hive/markers.rb` | ✓ [[modules/markers]] |
| `lib/hive/lock.rb` | ✓ [[modules/lock]] |
| `lib/hive/worktree.rb` | ✓ [[modules/worktree]] |
| `lib/hive/git_ops.rb` | ✓ [[modules/git_ops]] |
| `lib/hive/agent.rb` | ✓ [[modules/agent]] |
| `lib/hive/commands/init.rb` | ✓ [[commands/init]] |
| `lib/hive/commands/new.rb` | ✓ [[commands/new]] |
| `lib/hive/commands/run.rb` | ✓ [[commands/run]] |
| `lib/hive/commands/status.rb` | ✓ [[commands/status]] |
| `lib/hive/stages/base.rb` | ✓ (covered in [[templates]] + [[stages/index]]) |
| `lib/hive/stages/inbox.rb` | ✓ [[stages/inbox]] |
| `lib/hive/stages/brainstorm.rb` | ✓ [[stages/brainstorm]] |
| `lib/hive/stages/plan.rb` | ✓ [[stages/plan]] |
| `lib/hive/stages/execute.rb` | ✓ [[stages/execute]] |
| `lib/hive/stages/pr.rb` | ✓ [[stages/pr]] |
| `lib/hive/stages/done.rb` | ✓ [[stages/done]] |
| `templates/*.erb` (all 9) | ✓ [[templates]] |
| `test/**` | ✓ [[testing]] |

## Open questions about the codebase

1. **Has `hive run` been smoke-tested against a live `claude` v2.1.118?** The plan calls for this before declaring the MVP done. No evidence in tree (no `docs/solutions/` notes, no `docs/smoke-results.md`).
2. **Has `hive init` been run against a real project yet?** Planned pilot, but the working tree shows no first commit on `~/Dev/hive` itself, so the pilot may not have started.
3. **Is `hive/state` reachable after `git gc`?** The plan recommends `git config --add gc.reflogExpire never refs/heads/hive/state`. This is documented in [[decisions]] ADR-003 but not enforced in `Init#call`.
4. **Does the pilot project's pre-commit hook chain (lefthook/overcommit/husky) misbehave on `.hive-state/` commits?** The plan flags this as a known caveat to verify on first init; outcome unrecorded.
5. ~~**macOS PID-reuse fallback**~~ — closed 2026-04-25. `Lock#process_start_time` now tries `/proc/<pid>/stat` first, falls back to `ps -o lstart= -p <pid>` on macOS / BSD / containers without `/proc`. Returns nil only when neither source works.
6. **E2E surface matrix** — `bin/hive-e2e run` is green locally on Linux with tmux 3.6a, but the follow-up matrix across macOS and a different tmux minor version is still open.
7. **Asciinema local verification** — `AsciinemaDriver` is wired into TUI failure capture and has a fake-binary harness test, but `asciinema` is still not visible on this shell's PATH. Live playable cast capture still needs either PATH repair or `HIVE_ASCIINEMA_BIN=/absolute/path/to/asciinema`.
8. **R2 misdiagnosis artifact validation** — e2e artifacts exist, but the "fresh agent course-corrects from a wrong first diagnosis" case needs the first organic failure or a third-party synthetic failure.

## Patterns detected in code but not yet documented

1. **`Stages::Base::TemplateBindings` reflection pattern** — used as a generic kw-args → instance vars adapter. Worth a one-paragraph note in [[templates]] if the pattern appears elsewhere.
2. **Idempotency conventions** — `Init` exits with code 2 when already initialised; `New` exits with code 1 on slug collision; the `Pr` stage idempotent-PR path returns `:complete` without spawning. There's no centralised exit-code policy.
3. **Two patterns for marker writes** — `Markers.set` (now uses flock + tempfile-rename atomic write) vs the agent writing into the state file via `Edit`/`Write`. The orchestrator now owns the terminal marker after every stage (the reviewer template explicitly does not write `task.md`), so concurrent-write races on the state file should not arise during normal flow. The remaining unprotected case is a user editing the state file in vim/VSCode while AGENT_WORKING — documented as "don't do that" in the README.

## Areas the wiki could be expanded

- `wiki/troubleshooting.md` — currently lives only in README's Troubleshooting section. Could be lifted into a dedicated page once the project sees real-world failures.
- `wiki/security.md` — dedicated page for the trust model, prompt-injection policy, and the protected-files SHA-256 check. Currently spread across `[[architecture]]`, `[[decisions]]` ADR-008, and `[[modules/agent]]`.
- `wiki/operating.md` — log rotation, `.hive-state` backup strategy, recovering from a deleted feature worktree. Defer until ops practice exists.
- `wiki/roadmap.md` — Phase 2/3 work is listed in [[active-areas]]; a dedicated roadmap with status columns would be more navigable once Phase 2 work begins.

## Backlinks

- [[active-areas]]
- [[index]]
- [[e2e]]
