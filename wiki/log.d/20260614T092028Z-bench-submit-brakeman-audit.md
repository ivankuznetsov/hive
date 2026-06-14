# bench-submit Brakeman follow-up audit

Audited post-commit LLM wiki coverage after commit `c4e2cab5` changed
`lib/hive/commands/bench_submit.rb`, `config/brakeman.ignore`, and the
bench-submit wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; a QMD search for
bench-submit corpus coverage returned no exact indexed hits, and the configured
master wiki path had no matching `bench submit` / `hive-bench` context.
Inspected the committed diff plus
`lib/hive/commands/bench_submit.rb`,
`test/unit/commands/bench_submit_test.rb`, `config/brakeman.ignore`,
[[commands/bench-submit]], and [[testing]].

Verified the refreshed pages match the source: `hive bench submit` keeps
hive-bench extraction and `gh pr create` in argv-form subprocess calls, the
extractor now passes `ruby -I` and the harness path as separate argv elements,
and the remaining Brakeman ignore is documented as an array-form `Open3`
false positive for slug text used only in the PR title/body. [[gaps]] still
records the relevant uncertainty: no in-tree artifact proves a live
`HIVE_BENCH_PATH` submission, generated corpus validation, push, or GitHub PR.
No new wiki page was needed, so [[index]] page coverage stayed at 78. Did not
run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bench-submit]]
- [[testing]]
- [[gaps]]
