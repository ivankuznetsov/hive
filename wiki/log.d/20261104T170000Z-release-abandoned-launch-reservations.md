# 2026-11-04 — Release abandoned launch reservations

- `launch_reservations` rows stayed `reserved` forever when a launcher died
  before registering, or when an attempt wrapper exited before registering.
  Quiescence capability then stayed ineligible with
  `unresolved_launch_reservation` permanently. One install had 27 such rows
  dating back to 2026-09-29.
- `ProcessRegistry#release_abandoned_reservations!` releases a row in two
  cases. An attempt-linked row is released when its attempt has settled
  (`attempt_settled`). Any other row is released when its owner is proven
  missing or mismatched (`owner_gone`). The daemon runs it after attempt
  reconciliation. `hive daemon quiesce` runs it before the entry gate and
  again under the controller writer. A failure leaves the rows reserved, so
  the capability check still refuses.
