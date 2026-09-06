# Preserve attempt identity across dispatch cleanup

The dispatch queue deleted completed requests without a result delivery. Its
foreign key silently nulled attempts.request_id, breaking immutable record
comparison in the same reconciliation tick. Request IDs are now plain immutable
provenance; the unique index and full finalization comparison remain.

Explicit Database#migrate! supports the exact preceding schema, retaining every
row and all constraints in one transaction. Startup never upgrades storage.
With all Hive writers stopped and an external backup taken, run from the new
checkout using the explicit database path:

```sh
bundle exec ruby -Ilib -rhive -rhive/runtime_control_plane -e 'Hive::RuntimeControlPlane::Database.new(path: ARGV.fetch(0)).migrate!.disconnect' /absolute/path/to/runtime-control-plane.sqlite3
```

This is the existing Ruby migration boundary, not hive migrate --all's legacy
filesystem cutover. Tests cover no-chat and chat delivery, same-tick promotion,
preservation of all table rows including token history, migration rollback,
idempotent retry, and refusal to upgrade through ordinary open.
