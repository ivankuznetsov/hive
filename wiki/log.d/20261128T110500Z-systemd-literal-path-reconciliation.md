---
title: Preserve exact LLM-wiki scheduler paths
date: 2026-11-28
tags: [llm-wiki, init, systemd, scheduler]
---

Scheduled wiki refreshes now accept checkouts with spaces and literal backslashes. New services mark their path grammar with `X-HivePathEncoding=literal-v1`. Startup upgrades a historical unit only when its basename, command and project evidence identify one checkout. Conflicting destinations keep their service, timer, link and shared runtime. Proven migrations preserve timer enablement and record pending work before changing files.

Init and CLI integration tests exercised a rejected install, a mixed-version startup migration, an idle retry and strict observation routes. The real Linux user-manager gate verified that the executable condition passed and that the recorder received the exact working directory and three arguments for the space-containing checkout. The probe also exercised shell and systemd metacharacters and verified cleanup.

The broad local checkpoint used `TESTOPTS='--seed=58143' HIVE_TEST_WORKERS=2 bin/test --all` with Ruby 3.4.7 and Bundler 2.7.2. Both the implementation at `663cec92a1` and its untouched baseline at `185a3ca1b9` reported 29 failures and 74 errors. All 103 baseline cases reproduced on the implementation. For example, `ReviewGrantCommandTest#test_operator_decision_is_durable_applied_and_identically_replayed` raised `Hive::AgentSupport::OperatorAuthority::Denied` on both revisions under the managed-agent policy. The scheduler, init, CLI and declared real-manager checks passed.
