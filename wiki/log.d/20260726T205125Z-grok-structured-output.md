---
title: Consume Grok terminal schema results
date: 2026-07-26
---

**Fixed:** Managed Grok actors now normalize the terminal
`end.structuredOutput` object as their final structured message. Grok streams a
human-readable rendering before that event; treating the prose as the final
message caused Hive's host-output validator to reject a valid schema result and
surface `council_failed`.

**Safety:** Grok opts into this authority through the explicit
`AgentProfile#structured_output_protocol = :grok_end` capability; custom and
non-Grok profiles do not inherit the event shape. Parsed and conservatively
recognized unparseable terminal payloads are omitted from durable logs, plain
fallback, and quota diagnostics. A managed Grok run treats a non-object or
unparseable terminal payload as an authority barrier, so schema-looking prose
cannot bypass the CLI's failed terminal validation. Ordinary unstructured Grok
runs retain their preceding human-readable stream.

**Verified:** Added real Grok `streaming-json` event-shape regressions for a
valid object, malformed string/array/null values, syntactically invalid JSON,
quota-like private payloads, a negative non-Grok profile, and the complete
managed Agent-to-host-publication boundary.
