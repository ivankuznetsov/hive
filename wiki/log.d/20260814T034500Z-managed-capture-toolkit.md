---
date: 2026-08-14
title: Ship one managed outcome-evidence capture toolkit
tags: [artifacts, evidence, capture, agent-browser, terminal, hivebox]
---

- Replaced the supervised capture script's direct Playwright dependency with
  Hive's pinned native `agent-browser` and managed Chrome cache. Producers now
  receive `hive evidence browser`, a closed controller-owned gateway behind a
  random `.invalid` origin proxy that maps to one issued loopback app port. Hive
  opens and verifies the named session before production but never exposes its
  raw socket. The gateway constrains navigation and commands, stages media in a
  controller-private root, and exclusively publishes basename-only PNG/WebM
  output into the attempt before session/app/proxy cleanup.
- Added `hive evidence terminal NAME -- COMMAND...`, a controller-scoped Ruby
  PTY recorder that emits an asciinema v2-compatible cast and bounded plain text
  without a shell, asciinema, VHS, or GIF conversion. The recorder reuses Hive's
  Linux child-subreaper custody and rejects detached descendants.
- Moved task source identity, byte sizes, SHA-256 digests, rendering metadata,
  and immutable review-scope inventory from LLM output into the controller.
  Exact diffs are materialized for read-only roles, videos gain a
  controller-derived ordered contact sheet, and failed exclusion verdicts remain
  first-class `failed_targets`. Missing proof may publish a targeted `revise`
  attempt but can never be accepted.
- Updated Hivebox to prewarm the managed web stack outside `/data`, removed
  asciinema, and added Tesseract beside ffmpeg/ffprobe for visual proof
  admission.
- Retrospectively reran the conditional-plan-critique task over its exact
  historical range. The reviewer accepted the genuine Hive Web blocked-state
  screenshot and rejected both terminal summaries, so the package correctly
  exhausted as blocked with one accepted claim rather than accepting synthetic
  media or overstating completion. The run also drove fixes for incremental
  recapture, keep-alive proxy revalidation, and browser media custody.
