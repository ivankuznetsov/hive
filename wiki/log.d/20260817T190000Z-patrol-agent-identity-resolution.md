---
title: Document patrol agent identity resolution
date: 2026-08-17
tags: [patrol, refactor-patrol, config, model-routing]
---

Added an "Agent identity resolution" section to [[modules/patrol]]: ordinary
patrol launches route model/effort through `models.patrol` (registry parents
`patrol_review`/`patrol_fix`), while `RefactorPatrol::AgentIdentity` inherits
review from the **execute** identity and auto-fix from review. Documented the
operational consequences observed 2026-08-15..17 on the dogfood box: with
`execute.agent: codex` and no `refactor_patrol.agent`, every architecture
review/fix launch rode codex's exhausted subscription quota and died in
seconds; and a provider-switch override without an explicit `model:` fails
closed when the provider settings file exposes a non-concrete model value
(`claude-fable-5[1m]` in `.claude/settings.json`). Grounded in
`lib/hive/refactor_patrol/agent_identity.rb`,
`lib/hive/implementation_identity.rb` (`NativeDefaults`), and
`lib/hive/patrol/fixer.rb` launch sites.
