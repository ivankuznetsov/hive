---
date: 2026-11-07T19:35:00Z
type: feature
---

Added independent read/create/act/answer API principals with digest-only bearer
storage, registration-bound project grants, expiry and per-token revocation.
The stateless API controller uses no browser-cookie or loopback authentication.
Owner, loopback-bypass and missing-receipt interlocks share a safe unavailable
response. A request boundary caps mutation JSON before parsing and replaces
ordinary address/body request logging with public-principal audit fields.
Token CLI registration remains paired with the complete remote transport.
