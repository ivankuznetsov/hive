## Remove unused London date helper

- Removed the unreferenced `Hive::LondonDate` module and its isolated tests.
- Host-local scheduler calendar behavior remains implemented and covered by
  `LocalDateWindow`, `AnswerDigest`, and `AnswerDigestScheduler`.
