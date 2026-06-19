## [2026-06-18T17:36:32Z] babysitter - block gh dry-run host selectors

**Action:** Hardened `bin/hive-babysitter-stub-gh` so allowlisted dry-run reads skip host-redirection selectors before passthrough: `--hostname`, host-qualified `-R` / `--repo` values including glued `-R...`, host-qualified `repo view` operands, PR URL operands, full URL `api` operands, and `auth status` `-h` forms. Allowed `gh` reads now also scrub `GH_HOST`, `GH_REPO`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN`, gh config selector env, pager/browser/editor env, and neutralize `HOME` before exec.

**Coverage:** Added focused `test/unit/babysitter/dry_run_env_test.rb` regressions proving those host selectors skip without reaching the fake real `gh`, while non-host `--repo=owner/repo` reads still pass. Extended the gh env-scrub test to record the new host/config env behavior. Refreshed [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]; no new wiki page was needed.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]], [[gaps]]
