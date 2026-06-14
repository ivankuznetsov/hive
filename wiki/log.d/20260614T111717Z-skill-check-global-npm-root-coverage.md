## [2026-06-14T11:17:17Z] testing — pin SkillCheck global npm root coverage

**Action:** Added deterministic unit coverage for `Hive::SkillCheck::Pi.global_npm_root`'s successful `npm root -g` parse path after the root CI coverage gate reported only `lib/hive/skill_check.rb:374-375` uncovered. The new `test/unit/skill_check_test.rb` case stubs `Open3.capture3("npm", "root", "-g")`, asserts the exact argv, and verifies the first output line is stripped and returned, making the 100% line coverage gate independent of whether a test environment happens to exercise a real global npm install. Updated [[testing]] to list `skill_check_test.rb` and its Pi npm-root coverage.

**Refreshed pages:**
- [[testing]]
