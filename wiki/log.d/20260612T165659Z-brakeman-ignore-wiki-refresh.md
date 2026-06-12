---
date: 2026-06-12
slug: brakeman-ignore-wiki-refresh
pages: [testing, gaps]
---

Post-commit wiki refresh after commit `83f0a800` added a Brakeman
false-positive ignore for the hivebox task log path and committed the earlier
PR #300 command/API wiki-refresh fragment. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search "brakeman registry laundered log path"`
returned only prior log context, and direct `rg` over the project and
configured master wiki found generic Brakeman dependency/convention coverage.

Inspected the committed diff plus current `config/brakeman.ignore`,
`web/app/controllers/tasks_controller.rb`,
`web/app/controllers/application_controller.rb`, `web/config/routes.rb`,
`web/test/integration/tasks_test.rb`, `.github/workflows/ci.yml`,
[[commands/web]], [[testing]], and [[dependencies]]. Verified the ignore
rationale against source: `params[:project]` is resolved by
`find_project!` from registered projects before `hive_state_path` is used,
the route constrains `:slug`, and `latest_log` additionally applies
`File.basename(params[:slug])` before joining under the registry-derived
log root.

Updated [[testing]] so the CI static-analysis surface includes the Brakeman
job and `config/brakeman.ignore` false-positive policy, and updated [[gaps]]
with source-file coverage for CI/security-tooling config plus the remaining
uncertainty that no focused regression test exercises the task-log route with
malicious project/slug shapes. Parsed `config/brakeman.ignore` as JSON and ran
the CI Brakeman command successfully:

```bash
bundle exec brakeman --force --no-pager --quiet --format github --ignore-config config/brakeman.ignore
```

Page count did not change, so [[index]] was not edited. Did not edit compiled
[[log]], and did not run `qmd update` or `qmd embed`.
