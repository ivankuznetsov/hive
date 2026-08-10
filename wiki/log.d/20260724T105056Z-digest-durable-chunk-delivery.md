## Digest delivery now resumes without replaying accepted Telegram chunks

- Telegram MarkdownV2 chunking now selects only independently valid entity
  boundaries and rejects an over-limit or malformed entity before sending.
- Real digest delivery persists one stable redacted payload, its exact chunks,
  and the next-unsent cursor per date before the first API call. Each
  non-idempotent request also gets a durable in-flight marker, so an unknown
  response outcome is parked instead of blindly replayed. Safe retries resume
  the suffix, and a completed checkpoint makes a pre-cursor-advance retry a
  no-op.
- Telegram entity-parse HTTP 400 responses get one equivalent-HTML fallback.
  The fallback representation is persisted before sending, so a transient HTML
  rejection does not retry known-invalid MarkdownV2. Any deterministic 4xx or
  ambiguous outcome is parked; the daemon leaves the date owed but blocks
  repeated dispatch.
- Regression coverage includes a long two-project/five-PR digest, every
  section and footer, durable mid-stream recovery, no accepted-prefix
  duplicates, structured chunk logging, and permanent failure classification.

See [[modules/digest]], [[commands/digest]], [[modules/daemon]], and [[testing]].
