---
title: Add bounded Patrol deterministic receipt facade
type: added
date: 2026-08-04
---

- Add one public `Patrols.deterministic_receipt_for!` seam that selects a
  unique comparable terminal shadow decision by module and trigger identity
  under the exclusive migration lock, excluding concurrent same-identity
  writes until receipt construction finishes.
- Construct the canonical qualification receipt only from descriptor-validated
  capture, projection, and observational-effect evidence; caller authority is
  limited to bounded candidate metadata, and its repository must exactly match
  the nonempty host-qualified repository target captured by the scheduler.
- Bind Architecture Patrol manifests to the exact host in their PR URL so both
  Patrol products emit the same `host/owner/name` qualification identity.
- Preserve only exact replay of already-durable owner/name captures; new
  captures and qualification receipts require the host-qualified target, even
  when caller metadata attempts to repeat a hostless replay identity.
- Fail closed on missing or ambiguous selection and on nonterminal,
  configuration, effect, projection, or repository identity mismatch.
