## [2026-06-08T16:42:25Z] testing — cover pr_state error branches

**Action:** Fixed the PR #405 CI coverage gate by adding focused `Hive::Gh.pr_state` unit coverage for non-zero `gh pr view` failures and unparseable JSON responses. Refreshed [[testing]] and [[modules/gh]] so the documented `gh_test.rb` contract includes `pr_state` success/error parsing.

**Tests:**
- `bundle exec ruby -Itest test/unit/gh_test.rb`
- `bundle exec rake coverage`
