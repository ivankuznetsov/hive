## 2026-07-18 — Share durable command result interpretation

- Added `Hive::Attempts::CommandDispatch` for the identical durable dispatch
  and attach-result policy used by `hive run` and workflow stage actions.
- Kept command-owned intended-stage resolution, worker argv, error schema, and
  error-kind mapping separate while centralizing lost-attempt translation,
  worker-JSON deduplication, empty-output fallback, and receipt exit status.
- Verified both command surfaces and their integration envelopes together: 64
  runs, 317 assertions, zero failures, zero errors, and zero skips.
