## Web: wait on the golden path's durable PR gate

**Action:** Changed `web/test/e2e/golden_path_e2e.rb` to wait for the durable "Ready to open PR" result instead of first requiring a transient `execute` badge. The test still proves execute ran by inspecting the real implementation commit in the generated worktree.

**Root cause:** Hosted CI on PR #833 observed the task at `open-pr` before Capybara sampled the `execute` badge. The daemon had successfully traversed execute; the browser assertion was racing a valid fast transition.

**Verified:** `cd web && BUNDLE_PATH=/home/asterio/.local/share/gem /home/asterio/.local/share/gem/ruby/3.4.0/bin/bundle exec bin/rails test test/e2e/golden_path_e2e.rb` (1 run, 13 assertions, 0 failures, 0 errors).

**Links:** [[testing]]
