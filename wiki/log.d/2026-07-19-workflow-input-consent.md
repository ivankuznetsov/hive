---
date: 2026-07-19
slug: workflow-input-consent
---

- Added redacted optional-input binding and authorized-slot lines to install
  and update previews before interactive consent.
- Changed update binding precedence to preserve compatible installed bindings
  ahead of same-name environment suggestions while keeping explicit bindings
  authoritative.
- Added an input-binding configuration-change flag to update reports; secret
  values remain absent from output and immutable configuration snapshots.
