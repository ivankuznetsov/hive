---
title: Share digest truncation
type: changed
date: 2026-07-18
---

Shipped-task summary and label caps now share one private raw-text truncation
primitive in `Hive::Digest::Renderer`, and the merged-PR renderer delegates its
identical label cap to the existing public label policy. Length constants,
ellipsis placement, MarkdownV2 escaping, and rendered messages are unchanged.
