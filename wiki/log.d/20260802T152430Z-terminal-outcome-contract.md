# Preserve blocked terminal workflow outcomes

- Added an opt-in `terminal_outcomes` descriptor contract for final agent
  stages, including read-only validation output and strict placement rules.
- Classified the exact bounded first line before completion commit so declared
  blocks and invalid output become durable attributed `ERROR` markers rather
  than archived completion.
- Kept blocked tasks active, visibly labelled, explicitly retryable, and
  operator-owned while excluding semantic terminal errors from daemon
  automatic retry.
