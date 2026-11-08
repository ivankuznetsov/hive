# 2026-10-15 — Keyed `hive new` works again without command receipts

- Regression: #1494 (289501ba12) routed every `hive new --idempotency-key`
  through `CommandOperation`, which refuses with CONFIG unless the
  command-receipt extension (runtime migration 002) is installed. Production
  builds ship no published rollback package
  (`CommandSchemaInstallation::PUBLISHED_ROLLBACK_PACKAGE` is all `nil`), so
  installation is refused and every keyed `hive new` failed on every host.
- Fix: `Commands::New#keyed_call!` asks
  `Hive::CommandOperation.receipts_installed?(store)` — the same predicate the
  keyed constructor enforces. When it is false, Hive prints
  `hive: command receipts not installed; using per-project idempotency for this
  key` on stderr and runs the unchanged pre-#1494 TaskCapture path (commit-lock
  serialized; identical retry → existing task, `created: false`; different
  input → `IdempotencyConflict`, usage/64). Installed receipts keep the
  `CommandOperation` path unchanged.
- New `Hive::CommandReceiptsNotInstalled < Hive::ConfigError` is the only
  signal that selects the fallback. `CommandReceiptStore#verify_extension!`
  and `CommandOperation.verify_receipt_extension!` raise it for an absent
  extension and for a missing runtime database (`MigrationRequired`
  `:missing_database`); busy storage stays `ConcurrentRunError`, other
  storage faults stay `ConfigError "cannot verify command receipt storage"`.
  Receipt-only keyed commands (`answer --binding`, `approve`, stage actions,
  `act`, `archive TARGET`, `receipt prune`) therefore now report a fresh host
  as "command receipts are not installed" instead of "cannot verify … database
  is missing"; both remain CONFIG/78.
- Tests: `test/integration/new_idempotency_without_receipts_test.rb`,
  updated `new_wrapper_argv_test.rb` (real `bin/hive` subprocess) and
  `new_command_receipt_test.rb`, plus a `receipts_installed?` unit test.
- Pages: [[commands/new]], [[commands/receipt]];
  `docs/guides/current-format-migration.md`.
