# 2026-07-10 — Grok agent profile

**Action:** Added xAI Grok CLI as a fourth built-in `AgentProfile`. Hive now
delivers prompts with `grok -p <prompt>`, consumes `streaming-json` text chunks
without losing inter-chunk whitespace, supports `XAI_API_KEY`,
`GROK_CODE_XAI_API_KEY`, `GROK_HOME`, and device login, and preserves prompt
delivery when project overrides rebuild the profile. Grok is included in
diagnosis schemas, config defaults, Hivebox login/status, and token-stat rows;
unavailable Grok usage remains nil instead of being recorded as zero.

**Review hardening:** Replaced the 93 KB embedded CE skill snapshot with a
compact, self-contained, report-only reviewer prompt that treats repository
content as untrusted and forbids source edits, commits, and network access.

**Verification:** Added focused tests for exact argv, environment/file auth,
stream chunk concatenation, profile overrides, reviewer rendering, diagnosis,
usage aggregation, schemas, and Hivebox login. Live native Grok skill
resolution and token telemetry remain recorded in [[gaps]].

**Wiki:** Updated [[index]], [[architecture]], [[modules/agent]],
[[modules/agent_profile]], [[modules/config]], [[modules/diagnosis_agent]],
[[commands/status]], [[commands/web]], [[stages/review]], [[token-usage]],
[[decisions]], and [[gaps]].
