## 2026-08-29 — Planner revisions recover cross-provider model identities

**Action:** Fixed plan-author identity capture and legacy recovery after a
Screenote plan revision exposed `provider: codex` paired with the historical
Claude model `claude-opus-4-8`. Provider-neutral plan capture now reads only
the selected provider's legacy controls, uses a provider-default sentinel when
the route is unpinned, and shares one identity builder between live plan runs
and reconstruction. Planner revision renders that durable model/effort pair
through the captured provider's routing arguments instead of borrowing the
current project's unrelated agent settings.

Existing projections with the exact impossible Codex/Claude pairing are
repaired once without rewriting immutable evidence: Hive appends a versioned
planner identity receipt, resets a failed planner-revision series, retains
Codex as the original plan authority, and lets direct approval or daemon
automation retry. Blocked legacy rows are scheduler-owned during this
migration, and planner revision routes now expose their redacted diagnostic in
status evidence.

The same dogfood pass exposed an underspecified initial-review field: the
prompt showed `residual_evidence: []` but did not state that only disposition
verification may populate it. Initial prompts now require the empty array, and
the exact historical parser rejection receives one versioned automatic retry
for primary and adversarial roles without weakening verification attestations.

**Verification:** Focused planner-identity, automation, orchestration,
planner-revision, task-action, and plan-stage tests cover provider-scoped
capture, one-time recovery, daemon reachability, provider-default launch
arguments, and durable diagnostics.
