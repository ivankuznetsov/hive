---
title: Managed web runtime uses locked Bundler
type: log
created: 2026-07-26
---

`hive web` now launches managed `db:prepare` and the long-running Rails server
through the same exact lockfile-selected Bundler and current Ruby used by web
bundle provisioning. This closes a live systemd failure where installation and
asset compilation succeeded under Bundler 2.7.2, then direct `bin/rails`
startup activated host Bundler 4 and rejected `hive-cli`'s runtime dependency.
Operator-managed source and Hivebox app overrides retain their existing direct
Rails launch contract.

Focused command coverage pins both managed runtime commands to the canonical
locked launcher, while AppBundle coverage continues to pin the same launcher
for production asset compilation.
