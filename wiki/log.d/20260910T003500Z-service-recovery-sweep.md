# Verify service recovery before cleanup or activation

Uninstall now stops before configuration, data, or runtime-state cleanup when
pending service recovery fails with a raw filesystem error or a foreground bot
cannot be signalled. Regression tests exercise both paths with force-purge
requested and verify that the original state remains available.

See [UserService](../modules/user_service.md).

Service recovery now records removal intent before foreground stop, permits
verified rollback for teardown callers whose configuration differs, and checks
Linux activation identities after reload. Launchd stop unloads an inactive
registered job. Unused manager compatibility wrappers were removed so the
transition owner controls reload ordering.

Removal also records whether a foreground stop is required and complete.
Cross-command recovery retains the journal when the required handler is absent;
completed stop evidence allows the remaining teardown to resume safely.
