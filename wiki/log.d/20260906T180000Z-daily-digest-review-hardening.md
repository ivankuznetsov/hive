---
title: Harden daily digest collection, recovery, views, and delivery
date: 2026-09-06
---

Daily digest refresh now reuses committed file fingerprints, preserves prior
facts and frontiers during source outages, repairs coverage holes before later
records, and checks every retained interval for late observations. Malformed
journals and oversized creation receipts become bounded project-local gaps.
Gap resolution requires positive evidence from the attempted scope.

CLI, Web, and Telegram share deterministic item ordering. CLI and Web also
share effective state, project grouping, historical task-link validation, and
bounded changed-outcome labels. JSON command envelopes are schema-tested and
delivery errors include refresh remediation or the automatic retry bound.

Digest schedulers now share stage-scoped pending and backoff machinery.
Provider, authority, and capacity hold transitions are journaled for historical
boundary reconstruction, while provider quota failures retain their dedicated
same-runtime retry behavior. Navigation uses a rebuildable interval index, and
membership history keeps a persisted event-ID lookup for constant-time dedupe.
