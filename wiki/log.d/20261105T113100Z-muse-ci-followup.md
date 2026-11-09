# 2026-11-05 — Muse CI follow-up

**Action:** Repaired three regressions in the Muse profile change: the generated
configuration-defaults reference now includes Muse's `/ce-plan` mapping; the
Muse setup adapter depends on the public `Hive::AgentSkills` facade rather than
an internal skillpack path; and the web agent-login resource admits `muse` for
create, status, and completion routes.

**Verification:** `test/unit/config_defaults_doc_test.rb`,
`test/unit/component_boundaries_test.rb`, the fresh all-agent setup integration
case, and `web/test/integration/agents_test.rb` pass locally.

**Wiki:** Updated [[modules/config]] and [[commands/web]].
