---
title: Harden the unreleased OpenCode integration after review
date: 2026-08-15
tags: [agent-cli-runtime, opencode, security, validation, release]
---

**Security:** Made edit rules worktree-relative, preserved qualified edit
subtrees and nested read-only exceptions, removed per-agent permission
overrides, reserved overlay-owned environment keys, cleared ambient probe
credentials, bound authentication evidence to the requested provider, and
accepted ownership-safe roots beneath symlinked system ancestors.

**Reliability:** Preserved inherited routes, distinct repeated observations,
nullable usage through aggregation and TUI rendering, exact truncation state,
session identity on additive events, process reaping, and cleanup diagnostics
without masking completed results. Prepared Compound Engineering readiness now
uses the invocation's actual OpenCode config and environment.

**Proof:** The exact installed candidate and independently projected mirror
exercise probe, prepare, normalize, and cleanup. The component release workflow
installs OpenCode 1.18.16 and requires the guarded offline smoke, while local
runs may still skip when OpenCode is absent. Version selection and publication
remain outside this source-only change, so Hive retains its published 0.1.x
dependency until a separately authorized component release.

**Web compatibility:** Source Rails resolves the monorepo component directly;
managed Web bundle/install/server commands export the exact installed component
gem root. This keeps both source CI and extracted archives on the same ABI
without requiring an unpublished RubyGems version.
