---
title: Admit canonical Git PAX metadata at tag handoff
type: fix
module: release-candidate
created: 2026-08-06
tags: [release, release-candidate, archive, pax]
---

The tag-time release selector now accepts the one canonical PAX global header
that `git archive` emits for the candidate commit. The candidate builder had
already authenticated and validated that header, but the later selector
mistook it for a link or special entry and blocked publication before any
assets were released.

The selector independently binds the header payload to the exact candidate SHA
and continues to reject duplicate or malformed global metadata, symlinks, and
all other special archive entries. Focused fixtures now reproduce the
production PAX header and retain a hostile source-link regression.
