# JSON 3.1.0 web lockfile synchronization

**Action:** Synchronized `web/Gemfile.lock` after `agent-cli-runtime` widened
its JSON upper bound to admit JSON 3.1.0.

The Rails bundle now records the changed path-gem dependency and JSON 3.1.0.
It also locks Rails 8.1.4: Rails 8.1.3.1 called `JSON.parse` with a positional
options hash, but JSON 3 accepts parser options as keywords, breaking encrypted
session reads. Resolving the constraint additionally upgrades the web-only
RuboCop entry from 1.87.0 to 1.92.0, which drops its JSON 2.x-only requirement.
This prevents both frozen bundle setup failures and Rails session failures.

**Refreshed pages:** [[dependencies]]
