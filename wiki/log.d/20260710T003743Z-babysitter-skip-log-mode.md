## [2026-07-10T00:37:43Z] babysitter - enforce private modes on existing skip logs

**Action:** Fixed Hive patrol finding
`command-bin-hive-babysitter-skip-log-rb-1` by tightening the opened dry-run
skip-log descriptor to mode `0600` after its regular-file, owner, and link-count
checks. This closes the case where `File.open` appended sensitive skipped argv
to a pre-existing mode-`0644` file without changing its permissions.

**Coverage:** Added a focused regression in
`test/unit/babysitter/dry_run_env_test.rb` that pre-creates separate permissive
logs for the `git` and `gh` stubs, then verifies each stub appends the skipped
command and leaves the log at mode `0600`.

**Links:** [[commands/babysit]] · [[modules/babysitter]] · [[testing]]
