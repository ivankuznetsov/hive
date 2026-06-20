## [2026-06-20T08:22:59Z] babysitter — neutralize config-driven git signature verification in dry-run passthrough

**Action:** Closed a dry-run exec seam in `bin/hive-babysitter-stub-git`. The argv guard (`signature_verification_option?`) only skips `--show-signature` and `--format=`/`--pretty=` arguments carrying a literal `%G`, so a repo-local `.git/config` could still drive `git log`/`show`/`rev-list` to exec the local `gpg.<format>.program` two ways the argv never reveals: `log.showSignature=true` makes a plain `git log -1` verify, and a named `pretty.<name>=format:%G?` alias reached via `--pretty=<name>` smuggles the `%G?` placeholder in. `hardened_passthrough_argv` now injects `-c log.showSignature=false` plus blank `gpg.program` / `gpg.openpgp.program` / `gpg.x509.program` / `gpg.ssh.program` for those three subcommands; command-line `-c` outranks repo config, so even a surviving `%G?` cannot launch an attacker-controlled gpg binary. Verified empirically (git 2.x) that the blank gpg-program overrides stop the exec even under `gpg.format=ssh`, and that affected reads still exit 0.

**Tests:** Added `test_git_stub_neutralizes_config_driven_signature_verification` to `test/unit/babysitter/dry_run_env_test.rb` (config-driven `log.showSignature=true` plain read, plus `pretty.evil=format:%G?` on `log`/`show`/`rev-list`), confirmed it fails without the override. Updated the `expected_real_invocation` helper so existing `log`/`show`/`rev-list` passthrough assertions account for the new `-c` overrides. Full file green (25 runs); rubocop clean.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]
