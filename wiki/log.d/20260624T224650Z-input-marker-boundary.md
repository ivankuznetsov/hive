---
date: 2026-06-24T22:46:50Z
slug: input-marker-boundary
pages: [modules/markers, modules/bot, commands/status, commands/tui, testing]
---

## markers/bot/status/tui — needs_input now has a marker boundary

`Hive::Markers.input_marker?` now defines the only marker names whose
`needs_input` action represents a real operator question:
`waiting`, `execute_waiting`, and `review_waiting`.

Telegram notification dispatch applies that predicate before building alerts.
Rows such as `action=needs_input marker=none` or `marker=complete` are
suppressed before entering the alert store and logged as
`notification_skipped_incoherent`. Genuine `execute_waiting` and generic
`waiting` rows still notify, but their copy is reworded without raw marker
names and uses the existing Show details callback where no dedicated answer
callback exists.

`hive status --json` remains contract-stable and still emits the raw action.
Human renderers apply the shared predicate at the presentation boundary:
text status excludes incoherent rows from the "Needs your input" group and
summary count, while the TUI visible projection and keymap ignore those rows as
answerable input.
