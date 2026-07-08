## [2026-07-08T01:41:24Z] e2e - reject symlinked replay runs roots

**Action:** Hardened `bin/hive-e2e replay` so the configured `HIVE_E2E_RUNS_DIR` root is part of the symlink-free artifact chain before a stored `repro.sh` can be executed. A symlinked runs root now reports `error_kind: "unusable_repro"` with exit `78` instead of following the root to an executable script outside the intended runs tree.

**Coverage:** Added `test_replay_symlinked_runs_root_emits_json_artifact_error_when_requested` to `test/e2e/lib/hive_e2e_binary_test.rb`, and refreshed [[e2e]] / [[testing]] contract wording. Did not run `qmd update` or `qmd embed`.
