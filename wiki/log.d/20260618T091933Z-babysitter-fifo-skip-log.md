# babysitter FIFO skip-log guard

**Action:** Hardened the dry-run `git` / `gh` stub skip-log path after a patrol finding showed that opening a FIFO `HIVE_BABYSITTER_DRY_RUN_LOG` for write could block before the existing post-open regular-file check ran. Read `.llm-wiki/config.json`, searched QMD and the configured master wiki path, then checked [[commands/babysit]], [[modules/babysitter]], [[testing]], and the previous skip-log hardening fragment before changing code.

**Result:** `bin/hive-babysitter-stub-git` and `bin/hive-babysitter-stub-gh` now preflight existing skip-log targets with `File.lstat`, require regular files owned by the current uid before open, open with `File::NOFOLLOW | File::NONBLOCK`, and keep the post-open `fstat` guard for races. FIFO, symlink, device, and ownership failures still warn while the command remains skipped.

**Coverage:** Added `test_stubs_refuse_fifo_skip_log_without_hanging` in `test/unit/babysitter/dry_run_env_test.rb`; it uses a FIFO log path for both stubs and asserts they exit successfully with warning/skip stderr instead of hanging. Refreshed [[commands/babysit]], [[modules/babysitter]], and [[testing]]. No new wiki page was needed, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.
