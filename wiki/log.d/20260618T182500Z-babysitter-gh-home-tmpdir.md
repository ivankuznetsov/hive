## [2026-06-18T18:25:00Z] babysitter - point gh dry-run HOME at an empty tmpdir, not /dev/null

**Action:** Fixed a regression in `bin/hive-babysitter-stub-gh`: before exec it set `HOME=/dev/null`. Unlike git (which honors `GIT_CONFIG_GLOBAL=/dev/null` / `GIT_CONFIG_NOSYSTEM` as an explicit "no config" sentinel), gh has no such escape hatch — it resolves its config dir as `GH_CONFIG_DIR` -> `XDG_CONFIG_HOME/gh` -> `$HOME/.config/gh` and then reads/creates files under it, so `HOME=/dev/null` left gh resolving `/dev/null/.config/gh` and failing with `ENOTDIR`. The stub now points both `HOME` and `GH_CONFIG_DIR` at a fresh empty `Dir.mktmpdir` directory: gh finds no attacker-controlled config to honor (the real `~/.config/gh` is out of reach) yet still has a writable location for its own state. The dir is intentionally not cleaned up (passthrough execs over the stub, which never regains control); it is empty and swept by the OS tmp reaper.

**Coverage:** Reworked the gh env-scrub regression in `test/unit/babysitter/dry_run_env_test.rb` to assert every other exec-influencing var is `<unset>` while `HOME` and `GH_CONFIG_DIR` are real, fresh, empty directories distinct from the caller-supplied `evil-home` / `evil-gh-config` and never `/dev/null`.

**Verified:** `ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (16 runs, 0 failures); `rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb` clean.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]]
