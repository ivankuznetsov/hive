## [2026-06-08T21:42:25Z] test - harden tmux runner timeout harness

**Action:** Rebased PR #420 onto current `origin/main` and investigated the red `rake test (Ruby 3.4)` job. The failure was `TmuxRunnerTest#test_send_prompt_times_out_when_enter_submit_hangs`: CI timed out during fake `load-buffer` Ruby startup before reaching the intended hanging `send-keys` assertion. Swapped that fake tmux script to a lightweight shell script and `exec sleep 5` for the `send-keys` branch, keeping setup commands under the timeout budget and avoiding thread exception noise after the timeout kill.

**Verified:**
- `bundle exec ruby -Itest test/unit/tmux_runner_test.rb`
- `bundle exec ruby -Itest test/e2e/lib/hive_e2e_binary_test.rb`
- `bundle exec ruby -Itest test/unit/tui/state_source_test.rb`
- `bundle exec rake test`
- `bundle exec rubocop --format simple bin/hive-e2e test/e2e/lib/hive_e2e_binary_test.rb test/unit/tmux_runner_test.rb`

**Refreshed pages:**
- [[testing]]
