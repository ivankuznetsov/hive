# 2026-11-26 — Require `agent-cli-runtime ~> 0.2.5` in `hive.gemspec`

**Action:** Tightened Hive's runtime dependency on `agent-cli-runtime` from
`~> 0.2.4` to `~> 0.2.5` in `hive.gemspec`, `Gemfile.lock`, and
`web/Gemfile.lock` after `0.2.5` was published to RubyGems
(`sha256: cf78902ca78c9b6986fd5e386f36fc9fea7c307a604a068045a9eaf795d6b3eb`),
updated `test/unit/agent_cli_runtime_component_test.rb`, and updated
[[modules/agent_cli_runtime]]. This ensures packaged Hive installations resolve
a runtime containing both `:muse` and `:agy` profiles.
