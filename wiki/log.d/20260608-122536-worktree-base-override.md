## [2026-06-08T12:25:36Z] worktree — HIVE_WORKTREE_BASE override stops tests seeding real ~/Dev

**Action:** Centralized the default worktree-root fallback behind `Hive::Worktree.worktree_base` (`ENV["HIVE_WORKTREE_BASE"] || File.expand_path("~/Dev")`) and `Hive::Worktree.default_worktree_root(project_name)` (`<base>/<project>.worktrees`). Replaced the seven hardcoded `File.expand_path("~/Dev/#{X}.worktrees")` fallbacks (`worktree.rb` ×2, `task.rb`, `diagnosis_agent.rb`, `stages/execute.rb`, `stages/review.rb`, `commands/init.rb`) with the shared helper; behavior is identical when the env var is unset. The test suite now sets `HIVE_WORKTREE_BASE ||= Dir.mktmpdir("hive-test-wtbase")` in `test_helper.rb` and cleans it via `Minitest.after_run`, so worktree-creating tests no longer leak `hive-test<...>.worktrees` dirs into the developer's real `~/Dev` (1402 had accumulated). Extended `rake test:clean_tmp` to also sweep the legacy `~/Dev/hive-test*.worktrees` leak (the `hive-test` prefix cannot match the production `~/Dev/hive.worktrees`).

**Refreshed pages:**
- [[modules/worktree]]
