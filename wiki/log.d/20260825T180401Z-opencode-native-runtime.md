---
title: Use OpenCode native state in Hive launches
type: fix
source: lib/hive/agent.rb
created: 2026-08-25
tags: [opencode, authentication, permissions, agent-runtime]
---

Hive OpenCode launches now use the operator's native config, plugins, project
discovery, session store, and `opencode auth login` in place. Hive no longer
redirects OpenCode into private XDG homes, copies `auth.json`, disables native
configuration, or owns an OpenCode-specific cleanup tree.

Workflow `read-only` and scoped policies remain per-run rather than mutating
native config. The shared OpenCode permission compiler supplies those rules
through `OPENCODE_PERMISSION`; provider API-key variables remain scrubbed
unless a project explicitly names `credential_env`. Run and sanitized export
continue to share one environment and retain requested-versus-observed route,
usage, timeout, cancellation, and malformed-output evidence.

The former Hive-only `agents.opencode.isolation` and `credential_file` keys are
removed. The standalone component's prepared-overlay API remains available to
independent consumers for compatibility, but Hive does not select it.
