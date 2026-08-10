## 2026-08-10 — Bind trusted provider evidence to durable attempts

**Action:** Explicit routed workers now execute every provider call with the
attempt's admitted adapter/account binding/model/effort, normalize only exact
structured adapter transport errors, and publish one bounded safe signal over
a capability-bound descriptor separate from stdout/stderr. Supervisor binds a
valid signal to the immutable failed terminal receipt and protected log
reference. Provider health is a named finalization consumer that applies
generation-fenced evidence and probe outcomes before archival or downstream
recovery observation. Legacy no-pool workers receive no descriptor and retain
their existing invocation and `limits_reached` behavior.

**Why:** Raw provider output and embedded role loops cannot safely own shared
health or fallback. The durable enclosing attempt and its terminal receipt are
the existing ownership and fencing boundary.

**Files:** `lib/hive/agent_profiles/error_normalizers.rb`,
`lib/hive/agent_profiles/launch_bindings.rb`,
`lib/hive/attempts/evidence_channel.rb`, `lib/hive/attempts/supervisor.rb`,
`lib/hive/provider_health/attempt_observer.rb`,
`lib/hive/attempts/finalization_maintenance.rb`, and focused lifecycle tests.
