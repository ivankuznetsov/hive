## [2026-09-16T15:51:00Z] Daily digest enabled by default

Local daily digest generation now defaults on. Setup and daemon startup/reload
initialize the coverage frontier atomically; explicit opt-out is preserved.
Config and digest reads remain read-only, and Telegram delivery remains opt-in.
Coverage starts at initialization; historical activity is not reconstructed.
See [[modules/config]] and [[modules/daily-digest]].
