## 2026-07-18 — Share bot and daemon service-install results

- Added `Hive::Commands::ServiceInstaller::ResultPresenter` as the common
  command-side boundary above the existing platform installer base.
- Removed parallel bot/daemon copies of install invocation, human summaries,
  success/error JSON envelopes, drift/failure translation, and hostile-accessor
  fallbacks.
- Preserved each command's label, schema, error classes, exit codes, force and
  backup guidance, target path, restart flag, and operator messages.
- Verified command, installer, schema, and subprocess coverage together: 406
  runs, 1,663 assertions, zero failures, zero errors, and one existing opt-in
  skip.
