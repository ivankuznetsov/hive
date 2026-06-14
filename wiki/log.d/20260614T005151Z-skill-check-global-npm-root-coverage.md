---
date: 2026-06-14
slug: skill-check-global-npm-root-coverage
pages: [commands/doctor]
---

Patched the post-rebase coverage gap from `origin/main` by adding focused
`test/unit/skill_check_test.rb` coverage for `Hive::SkillCheck::Pi.global_npm_root`.
The existing implementation already shells out to `npm root -g`, returns the
first stripped output line on success, returns nil for blank output, and fails
closed on timeout or subprocess errors. The new tests pin the success and blank
branches that were previously uncovered, restoring the root CI coverage gate
without changing production behavior.

Updated [[commands/doctor]] so the SkillCheck test inventory mentions global
npm-root handling. Verified with `bundle exec ruby -Itest test/unit/skill_check_test.rb`.
Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
