## [2026-06-08T18:10:49Z] wiki — refresh leading JSON falsey relocation coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `34346c6d` changed `bin/hive` and `test/integration/cli_version_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "leading json false falsey option Thor boolean bin hive"` returned no indexed hits, and the configured master wiki path had no matching context. Inspected the committed diff plus current `bin/hive`, `test/integration/cli_version_test.rb`, [[cli]], [[commands]], [[testing]], and [[gaps]]. Documented that leading Thor-falsey `--json=false` / `--json=f` forms are relocated after the subcommand like `--no-json` / `--skip-json`, so `hive --json=false status` dispatches like `hive status --json=false` instead of printing top-level usage. Page coverage did not change, so [[index]] was left unchanged. The packaged executable smoke gap remains open. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[testing]]
- [[gaps]]
