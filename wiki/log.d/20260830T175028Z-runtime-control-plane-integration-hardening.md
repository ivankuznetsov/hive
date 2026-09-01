---
title: Harden SQLite control-plane integration boundaries
date: 2026-08-30
tags: [runtime-control-plane, sqlite, registry, patrol, workflow-packages, tests]
---

The post-cutover integration pass removed the remaining implicit file-runtime
test worlds and fixed the production seams they exposed. Global project YAML
remains authoritative, while register, unregister, and stale-registration
pruning now refresh the activated `projects` SQL projection without creating a
database before activation. Daemon recovery and command/module readers open
their SQL repositories lazily so observation and dry-run paths do not invent a
runtime authority.

Managed Honeycomb task migration now prunes dispatch recovery through the same
database that owns its task lease, rather than assuming the file-backed managed
store owns SQLite. Patrol's synthetic review workspaces no longer require a
task lease, while real workflow agents still publish child PID identity only
under their held lease. Patrol usage telemetry again attributes a profile-less
adapter to the configured ordinary, architecture-review, or architecture-fix
agent instead of recording the stage name as an agent.

Tests now provision registered projects, stable task subjects, and explicitly
migrated temporary databases where those contracts are relevant. The deletion
inventory also accounts for the net line delta in modified production files
outside the replacement list, so moving code into an existing file cannot evade
the ceiling; the final exact receipt is recorded by the deletion contract.
