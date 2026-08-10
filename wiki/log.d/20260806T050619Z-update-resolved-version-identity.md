---
title: Repair release update identity and installed setup-agents loading
type: fix
module: update
created: 2026-08-06
tags: [update, installer, cosign, release, setup-agents, packaging]
---

The bash installer now binds cosign's certificate identity to its resolved
release tag rather than the optional raw version input. `hive update`, which
discovers the latest release without setting `HIVE_VERSION`, therefore verifies
the exact `release.yml@refs/tags/vX.Y.Z` identity instead of constructing an
empty tag expectation and failing before installation.

The installer fixture now exercises the latest-release API path with no
explicit version input and captures the exact tag passed to cosign.

The public `setup-agents` route now explicitly loads `Hive::Config` before
dispatch. An isolated packaged-gem regression builds and installs the gem,
invokes that route without the source test bundle's implicit requires, and
proves it reaches the typed configuration-error boundary instead of raising an
unhandled missing-constant exception.
