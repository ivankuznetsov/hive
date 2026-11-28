---
title: hive digest
type: command
source: lib/hive/commands/digest*.rb, lib/hive/daily_digest/, schemas/hive-digest*.json
created: 2026-08-30
updated: 2026-09-10
tags: [command, digest, activity, history, json, telegram, retention]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-digest) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

`hive digest` reads one saved changes document. PRDigest collects descriptions
and relevant patches; Hive's configured agent writes the text, and Hive stores
and delivers it. Any registered agent and model may write it:
`daily_digest.agent`/`model`/`effort` select the route (default: the `execute`
stage agent), and optional `daily_digest.fallback_agents` (a list of `{agent, model?, effort?}`) are tried in order when a route fails; an
all-routes failure names every cause. See [[modules/daily-digest]] for the integration contract.

Default reads return today's preview if present, otherwise the latest saved
document. Always inspect `local_date`; adjacent saved dates need not be adjacent
calendar days. A legacy project filter does not rewrite a document or generate
a separate report. Web displays one escaped text article.

Generation uses unique registered GitHub repositories regardless of which tool
created each PR. Local tracking start does not prevent querying older GitHub
changes. Future dates fail. Empty days need no agent invocation. Collection or
generation failures leave the last saved document intact, but they are not
silent: `DocumentWriter` records the latest failure per date in
`<daily_digest_root>/generation-failures.json` (redacted, cleared by the next
successful write). The reader attaches it as `generation_failure` (and sets
`stale: true`) for that explicit date, or for an implicit `today` read that
falls back to an older saved document. `hive digest` prints it first, `--json`
carries it in `hive-digest.v1`, and Web shows an alert banner above the saved
document. A failed agent run reports the provider's own error event (for
example an expired OpenCode API key) rather than its stderr. Reads have no network,
generation, or delivery side effects.

Closed documents are immutable and reused on retry. Pruned documents are not
recreated. Telegram sends the entire saved text in one message or, when too long,
one UTF-8 text attachment. Existing delivery receipts prevent accidental replay;
an ambiguous send requires an explicit delivery retry.

The JSON envelope remains `hive-digest` and now includes optional `document`.
Metadata and PR references support inspection; workflow-event lists are not the
human-facing digest. `reader_status` distinguishes `ok`, `missing`, and `pruned`.
A missing document does not claim that historical source evidence is unavailable.

Generation and delivery are independently configured under `daily_digest`;
see [[modules/config]]. Neither this command nor this feature authorizes releases
or changes to external publication destinations.
