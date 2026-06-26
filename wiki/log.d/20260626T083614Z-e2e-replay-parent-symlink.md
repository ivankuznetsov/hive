## [2026-06-26T08:36:14Z] e2e - reject symlinked replay artifact parents

**Action:** Hardened `bin/hive-e2e replay` so the selected run directory,
`scenarios` directory, scenario directory, and final `repro.sh` entry must not
be symlinks before replay execs the script. A symlinked scenario directory that
points at an outside executable `repro.sh` now reports `error_kind:
"unusable_repro"` with exit `78` instead of executing the outside script.
Added a focused regression in `test/e2e/lib/hive_e2e_binary_test.rb` and
refreshed [[testing]] coverage wording. Did not run `qmd update` or
`qmd embed`.
