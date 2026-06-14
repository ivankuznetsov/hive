# bench-submit default seam coverage audit

Refreshed LLM wiki coverage after commit `90aa0501` added tests for the
default `Hive::Commands::BenchSubmit` seams. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "bench submit default seams coverage gate
hive-bench Brakeman"` returned no indexed hits; the configured master wiki had
only the general [[learnings]] reminder to use array-form `system()` /
`Open3.capture3()` for user-influenced subprocess argv.

Inspected the committed diff plus `lib/hive/commands/bench_submit.rb`,
`test/unit/commands/bench_submit_test.rb`, `config/brakeman.ignore`,
[[commands/bench-submit]], [[testing]], and [[gaps]]. Updated stale wording
that still described the command tests as only injected-seam coverage. The
suite now also exercises the default local secret scanner, JSON/text reporter,
`run_git`, extractor invocation against a stub `harness/extract.rb`, and PR
opener through stub `git`/`gh` binaries. The live gap remains: no in-tree
artifact proves a real `HIVE_BENCH_PATH` checkout submission, generated corpus
validation, push, or GitHub PR. No new page was needed, so [[index]] page
coverage stayed at 78. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bench-submit]]
- [[testing]]
- [[gaps]]
