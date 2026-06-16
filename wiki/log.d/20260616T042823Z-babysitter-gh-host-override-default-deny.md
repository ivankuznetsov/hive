## [2026-06-16T04:28:23Z] babysitter - default-deny every dry-run gh host override

**Action:** Closed the residual host-selector bypasses in `bin/hive-babysitter-stub-gh`. The gate classifies the *stripped* argv but `exec`s the *original*, so the prior fix (rejecting only leading `--hostname` globals) still let host overrides through: a host-qualified `--repo`/`-R`/`--repo=` value (`HOST/OWNER/REPO` or a URL) and a command-position `--hostname`/`--hostname=` on `gh api` / `gh auth status` both reached the real gh against an agent-chosen host. Added a `host_override?(argv)` check that scans the whole argv (so leading *and* trailing forms are caught) and a `repo_value_selects_host?` helper that allows only the bare `OWNER/REPO` slug (exactly one slash, no scheme). Extended `auth_status_read_only?` with `auth_status_selects_host?` so the short `-h <host>` / `-h<host>` and clustered `-ah` hostname selectors are skipped too — `-h` stays scoped to `auth status` because it means `--help` on other gh subcommands.

**Coverage:** Extended `test/unit/babysitter/dry_run_env_test.rb` with skip+log regressions for `gh auth status -h/--hostname/-ah`, host-qualified `--repo`/`-R` leading and trailing the subcommand (including the URL form), and command-position `gh api ... --hostname`. The previously passing `gh auth status -h github.com` / `-hgithub.com` cases now assert skipped.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (16 runs, 1110 assertions, 0 failures); `bundle exec rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb` (no offenses).

**Links:** [[modules/babysitter]], [[testing]]
