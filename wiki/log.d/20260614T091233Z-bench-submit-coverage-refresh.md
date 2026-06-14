# bench-submit command/API coverage refresh

Refreshed LLM wiki command/API coverage after commit `ef47b9c0` added
`hive bench submit SLUG [--project NAME]`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first; `qmd search "bench submit hive bench command
corpus"` returned no prior indexed context and the configured master wiki path
had no matching hits. Inspected the committed diff plus
`lib/hive/cli.rb`, `lib/hive/commands/bench_submit.rb`,
`test/unit/commands/bench_submit_test.rb`, and adjacent command/testing wiki
pages. Tightened [[commands/bench-submit]] to the current source behavior,
added the command to [[cli]], [[commands]], [[testing]], and [[gaps]], bumped
[[index]] page metadata to 78 pages, and recorded the missing live
hive-bench/`gh pr create` smoke evidence. Did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[commands/bench-submit]]
- [[cli]]
- [[commands]]
- [[testing]]
- [[gaps]]
- [[index]]
