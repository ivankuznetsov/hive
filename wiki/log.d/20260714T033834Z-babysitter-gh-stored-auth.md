## [2026-07-14T03:38:34Z] babysitter — preserve stored gh auth in dry-run reads

**Root cause:** `DryRunEnv` still captured the parent gh config directory, but the shared `gh` stub deleted that trusted handoff and replaced both `HOME` and `GH_CONFIG_DIR` with a fresh empty directory. With token environment variables absent, real `gh` therefore lost the `hosts.yml` host/account context needed to retrieve the operator's stored/keyring credential, so allowlisted reads failed authentication.

**Change:** `DryRunEnv` now resolves and validates the parent config directory and `hosts.yml` as current-uid, non-group/world-writable entries, copies only `hosts.yml` into a private run-scoped temp directory, pins that view through the launcher, and removes it on exit. The stub validates the pinned directory before using it for `HOME` and `GH_CONFIG_DIR`; executable `config.yml` settings and command-local home/config overrides remain excluded, with an empty temp directory retained as the fail-closed fallback.

**Coverage:** Strengthened `test/unit/babysitter/dry_run_env_test.rb` to prove the view contains only the trusted host/account file, excludes `config.yml`, resists command-local handoff replacement, and is cleaned up. Added `test/smoke/live_gh_dry_run_auth_smoke_test.rb`, which removes all token env variables and exercises stored authentication through the wrapper with the real `gh` binary. The broader full-agent dry-run uncertainty remains recorded in [[gaps]].

**Verified:** focused unit regression; remaining dry-run unit cases and the large allowlist matrix; real-gh stored-auth smoke; RuboCop and wiki log validation.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]]
