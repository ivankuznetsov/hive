---
title: CI enables Bubblewrap user namespaces on Ubuntu 24.04
date: 2026-08-29
tags: [ci, patrol, bubblewrap, apparmor, testing]
---

**Fix:** The coverage-shard setup now conditionally disables Ubuntu 24.04's
AppArmor restriction on unprivileged user namespaces after installing
`bubblewrap`. Without this runner-local setting, Bubblewrap cannot write its
UID map and the Patrol Git-isolation tests fail before exercising their
private-metadata boundary.

The change is scoped to the CI job and preserves the production fail-closed
requirement for `/usr/bin/bwrap`.
