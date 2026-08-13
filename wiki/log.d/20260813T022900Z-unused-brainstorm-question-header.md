---
date: 2026-08-13
slug: unused-brainstorm-question-header
pages: [modules/bot]
---

Removed the unused `Hive::BrainstormParser.question_header` formatter and its
direct assertion. The runtime that originally consumed it was retired; answer
slot creation continues to use the retained canonical `answer_header` helper.
Updated [[modules/bot]] to describe the remaining formatter surface.
