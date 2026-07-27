# 2026-07-27 — Update the Telegram client to Bot API 10.2

**Why:** `telegram-bot-ruby` 2.8.0 covers Telegram Bot API 10.0, 10.1, and
10.2 while retaining Hive's supported Ruby floor and dependency shape.

**Change:** Root and packaged-web lockfiles now resolve
`telegram-bot-ruby` 2.8.0. The root resolver also selected current compatible
patches of `concurrent-ruby`, `faraday-net_http`, `json`, and `zeitwerk`; the
web resolver changed only the Telegram client because its compatible
transitives were already independently locked.

**Boundary:** Hive does not yet require a 2.8-only API, so the gemspec keeps its
existing `~> 2.7` compatibility range. Reproducible development, CI, and
packaged-web installs use the reviewed 2.8.0 locks.
