---
title: Harden identity-bound brainstorm answer writes
type: change
date: 2026-08-10
tags: [brainstorm, answers, bindings, telegram, web, concurrency]
---

- Reversibly neutralized answer lines that resemble Q/A structure, rounds, or
  stage markers so literal replies cannot create parser slots or forge state;
  invalid UTF-8 and CRLF writes now follow the parser's tolerant contract.
- Serialized answer read/replace cycles on the marker sidecar lock as well as
  the task lock, preserving concurrent marker updates without recreating a
  disappeared task folder.
- Tightened relocation to unique unanswered fingerprint matches, removed the
  waiting marker from question fingerprints, validated every public v1 binding
  constraint, preserved writer outcomes, and classified corrupt task journals
  and pre-lock folder moves through their documented contracts.
- Routed Telegram typed/voice conversations and Hive web Q&A/intervention forms
  through the shared identity-bound answer seam. Both retain the presented
  opaque binding and reject a same-number question from a replacement round.
- Expanded focused command, parser, writer, bot, and web coverage for every
  closed outcome and the new security/concurrency regressions.
