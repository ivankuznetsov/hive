## [2026-06-15T19:28:58Z] status/tui/bot — surface PR URLs from task sidecars

**Action:** Refreshed command/API and TUI surface coverage after commits
`42fd5e2b` (`feat(status): U1 surface PR URLs from task frontmatter`) and
`5e4e1ffa` (`feat(tui): U2 show PR column in tasks pane`), plus follow-up
`408192cb` (`feat(status): U3 show PR column in text output`), `50552435`
(`feat(bot): U4 show PR links in status queue`), and `06e37a80`
(`feat(bot): U5 include PR link in review notification`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] / `wiki/log.d` entries first; `qmd search "status pr_url task
frontmatter hive-status schema"` found existing status/frontmatter coverage, so
verification used the committed diffs plus direct source reads.

Inspected `lib/hive/commands/status.rb`, `lib/hive/pr.rb`,
`lib/hive/bot/status_watcher.rb`, `lib/hive/bot/format.rb`,
`lib/hive/bot/supervisor.rb`, `lib/hive/bot/notification_builders.rb`,
`lib/hive/bot/notification_dispatcher.rb`, `lib/hive/tui/snapshot.rb`,
`lib/hive/tui/views/tasks_pane.rb`, `lib/hive/tui/views/hyperlink.rb`,
`schemas/hive-status.v3.json`, and the focused status/bot/TUI/schema tests.
Documented that `hive-status` v3 task rows now always carry `pr_url`, populated
from `pr.md` frontmatter only at `5-open-pr` and later and `null` on early,
missing, blank, or malformed sidecars; the bot and TUI snapshot preserve that
field; text status/archive output and the TUI render fixed PR columns as
`#<number>` through [[modules/pr]] and wrap valid http(s) links in OSC 8 only on
a TTY; Telegram `/status` and `/queue` render `#<number>` as an HTML link with
dash fallback; and the existing ready-for-review push appends the same PR link
without changing its de-dup fingerprint. Added [[modules/pr]] for the new
formatter helper, updated [[index]] for the new page, and recorded the remaining
missing live TTY/Telegram/open-PR smoke evidence in [[gaps]]. Did not run
`qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[state-model]]
- [[modules/bot]]
- [[modules/pr]]
- [[testing]]
- [[gaps]]
- [[index]]
