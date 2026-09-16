---
title: hive digest
type: command
source: lib/hive/commands/digest*.rb, lib/hive/daily_digest/, schemas/hive-digest*.json
created: 2026-08-30
updated: 2026-09-10
tags: [command, digest, activity, history, json, telegram, retention]
---

`hive digest` reads one saved changes document. PRDigest collects descriptions
and relevant patches; Hive's configured agent writes the text, and Hive stores
and delivers it. See [[modules/daily-digest]] for the integration contract.

```bash
hive digest                         # saved document as text
hive digest --json                  # includes document and source references
hive digest --date YYYY-MM-DD        # a saved date
hive digest --open-web              # open the saved digest in Web
hive digest refresh --json           # generate yesterday
hive digest refresh --date YYYY-MM-DD --json  # historical day or today's preview
hive digest send --date YYYY-MM-DD --json     # send a saved closed document
hive digest prune --before YYYY-MM-DD --dry-run --json # projection-only retention
```

Default reads return today's preview if present, otherwise the latest saved
document. Always inspect `local_date`; adjacent saved dates need not be adjacent
calendar days. A legacy project filter does not rewrite a document or generate
a separate report. Web displays one escaped text article.

Generation uses unique registered GitHub repositories regardless of which tool
created each PR. Local tracking start does not prevent querying older GitHub
changes. Future dates fail. Empty days need no agent invocation. Collection or
generation failures leave the last saved document intact. Reads have no network,
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
