---
title: Treat the managed Hive symlink as the installed binary
type: log
created: 2026-08-07
---

**Action:** Updated daemon status drift classification to compare the installed
service executable and expected executable by filesystem identity after exact
path comparison. A stable `~/.local/bin/hive` symlink that points at the current
deployment now reports `binary_drift: none`, while paths that resolve to
different files remain actionable `path` drift.

**Coverage:** Added a focused daemon-status regression using a real symlink and
refreshed [[modules/daemon]], [[commands/daemon]], and [[testing]].
