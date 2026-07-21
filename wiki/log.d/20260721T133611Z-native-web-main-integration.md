## [2026-07-21T13:36:11Z] native web — reconcile the current main integration

- Kept current-main Rails controllers, status/mobile behavior, and repository
  models while replaying the native-web setup and delivery review fixes.
- Kept temporary asset compilation on the canonical
  `HIVE_WEB_STORAGE_DIR` contract after the legacy alias migration.
- Routed Rails task-diff and repository-clone timeout constants through the
  canonical environment resolver instead of reading deprecated aliases.
- Isolated both canonical and legacy loopback variables in integration tests
  so the host-authorization gate cannot leak state between requests.
- Native authenticated installs now retain the `Hive web` identity, verified
  local installs use `hive`, and the container-only precompiled-assets marker
  preserves the `hivebox` identity.
