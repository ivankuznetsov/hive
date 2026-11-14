---
title: Patrol Fix prompt states the single-line report contract
type: change
created: 2026-11-14
updated: 2026-11-14
tags: [patrol, patrol-fix, agent-contract, reports]
---

A secret-reworked todero Patrol Fix (`sidebar-more-lists-…-8c075437bb0d`) ran
the Codex fix agent to a passing fix: 912 Ruby, 37 browser, and 78 JavaScript
tests. Hive then rejected the whole report with "fix report command is
invalid". The agent had written its first validation command as a multi-line
script, and `FixReport.string!` rejects any control character. The prompt
asked for commands that "include any dependency or bootstrap setup" but never
stated the single-line rule, and the error named neither the field nor the
rule. A Muse fix failed the same way on 2026-11-06.

- The Fix prompt now states that every report string is one line with no
  control character, tells the agent to chain steps with `&&`, and gives the
  exact key set and byte limits.
- `FixReport` rejections name the field (`validation_commands[1].command`,
  `summary`) and the rule. The validation rules are unchanged.

Tests: `test/unit/patrol_fix/reports_test.rb` (indexed field and rule in the
message, summary newline) and `test/unit/stages/patrol_fix/fix_test.rb` (prompt
contract).
