---
title: Keep managed profile drift at the launch boundary
type: fix
date: 2026-08-27
tags: [workflow-package, task, status, agent-profile]
---

Managed task and status reads now load the selected immutable workflow mapping
without resolving or comparing it to the current process's agent profiles.
This keeps completed and retained tasks visible after agent renames, capability
changes, and compatible profile upgrades.

Runtime-context preparation still fails closed, but checks current capabilities
and the fingerprint only for the executable actor slot about to launch.
Configuration and integration regressions cover both the exact-slot validation
and the read-versus-launch boundary.
