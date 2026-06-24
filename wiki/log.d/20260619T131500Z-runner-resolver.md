---
date: 2026-06-19
slug: runner-resolver
pages: [commands/run, modules/workflows, stages/agent, testing]
---

Wired `hive run` stage dispatch through `Hive::Stages::Resolver`. The resolver
keeps coding stage names authoritative and lazy-requires their bespoke runners,
then falls back to the generic [[stages/agent]] runner for descriptor stages with
`kind: :agent`. Unknown stages retain the existing `Hive::StageError` message.

Updated [[commands/run]] and [[modules/workflows]] to document name-first coding
precedence and descriptor fallback dispatch, refreshed [[stages/agent]], and added
the new runner tests to [[testing]].
