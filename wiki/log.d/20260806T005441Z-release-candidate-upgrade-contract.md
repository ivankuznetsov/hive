---
title: Align the hosted upgrade contract with current migrations
type: change
module: release-candidate
created: 2026-08-06
tags: [release-candidate, upgrade, migration, macos, sandbox]
---

The historical v0.4.1 qualification row now recognizes the explicit migrations
performed by current Hive: bench default binding, registry identity enrichment,
doctor v2 replacement, and the named additive status-condition projection
fields. User task identity, contents, stage, dependencies, and markers remain
protected, and the second migration run still permits no changes.

The macOS deny-default profile now permits writes only to the literal
`/dev/null` device in addition to its existing run-root write boundary. The
ordinary macOS install smoke opens that device under the exact profile, covering
the RubyGems resolver behavior that the full hosted candidate exposed.
