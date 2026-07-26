---
title: Consume Grok terminal schema results
date: 2026-07-26
---

**Fixed:** Managed Grok actors now normalize the terminal
`end.structuredOutput` object as their final structured message. Grok streams a
human-readable rendering before that event; treating the prose as the final
message caused Hive's host-output validator to reject a valid schema result and
surface `council_failed`.

**Safety:** Any parsed terminal event carrying the `structuredOutput` key is
now omitted from durable stream logs, including malformed non-object values.
Invalid, missing, truncated, or incorrectly shaped managed output still fails
closed before Hive writes any authorized target.

**Verified:** Added real Grok `streaming-json` event-shape regressions for a
valid object plus malformed string, array, and null values; ran the focused
agent, managed runtime-policy, and council test suites.
