---
title: Reuse native OpenCode login for hermetic launches
type: fix
source: lib/hive/agent_profiles.rb
created: 2026-08-25
tags: [opencode, authentication, isolation, setup]
---

Hive now resolves a valid native OpenCode `auth.json` as the credential source
when an OpenCode project route does not explicitly select a credential file or
environment variables. The existing hermetic launch boundary copies that file
into its private XDG data home with owner-only permissions and removes the copy
after the invocation; no token is written into project config or durable Hive
state. Explicit project credential sources remain authoritative.

The profile regression test joins the setup-visible native login state to the
runtime lookup contract and pins the explicit-environment precedence rule.
