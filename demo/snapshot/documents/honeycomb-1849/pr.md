---
pr_url: https://github.com/ivankuznetsov/honeycomb/pull/2
pr_number: 2
---

# feat(security-lint): fork-safe CI, trusted approvals, and catalog lifecycle

## Summary

This adds the complete trust boundary for accepting Honeycomb submissions:

- a read-only, maintainer-gated analyzer scans fork content as data and emits deterministic redacted evidence;
- default-branch reporter code validates hostile artifacts and publishes the authoritative `honeycomb/security-lint` status for the exact PR head;
- a protected trusted workflow issues immutable, exact-SHA maintainer approvals on the append-only `honeycomb-evidence` branch, with a deterministic offline exporter;
- catalog records now model immutable release tier, current tier, permission risk, lifecycle state, verification evidence, history, and advisories independently.

Catalog eligibility remains fail-closed. Lint and human approvals must match the release fingerprint and head SHA; high-risk releases need two distinct current maintainers; Verified releases need matching archive, signature, and Actions-attestation evidence. Soft-hidden, yanked, and revoked releases remain auditable but are excluded from discovery and latest-version selection.

## Verification

- [x] `ruby test/run.rb` — 145 runs, 843 assertions, 0 failures, 0 errors.
- [x] `ruby script/honeycomb-manifest --check --all`.
- [x] `ruby script/honeycomb-validate --all --json` — no findings.
- [x] `ruby script/honeycomb-catalog --check --evidence test/fixtures/listing-evidence/empty.json`.
- [x] `git diff --check origin/main...HEAD`.
- [x] Static and fixture coverage includes fork permissions, event races, stale evidence, secret/PII redaction, exact suppressions, approval eligibility/storage, trust lifecycle, Verified evidence, and high-risk reviewer counts.
- [ ] After merge, create/protect the evidence branch and environment, configure required status/fork settings, and run the documented live fork canary.

## Linked work

Hive task 1849 consumes the registry/manifest foundation from #1 and now supplies the technical contracts required by task 1850's public trust-policy documentation and task 1851's seed catalog.

---

[![Compound Engineering](https://img.shields.io/badge/Built_with-Compound_Engineering-6366f1)](https://github.com/EveryInc/compound-engineering-plugin)

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/honeycomb/pull/2 is_draft=true -->
