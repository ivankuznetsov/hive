## [2026-06-19T22:09:02Z] babysitter — skip git signature-verifying dry-run reads

**Action:** Hardened `bin/hive-babysitter-stub-git` so allowlisted history reads skip before invoking signature verification. `git log`, `git show`, and `git rev-list` now reject `--show-signature` and `--format` / `--pretty` values containing `%G`, because those paths can execute repo-local `gpg.program` during an otherwise read-only passthrough.

Added `test_git_stub_skips_signature_verification_before_local_gpg_program`, which signs a temporary commit with a fake local `gpg.program` marker helper and proves the dry-run stub logs/skips the dangerous reads before the helper can run.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]
