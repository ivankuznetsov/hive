## 2026-09-08 — Workflow pre-dispatch schema compatibility

The CI inventory exposed an existing mismatch between workflow lifecycle usage
envelopes and their published schemas. Install/list/remove/update now admit
`usage`; publish adds a closed pre-dispatch usage arm with exit 64. Existing
payloads and schema versions are preserved. Handler-specific publish errors
retain their retryability and recovery requirements. Regression coverage checks
all five lifecycle schemas and rejects unknown kinds and additional fields.
