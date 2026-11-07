## 2026-11-07 — Dogfood rollback target for `hive setup --install-command-receipts`

- `hive setup --install-command-receipts` refused everywhere because
  `CommandSchemaInstallation::PUBLISHED_ROLLBACK_PACKAGE` is still empty
  (#1550). On the dogfood channel the rollback target is now the previous
  retained dogfood deployment, resolved by
  `Hive::RuntimeControlPlane::DogfoodRollbackDeployment`.
- Eligibility: a different, clean, not-newer `hive-dogfood-<sha9>` checkout
  with an executable `bin/hive` whose source pins the same receipt schema
  (`CommandSchema` version and digest) and base runtime schema. The newest
  eligible one wins and is pinned by a `bin/hive+lib` manifest sha256 that is
  re-verified before the transaction.
- Setup reports the coordinates in the `runtime_control_plane` phase's
  `rollback_package`, the install result in `command_receipts`, and a fresh
  install writes `command-receipts-installation.json` beside the runtime
  database. Release-channel behavior is unchanged.
- Pages: [[commands/setup]], [[commands/receipt]].
