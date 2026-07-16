---
title: Fail-closed dependency admission across dispatch boundaries
type: log
created: 2026-07-16
tags: [dependencies, admission, status, daemon, cli, repository]
---

**Action:** Replaced the daemon-only same-project dependency gate with one
strict three-verdict admission subsystem shared by status, daemon policy,
manual run, and forward approval. The scalar grammar now supports same-project
slug/numeric references and explicit `project:slug`, verifies enrolled
canonical remotes, walks complete cross-project chains and cycles, checks
workflow gates, and cross-checks optional structured plan frontmatter.

**Safety:** Corrupt or inconsistent evidence produces a structured admission
error and inert status action. Daemon merge watching and metadata healing stop
for held rows; manual commands revalidate under task/commit locks, and
`--force` cannot bypass the gate. Backward recovery and same-stage no-ops
remain available.

**Contract:** `hive-status` is now v5 with required nullable
`admission_error`. Command error envelopes distinguish retryable
`dependency_wait` (exit 75) from non-retryable `admission_error` (exit 78) and
carry `reason_code`, `offending_ref`, and `safe_correction`.

**Evidence:** Focused parser, metadata, identity, graph, status/TUI, daemon,
manual-command, creation, schema, and anonymized two-project integration suites
cover the plan-only ordering failure and repository-mismatch provenance.
