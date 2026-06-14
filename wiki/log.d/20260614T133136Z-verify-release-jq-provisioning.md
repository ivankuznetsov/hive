---
date: 2026-06-14
slug: verify-release-jq-provisioning
pages: [testing]
---

Fixed the PR #474 install-smoke failure before `packaging/verify-release.sh`
started: the `verify-release.sh (end-to-end behavior)` job unconditionally ran
`sudo apt-get update -qq && sudo apt-get install -y -qq jq`, and the
Ubuntu 24.04 runner's preconfigured `packages.microsoft.com` repositories
returned 403 during `apt-get update`. That unrelated apt-source outage failed
the verifier job before the release behavior check could run.

The workflow now treats `jq` provisioning as idempotent: it uses runner-provided
`jq` when available, falls back to apt only when missing, and if the fallback
update is blocked by `packages.microsoft.com`, disables those Microsoft source
files and retries before installing `jq`. Verified the workflow YAML parses,
`install.sh` and `packaging/verify-release.sh` still pass `bash -n`, and
`packaging/verify-release.sh --version=v0.1.0 --report=json` passes with a
clean temporary `HOME` anchor. Updated [[testing]] with the CI provisioning
contract. No index update was needed because no new wiki page was created.
