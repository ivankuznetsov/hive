## [2026-07-20T08:50:28Z] daemon — retry provider-limit holds hourly despite reset estimates

**Action:** Split provider-limit display from scheduling. Complete provider reset dates remain in `retry_after` for status/TUI visibility, but `StaleAgentHealer` now admits review and terminal `limits_reached` rows one configured cooldown interval after the latest quota marker mtime. Repeated walls write a fresh marker and restart the interval; account switches, usage resets, and credit top-ups can therefore recover before the advertised date. Quota readiness attempts no longer consume the bounded task-failure recovery budgets.

**Tests:** Added `Hive::AgentLimit` marker-age eligibility coverage, review/terminal healer coverage for distant/missing/malformed reset hints and retries beyond a one-attempt budget, plus status-to-healer integration proving a five-day provider estimate is retried after one hour. Updated quota-held text to distinguish the provider estimate from Hive's hourly retry policy.

**Uncertainty:** No installed-daemon live replay has yet exercised an early account reset/top-up against a real provider hold, and a same-tick cohort of eligible tasks has not been live load-smoked beyond the daemon's normal concurrency caps; [[gaps]] keeps those boundaries explicit.
