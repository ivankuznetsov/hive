---
title: Delete retired runtime compatibility machinery
date: 2026-08-30
tags: [runtime-control-plane, sqlite, deletion, cutover]
---

The one-way SQLite cutover now has no dormant filesystem runtime consumer.
Retired attempt, dispatch, provider-health, routing-policy, PR reconciliation,
recovery, and internal JSON-schema implementations were deleted after their
consumers switched to typed Sequel repositories. The migration-only legacy
decoder and its fixtures are gone; fresh bootstrap and ordinary runtime do not
load a decoder or honor retired runtime path overrides.

External cutover phase manifests remain the recovery authority. The private
service journal records only which services were running, and activation
refuses genuine live attempt owners or held runtime locks after those services
stop. Disposable dispatch, provider, routing, Patrol, counter, PR, and
operational rows are reset without legacy JSON decoding. Project/task identity
is rebuilt through `TaskMeta` from file authority, while validated token-usage
history is the sole legacy runtime data imported. Task journals, projections,
artifacts, and referenced payload files stay under their existing file
authorities.

The corrected KTD12 union counts every surviving U2 baseline path plus every
new production file. After the simplification pass it measures 7,954 physical
lines across 31 files against the 7,960-line cap. The executable deletion
contract also discovers added worktree production files, so an uncommitted or
future file cannot escape the inventory.
