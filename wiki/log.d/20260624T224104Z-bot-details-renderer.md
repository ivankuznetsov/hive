## [2026-06-24T22:41:04Z] bot — render Show details from cached rows

**Action:** Inline `details:` callbacks, `/details <slug>`, and supervisor status-row detail rendering now share `NotificationBuilders.details_reply(row)`. The reply always includes a row summary and row-specific next-step hint, appends cached `row.diagnostic` summary/detail when present, and truncates oversized diagnostic detail to Telegram's message limit. Show details no longer spawns read-only `hive status --diagnose`, so non-red waiting rows no longer dead-end with an empty diagnostic reply; `refresh_diagnose` remains the explicit `--diagnose --write --force` path.

**Refreshed pages:**
- [[modules/bot]]
- [[commands/bot]]
