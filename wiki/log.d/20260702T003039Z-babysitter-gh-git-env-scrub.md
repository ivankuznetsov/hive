## [2026-07-02T00:30:39Z] babysitter - scrub Git env before gh dry-run passthrough

**Action:** Fixed patrol finding `command-bin-hive-babysitter-stub-gh-1` by hardening `bin/hive-babysitter-stub-gh` before it execs a real allowlisted `gh` read. The stub already scrubbed gh/proxy/config environment; it now also deletes Git child-process seams (`GIT_CONFIG*`, `GIT_TRACE*`, `GIT_EXEC_PATH`, `GIT_EXTERNAL_DIFF`, `GIT_SSH*`, `GIT_ASKPASS`, `SSH_ASKPASS`, `GIT_PROXY_COMMAND`, and `GIT_PAGER`) so real `gh` cannot hand them to its internal git probes.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` so the gh env-scrub regression records those Git vars as unset, and added a focused `gh pr view` passthrough test whose fake real `gh` runs `git status` and proves an inherited `GIT_TRACE` file is not created while the command still reaches real `gh`.

**Verified:** `ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[testing]]
