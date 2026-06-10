## [2026-06-10T12:00:00Z] config — `hive init` patrol-mode default reverted to `medium`

**Action:** Reverted the `hive init` patrol-mode default (`Hive::Config::DEFAULT_PATROL_MODE`) from `low` back to `medium`, undoing PR #436. Only the patrol-**mode** default was reverted; the patrol-**reviewer** default (`patrol.review.reviewers` → `codex-native-review`, introduced by #440) was left untouched. Updated the constant + its comment in `lib/hive/config.rb`, reverted the init-default assertions in `test/unit/commands/init/prompts_test.rb` and `test/integration/init_test.rb` (renamed `test_interactive_patrol_mode_blank_defaults_to_low` → `_medium`; the no-explicit-knobs render now derives `timer`/`14400`), and corrected the `wiki/modules/config.md` prose. Explicit-mode tests (the `low` / mixed-case-`LOW` / mode-derivation-table cases) were intentionally preserved — `low` remains a valid mode, just not the default.

**Reasoning:** With the cheap native codex-review reviewer just merged (#440), per-cycle review cost is low, so scan **cadence** dominates cost again. `low`'s `new_commits` trigger fires on **every** commit, which on a high-velocity repo is more frequent (and costlier) than `medium`'s 4h timer. `medium`'s steady cadence is therefore the better default.

**Refreshed pages:**
- [[modules/config]]
