---
title: Route OpenCode artifact readers through typed permissions
type: fix
source: lib/hive/stages/artifacts.rb
created: 2026-08-25
tags: [artifacts, opencode, permissions, outcome-evidence]
---

OpenCode inference and reviewer roles in `7-artifacts` now use the standard
OpenCode permission adapter. Their task and implementation roots reach the
prepared invocation through the typed read-only overlay, while the legacy
`allowed_tools` and `disallowed_tools` channels remain unset. This prevents a
valid OpenCode artifacts run from failing before launch with
`outcome_evidence_invalid`.

The owning artifacts-stage test covers both read-only roles and asserts the
complete launch boundary: read-only mode, exact additional read roots, no write
roots or edit/shell patterns, and no legacy tool arrays.
