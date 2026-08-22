# OpenCode long-session exports remain inspectable

OpenCode completion still requires a sanitized session export correlated to
the terminal assistant message. Hive now captures that export in owner-private
temporary files and accepts it through a 64 MiB bound. The prior 4 MiB pipe
capture was sized for short fixtures, not hour-long implementation and review
sessions whose exports include every tool result; its timed drain could also
surface a truncated capture as malformed JSON under host I/O pressure.

Malformed, over-bound, uncorrelated, or incomplete exports continue to fail
closed. A lifecycle regression test uses a valid export larger than the old
limit and proves actual route evidence and completion survive.
