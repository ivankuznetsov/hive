---
title: Validate the unreleased OpenCode candidate
date: 2026-08-12
tags: [agent-cli-runtime, opencode, validation, package, mirror]
---

**Validation:** Added an installed-CLI offline smoke that permits only version,
run/export help, authentication inventory, and cached model inventory commands;
it refuses any model run. Added a separately gated authenticated smoke that
requires an explicit route, selected config, and credential environment key.
The mirror test now independently reconstructs and compares projected paths,
bytes, modes, and metadata before building and installing the projected gem.

**Lifecycle:** Fake-CLI integration proves one execute role and one native
Compound Engineering skill-dependent plan role through exact routing,
deny-first workspace confinement, one run plus one sanitized export, selected
credential forwarding, ambient credential removal, observed identity, and
idempotent cleanup. Direct execute runs resolve the same
`models.execute_implementation` cell even without a durable attempt context.
Implementation stages defer their controller-owned OpenCode observation append
until after artifact-firewall validation, so journal/projection evidence remains
protected without misclassifying Hive's own write as agent tampering.

**Boundary:** Candidate and mirror build/install checks are pre-release proof.
The authenticated live smoke skips unless explicitly configured. No tag,
publication, deployment, release workflow, mirror release, or downstream
release is part of this validation.
