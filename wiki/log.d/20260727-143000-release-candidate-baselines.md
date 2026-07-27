---
date: 2026-07-27
slug: release-candidate-baselines
---

- Added the reviewed, non-floating v0.6.9 latest-stable baseline and the
  v0.4.1 producer/v0.4.2 observer historical baseline with exact release
  package and checksum/signature/certificate asset identities.
- Added strict catalog and dependency-closure validation, deterministic
  tag-scoped missing-cache fetch instructions, authenticated regular-file
  verification, role-only installed gem/skills targets, a closed target
  environment, and fail-closed Podman/Docker sandbox invocation contracts.
- Bound the catalog and dependency-closure policy into immutable candidate
  identity and added a separate attempt fingerprint plus gate details for the
  authenticated release assets and verified offline cache. Real historical
  upgrade execution remains a later lane and is not claimed by these tests.
