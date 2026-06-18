## [2026-06-17T01:21:43Z] e2e - classify non-executable replay repro artifacts

**Action:** Fixed `bin/hive-e2e replay` so a stored `repro.sh` that exists but is not executable is reported as a deterministic replay artifact config failure instead of falling through to the generic outer error rescue. JSON callers now receive `error_kind: "unusable_repro"` with exit `78`. Added focused coverage in `test/e2e/lib/hive_e2e_binary_test.rb` and refreshed [[e2e]] / [[testing]] contract wording. Did not run `qmd update` or `qmd embed`.
