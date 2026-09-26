# 2026-09-25 — Validate runtime database custody before writer fencing

- Runtime control-plane transactions now open and validate their database
  before deriving the shared writer fence, preserving typed database-custody
  failures for authoritative UsageDb writes.
