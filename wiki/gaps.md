---
title: Gaps
type: gaps
source: wiki/* vs lib/, templates/, test/
created: 2026-04-25
updated: 2026-04-25
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
2. **Has `hive init` been run against a real project (writero) yet?** Planned pilot, but the working tree shows no first commit on `~/Dev/hive` itself, so the pilot may not have started.
3. **Is `hive/state` reachable after `git gc`?** The plan recommends `git config --add gc.reflogExpire never refs/heads/hive/state`. This is documented in [[decisions]] ADR-003 but not enforced in `Init#call`.
4. **Does writero's pre-commit hook chain (lefthook/overcommit/husky) misbehave on `.hive-state/` commits?** The plan flags this as a known caveat to "verify on writero first init"; outcome unrecorded.
5. **macOS PID-reuse fallback**: `Lock#process_start_time` is Linux-only. The plan acknowledges this; macOS users have no defence against PID reuse in stale-lock detection.

## Patterns detected in code but not yet documented

1. **`Stages::Base::TemplateBindings` reflection pattern** — used as a generic kw-args → instance vars adapter. Worth a one-paragraph note in [[templates]] if the pattern appears elsewhere.
2. **Idempotency conventions** — `Init` exits with code 2 when already initialised; `New` exits with code 1 on slug collision; the `Pr` stage idempotent-PR path returns `:complete` without spawning. There's no centralised exit-code policy.
3. **Two patterns for marker writes** — `Markers.set` (uses flock) vs reviewer agent writing markers via prompt instructions (uses an editor `Edit`/`Write` from inside claude). These are not synchronised against each other; the inode-tracking check is the only safety net.

## Areas the wiki could be expanded

- `wiki/troubleshooting.md` — currently lives only in README's Troubleshooting section. Could be lifted into a dedicated page once the project sees real-world failures.
- `wiki/security.md` — dedicated page for the trust model, prompt-injection policy, and the protected-files SHA-256 check. Currently spread across `[[architecture]]`, `[[decisions]]` ADR-008, and `[[modules/agent]]`.
- `wiki/operating.md` — log rotation, `.hive-state` backup strategy, recovering from a deleted feature worktree. Defer until ops practice exists.
- `wiki/roadmap.md` — Phase 2/3 work is listed in [[active-areas]]; a dedicated roadmap with status columns would be more navigable once Phase 2 work begins.

## Backlinks

- [[active-areas]]
- [[index]]
