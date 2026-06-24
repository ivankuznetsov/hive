## [2026-06-21T10:11:17Z] e2e - reject symlinked replay repro artifacts

**Action:** Hardened `bin/hive-e2e replay` so `repro.sh` must be a regular executable directory entry before the no-shell `exec`; symlinks now report `error_kind: "unusable_repro"` with exit `78` instead of following the target. Added focused coverage in `test/e2e/lib/hive_e2e_binary_test.rb` for an executable symlinked repro and refreshed [[e2e]] / [[testing]] contract wording. Did not run `qmd update` or `qmd embed`.
