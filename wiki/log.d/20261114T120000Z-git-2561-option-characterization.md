---
date: 2026-11-14
type: test
---

`test/fixtures/babysitter/git_option_spellings.v1.json` now records git 2.56.1. The CI runner's `/usr/bin/git` moved to 2.56.1, so `dry_run_env_test` raised `characterize git version 2.56.1` and coverage shard 4 failed on every PR (#1649, #1650, #1651).

All 36 option cases were reproduced on git 2.56.1, built from the checksum-verified kernel.org tarball, using the test's own repo setup and classification. The same procedure first reproduced the recorded 2.56.0 cases byte-for-byte. Every 2.56.1 outcome is identical to 2.56.0.
