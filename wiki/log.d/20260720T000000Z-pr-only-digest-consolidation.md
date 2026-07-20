---
title: Unified PR-only daily digest
date: 2026-07-20T00:00:00Z
---

Replaced the shipped-task digest and the separate merged-PR source with one
canonical GitHub pipeline. Bare `hive digest` now selects every pull request
merged during the requested Europe/London day across registered repositories;
repeatable `--repo owner/name` values filter that registered scope. Hive task,
stage, completion, ship-time, matching, and pairing state no longer influence
digest selection or content.

Collection now fetches complete repository metadata and each qualifying PR's
body, raw diff, and paginated file identities through explicit-host GitHub REST
calls. Repository-atomic outcomes distinguish successful empty queries from
failures, partial results carry scoped warnings, and total collection failure
sends nothing. Raw evidence is private and ephemeral, fixed evidence ceilings
fail closed, and recognized secrets are redacted before agent-provider egress.

The generator proves evidence-to-fact-to-bullet coverage before Hive accepts
one significance sentence per project and concrete bullets for every PR.
Generated text is redacted again before dry-run or Telegram delivery. Optional
additions, deletions, and commit statistics preserve measured zeroes, label
partial subtotals, omit wholly unknown totals, and use the same warnings in
human and JSON output. Empty successful days skip generation but still render
the normal `PRs 0` footer and deliver normally.

The sole live JSON identity is now `hive-digest` v2. The old `--source` flag,
`digest.source`, `hive-merged-pr-digest`, Hive match fields, categories,
failed-notice success state, and compatibility aliases were removed;
`schemas/hive-digest.v1.json` remains immutable historical documentation.
Daemon scheduling retains the canonical `hive digest --date D --json` command,
catch-up/cursor/backoff behavior, and one global slot, while date calculations
now use Europe/London explicitly. `hive answer-digest` keeps its separate
host-local calendar behavior.

Migration: remove any source selector, migrate v1 consumers to the v2
project/PR/bullet/warning shape, treat `--repo` as a registered-repository
filter, and stop expecting task-derived or Hive-match fields. This work reused
only the empty-scope and statistics-seam ideas from closed PR #752; its dual
source, source propagation, matching, and alternate identity were not carried
forward.

Release-note-ready copy: "Hive's daily digest is now one complete PR-only
changelist for each Europe/London day. It validates full GitHub body/diff
evidence, reports partial repositories and metrics honestly, redacts recognized
secrets at both outbound boundaries, and publishes the new `hive-digest` v2
contract. Remove `--source` and migrate v1 JSON consumers before upgrading."

This fragment is version-neutral. It does not select a release version, change
release metadata, create a tag, publish a package, or deploy anything.

