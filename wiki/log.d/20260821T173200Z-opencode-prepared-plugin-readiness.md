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
