---
title: Repair hosted release-candidate runtime boundaries
type: change
module: release-candidate
created: 2026-08-05
tags: [release-candidate, workflow, macos, sandbox, encoding]
---

The macOS upgrade gate now permits read-only `sysctl` calls required to start
the hosted Ruby runtime while retaining deny-default, deny-network, run-root-only
writes, and no Mach service lookup. The ordinary macOS install-smoke job runs a
minimal Ruby process under the same sandbox profile so this prerequisite fails
on pull requests instead of during release qualification.

Bounded subprocess stdout and stderr are normalized to valid UTF-8 after byte
truncation. Legacy package warnings and split multibyte tails can therefore be
retained in JSON receipts without making the hosted upgrade entrypoint fail
during final serialization.
