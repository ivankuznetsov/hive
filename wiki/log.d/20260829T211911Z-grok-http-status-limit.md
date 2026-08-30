# 2026-08-29 — Grok HTTP-status limit classification

Agent CLI Runtime now reads Grok's nested `http_status` field from dedicated
error events. HTTP 402 balance exhaustion is therefore a typed provider limit:
reviewers stop their transient retry loop and Hive writes the ordinary
`limits_reached` cooldown marker instead of generic `all_failed`.
