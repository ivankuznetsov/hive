---
title: Forced web install refreshes same-version bundles
type: log
tags: [web, install, systemd, dogfood, bugfix]
---

# Forced web install refreshes same-version bundles

A current-main dogfood deployment exposed an identity gap in managed Hive web:
the service binary could advance while the web bundle retained the same
`Hive::VERSION` stamp. `AppBundle.ensure!` then treated healthy compiled assets
as proof that the older app and lockfile were current, so the replacement
service booted against stale dependencies.

`hive web install --force` now forces the existing staged dependency and asset
preparation path before rollback-safe bundle activation, even when version and
asset checks pass. A persistent parent-directory lock serializes refreshes. The
prepared generation receives its version stamp before activation, the previous
generation remains available as a sibling backup until activation succeeds,
and a failed activation restores it. Ordinary web startup still avoids all
provisioning work for a healthy current bundle.

If a successful refresh leaves the service unit unchanged, install now restarts
an already-running service exactly once so it consumes the new bundle. A unit
upgrade's existing restart is not duplicated. The CLI help discloses both the
bundle refresh and service-unit overwrite scope. `--no-bootstrap` remains
authoritative, and the signed-release default fails closed before service
mutation if download, verification, or preparation fails.

Focused tests pin the no-op/forced split, activation rollback, restart
coordination, help text, and force propagation. The remaining release proof is
an installed-main same-version repair on real systemd-user plus equivalent
launchd coverage.
