---
title: Bind bash updates to the resolved release identity
type: fix
module: update
created: 2026-08-06
tags: [update, installer, cosign, release]
---

The bash installer now binds cosign's certificate identity to its resolved
release tag rather than the optional raw version input. `hive update`, which
discovers the latest release without setting `HIVE_VERSION`, therefore verifies
the exact `release.yml@refs/tags/vX.Y.Z` identity instead of constructing an
empty tag expectation and failing before installation.

The installer fixture now exercises the latest-release API path with no
explicit version input and captures the exact tag passed to cosign.
