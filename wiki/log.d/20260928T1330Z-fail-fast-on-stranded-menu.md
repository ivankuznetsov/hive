# 2026-09-28 — tmux Claude waits fail fast on a stranded menu

- A detached execute session sat on a Claude question menu for the full
  stage timeout (~4h) and then surfaced as the generic "claude stop hook did
  not signal completion".
- All three tmux waits (`wait_for_terminal_marker`, `wait_for_expected_output`,
  `wait_for_done_signal`) now watch the bottom pane lines for Claude's
  selection-menu footer. If it stays up past a 300s grace window
  (`HIVE_CLAUDE_TMUX_STRANDED_MENU_GRACE_SEC`), the wait fails with
  "claude is waiting on an interactive menu in a detached session";
  marker-owned launches stamp `ERROR reason=interactive_menu_stranded`.
- The provider-limit menu check still runs first and keeps `limits_reached`.
  A footer above newer output is ignored. This complements the
  `AskUserQuestion` deny: it also covers any other menu that can strand a
  session.
