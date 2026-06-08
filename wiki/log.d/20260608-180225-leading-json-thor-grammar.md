## [2026-06-08T18:02:25Z] wiki — refresh leading JSON Thor grammar coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `b44579b7` changed `bin/hive` and `test/integration/cli_usage_error_json_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "leading JSON normalization CLI help rewrite hive"` surfaced existing [[gaps]] and [[log]] context, and the configured master wiki path had no separate pattern. Inspected the committed diff plus current `bin/hive`, `lib/hive/cli.rb`, `test/integration/cli_usage_error_json_test.rb`, `test/integration/cli_version_test.rb`, [[cli]], [[commands]], [[testing]], and [[gaps]]. Corrected the prior leading-JSON documentation so wrapper truthiness mirrors Thor: `--json`, `--json=true`, and `--json=t` are normalized, while `--json=1` and `--json=yes` are not. While verifying the cited focused tests, added the missing `require "json"` to `test/integration/cli_version_test.rb` so the wrapper test remains standalone-runnable. Page coverage did not change, so [[index]] was left unchanged. The packaged executable smoke gap remains open. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[testing]]
- [[gaps]]
