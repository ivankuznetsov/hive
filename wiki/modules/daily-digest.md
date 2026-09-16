---
title: Daily changes digest
type: module
source: lib/hive/daily_digest/, web/app/views/digests/
created: 2026-08-30
updated: 2026-09-16
tags: [digest, prdigest, document, telegram]
---

Hive's digest is one readable document describing merged changes across its
registered GitHub repositories. PRDigest remains an independent product and
owns collection of PR descriptions and relevant patches, plus the shared writing
instructions. Hive supplies its configured agent and owns scheduling, storage,
Web/CLI reads, and Telegram delivery.

## Generation

`DocumentWriter`, the default for `hive digest refresh`, generates yesterday's
calendar-day document. An explicit `--date YYYY-MM-DD` can generate an older day
or preview today. GitHub evidence can be collected before local digest setup;
workflow events and the old coverage frontier do not gate this query.

`PrdigestSource` derives unique GitHub repository names from registered project
identities (falling back to the origin remote), reuses `gh` authentication, and
calls PRDigest's collector. It redacts recognized secrets before giving facts
to an agent. Non-GitHub projects are outside this PR-only scope. Collection
failure leaves the previous document intact instead of publishing an empty day.

`DocumentGenerator` invokes the selected Hive agent with
`Prdigest::Document.prompt`. `daily_digest.agent`, `model`, and `effort` can
select a digest-specific route; otherwise the execute route is used. The writer
validates non-empty output and preserves the exact generated document. A day
with no merged PRs produces a short no-changes document without an agent call.

PRDigest bounds descriptions and source patches, prioritizes source files over
lock/generated files, and records omitted or truncated evidence. The shared
prompt has a total evidence budget; oversized metadata fails generation rather
than silently dropping PRs. Generated descriptions must not claim complete
inspection when evidence was truncated.

## Persistence and retries

Documents use the existing private `Store` under
`daily-digest/documents/v1/`. The earlier workflow-event store under
`daily-digest/v1/` is left intact and is not the default digest source.

A generation lock serializes writers without blocking reads during GitHub or
agent calls. Atomic publication replaces an open preview. Unchanged evidence
reuses its text; closed documents are reused without another generation call.
Failed generation preserves the last saved document. Pruning leaves a tombstone
and refresh does not recreate that day.

Existing preview intervals retain their timezone and boundaries. Collection
that starts before midnight stays open even if it finishes after midnight; the
next collection can observe the full day before closing it.

## Reading and delivery

The shared reader returns the current preview if one exists, otherwise the most
recent saved document. CLI text prints the document, JSON exposes `document`,
and Web displays sanitized Markdown as one article. A document always covers its
recorded repository scope; legacy project-filter query strings do not rewrite it.
Reads never generate or send.

Telegram sends the same text as one formatted HTML message when it fits, or one complete
UTF-8 `.txt` attachment when it exceeds Telegram's message size. Existing delivery
receipts prevent automatic replay after a confirmed or ambiguous send. Scheduled
delivery selects yesterday's closed document at the configured local hour; it
does not require a separate current-day preview.

## Dependency and verification

This integration requires PRDigest 0.4.0 or newer in the 0.4 line and
agent-cli-runtime 0.2.4 or newer in the 0.2 line. Both dependencies are published
and verified through clean registry installs.

Focused tests cover real Store/Reader document round trips, before-setup dates,
unchanged evidence, failed generation, midnight closure, timezone preservation,
CLI/JSON/Web output, long Telegram attachments, and receipt reuse. Live QA must
inspect an actual generated document as well as transport success.

## Project statistics and Web presentation

Collection enables PRDigest's line statistics. Each document saves per-repository
merged PR counts, commits in those PRs, additions, and deletions in
`repository_stats`; LOC changed is additions plus deletions, not net growth.
These counts cover merged PRs, not every direct commit to a repository.

Refreshing an older closed document with no statistics appends a metadata-only
amendment from its saved repository scope and PR URLs. Missing evidence fails
without changing the base. Subsequent refreshes reuse that amendment. The reader
and CLI JSON expose these saved totals; Web requests never fetch GitHub data.

Web removes the leading document title because its date is already in the page
header. It starts with the introduction, links project headings to GitHub with
an external-link icon, and shows the corresponding statistics under the heading.
The article uses the page width, compact vertical spacing, and body-sized theme
headings. The stored Markdown remains unchanged for CLI and Telegram.
