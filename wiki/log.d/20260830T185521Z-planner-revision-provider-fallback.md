# 2026-08-30 — Planner revision provider fallback

Plan review now supports an optional, operator-configured planner-revision
fallback route. Hive first tries the captured planner, then moves transient
revision failures to the fallback without changing the logical review or
discarding its findings and decisions. Receipts preserve both identities and
the original failure; bounded attempt series and widening cooldown recovery
remain unchanged.
