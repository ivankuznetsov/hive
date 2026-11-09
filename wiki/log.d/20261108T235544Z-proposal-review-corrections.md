---
title: Proposal review correctness fixes
type: change
created: 2026-11-08
updated: 2026-11-09
tags: [proposals, correctness, recovery, context, llm-wiki]
---

Proposal persistence now compares canonical bytes independently of Ruby string
encoding, fails closed around corrupt reserved lifecycle slots and transitive or
multi-edge lineage, and keeps transient materialization failures out of
published views and automatic context. Reconciliation scans past retryable
receipts while surfacing failed quarantine compensation. Managed proposal-only
refreshes retain their provider-circuit exemption while gaining bounded retry
accounting, timeout-safe diagnostics, and checkout paths with spaces.
