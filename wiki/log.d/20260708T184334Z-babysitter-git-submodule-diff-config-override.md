## [2026-07-08T18:43:34Z] babysitter - neutralize config-selected submodule diff mode

**Action:** Closed the remaining half of patrol finding `command-bin-hive-4`. The argv guard added earlier only sees `--submodule=diff` / split `--submodule diff` on the command line; a worktree-local `diff.submodule=diff` (or `=log`) config selects the same nested-submodule diff expansion with no `--submodule` token in argv, so it slips past the argv scan while git still enters each submodule repo and runs its local diff drivers — the exec seam the top-level `--no-ext-diff --no-textconv` do not reach inside a nested submodule. `hardened_passthrough_argv` now injects `-c diff.submodule=short` alongside the existing gpg/core `-c` overrides, pinning the inert commit-hash summary format; the `-c` override outranks the worktree config.

**Coverage:** Updated `test/unit/babysitter/dry_run_env_test.rb` — the injected-override assertion and the `expected_real_invocation` helper now include `-c diff.submodule=short`, so every allowlisted git passthrough (including `diff`/`log`/`show`) is checked to carry the override.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `ruby -c bin/hive-babysitter-stub-git`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[testing]]
