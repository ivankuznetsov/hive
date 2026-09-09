---
title: Review publisher dedupe probe honors configured GitHub invocation
date: 2026-08-30
tags: [review, github, config, timeout]
---

**Problem:** `Review::GithubPublisher.already_posted?` invoked `Hive::Gh.capture3` without `cfg`, so the duplicate-prevention `gh pr view` probe ignored `gh.network_timeout_sec` while the adjacent `gh pr comment` post honored it — the two halves of one publish decision ran on different invocation paths.

**Action:** Threaded `cfg` from `publish!` into `already_posted?` and onto the `gh pr view --json comments` call. The probe's fail-open behavior on command failure is unchanged (a failed probe still permits one post attempt, which then fails closed through the retry budget).

**Evidence:** `test/unit/stages/review/github_publisher_test.rb#test_already_posted_forwards_cfg_to_configured_github_invocation` asserts the `cfg:` kwarg reaches `Hive::Gh.capture3`; the focused publisher, review-unit, gh, and run-review integration suites pass.
