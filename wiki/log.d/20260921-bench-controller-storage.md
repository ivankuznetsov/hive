Bench runner controller storage now lives in a per-cell `controller-home`
directory beside the candidate target and is mounted at `/opt/hb/hive-home`.
Candidate launchers' recursive workspace ownership changes cannot alter the
runtime database or its private parent. The sealed controller establishes root
ownership and invokes the pinned Hive runtime's explicit
`RuntimeControlPlane::Installation.setup` before any provider preflight or stage
action. Setup preserves an existing installation; malformed storage fails the
cell before provider spend.

Execute/review resumes retain controller storage. A fresh generation archives
the previous controller home rather than reusing its attempts. Legacy resumes
without the separate controller home fail closed and need fresh generation.
Focused coverage: `test/unit/bench_harness/controller_storage_test.rb`.

The controller exports normalized OpenCode token totals on stage-script exit to
read-only, timestamped receipts in a separate `usage-export` mount. Receipts
contain only model names and billing buckets; the private runtime database stays
inside controller custody. Retries publish cumulative snapshots, and the host
reads the latest snapshot without adding previous exports or duplicate stream
events. Missing or failed exports are explicitly unavailable. Historical cells
without an export directory retain the old `usage.db` fallback. Coverage uses
the real runtime database through `UsageDb.record!` in
`test/unit/bench_harness/controller_usage_test.rb`.
