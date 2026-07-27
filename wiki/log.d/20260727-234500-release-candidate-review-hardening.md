---
title: Harden trusted pre-release execution after adversarial review
date: 2026-07-27
tags: [release, candidate, evidence, security, testing]
---

Adversarial review tightened the pre-release candidate boundary before
handoff. Blocking hosted jobs now reject candidate-controlled harness drift
against the protected-main control checkout. Linux historical lanes use pinned
rootless read-only containers with no network, capabilities, or
no-new-privileges bypass; macOS keeps a deny-network sandbox and isolated
control/cache/run roots. The offline runtime closure includes exact Bundler
bytes, and channel proof drives the installed candidate's real `hive update`
through reviewed offline Linux and macOS shims.

The evidence contract now has strict local and `trusted_remote` schema
branches, represents a missing baseline version as JSON `null`, returns a
nonzero hosted-lane status for failed or unavailable proof, and resumes only
genuinely incomplete gates. Candidate-version validation loads the reviewed
catalog dynamically rather than embedding the initial v0.6.9 baseline.
Candidate planning, artifact verification, and tag-time source verification
read the rebased canonical version declaration from `lib/hive/version.rb`.
