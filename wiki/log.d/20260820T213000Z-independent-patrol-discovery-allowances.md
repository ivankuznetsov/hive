## Independent Patrol discovery allowances and current-main Architecture slices

- Replaced the shared UsageDb-backed Patrol launch cap with strict durable
  scheduled-discovery ledgers keyed by stable project ID, UTC date, and engine.
  Ordinary and Architecture Patrol now independently receive 2/4/8/16 launches
  in low/medium/high/ultrapatrol mode; the legacy shared override is inert and
  there are no token budgets.
- Reservations are atomic immediately before discovery provider spawn and
  survive restart. Date-sharded files keep retained clock-rollback evidence
  bounded without rewriting all historical reservations on every launch. Mode
  changes alter headroom without resetting a ledger; provider retry holds are
  durable, lane-specific, and survive UTC rollover.
- Existing attributable current-day discovery telemetry seeds a new ledger once.
  Fix/non-discovery rows are excluded; ambiguous or unavailable legacy evidence
  parks only the affected lane until the next UTC day. UsageDb remains telemetry
  after seeding and cannot create capacity on failure.
- Fix, admission, validation, review, publish, merged-PR Architecture discovery,
  and Architecture actions do not consume scheduled discovery allowance. Fixer
  launches retain completion telemetry without an allowance admission call.
- Each completed daemon operational snapshot projects both lanes' exact limit,
  used, remaining, seed status, and provider retry deadline per stable project.
- Added a separate scheduled Architecture producer that fetches and maps current
  `main` for every claim, advances a stable feature-ID cursor one slice per
  launch, and persists an enumerable exact-SHA result before fix-admission
  outbox publication and cursor advance. A durable coverage-pass generation
  gives later same-SHA sweeps distinct occurrences, while crash replay within
  one pass converges on the same project/SHA/feature occurrence.
- The first-party Architecture Patrol module now documents current-main
  scheduled discovery separately from merged-PR JobStore recovery. Scheduled
  discovery needs repository/state mutation capability but no GitHub mutation
  capability; merged jobs and actions retain their existing permissions.
