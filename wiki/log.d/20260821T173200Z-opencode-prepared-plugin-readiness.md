---
title: Accept OpenCode prepared plugin readiness
date: 2026-08-21
tags: [opencode, doctor, setup-agents, skills]
---

**Fix:** Managed-skill inspection now accepts OpenCode's synthetic
`configured:<package>` resolution when it exactly matches the package id from
the native pinned-plugin inventory. The prepared invocation can provide the
skill before OpenCode exposes a stable package install directory; treating that
valid identity as a foreign higher-precedence path made `hive doctor` and
`hive setup-agents` remain red after a successful configuration.

**Safety:** The exception is limited to the OpenCode adapter and requires an
exact expected package-id match. Physical project/user shadows and arbitrary
configured identities remain conflicts.

**Coverage:** The inspector regression uses the real pinned Compound
Engineering package identity with no materialized install root and requires a
healthy result while preserving the requested synthetic resolution evidence.

The same dogfood run exposed a separate cold-start failure in the component
route probe: `opencode models <provider> --verbose` can exceed the generic
10-second local-inspection deadline while emitting a large hermetic model
catalog. Agent CLI Runtime now grants only that inventory command 30 seconds;
version, help, export, and auth probes retain the original 10-second bound. The
component regression records the deadline selected for every probe leg without
sleeping or invoking a model.

A later retry exposed the other half of cold hermetic route readiness: the
fetch-disabled CLI inventory can omit a newly configured custom model even
though the exact selected configuration declares that model and its variant.
Preparation now combines those operator-owned declarations with the CLI
inventory. An exact configured route therefore survives a stale bundled
catalog, while an undeclared route absent from the inventory still fails
closed. Regressions pin both sides of that boundary.
