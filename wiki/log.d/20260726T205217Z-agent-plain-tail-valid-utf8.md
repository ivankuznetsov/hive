---
title: Keep byte-bounded agent output valid UTF-8
type: fix
source: lib/hive/agent/message_extractor.rb
created: 2026-07-26
tags: [agent, output, utf-8, patrol]
---

Ordinary patrol found that the bounded fallback tail for unstructured agent
output could begin in the middle of a multi-byte UTF-8 character. The shared
message accumulator now drops invalid fragments after byte truncation, so
agent and display-name fallback messages remain valid text. A focused
regression test pins the split-character boundary.
