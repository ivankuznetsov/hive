---
title: Audit queued Rails filter tests and integrated wiki worker fixes
date: 2026-07-22T22:00:12Z
tags: [wiki, web, testing, llm-wiki, scheduler, provenance]
---

Inspected all three queued commits and all 45 changed-path blobs with direct
`git show`. None of the supplied SHAs is a graph ancestor of the refresh
branch, but their integration states differ.

Rails commit `22d80d1b` is a sibling of previously documented `affc392f` from
the same parent. Their production web blobs are identical: Rails owns the
URL-addressed project filter and broadcasts refresh plus composer
reconciliation. The new sibling differs in focused test infrastructure. It
resets the guarded Playwright project sandbox, registry, broadcaster, and
workflow cache before each example, and it waits for a confirmed Cable lease
before filesystem mutations expected to trigger a morph. [[testing]] and
[[gaps]] now record that additional evidence without claiming current-main
integration or deployed multi-client proof.

Timeout commit `c93b29b` and provider-dispatch follow-up `f4f863fe` were
squash-merged into current default as `5dc06203`. Their final runner,
scheduler, integration-test, and affected wiki blobs match the squash result.
Existing [[commands/init]], [[dependencies]], [[templates]], and [[testing]]
already cover the four-hour outer service timeout, the canonical cross-package
lock, and configured-provider-only production dispatch; [[gaps]] now closes
the stale source-integration uncertainty while retaining the separate v0.6.9
publication/install gap.

Page coverage remains 95, so [[index]] did not change. Compiled [[log]] was
not edited, and QMD was intentionally not run.

**Refreshed pages:**

- [[testing]]
- [[gaps]]
- [[log]]
