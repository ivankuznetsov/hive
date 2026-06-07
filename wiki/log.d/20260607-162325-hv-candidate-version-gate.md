## [2026-06-07T16:23:25Z] cli/install — gate hv fallback candidates by Hive CLI version contract

**Action:** Tightened the `bin/hv` Apache Hive collision fallback so each candidate must return a strict bare `X.Y.Z` first line from `--version` before it can be execed. Added focused unit coverage with a fake XDG `hive` that reports Apache-style `Hive 4.0.0`; `hv` now skips it and delegates to a later valid Hive CLI candidate. Updated the `HIVE_BIN_OVERRIDE` fixture to mimic the same version contract. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[operating]]
- [[testing]]
- [[gaps]]
