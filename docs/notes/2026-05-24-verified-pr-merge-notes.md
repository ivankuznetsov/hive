# 2026-05-24 Verified PR Merge Notes

This note records the ordered verification-and-merge pass that started with
PR #121, then continued through every remaining open PR until the GitHub open-PR
list was empty after PR #135.

## Scope

The verified merge batch in this pass was:

- #121 test: add merged coverage reporting
- #126 feat(events): per-task event log foundation
- #131 feat(tui): redesign red-status recovery detail screen
- #127 feat(tui): full-screen info panel and footer hint for [i]
- #129 feat(claude): global claude.mode launch setting for every stage
- #136 docs: record verified PR merge notes
- #134 test(eval): add Telegram bot evaluation harness
- #135 feat(usage): record and surface hive agent token usage

PR #125 also merged earlier on 2026-05-24 before this ordered #121-first pass
began. It is included in the same-day context section, but not counted in the
verified-batch totals below.

This final docs refresh is intentionally excluded from the totals to avoid the
release note recursively counting the note that updates itself.

## Merge Order

| PR | Merged | Commit | Change summary | Diff stat |
| --- | --- | --- | --- | --- |
| [#121](https://github.com/ivankuznetsov/hive/pull/121) | 2026-05-24 14:41 BST | `86f6fe1f` | Added the merged coverage harness, broad test coverage, and an honest coverage gate that fails on missing or corrupt subprocess results. | 112 files, +11,386 / -350 |
| [#126](https://github.com/ivankuznetsov/hive/pull/126) | 2026-05-24 14:51 BST | `e174ced7` | Added task-local `events.jsonl`, derived `status.md`, stage/agent lifecycle events, and review/plan event bracketing. | 16 files, +910 / -51 |
| [#131](https://github.com/ivankuznetsov/hive/pull/131) | 2026-05-24 15:10 BST | `c0978cf3` | Rebuilt the red-status recovery detail screen with a safer, clearer recovery/open-in-agent surface and hardened file/log reads. | 19 files, +1,114 / -106 |
| [#127](https://github.com/ivankuznetsov/hive/pull/127) | 2026-05-24 15:30 BST | `aaffed10` | Added the full-screen read-only TUI info panel behind `i`, footer hinting, stage-specific details, and focused renderer coverage. | 14 files, +880 / -152 |
| [#129](https://github.com/ivankuznetsov/hive/pull/129) | 2026-05-24 16:35 BST | `80d35a0a` | Added global `claude.mode`, shared tmux/headless Claude launcher wiring, init/doctor/docs support, tmux review-session sharing, and stage parity fixes. | 71 files, +3,470 / -853 |
| [#136](https://github.com/ivankuznetsov/hive/pull/136) | 2026-05-24 16:50 BST | `bb482458` | Added this release-notes file and the first verified-batch wiki log entry after #129. | 2 files, +157 / -0 |
| [#134](https://github.com/ivankuznetsov/hive/pull/134) | 2026-05-24 17:14 BST | `3cd6ebc1` | Added the Telegram bot eval harness, typed scenario reports, judge support, and fixed waiting-question wording so bot prompts explicitly ask for input. | 32 files, +1,750 / -2 |
| [#135](https://github.com/ivankuznetsov/hive/pull/135) | 2026-05-24 17:44 BST | `4b3d934d` | Added SQLite-backed token usage capture, profile extractors, TUI footer/matrix views, docs, and a CI cleanup flake fix for bot tmpdirs. | 40 files, +1,922 / -38 |

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
tmux session across Claude reviewers while keeping non-Claude reviewers
separate.

### Release Notes Checkpoint

PR #136 recorded the first verified merge notes after the #121-through-#129
batch was merged. This kept the operator-facing merge evidence and line-change
scoreboard in the repo before the later eval and usage PRs were handled.

### Telegram Bot Eval Harness

PR #134 added an opt-in `test/eval/` harness and `bin/hive-eval` runner for the
Telegram bot. The harness drives the real supervisor through fake Telegram,
status, and child-process boundaries, writes structured JSON reports, and can
run judge-backed scenario checks. During verification, scenario S2 exposed that
waiting-question notifications did not clearly ask the user to provide input;
the production bot text and assertion were updated before merge.

### Token Usage Observability

PR #135 added hive-driven token usage capture at the agent spawn boundary. The
reader thread extracts profile-specific usage events for Claude, Codex, and Pi;
`Hive::UsageDb` stores rows in SQLite; and the TUI now shows scoped totals in
the footer plus a full-screen `T` token matrix. The PR also documented the
capture boundary in `wiki/token-usage.md`.

## Verification Record

- All eight PRs in the verified batch are `MERGED` on GitHub with the merge commits listed above.
- `gh pr list --state open --json number,title,url` returned `[]` after PR #135 merged.
- Local `main` was fetched and fast-forwarded to `origin/main` after #134 and #135.
- PR #129 was rebased onto the then-current `origin/main`, fixed, pushed with `--force-with-lease`, and merged only after GitHub checks passed.
- PR #134 was rebased onto the then-current `origin/main`, fixed, pushed with `--force-with-lease`, marked ready, and merged only after GitHub checks passed.
- PR #135 was rebased onto the then-current `origin/main`, fixed, pushed with `--force-with-lease`, marked ready, and merged only after GitHub checks passed.

Local verification highlights:

- PR #129 final stack:
  - `bundle exec rake test`: 3334 runs, 11930 assertions, 0 failures, 0 errors, 2 skips.
  - `CI=true bundle exec rake coverage`: gate passed, 98.72% line coverage, 87.99% branch coverage, 3334 runs, 11926 assertions, 0 failures, 0 errors, 4 skips.
- PR #134 final stack:
  - `bundle exec ruby -Itest -Ilib test/unit/bot/notification_builders_test.rb`: 19 runs, 67 assertions, 0 failures, 0 errors.
  - Eval support plus S1/S2/S4/S5 scenario tests: 26 runs, 95 assertions, 0 failures, 0 errors.
  - `bundle exec rubocop`: 399 files inspected, no offenses.
  - `bundle exec rake test`: 3334 runs, 11934 assertions, 0 failures, 0 errors, 2 skips.
  - `bin/hive-eval --scenario s3_noise --no-judge --report tmp/hive-eval-s3.json` still exited 1 as the documented baseline S3 proactive-notification failure.
- PR #135 final stack:
  - Focused token usage tests: 28 runs, 89 assertions, 0 failures, 0 errors.
  - Changed-area TUI/agent tests: 643 runs, 2405 assertions, 0 failures, 0 errors.
  - `bundle exec rake test`: 3382 runs, 12115 assertions, 0 failures, 0 errors, 2 skips.
  - `TESTOPTS=--seed=10074 bundle exec rake coverage`: gate passed, 98.62% line coverage, 87.53% branch coverage, 3382 runs, 12115 assertions, 0 failures, 0 errors, 2 skips.
  - `bundle exec rubocop`: 410 files inspected, no offenses.

GitHub verification highlights:

- PR #134 passed `rake test (Ruby 3.4)`, `rubocop`, `brakeman`, `bundler-audit`, and all install-smoke jobs before merge.
- PR #135 initially failed the GitHub coverage-backed Ruby test on a `Dir.mktmpdir` cleanup race in `HiveBotLifecycleTest#test_stop_terminates_live_pid_and_removes_pid_file`.
- PR #135 was fixed with `test(bot): tolerate tmpdir cleanup races`, rerun locally with the failing seed, pushed, and then passed all GitHub checks before merge.
- The first PR #129 `verify-release.sh` job got stuck in the `Install jq` step, so that install-smoke run was cancelled and rerun; the rerun completed successfully before merge.

## Lines Changed Scoreboard

Verified-batch totals:

- 8 PRs
- 306 file-touches
- 21,589 insertions
- 1,552 deletions
- 23,141 total changed lines
- Net growth: +20,037 lines

Per-PR stats:

| Rank by churn | PR | Files | Insertions | Deletions | Total changed | Net |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | #121 coverage gate | 112 | 11,386 | 350 | 11,736 | +11,036 |
| 2 | #129 global Claude mode | 71 | 3,470 | 853 | 4,323 | +2,617 |
| 3 | #135 token usage | 40 | 1,922 | 38 | 1,960 | +1,884 |
| 4 | #134 bot eval harness | 32 | 1,750 | 2 | 1,752 | +1,748 |
| 5 | #131 red-status detail | 19 | 1,114 | 106 | 1,220 | +1,008 |
| 6 | #127 info panel | 14 | 880 | 152 | 1,032 | +728 |
| 7 | #126 events | 16 | 910 | 51 | 961 | +859 |
| 8 | #136 release notes checkpoint | 2 | 157 | 0 | 157 | +157 |

Top-level churn:

| Area | File-touches | Changed lines | Insertions | Deletions |
| --- | ---: | ---: | ---: | ---: |
| `test/` | 194 | 17,750 | 17,082 | 668 |
| `lib/` | 64 | 4,430 | 3,688 | 742 |
| `wiki/` | 31 | 523 | 431 | 92 |
| `docs/` | 5 | 261 | 223 | 38 |
| `bin/` | 1 | 51 | 51 | 0 |
| `Rakefile` | 2 | 48 | 48 | 0 |
| `templates/` | 2 | 41 | 38 | 3 |

Top files by aggregate churn:

| File | Touches | Changed lines | Insertions | Deletions |
| --- | ---: | ---: | ---: | ---: |
| `test/unit/tui/bubble_model_test.rb` | 4 | 1,485 | 1,406 | 79 |
| `lib/hive/claude_launcher.rb` | 1 | 796 | 796 | 0 |
| `test/unit/bot/supervisor_test.rb` | 1 | 788 | 783 | 5 |
| `test/unit/commands/daemon_test.rb` | 1 | 597 | 597 | 0 |
| `test/support/coverage.rb` | 1 | 524 | 524 | 0 |
| `test/unit/stages/review/run_reviewers_test.rb` | 2 | 455 | 448 | 7 |
| `lib/hive/stages/brainstorm_tmux.rb` | 1 | 410 | 63 | 347 |
| `lib/hive/stages/review.rb` | 2 | 400 | 288 | 112 |
| `test/unit/tui/update_test.rb` | 4 | 348 | 338 | 10 |
| `test/unit/tui/views/red_status_detail_test.rb` | 2 | 346 | 310 | 36 |

Fun stats:

- The test suite took 17,750 of 23,141 changed lines, about 77% of the verified batch.
- PR #121 alone contributed 11,386 insertions, about 53% of all additions.
- The two late observability/testing PRs (#134 and #135) added 3,672 insertions with only 40 deletions.
- The biggest new production file remains `lib/hive/claude_launcher.rb` at 796 lines.
- The biggest cleanup by deletion count remains `lib/hive/stages/brainstorm_tmux.rb`, which lost 347 lines while the shared launcher took over.
- The busiest file was `test/unit/tui/bubble_model_test.rb`: 1,406 additions and 79 deletions across four PRs.

## Same-Day Context

PR #125 (`feat(drop): hard-delete tasks via Shift+X and hive drop`) was already
merged on 2026-05-24 12:51 BST as `c03546e1` before this ordered batch began.
Its stat was 33 files, +2,428 / -222.

If #125 is counted together with the verified batch, the same-day visible total
becomes 339 file-touches, 24,017 insertions, 1,774 deletions, 25,791 total
changed lines, and net growth of +22,243 lines.
