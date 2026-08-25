---
title: Scrub Hive's Ruby toolchain from native agent launches
type: fix
source: lib/hive/agent.rb
created: 2026-08-25
tags: [opencode, agent-runtime, environment, agent-cli-runtime]
---

The native OpenCode launch keeps the operator's environment instead of
rebuilding one, so `Process.spawn` no longer passes `unsetenv_others: true`
unless a runtime policy or `isolate_environment` asks for it. That handed the
agent Hive's own bundle context: `RUBYOPT`, `RUBYLIB`, `GEM_HOME`, `GEM_PATH`,
and the `BUNDLE_*`/`BUNDLER_*` variables reached the child, so any `ruby`,
`gem`, or `bundle` the agent ran inside the task repository resolved against
Hive's Gemfile rather than the project's.

`Hive::Agent::SCRUBBED_TOOLCHAIN_ENV_KEYS` now unsets those keys through
`SCRUBBED_CHILD_ENV`, alongside the existing `HIVE_SCREENOTE_BASE_URL`
blanking, for every profile and both spawn paths. The isolated and
runtime-policy paths already rebuilt their environment, so the unsets are
inert there.

CI caught the leak: `test/unit/opencode_agent_lifecycle_test.rb` drives a
fixture CLI whose `#!/usr/bin/ruby --disable-gems` shebang is a different Ruby
than the runner's bundled 3.4, so an inherited `RUBYOPT=-rbundler/setup` made
the fixture load RubyGems, warn about unbuilt extensions, and exit 1. Every
fixture-backed assertion then read as `:cli_failure`.

The independently callable permission compiler ships as `agent-cli-runtime`
0.2.4, which the native launch calls; see [[dependencies]] and
[[modules/agent]]. Related: [[log.d/20260825T180401Z-opencode-native-runtime]].
