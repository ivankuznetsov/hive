# 2026-05-24 Verified PR Merge Notes

This note records the ordered verification-and-merge pass that started with
PR #121, then merged the remaining open PRs one by one onto `main`.

## Scope

The verified merge batch in this pass was:

- #121 test: add merged coverage reporting
- #126 feat(events): per-task event log foundation
- #131 feat(tui): redesign red-status recovery detail screen
- #127 feat(tui): full-screen info panel and footer hint for [i]
- #129 feat(claude): global claude.mode launch setting for every stage

After #129 merged, `gh pr list --repo ivankuznetsov/hive --state open` returned
an empty list. Local `main` was fast-forwarded to `origin/main` and was clean.

PR #125 also merged earlier on 2026-05-24 before this ordered #121-first pass
began. It is included in the same-day context section, but not counted in the
verified-batch totals below.

## Merge Order

| PR | Merged | Commit | Change summary | Diff stat |
| --- | --- | --- | --- | --- |
| [#121](https://github.com/ivankuznetsov/hive/pull/121) | 2026-05-24 14:41 BST | `86f6fe1f` | Added the merged coverage harness, broad test coverage, and an honest coverage gate that fails on missing or corrupt subprocess results. | 112 files, +11,386 / -350 |
| [#126](https://github.com/ivankuznetsov/hive/pull/126) | 2026-05-24 14:51 BST | `e174ced7` | Added task-local `events.jsonl`, derived `status.md`, stage/agent lifecycle events, and review/plan event bracketing. | 16 files, +910 / -51 |
| [#131](https://github.com/ivankuznetsov/hive/pull/131) | 2026-05-24 15:10 BST | `c0978cf3` | Rebuilt the red-status recovery detail screen with a safer, clearer recovery/open-in-agent surface and hardened file/log reads. | 19 files, +1,114 / -106 |
| [#127](https://github.com/ivankuznetsov/hive/pull/127) | 2026-05-24 15:30 BST | `aaffed10` | Added the full-screen read-only TUI info panel behind `i`, footer hinting, stage-specific details, and focused renderer coverage. | 14 files, +880 / -152 |
| [#129](https://github.com/ivankuznetsov/hive/pull/129) | 2026-05-24 16:35 BST | `80d35a0a` | Added global `claude.mode`, shared tmux/headless Claude launcher wiring, init/doctor/docs support, tmux review-session sharing, and stage parity fixes. | 71 files, +3,470 / -853 |

## What Shipped

### Coverage and Test Gate

PR #121 made coverage a first-class gate instead of a best-effort report. The
new harness merges subprocess coverage, detects corrupt or missing results,
loads source files intentionally, and reports a clear summary. This gave the
later PRs a much stronger test suite before they were rebased and merged.

### Task Event History

PR #126 added the event foundation: each task now has an append-only event log,
stage enter/exit records, agent start/end records, status rendering, and review
phase instrumentation. The event stream is deliberately tolerant of torn lines
and keeps enough tail context for status displays without repeatedly loading the
whole file.

### Red-Status Recovery UX

PR #131 redesigned the red-status detail surface into a more direct recovery
view. It keeps the user on the key actions that matter for broken tasks: recover
automatically when Hive knows the recipe, or open the task in an agent when it
needs a human/agent intervention. The supporting read paths were hardened so
weird task files and logs do not crash the TUI.

### TUI Info Panel

PR #127 upgraded the `i` key into a full-screen, read-only task info panel. The
panel shows task identity, source paths, latest logs, original idea text, and
stage-specific details such as brainstorm/plan text or execute-log tails. It
also adds the footer hint so the key is discoverable.

### Global Claude Launch Mode

PR #129 replaced the brainstorm-only tmux setting with global `claude.mode`.
Claude-backed stages now route through shared launcher code, with tmux and
headless paths producing matching envelopes. Init prompts for the mode, doctor
reports it, docs call out daemon/headless requirements, and review can share a
tmux session across Claude reviewers while keeping non-Claude reviewers separate.

During the PR #129 rebase, conflicting test/docs/runtime changes were reconciled
against the already-merged coverage, events, red-status, and info-panel work.
The final cleanup commit on the PR branch was `35e6d21d`.

## Verification Record

- All five batch PRs are `MERGED` on GitHub with the merge commits listed above.
- `main` was fetched and fast-forwarded to `origin/main` after #129.
- No open PRs remained after the merge pass.
- The PR #129 branch was rebased onto the current `origin/main`, fixed, and
  pushed with `--force-with-lease`.
- Local verification for the final rebased stack:
  - `bundle exec rake test`: 3334 runs, 11930 assertions, 0 failures, 0 errors, 2 skips.
  - `CI=true bundle exec rake coverage`: gate passed, 98.72% line coverage, 87.99% branch coverage, 3334 runs, 11926 assertions, 0 failures, 0 errors, 4 skips.
- GitHub checks for #129 passed. The first `verify-release.sh` job got stuck in
  the `Install jq` step, so that install-smoke run was cancelled and the job was
  rerun; the rerun completed successfully before merge.

## Lines Changed Scoreboard

Verified-batch totals:

- 5 PRs
- 232 file-touches
- 17,760 insertions
- 1,512 deletions
- 19,272 total changed lines
- Net growth: +16,248 lines

Per-PR stats:

| Rank by churn | PR | Files | Insertions | Deletions | Total changed | Net |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | #121 coverage gate | 112 | 11,386 | 350 | 11,736 | +11,036 |
| 2 | #129 global Claude mode | 71 | 3,470 | 853 | 4,323 | +2,617 |
| 3 | #131 red-status detail | 19 | 1,114 | 106 | 1,220 | +1,008 |
| 4 | #127 info panel | 14 | 880 | 152 | 1,032 | +728 |
| 5 | #126 events | 16 | 910 | 51 | 961 | +859 |

Top-level churn:

| Area | Changed lines | Insertions | Deletions |
| --- | ---: | ---: | ---: |
| `test/` | 15,062 | 14,416 | 646 |
| `lib/` | 3,635 | 2,907 | 728 |
| `wiki/` | 363 | 275 | 88 |
| `docs/` | 110 | 72 | 38 |
| `templates/` | 41 | 38 | 3 |

Top files by aggregate churn:

| File | Changed lines | Insertions | Deletions |
| --- | ---: | ---: | ---: |
| `test/unit/tui/bubble_model_test.rb` | 1,376 | 1,315 | 61 |
| `lib/hive/claude_launcher.rb` | 796 | 796 | 0 |
| `test/unit/bot/supervisor_test.rb` | 788 | 783 | 5 |
| `test/unit/commands/daemon_test.rb` | 597 | 597 | 0 |
| `test/support/coverage.rb` | 524 | 524 | 0 |
| `test/unit/stages/review/run_reviewers_test.rb` | 455 | 448 | 7 |
| `lib/hive/stages/brainstorm_tmux.rb` | 410 | 63 | 347 |
| `lib/hive/stages/review.rb` | 400 | 288 | 112 |

Fun stats:

- The test suite took 15,062 of 19,272 changed lines, about 78% of the batch.
- PR #121 alone contributed 11,386 insertions, about 64% of all additions.
- The biggest new production file was `lib/hive/claude_launcher.rb` at 796 lines.
- The biggest cleanup by deletion count was `lib/hive/stages/brainstorm_tmux.rb`,
  which lost 347 lines while the shared launcher took over.
- The single busiest file was `test/unit/tui/bubble_model_test.rb`: 1,315 lines
  added and 61 removed across the TUI-heavy PRs.

## Same-Day Context

PR #125 (`feat(drop): hard-delete tasks via Shift+X and hive drop`) was already
merged on 2026-05-24 12:51 BST as `c03546e1` before this ordered batch began.
Its stat was 33 files, +2,428 / -222. If counted together with the verified
batch, the same-day #121+ visible total becomes 265 file-touches, 20,188
insertions, 1,734 deletions, and 21,922 total changed lines.
