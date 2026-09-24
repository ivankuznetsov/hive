# 2026-09-24 — Claude folder-trust prompt: newer layout

- Newer Claude Code shows "Is this a project you created or one you trust?"
  with the caret on "No, exit" and blank lines between options and footer.
  Hive only recognised the older "Quick safety check" layout, so launches in a
  never-trusted folder (for example a newly initialised project's task folder)
  waited out the ready timeout as "prompt did not become ready".
- `claude_trust_prompt?` now reads a window of recent non-empty lines after the
  last `Claude Code vX` banner and accepts either layout. `prepare_claude_session!`
  sends Enter only when the caret is on "Yes, I trust this folder"; otherwise it
  sends Down and re-reads, so it never confirms "No, exit".
