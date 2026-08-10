---
title: PRDigest becomes the sole merged-PR digest engine
date: 2026-07-24
tags: [digest, prdigest, telegram, architecture]
---

# PRDigest becomes the sole merged-PR digest engine

`hive digest` now resolves the registered `github.com/owner/name` scope and
delegates an explicit date to the standalone PRDigest CLI. JSON is the unchanged
`prdigest-result` v1 document and child exit codes are preserved.

Removed Hive's collector, evidence model, agent generator, renderer, sender,
delivery checkpoint, digest-specific GitHub transport, prompt, and
`hive-digest` schemas/tests. PRDigest owns HTML rendering, chunk boundaries,
stable payload persistence, next-unsent resume, and permanent/ambiguous
Telegram policy.

The Hive Telegram wrapper also dropped the digest-only chunk inspection,
MarkdownV2 validator/converter, and checkpoint-oriented single-chunk API. Its
ordinary bot-message splitter and parse-mode forwarding remain unchanged.

Hive retains the Europe/London daemon cursor, registered-project subset gate,
credential/config bridge, and permanent-result parking. The remaining digest
configuration is only `enabled` plus `max_catchup_days`.

See [[commands/digest]], [[modules/digest]], [[modules/daemon]],
[[modules/config]], [[dependencies]], and [[testing]].
