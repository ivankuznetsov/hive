---
title: Reusable visual workspaces and web account branding
---

Added empty/populated native test workspaces and a full-page capture matrix for
Board, Grid, and the mobile menu in both themes. Each successful run writes a
Screenote manifest with synthetic/local provenance; it does not publish itself.
Populated navigation checks now reuse the same fixture setup.

The header uses a transparent terracotta Hive mark for the web palette. GitHub
avatars appear beside signed-in accounts with an initial fallback. Browser tests
intercept the avatar image request with a local fixture.
