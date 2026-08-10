---
title: Harden PR-only digest review boundaries
type: change
tags: [digest, security, github, schema, review]
---

The first review fix pass hardened the PR-only digest without changing its
scope. Closed unmerged PR rows are ignored; Git C-quoted and space-containing
paths validate against authoritative file identities; evidence limits now stop
streaming `gh` output before oversized responses are materialized; malformed
registry rows produce discovery warnings; and every v2 warning requires a
repository scope.

Confidential PR evidence now reaches only a fail-closed Claude runtime policy
limited to private-run Read/Write access with isolated settings, MCP, and child
environment. Raw provider streams are not retained for digest runs. Changelog
validation also supports honest no-user-facing-change PRs, preserves Unicode
title comparisons, and includes an explicit implementation/fix/release/
migration acceptance proof. Unexpected runtime and delivery exceptions are
wrapped in the canonical `hive-digest` v2 error envelope.
