# 2026-06-09 - Bot success confirmations

- Generalized Telegram bot success handling so exit-0 child completions
  no longer stay silent or surface raw `exit 0` diagnostics. `hive new`
  keeps its idea-captured message, while other successful commands now
  render command-specific confirmations such as approve, run, archive,
  status, and findings actions. See [[modules/bot]].
- Changed daemon dispatch-result notices from failure-only feedback to
  bot-originated completion feedback. The daemon now writes an exit-0
  result notice for completed queued bot requests, suppressing only
  intermediate success notices that promote the next command in a hidden
  recovery sequence. See [[modules/daemon]].
