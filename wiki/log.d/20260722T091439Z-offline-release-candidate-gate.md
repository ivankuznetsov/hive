---
title: Release candidate verification no longer requires provider keys
date: 2026-07-22
tags: [release, agent-skills, packaging, ci]
---

The tag-driven release workflow now builds and verifies its exact candidate
offline. It rejects tags outside protected `main`, checks manifest digests,
compares the packaged OpenClaw, Claude, Codex, and Pi projections byte-for-byte
with the canonical skill source, installs and invokes the exact gem, and
exercises the digest-pinned managed web archive before publication. The
authenticated `live-agent-skills.yml` workflow remains available as an optional
diagnostic but is no longer a credential-bound release prerequisite. The
managed-web verifier also provides hermetic Ruby/Bundler launchers so the
candidate gem's private gem-path isolation does not hide Bundler during
dependency installation or asset compilation.
