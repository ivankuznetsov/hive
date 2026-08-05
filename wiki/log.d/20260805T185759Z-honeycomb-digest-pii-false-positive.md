---
title: Keep Honeycomb digests out of payment-card findings
type: fix
module: workflows
created: 2026-08-05
tags: [honeycomb, authoring-lint, pii, sha256]
---

Honeycomb authoring lint no longer classifies a Luhn-valid digit run wholly
contained inside an exact SHA-256 token as a payment-card number. The 0.7.0
release manifest exposed the false positive through its generated
`release_sha256`; ordinary card-number fixtures remain rejected.
