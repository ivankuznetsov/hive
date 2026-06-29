## [2026-06-29T08:46:17Z] babysitter - scrub gh passthrough transport env

**Action:** Fixed the dry-run `gh` stub exec seam for allowlisted reads. The
stub already scrubbed host/config selectors before execing real `gh`, but still
inherited generic proxy and TLS trust variables, which could redirect
credential-bearing GitHub API traffic. `bin/hive-babysitter-stub-gh` now deletes
upper/lower proxy variables plus `SSL_CERT_FILE` and `SSL_CERT_DIR` before
passthrough.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb`'s recording
fake-`gh` environment regression so `repo view owner/repo` proves the proxy and
TLS trust overrides are unset while `HOME` / `GH_CONFIG_DIR` remain fresh
temporary directories.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb -n '/gh_stub_scrubs_exec_influencing_environment/'`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[testing]]
