---
title: Gaps
type: gaps
source: wiki/* vs lib/, templates/, test/
created: 2026-04-25
updated: 2026-05-22
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
| `lib/hive/agent_profiles/usage_extractors.rb` | ✓ [[token-usage]] |
| `lib/hive/usage_db.rb` | ✓ [[token-usage]] |
| `lib/hive/llm_wiki_bootstrap*.rb` | ✓ [[commands/init]] |
| `lib/hive/commands/init.rb` | ✓ [[commands/init]] |
| `lib/hive/commands/new.rb` | ✓ [[commands/new]] |
| `lib/hive/commands/run.rb` | ✓ [[commands/run]] |
| `lib/hive/commands/status.rb` | ✓ [[commands/status]] |
| `lib/hive/stages/base.rb` | ✓ (covered in [[templates]] + [[stages/index]]) |
| `lib/hive/stages/inbox.rb` | ✓ [[stages/inbox]] |
| `lib/hive/stages/brainstorm.rb` | ✓ [[stages/brainstorm]] |
| `lib/hive/stages/plan.rb` | ✓ [[stages/plan]] |
| `lib/hive/stages/execute.rb` | ✓ [[stages/execute]] |
| `lib/hive/stages/open_pr.rb` | ✓ [[stages/open-pr]] |
| `lib/hive/stages/finalize.rb` | ✓ [[stages/finalize]] |
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
7. ~~**Asciinema local verification**~~ — closed 2026-04-30. `/usr/bin/asciinema` 3.2.0 is visible on this shell's PATH, and a smoke run created an asciicast v2 file. `HIVE_ASCIINEMA_BIN=/absolute/path/to/asciinema` remains the fallback for installs outside PATH.
8. **R2 misdiagnosis artifact validation** — e2e artifacts exist, but the "fresh agent course-corrects from a wrong first diagnosis" case needs the first organic failure or a third-party synthetic failure.
9. **Codex and Pi token usage payloads need real-stream refinement.** [[token-usage]] ships zero-fill extractors for missing or unrecognized usage payloads so hive-driven spawns still record rows, but the exact non-zero JSON shapes should be updated after one captured Codex and one captured Pi spawn.

## Release install follow-ups

1. **AUR + Homebrew publishing — automation built, awaiting human bootstrap.** The `exit 1` AUR placeholder is replaced by a real `aur-publish` job and the `ivankuznetsov/homebrew-hive` tap repo now exists and serves v0.1.0 installs (see ADR-033 in [[decisions]], `docs/RELEASING.md`). Remaining external steps before the AUR channel goes live: the maintainer must register the AUR `hive-bin` package via a first manual bootstrap push, provision the `AUR_SSH_PRIVATE_KEY` secret, set `HOMEBREW_TAP_TOKEN` (to enable auto-update dispatch), and add the `v*` tag-protection ruleset. Until the AUR bootstrap is done, `README.md`/`install.md` mark `yay -S hive-bin` as "coming soon" and route Arch users to the bash installer. The retry/idempotency question is resolved (both publish paths are idempotent on re-run). Validating the full automated path end-to-end is the v0.1.1 release (plan unit U7).
2. **macOS x86_64 install.sh support deferred to v0.1.x.** v0.1.0 treats macOS x86_64 as tier-3 for the bash installer rather than attempting an untested Rosetta path. A future follow-up can add best-effort Rosetta behavior once the release smoke matrix covers it.
3. **Hive skills package deferred to a companion-package follow-up.** The intended marketplace slugs are documented in `install.md` and [[operating]], but agents must not run those commands until `ivankuznetsov/hive-skills` is actually published.

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

## Resolved Bootstrap Validation

- 2026-05-14: Managed llm-wiki config, agent context, post-commit hook, and daily systemd timer were validated for `hive`.
- 2026-05-15: `qmd status` reports Vulkan GPU offload on AMD Radeon 890M Graphics (RADV STRIX1) after installing the Arch Vulkan stack.
- 2026-05-15: `qmd query "llm wiki managed bootstrap" -c hive --no-rerank -n 3` completed with local Vulkan-backed generation; sandboxed agent sessions still need qmd cache write access via `--add-dir` or host-side maintenance hooks.
