---
title: Babysitter gh config temp cleanup
type: log
created: 2026-07-11
tags: [babysitter, dry-run, gh, performance, test]
---

`Hive::Babysitter::DryRunEnv.with_env` now creates one empty `gh` config/home directory for the agent-command lifetime and removes it in its ensure cleanup. The `gh` launcher pins that directory into the shared stub, so allowlisted passthroughs remain isolated from caller/user configuration without leaking a uniquely named `/tmp` directory on every `exec`. `test/unit/babysitter/dry_run_env_test.rb` asserts that a successful passthrough leaves no config directory behind. Updated [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]; compiled [[log]] remains unchanged.
