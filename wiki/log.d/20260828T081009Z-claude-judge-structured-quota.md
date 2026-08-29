---
title: Recognize Claude judge structured quota failures
date: 2026-08-28
---

- The benchmark Claude judge now classifies Claude Code's structured failed
  result as provider quota only when it is an API error with status 429 and its
  result text independently matches a quota wall.
- Model-authored quota prose and non-error result envelopes remain ordinary
  judge failures, so they cannot forge automatic retry evidence.
