# JSON 3.1.0 web lockfile synchronization

**Action:** Synchronized `web/Gemfile.lock` after `agent-cli-runtime` widened
its JSON upper bound to admit JSON 3.1.0.

The Rails bundle now records the changed path-gem dependency and JSON 3.1.0.
Resolving that constraint also upgrades the web-only RuboCop entry from 1.87.0
to 1.92.0, which drops its JSON 2.x-only requirement. This prevents frozen web
bundle setup from failing before integration, system, and golden-path tests run.

**Refreshed pages:** [[dependencies]]
