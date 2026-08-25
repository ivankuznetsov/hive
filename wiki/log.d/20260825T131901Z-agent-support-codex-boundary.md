---
title: Codex support boundary
module: agent-support
date: 2026-08-25
---

- Moved Codex skill inventory, setup, managed runtime, evidence permissions,
  native reviewer, model/effort parsing, and invocation rules under
  `Hive::AgentSupport::Codex` with lazy facets.
- Kept generic process, schema-write, artifact-admission, credential-write,
  and workflow-transition authority in core. `Hive::Reviewers::Runtime` owns
  native-review subprocess and findings-file custody; the provider reviewer
  receives that runtime and its stage host instead of requiring orchestration.
- Reused one Ruby skill-policy mixin and lazy verifier/model callable factories
  across Pi, OpenCode, and Codex. The Codex phase is smaller than its exact
  OpenCode checkpoint in both raw and substantive production Ruby lines.
