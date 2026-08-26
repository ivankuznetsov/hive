# Bind Patrol Fix attempts to receipt progress

Patrol Fix durable attempt generation now includes the validated append-only
receipt journal as owner progress alongside the immutable task manifest. A
successful controller run still replays while no receipt has changed, but the
receipt written by that run advances generation so the daemon can admit the
separate stage-transition command.

Previously the run and its following transition had the same task artifact,
stage, and dependency token. The earlier successful attempt therefore remained
the semantic owner forever, leaving ready inbox and fix tasks idle while every
daemon tick reported terminal replay. Focused regressions now pin unchanged
journal replay, receipt-driven advancement, and stable fail-closed tokens for
invalid journals. Worker-side generation validation and recovery generation
resolution consume the same task-owned token, preventing the dispatcher,
worker, and recovery queue from minting incompatible identities.
