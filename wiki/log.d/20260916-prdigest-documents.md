## [2026-09-16T16:00:00Z] Restore readable daily changes documents

PRDigest supplies bounded PR descriptions/patches and the reusable generation
contract. Hive generates with its configured agent, saves one document, exposes
it in Web/CLI, and sends the same text or a complete text attachment to Telegram.
The default refresh writes yesterday's document, with explicit dated previews
and historical GitHub queries. Workflow events are no longer digest inputs.
The old activity store remains archived; shipping requires the matching PRDigest
release. See [[modules/daily-digest]].

Polish: the shared prompt requests concise editorial Markdown with clickable PR
links. Web renders sanitized Markdown in a readable article; Telegram formats
headings, emphasis and safe links, retaining one complete attachment for long days.

The document is presented as a readable Markdown article with responsive spacing
and headings. Telegram converts the supported Markdown to escaped HTML, preserving
headings and source links. The manual bot E2E workflow now includes a digest receipt
check using the existing private test bot, including repeat-delivery deduplication.
