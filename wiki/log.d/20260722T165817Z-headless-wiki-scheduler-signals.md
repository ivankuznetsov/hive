---
title: Preserve bounded wiki scheduling in headless hooks
date: 2026-07-22
tags: [llm-wiki, systemd, scheduler, queue, release]
---

Fixed two follow-up edge cases observed while draining the recovered Hive wiki
queue. Commit hooks and scheduler reconciliation now reconstruct a missing
user-systemd bus environment from the standard runtime socket. A failed
best-effort service signal retains the installer-owned scheduler marker and
uses the existing host-wide serialized fallback, so later commits continue to
target the 4 GiB/no-swap bounded worker.

Commits that change only compiled `wiki/log.md` now exit before queue creation,
source pinning, or provider launch. Changes to `wiki/log.d/`, other wiki pages,
and normal project sources remain eligible for refresh.

Focused scheduler and transactional refresh tests cover bus recovery, marker
retention, fallback processing, compiled-log no-op behavior, queue cleanliness,
and parity between the packaged template and Hive's dogfood copy. Prepared the
urgent v0.6.8 patch metadata and synchronized both gem lockfiles, installer
references, and the four-platform skill projection.
