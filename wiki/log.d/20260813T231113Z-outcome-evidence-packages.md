---
date: 2026-08-14
title: Require independently reviewed outcome evidence for artifact completion
tags: [artifacts, evidence, review, web, recovery]
---

- Replaced visual-only artifact completion authority with a strict package bound
  to the controller-owned implementation base/head, durable task generation,
  recovery epoch, and complete committed changed-path set.
- Added three fresh role contexts: read-only semantic claim inference, a
  controller-scoped proof producer, and a read-only independent reviewer. Claims
  choose screenshot, temporal video, terminal recording, or document proof;
  every changed path traces to a claim or justified exclusion.
- Added closed, schema-validated append-only requirements/attempts and an atomic
  accepted-or-blocked pointer. Retained proof is bounded, hash-checked,
  media/structure decoded, secret-scanned, source-bound, and revalidated before
  publication or Hivebox display. Synthetic Hivebox capture remains diagnostic.
- Added at most two targeted recaptures, preserving accepted proof while a fresh
  reviewer rechecks the full package. Uncertainty, reviewer capability gaps, and
  exhaustion block instead of completing or entering infinite daemon retry.
- Added `hive evidence recover` as an exact generation/recovery-digest CAS that
  advances a separate recovery epoch without rewriting history, followed by the
  normal guarded `workflow.retry` action.
- Hivebox now leads task pages with claims, proof, rationales, traceability,
  provenance, capabilities, attempts, and recovery; legacy media is visibly
  labelled as a diagnostic. Tampered packages fail closed and evidence files are
  served only through admitted attempt/hash identities.
