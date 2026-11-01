# 2026-11-01 — Escaped brainstorm answers restore as UTF-8

- `BrainstormParser.restore_answer_line` returned `Base64.urlsafe_decode64`
  bytes as ASCII-8BIT. An escaped answer line (one containing `<!--`, a
  backslash or a heading) that also held non-ASCII text, such as an ellipsis
  next to a quoted `<!-- BEGIN LLM WIKI -->`, made every later `hive answer`
  inventory of the task fail with exit 70 (`JSON::GeneratorError "\xE2" from
  ASCII-8BIT to UTF-8`). The task could not be answered any further.
- Decoded lines are now UTF-8. Bytes that are not valid UTF-8 fall back to the
  literal escaped line, matching the existing fallback for invalid base64.
- Tests: `test/unit/bot/brainstorm_parser_test.rb`.
