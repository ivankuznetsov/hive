# hive bench submit — corpus producer for hive-bench

Added `hive bench submit SLUG` (`lib/hive/commands/bench_submit.rb`, wired in
`lib/hive/cli.rb`): extracts a `9-done` task into a hive-bench corpus entry and
opens a submission PR. Thin orchestration over hive-bench's `harness/extract.rb`
(located via `HIVE_BENCH_PATH`) plus a local secret/PII preflight that aborts
before opening a PR. hive depends on hive-bench only as a producer; never the
reverse. Part of the hive-bench benchmark (plan U6).
