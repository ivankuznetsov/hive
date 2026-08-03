# Keep daemon event producers inside the logger contract

- Added every production-emitted daemon event missing from the closed
  `Hive::Daemon::Logger::EVENTS` enum. This prevents successful merged-task
  archival from being followed by a false `fatal` when the dispatcher emits
  `completed`, and repairs the same latent crash in module-runtime,
  markerless-stall, dispatch-sequence, and task-id-backfill paths.
- Added a source-scan regression test over `lib/hive/daemon/**/*.rb` so a
  future literal `.event(:symbol)` call fails CI unless the real logger accepts
  it. Existing fake loggers can no longer mask this integration contract.
