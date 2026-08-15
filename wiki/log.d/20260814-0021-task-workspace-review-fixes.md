---
title: Harden task workspace Web ownership and archive safety
type: change
date: 2026-08-14
tags: [web, task-workspace, archive, timeline, accessibility]
---

The task workspace now rejects every archived-task mutation at the shared
controller boundary. HTML renders normalized question, recovery, and diagnostic
facts from the same workspace snapshot as JSON. Local publication evidence stays
live under page morphs, timeline drill-down has a separate stable frame and
return path, and browser coverage pins 400% reflow plus exact Q&A selection-range
preservation. Scroll restoration also cancels queued animation work when its
workspace disconnects.
