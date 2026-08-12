# Give bench quota errors canonical recovery identity

**Date:** 2026-08-11
**Scope:** built-in `bench` generate recovery

## Change

The packaged generate instruction no longer appends a raw
`ERROR reason=limits_reached` marker. It records the human-readable status and
then calls `Hive::Markers.set`, which adds the canonical `marker_id` and current
attempt projection used by `RecoveryCoordinator`'s compare-and-swap admission.

## Evidence

The live Opus/Fable campaign proved the prior migration was not one-off: after
`hive migrate` added an identity and recovery ran again, the next quota wall
created a fresh id-less marker and parked as `recovery_migration_required`.
Focused workflow coverage now executes the packaged shell function and asserts
that the resulting error has a valid recovery identity.

## Remaining gap

The source contract is test-pinned, but the fix has not yet been installed into
the shared daemon or replayed against the live campaign.
